# SQL Server 2022 — Trilio for Kubernetes Backup Demo

## Overview

This demo deploys **Microsoft SQL Server 2022** on Kubernetes and demonstrates volume-snapshot-based backup using Trilio for Kubernetes. SQL Server is arguably the most snapshot-friendly of the four databases in this demo — it was designed with VSS (Volume Shadow Copy Service) in mind from the beginning.

---

## Requirements

SQL Server has stricter infrastructure requirements than the other databases:

- Minimum **2 GB RAM** available for the SQL Server pod (4 GB recommended)
- PVC of at least **10 GB** (SQL Server system databases alone consume ~700 MB)
- The EULA must be accepted (`ACCEPT_EULA: Y` is set in the manifests)

---

## Demo Flow

```bash
# STEP 1 — Create namespace and deploy SQL Server
#          SQL Server takes 30–60s to initialize — wait for ready before proceeding
kubectl create namespace trilio-demo

# OpenShift only: SQL Server requires UID/GID 10001 — grant anyuid SCC
oc adm policy add-scc-to-user anyuid -z default -n trilio-demo

kubectl apply -f deploy/ -n trilio-demo
kubectl rollout status statefulset/sqlserver -n trilio-demo

# STEP 2 — Start the continuous writer (standard: 1 row/sec, 10,000 rows)
kubectl apply -f writer/writer-configmap.yaml -n trilio-demo
kubectl apply -f writer/writer-job.yaml -n trilio-demo

# Terminal 2 — confirm rows are being written (keep open during backup)
kubectl logs -f job/sqlserver-writer -n trilio-demo

# STEP 3 — Edit backupplan.yaml: set target name/namespace, then apply Hook + BackupPlan
#          ⚠️  Do NOT apply the whole trilio/ folder — backup.yaml triggers a backup immediately
kubectl apply -f trilio/hook.yaml -n trilio-demo
kubectl apply -f trilio/backupplan.yaml -n trilio-demo

# STEP 4 — Verify BackupPlan is Available and hook is registered
kubectl get backupplan sqlserver-backupplan -n trilio-demo
kubectl get backupplan sqlserver-backupplan -o jsonpath='{.spec.hookConfig}' -n trilio-demo

# STEP 5 — Trigger the backup (writer keeps running throughout)
kubectl apply -f trilio/backup.yaml -n trilio-demo
kubectl get backups.triliovault.trilio.io sqlserver-demo-backup -n trilio-demo -w

# STEP 6 — Run checker BEFORE restore (read-only, safe to run anytime)
#          This shows the latency baseline and any write stalls during the backup window
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/sqlserver-consistency-checker -n trilio-demo

# STEP 7 — Simulate disaster (delete StatefulSet + PVC — data is physically gone)
kubectl delete statefulset sqlserver -n trilio-demo
kubectl delete pvc sqlserver-data-sqlserver-0 -n trilio-demo

# STEP 8 — In-place restore (namespace is preserved — no need to reconfigure target)
kubectl apply -f trilio/restore.yaml -n trilio-demo
kubectl get restores.triliovault.trilio.io -n trilio-demo -w

# STEP 9 — Run consistency checker after restore and compare with baseline
kubectl delete job sqlserver-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f checker/ -n trilio-demo
kubectl logs -f job/sqlserver-consistency-checker -n trilio-demo
```

> **Automated path:** `test.sh` at the repo root runs the full deploy → backup → restore → check workflow for all 4 databases with a single command. See [shared/README.md](../shared/README.md).

---

## Hook Rationale

### SQL Server and VSS

SQL Server 2022 is designed to work with **VSS (Volume Shadow Copy Service)**, Microsoft's framework for creating consistent point-in-time copies of data. When a VSS snapshot is requested, SQL Server automatically:

1. Freezes I/O to the database files momentarily
2. Allows the snapshot to be taken
3. Resumes I/O

Trilio for Kubernetes's volume snapshot mechanism triggers storage-level snapshots, which are consistent with SQL Server's crash recovery architecture even without an explicit VSS call. A CHECKPOINT before the snapshot simply reduces the recovery work needed.

### Why `CHECKPOINT` is the right pre-hook

`CHECKPOINT` is a standard SQL Server operation that writes all dirty pages from the buffer pool cache to the database data files. After a CHECKPOINT:

- The data files (`.mdf`, `.ndf`) are as current as possible
- The transaction log (`.ldf`) has a clear checkpoint record
- If the server were to restart using this data, minimal transaction log replay would be needed

This is sufficient for Trilio for Kubernetes because SQL Server's transaction log guarantees that any snapshot is recoverable to a consistent state. SQL Server performs this recovery automatically on startup — there is no manual intervention needed after a restore.

### Full Recovery Model

The writer creates the database with `RECOVERY FULL`. This is important for two reasons:

