# MariaDB 11.4 LTS — Trilio for Kubernetes Backup Demo

## Overview

This demo deploys **MariaDB 11.4 LTS** (InnoDB engine) on Kubernetes, runs a continuous writer, and takes an application-consistent backup using Trilio for Kubernetes. The hook design is deliberately different from the commonly seen `FLUSH TABLES WITH READ LOCK` approach — for good reasons explained below.

---

## Demo Flow

```bash
# STEP 1 — Create namespace and deploy MariaDB
kubectl create namespace trilio-demo
kubectl apply -f deploy/ -n trilio-demo
kubectl rollout status statefulset/mariadb -n trilio-demo

# STEP 2 — Start the continuous writer
kubectl apply -f writer/ -n trilio-demo

# Terminal 2 — confirm rows are being written (keep open during backup)
kubectl logs -f deployment/mariadb-writer -n trilio-demo

# STEP 3 — Edit backupplan.yaml: set target name/namespace, then apply Hook + BackupPlan
#          ⚠️  Do NOT apply the whole trilio/ folder — backup.yaml triggers a backup immediately
kubectl apply -f trilio/hook.yaml -n trilio-demo
kubectl apply -f trilio/backupplan.yaml -n trilio-demo

# STEP 4 — Verify BackupPlan is Available and hook is registered
kubectl get backupplan mariadb-backupplan -n trilio-demo
kubectl get backupplan mariadb-backupplan -o jsonpath='{.spec.hookConfig}' -n trilio-demo

# STEP 5 — Trigger the backup (writer keeps running throughout)
kubectl apply -f trilio/backup.yaml -n trilio-demo
kubectl get backup mariadb-demo-backup -n trilio-demo -w

# STEP 6 — Simulate disaster
kubectl delete namespace trilio-demo

# STEP 7 — Restore via T4K (UI or CLI), then run consistency checker
kubectl delete job mariadb-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/mariadb-consistency-checker -n trilio-demo
```

---

## Hook Rationale

### Why NOT `FLUSH TABLES WITH READ LOCK` (FTWRL)?

This is the most important question — and the answer is specific to how Trilio for Kubernetes executes hooks.

`FLUSH TABLES WITH READ LOCK` acquires a **session-scoped global read lock**. The lock is held by the MySQL connection that issued it and is **automatically released when that connection closes**. There is no way to hold a FTWRL lock after the mysql client exits.

Trilio for Kubernetes's hook executor works like this:

```
Pre-hook command runs → command completes → lock released → SNAPSHOT TAKEN
```

By the time Trilio for Kubernetes takes the volume snapshot, the FTWRL lock is already gone. The lock never overlaps with the snapshot. Using FTWRL gives a false sense of security — you pay the cost of blocking all writes during the lock, but gain nothing in terms of snapshot consistency.

> This is a common mistake in MariaDB/MySQL backup hook documentation that was written for backup tools (like Velero with async hooks) where the hook keeps running in the background during the snapshot. Trilio for Kubernetes hooks run synchronously to completion before the snapshot.

### Why `FLUSH TABLES` + `FLUSH BINARY LOGS` instead?

**InnoDB is crash-safe by design.** It uses a redo log (transaction log) to guarantee that any crash — including a sudden volume snapshot — can be recovered to a consistent state:

- Committed transactions that weren't flushed to data files are re-applied from the redo log.
- Uncommitted transactions are rolled back.

This means a volume snapshot of InnoDB is always recoverable, with or without a lock. The lock was never providing consistency — InnoDB's redo log was.

`FLUSH TABLES` contributes by:
- Writing all dirty pages from the InnoDB buffer pool to the `.ibd` data files.
- Closing all open tables and flushing the table cache.
- After this, the data files are as up-to-date as possible, minimizing the redo log replay needed at recovery time.

`FLUSH BINARY LOGS` contributes by:
- Closing the current binary log file and opening a fresh one.
- Creating a clean, identifiable boundary for Point-In-Time Recovery.

### What about MyISAM tables?

MyISAM does NOT have crash recovery. If your database has MyISAM tables, a lock must be held during the snapshot to prevent corruption. In that case, the right approach requires a persistent background process that holds the FTWRL — a more complex setup not covered in this demo. For any modern production MariaDB deployment, migrating MyISAM tables to InnoDB is strongly recommended.

### Summary

| Hook | Command | Purpose |
|---|---|---|
| Pre | `FLUSH TABLES` | Flush InnoDB buffer pool to disk |
| Pre | `FLUSH BINARY LOGS` | Create a clean binary log boundary |
| Post | `FLUSH BINARY LOGS` | Mark end of backup window in binary log |

---

## Production Usage Notes

1. **InnoDB only**: This hook is designed for InnoDB tables. Verify with `SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'your_db';`.

2. **Credentials**: Uses `MYSQL_PWD` environment variable — credentials do not appear in process lists (`ps aux`).

3. **`--connect-timeout=10`**: Added to avoid the hook hanging if MariaDB is temporarily unreachable during connection setup.

4. **Timeout**: `timeoutSeconds: 60` covers both commands. On large databases with many dirty pages, `FLUSH TABLES` can take several seconds. Monitor with `SHOW ENGINE INNODB STATUS\G` to understand your buffer pool flush time.

5. **Binary logs**: `FLUSH BINARY LOGS` only works if binary logging is enabled (`log_bin=ON`). If your MariaDB does not use binary logs, remove `FLUSH BINARY LOGS` from both hooks — `FLUSH TABLES` alone is sufficient.

6. **MariaDB BACKUP STAGE (advanced)**: MariaDB 10.4.2+ offers `BACKUP STAGE` commands for finer-grained quiescing. These have the same session-scope limitation as FTWRL when used with Trilio for Kubernetes's synchronous hook model. `FLUSH TABLES` is simpler and equally effective for InnoDB.

---

## Files

```
mariadb/
├── deploy/
│   ├── 00-secret.yaml
│   ├── 01-statefulset.yaml     MariaDB 11.4 LTS with 5Gi PVC
│   └── 02-service.yaml
├── writer/
│   ├── writer-configmap.yaml
│   └── writer-deployment.yaml
├── checker/
│   └── consistency-checker-job.yaml
└── trilio/
    ├── hook.yaml               pre: FLUSH TABLES + FLUSH BINARY LOGS
    ├── backupplan.yaml         (edit target name/namespace)
    └── backup.yaml
```
