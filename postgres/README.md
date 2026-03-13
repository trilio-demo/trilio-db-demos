# PostgreSQL 17 — Trilio for Kubernetes Backup Demo

## Overview

This demo deploys **PostgreSQL 17** on Kubernetes, runs a time-limited writer Job (10,000 rows, ~2.7h at 1 row/sec), and takes an application-consistent backup using Trilio for Kubernetes hooks. The consistency checker runs **twice** — before restore (to measure any write stalls during the backup window) and after restore (to verify data integrity).

---

## Demo Flow

```bash
# STEP 1 — Create namespace and deploy PostgreSQL
kubectl create namespace trilio-demo
kubectl apply -f deploy/ -n trilio-demo
kubectl rollout status statefulset/postgres -n trilio-demo

# STEP 2 — Start the writer Job (writes 10,000 rows then exits automatically)
kubectl apply -f writer/ -n trilio-demo

# Watch rows being written (optional, Ctrl+C safe — job keeps running)
kubectl logs -f job/postgres-writer -n trilio-demo

# STEP 3 — Edit backupplan.yaml: set target name/namespace, then apply Hook + BackupPlan
#          ⚠️  Do NOT apply the whole trilio/ folder — backup.yaml triggers a backup immediately
kubectl apply -f trilio/hook.yaml -n trilio-demo
kubectl apply -f trilio/backupplan.yaml -n trilio-demo

# STEP 4 — Verify BackupPlan is Available and hook is registered
kubectl get backupplan postgres-backupplan -n trilio-demo
kubectl get backupplan postgres-backupplan -o jsonpath='{.spec.hookConfig}' -n trilio-demo

# STEP 5 — Trigger the backup (writer keeps running throughout)
kubectl apply -f trilio/backup.yaml -n trilio-demo
kubectl get backups.triliovault.trilio.io postgres-demo-backup -n trilio-demo -w

# STEP 6 — Run the checker BEFORE restore (read-only, safe to run anytime)
#          This shows the latency baseline and any write stalls during the backup window
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/postgres-consistency-checker -n trilio-demo

# STEP 7 — Simulate disaster (delete StatefulSet + PVC — data is physically gone)
kubectl delete statefulset postgres -n trilio-demo
kubectl delete pvc postgres-data-postgres-0 -n trilio-demo

# STEP 8 — In-place restore (namespace is preserved — no need to reconfigure target)
kubectl apply -f trilio/restore.yaml -n trilio-demo
kubectl get restores.triliovault.trilio.io -n trilio-demo -w

# STEP 9 — Run consistency checker after restore and compare with baseline
kubectl delete job postgres-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/postgres-consistency-checker -n trilio-demo
```

### Expected writer output