1. **All transaction log records are kept** until a log backup is taken, enabling Point-In-Time Recovery.
2. **The transaction log never auto-truncates**, so you have a complete record of all changes made after the snapshot.

In production, you would schedule regular transaction log backups in addition to Trilio for Kubernetes full backups, giving you the ability to recover to any point in time between snapshots.

### Why no lock is needed

SQL Server uses **write-ahead logging** (WAL). Every change is written to the transaction log before being applied to the data pages. This architectural guarantee means:

- Any snapshot of the data files can be recovered using the transaction log
- Uncommitted transactions at the time of the snapshot are automatically rolled back
- Committed transactions not yet flushed to data files are replayed from the log

A volume snapshot of SQL Server is always crash-consistent, with or without a pre-hook. The `CHECKPOINT` pre-hook optimizes this by minimizing the amount of log replay needed.

### Summary

| Hook | Command | Purpose |
|---|---|---|
| Pre | `CHECKPOINT` | Flush buffer pool to data files |
| Post | `CHECKPOINT` | Optional: clean boundary post-snapshot |

### What happens to transactions between the pre-hook and the snapshot?

The story here is essentially the same as PostgreSQL. SQL Server uses write-ahead logging — every committed transaction is written to the transaction log (`.ldf`) before the data pages are modified. After `CHECKPOINT`, writes keep coming. Any transaction that commits in the gap between CHECKPOINT and snapshot has its log records captured in the snapshot.

When SQL Server starts after a restore, it runs automatic crash recovery: it reads the transaction log forward from the last checkpoint, replays committed transactions whose data pages weren't yet written to disk, and rolls back any in-flight transactions with no commit record. No manual steps are needed — this happens automatically before SQL Server opens for connections.

```
CHECKPOINT ──── [transactions keep committing] ──── SNAPSHOT
                ↑                                    ↑
                Transaction log records these         Snapshot captures log + data files
                They are recovered on restore         Post-snapshot commits are lost
```

On a busy database, many transactions may commit between CHECKPOINT and snapshot. All are recovered via log replay. The CHECKPOINT reduces recovery time by establishing a recent starting point, but correctness is guaranteed by the transaction log regardless.

### Recovering with transaction log backups (native S3)

SQL Server 2022 has native S3 support — no external tool needed. If you are taking regular `BACKUP LOG ... TO URL` transaction log backups, a T4K restore alone recovers you to the snapshot point. To recover to a later point:

1. **T4K restores the base** — the PVC is recreated. SQL Server runs automatic crash recovery and reaches the state at snapshot time.
2. **Transaction log restore** — apply each `BACKUP LOG` file in sequence using `RESTORE LOG ... WITH NORECOVERY`, finishing with `RESTORE LOG ... WITH RECOVERY, STOPAT = '...'` to reach your exact target time.

See [`pitr/README.md`](pitr/README.md) for the full setup and step-by-step recovery procedure.

---

## Production Usage Notes

1. **SA account**: This demo uses the SA (system administrator) account. In production, create a dedicated backup user with minimal required permissions: `EXECUTE` on `sys.sp_executesql`, membership in `db_backupoperator`.

2. **Password complexity**: SQL Server enforces strict password complexity (uppercase, lowercase, digit, special character, min 8 chars). The SA_PASSWORD in the secret must meet these requirements.

3. **ACCEPT_EULA**: SQL Server requires explicit EULA acceptance. Ensure your organization's licensing is appropriate for the SQL Server edition (`MSSQL_PID`). `Developer` is free for non-production use.

4. **Memory**: SQL Server aggressively uses available memory for its buffer pool. The `limits.memory: 4Gi` in the StatefulSet caps this. In production, set `sp_configure 'max server memory'` to leave headroom for the OS.

5. **`-No` flag**: The `sqlcmd -No` flag disables server certificate validation for TLS. In production, configure proper TLS certificates and remove this flag.

6. **Transaction log backups**: For production use with Full Recovery model, schedule regular `BACKUP LOG` operations to prevent the transaction log from growing unboundedly.

7. **Windows Authentication**: This demo uses SQL Authentication (username/password). In production Kubernetes environments, consider using SQL Server's support for Azure AD or Active Directory authentication.

---

## Files

```
sqlserver/
├── deploy/
│   ├── 00-secret.yaml
│   ├── 01-statefulset.yaml     SQL Server 2022 with 10Gi PVC, 2Gi RAM minimum
│   └── 02-service.yaml
├── writer/
│   ├── writer-configmap.yaml
│   └── writer-deployment.yaml
├── checker/
│   └── consistency-checker-job.yaml
└── trilio/
    ├── hook.yaml               pre: CHECKPOINT, post: CHECKPOINT
    ├── backupplan.yaml         (edit target name/namespace)
    └── backup.yaml
```
