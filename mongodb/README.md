# MongoDB 8.0 — Trilio for Kubernetes Backup Demo

## Overview

This demo deploys **MongoDB 8.0** (WiredTiger engine) on Kubernetes and demonstrates the strongest consistency guarantee of all four database demos: MongoDB's `fsyncLock` persists across sessions, meaning the write lock is **still active when Trilio for Kubernetes takes the volume snapshot**.

---

## Demo Flow

```bash
# STEP 1 — Create namespace and deploy MongoDB
kubectl create namespace trilio-demo
kubectl apply -f deploy/ -n trilio-demo
kubectl rollout status statefulset/mongodb -n trilio-demo

# STEP 2 — Start the continuous writer
kubectl apply -f writer/ -n trilio-demo

# Terminal 2 — confirm rows are being written (keep open during backup)
kubectl logs -f deployment/mongodb-writer -n trilio-demo

# STEP 3 — Edit backupplan.yaml: set target name/namespace, then apply Hook + BackupPlan
#          ⚠️  Do NOT apply the whole trilio/ folder — backup.yaml triggers a backup immediately
kubectl apply -f trilio/hook.yaml -n trilio-demo
kubectl apply -f trilio/backupplan.yaml -n trilio-demo

# STEP 4 — Verify BackupPlan is Available and hook is registered
kubectl get backupplan mongodb-backupplan -n trilio-demo
kubectl get backupplan mongodb-backupplan -o jsonpath='{.spec.hookConfig}' -n trilio-demo

# STEP 5 — Trigger the backup (writer will briefly pause during snapshot — this is expected)
kubectl apply -f trilio/backup.yaml -n trilio-demo
kubectl get backups.triliovault.trilio.io mongodb-demo-backup -n trilio-demo -w

# STEP 6 — Simulate disaster
kubectl delete namespace trilio-demo

# STEP 7 — Restore via T4K (UI or CLI), then run consistency checker
kubectl delete job mongodb-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/mongodb-consistency-checker -n trilio-demo
```

### What you will see during the backup

Unlike PostgreSQL and MariaDB (where writes continue uninterrupted), with MongoDB the writer **will briefly pause** during the snapshot window. This is expected — it means the write lock is working. The MongoDB driver queues the writes, and they resume immediately when the post-hook calls `fsyncUnlock`. No writes are lost.

```
[10:01:44 UTC]  Doc #104     seq=104       OK
[10:01:45 UTC]  Doc #105     seq=105       OK
[10:01:46 UTC]  ERROR writing doc #106 — retrying in 3s...   ← lock active, snapshot happening
[10:01:49 UTC]  ERROR writing doc #106 — retrying in 3s...   ← still locked
[10:01:52 UTC]  Doc #106     seq=106       OK                ← lock released by post-hook
[10:01:53 UTC]  Doc #107     seq=107       OK
```

The consistency checker will confirm **zero gaps** — row 106 was not lost, just delayed.

---

## Hook Rationale

### MongoDB fsyncLock — the key difference

MongoDB's `db.adminCommand({fsync:1, lock:true})` is fundamentally different from MariaDB's `FLUSH TABLES WITH READ LOCK` in one critical way:

**MongoDB's fsyncLock is GLOBAL, not session-scoped.**

| Mechanism | Scope | Survives connection close? |
|---|---|---|
| MariaDB `FLUSH TABLES WITH READ LOCK` | Per-session | ❌ No — lock released on disconnect |
| MongoDB `db.adminCommand({fsync:1, lock:true})` | Global | ✅ Yes — persists until fsyncUnlock |

This means:
1. Pre-hook runs → `fsync:1` flushes WiredTiger cache to disk
2. Pre-hook runs → `lock:true` acquires a global write lock
3. Pre-hook command exits (mongosh closes)
4. **Lock is still held** ← this is the key
5. Trilio for Kubernetes takes the volume snapshot — **database is frozen**
6. Post-hook runs → `fsyncUnlock:1` releases the lock
7. Writes resume

This is the only hook in this demo set that provides a true "frozen" state during the snapshot. The other databases rely on crash recovery to produce a consistent state; MongoDB takes it a step further with an actual write barrier.

### WiredTiger and crash recovery

Even without `fsyncLock`, MongoDB's WiredTiger engine uses a journal (write-ahead log) for crash recovery, similar to PostgreSQL's WAL and InnoDB's redo log. A snapshot without locking would be recoverable. The `fsyncLock` adds a layer of strictness: it guarantees not just that the snapshot is recoverable, but that it represents a point in time where no writes were in flight.

### Why `ignoreFailure: false` on the post-hook?

If `fsyncUnlock` fails, the database remains permanently locked — writes are blocked until the lock is manually released. This is a critical failure state. Setting `ignoreFailure: false` ensures Trilio for Kubernetes reports a failure and alerts operators if the unlock does not succeed. The `maxRetryCount: 3` gives extra attempts to unlock before giving up.

To manually unlock a stuck database: `mongosh --eval "db.adminCommand({fsyncUnlock:1})"`

### Summary

| Hook | Command | Purpose |
|---|---|---|
| Pre | `{fsync:1, lock:true}` | Flush WiredTiger cache + acquire global write lock |
| Post | `{fsyncUnlock:1}` | Release the global write lock |

---

## Production Usage Notes

1. **Replica Sets**: In a replica set, `fsyncLock` must be run on **each replica separately** if you need the entire set locked. For a single-node primary (as in this demo), one lock is sufficient.

2. **Sharded Clusters**: For a sharded MongoDB, you must lock each shard's primary independently. This demo deploys a standalone (non-sharded) node.

3. **Lock check**: Verify the lock status with `db.currentOp()` — look for a `fsyncLock: true` field.

4. **Credentials**: URI-embedded credentials are used for simplicity in the hook command. In production, consider using MongoDB's `--authenticationDatabase` with a dedicated backup user that has the `fsync` privilege.

5. **Snapshot duration**: The write lock is held for the entire duration of the volume snapshot. For large volumes, this can be several seconds to minutes. Ensure your `timeoutSeconds` on the post-hook is generous enough to cover snapshot completion plus the unlock call.

6. **MongoDB Ops Manager / Atlas**: For managed MongoDB, use the platform's native snapshot capabilities instead of this hook approach.

---

## Files

```
mongodb/
├── deploy/
│   ├── 00-secret.yaml
│   ├── 01-statefulset.yaml     MongoDB 8.0 with 5Gi PVC
│   └── 02-service.yaml
├── writer/
│   ├── writer-configmap.yaml
│   └── writer-deployment.yaml
├── checker/
│   └── consistency-checker-job.yaml
└── trilio/
    ├── hook.yaml               pre: fsyncLock, post: fsyncUnlock
    ├── backupplan.yaml         (edit target name/namespace)
    └── backup.yaml
```