The writer is a **Job** — it writes 10,000 rows then exits cleanly. No need to kill it.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Trilio for Kubernetes Database Backup Demo — PostgreSQL Writer
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Host      : postgres-service:5432
  Database  : demodb
  Interval  : 1s per row
  Target    : 10000 rows then exit
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Connected to PostgreSQL!
📋 Table 'writes_log' ready.
📝 Writing 10000 rows from seq #1 at 1s/row.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-02-27 10:00:01 UTC]  Row #1       seq=1         OK
[2026-02-27 10:00:02 UTC]  Row #2       seq=2         OK
...
[2026-02-27 10:01:45 UTC]  Row #105     seq=105       OK  ← backup happening here
[2026-02-27 10:01:46 UTC]  Row #106     seq=106       OK  ← writes continue uninterrupted
...
✅ Writer complete — 10000 rows written. Job done.
```

### Expected checker output

The checker runs **twice**: once before restore (latency baseline) and once after (integrity check). Both reports should match.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Trilio for Kubernetes — PostgreSQL Backup Consistency & Latency Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 WRITE SUMMARY
   Total rows       : 10000
   Sequence range   : 1 → 10000 (expected 10000)
   First write      : 2026-02-27 10:00:01 UTC
   Last write       : 2026-02-27 12:46:41 UTC

─── ① Gap Check ─────────────────────────────────────────────────────
   ✅ PASSED — No missing sequence numbers. Backup was crash-consistent.

─── ② Write Latency (inter-row intervals) ───────────────────────────
   Expected interval : ~1000ms  (1 row/sec)
   p50               : 1001ms
   p95               : 1089ms
   p99               : 2341ms
   max               : 4210ms

─── ③ Write Stalls (interval > 2× expected = >2000ms) ───────────────
   ⚠️  Stalls detected (rows where write was delayed >2s):
   seq_num     time              interval
   ──────────  ────────────────  ──────────
   4821        10:41:03.142      4210ms   ← coincides with CHECKPOINT hook
   4822        10:41:07.353      2341ms

─── ④ Write Rate Timeline (rows per 10-second bucket) ───────────────
   (a dip here during the backup window shows hook/snapshot impact)

   10:39:00  ██████████  10 rows
   10:39:10  ██████████  10 rows
   10:39:20  ██████       6 rows  ← backup window (CHECKPOINT + snapshot)
   10:39:30  ██████████  10 rows
   10:39:40  ██████████  10 rows

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅  OVERALL: PASSED — data is complete and consistent
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Hook Rationale

### Why `CHECKPOINT` for the pre-hook?

PostgreSQL uses a **Write-Ahead Log (WAL)** architecture. Every change is first written to the WAL before being applied to the actual data files. The data files may lag behind the WAL — this is intentional for performance.

A `CHECKPOINT` event does two things:
1. Flushes all **dirty pages** from the shared buffer pool to the data files on disk.
2. Writes a **checkpoint record** to the WAL, marking the point where all in-flight changes are guaranteed to be on disk.

After a `CHECKPOINT`, the data files on disk represent a **complete, consistent database state**. A volume snapshot taken at this point can be recovered by PostgreSQL's crash recovery mechanism — even if the snapshot captures some mid-transaction WAL records, crash recovery will resolve them correctly.

**No lock is needed.** PostgreSQL's WAL guarantees that any snapshot can be made consistent. The `CHECKPOINT` simply ensures the snapshot starts from the cleanest possible point, minimizing recovery time.

### What happens to transactions between CHECKPOINT and the snapshot?

The database keeps running normally in that gap. Any transactions that commit write their changes to the **WAL on disk first** — that is the entire point of Write-Ahead Logging. The snapshot captures the whole PVC, which includes both the data files and the WAL files.

When PostgreSQL starts after a restore, it enters crash recovery and replays the WAL forward from the last checkpoint. Any transaction that committed before the snapshot was taken will have a commit record in the captured WAL, so it gets replayed and recovered. Any transaction that was still in-flight when the snapshot was taken has no commit record, so crash recovery ignores it — exactly as if the server had crashed mid-transaction.

On a busy database this means hundreds of transactions may commit between the CHECKPOINT and the snapshot — all of them are recovered via WAL replay. The only data that cannot be recovered is transactions that committed *after* the snapshot was taken, which is the definition of RPO for any backup system.

```
CHECKPOINT ──── [transactions keep committing] ──── SNAPSHOT
               ↑                                    ↑
               WAL records these to disk             Snapshot captures WAL + data files
               They are recovered on restore         Post-snapshot commits are lost
```

### Why `pg_switch_wal()` for the post-hook?

After the snapshot is complete, `pg_switch_wal()` forces a switch to a new WAL segment file. This creates a **clean boundary** in the WAL stream at the exact point the backup was taken. If you later use Point-In-Time Recovery (PITR) to restore to the moment of the backup, you know exactly which WAL segment the backup covers.

This is a non-disruptive operation — running transactions are not affected.

### Recovering with WAL archiving (WAL-G + S3)

If you are archiving WAL segments to S3 using WAL-G, a T4K restore alone is not enough to reach a point in time beyond the snapshot. Recovery works in two phases:

1. **T4K restores the base** — the PVC is recreated from the snapshot. PostgreSQL enters crash recovery and replays the local WAL captured inside the snapshot, reaching the exact state at snapshot time.
2. **WAL-G replays from S3** — if you configure `restore_command`, PostgreSQL keeps fetching WAL segments from S3 and replaying them until it reaches your `recovery_target_time`.

The `pg_switch_wal()` post-hook is what makes the boundary between these two phases clean: it forces the WAL segment at snapshot time to be archived to S3 immediately, so there is no gap between what the snapshot contains and what S3 has.

See [`pitr/README.md`](pitr/README.md) for the full setup and step-by-step recovery procedure.

### Why NOT `pg_start_backup()` / `pg_stop_backup()`?

`pg_start_backup()` was designed for **pg_basebackup** — a file-level streaming replication backup that copies data files while the server is running. It forces a CHECKPOINT, creates a backup label file, and enters a special backup mode that keeps all generated WAL until `pg_stop_backup()` is called.

Trilio for Kubernetes uses **volume-level snapshots**, not file-level copies. The snapshot mechanism is atomic (at the storage layer), so `pg_start_backup()` is unnecessary and would leave the server in a backup mode that must be manually exited.

### Summary

| Hook | Command | Purpose |
|---|---|---|
| Pre | `CHECKPOINT` | Flush buffer pool and WAL to disk |
| Post | `SELECT pg_switch_wal()` | Mark clean WAL boundary for PITR |

---

## Production Usage Notes

These hooks are production-safe. Before deploying:

1. **Permissions**: The database user (`POSTGRES_USER`) must have the `CHECKPOINT` privilege. In PostgreSQL 17, `CHECKPOINT` requires superuser or `pg_checkpoint` role. Grant it with: `GRANT pg_checkpoint TO your_backup_user;`

2. **Timeout**: `timeoutSeconds: 60` is conservative. On a heavily loaded system with large buffers, CHECKPOINT can take longer. Monitor your `pg_stat_bgwriter` to tune this.

3. **Credentials**: The hook reads `$POSTGRES_PASSWORD` from the container's environment (injected by the Secret). No credentials appear in process lists.

4. **`pg_switch_wal()` failure**: The post-hook has `ignoreFailure: true` because the snapshot is already complete at that point. A WAL switch failure does not affect backup integrity.

5. **`PGDATA` subpath**: This StatefulSet uses `PGDATA=/var/lib/postgresql/data/pgdata` (a subdirectory) to avoid a known issue with the official `postgres` Docker image and mounted volumes. Do not change this.

---

## Files

```
postgres/
├── deploy/
│   ├── 00-secret.yaml          Credentials (edit before use)
│   ├── 01-statefulset.yaml     PostgreSQL 17 StatefulSet with 5Gi PVC
│   └── 02-service.yaml         Headless + ClusterIP services
├── writer/
│   ├── writer-configmap.yaml               Standard writer script (Python, 1 row/sec, 10k rows)
│   ├── writer-configmap-highpressure.yaml  High-pressure writer script (Python+pip, batch=10, 50k rows)
│   ├── writer-job.yaml                     Job manifest (standard)
│   └── writer-job-highpressure.yaml        Job manifest (high-pressure)
├── checker/
│   ├── checker-configmap.yaml              Checker script (gap check, latency, timeline)
│   └── consistency-checker-job.yaml        Job manifest
└── trilio/
    ├── hook.yaml               Trilio for Kubernetes Hook CR (pre: CHECKPOINT, post: pg_switch_wal)
    ├── backupplan.yaml         BackupPlan CR (edit target name/namespace)
    ├── backup.yaml             Backup CR (trigger a backup)
    └── restore.yaml            Restore CR for individual DB in-place restore
```
