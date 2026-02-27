# SQL Server 2022 — PITR with Native Transaction Log Backup to S3

> **⚠️ OPTIONAL**: PITR is a complementary capability — not required for T4K backups. Your T4K snapshots work perfectly without it.
>
> **☁️ S3 ONLY**: The archiving mechanisms described here require S3-compatible object storage (AWS S3, MinIO, Ceph, etc.). NFS and filesystem-based T4K targets are **not supported** for WAL/log archiving.

## The Philosophy

SQL Server 2022 is the **only database in this demo set with native S3-compatible object storage support built in**. No external tool. No sidecar binary. Just a T-SQL statement:

```sql
BACKUP LOG [demodb] TO URL = 's3://your-bucket/sqlserver/logs/log_20260227_143500.bak'
WITH COMPRESSION, STATS = 10;
```

The same layered strategy applies:

```
 Trilio for Kubernetes Snapshot         Trilio for Kubernetes Snapshot
        │                            │
        ▼                            ▼
────────●────────────────────────────●──────────────── time
        └── log backups to S3 every 5min ─────────────►

  RPO without log backups: up to the full backup interval
  RPO with log backups:    ≤ 5 minutes (your log backup interval)
```

Unlike the other three databases where the log shipping is continuous (event-driven), SQL Server uses **scheduled transaction log backups**. This is a deliberate design — SQL Server's Full Recovery model guarantees no committed transaction is lost between log backups, as long as logs are backed up before the log file fills up.

---

## How SQL Server PITR Works

SQL Server PITR is the most mature and well-understood of the four databases. The mechanism:

1. **Full backup** (Trilio for Kubernetes snapshot) — the base restore point.
2. **Differential backups** (optional, skipped in this demo) — cumulative changes since the last full backup.
3. **Transaction log backups** (every N minutes) — sequential, chained chain of log files. **All log backups must be applied in order** — no gaps are allowed.
4. **RESTORE DATABASE ... WITH NORECOVERY** — restores the base.
5. **RESTORE LOG ... WITH STOPAT = '...'** — replays each log file in sequence, stopping at the desired time.

The transaction log chain is the key concept: SQL Server enforces that each log backup picks up exactly where the previous one ended. A single missed log backup breaks the chain and prevents PITR beyond that point.

---

## Native S3 Support in SQL Server 2022

SQL Server 2022 added `s3://` as a valid URL scheme for `BACKUP ... TO URL`, alongside the existing Azure Blob (`https://`) support. It is compatible with any S3-compatible object store: AWS S3, MinIO, Ceph, NetApp StorageGRID, etc.

No additional drivers or extensions are needed. The feature is part of the SQL Server engine itself.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  sqlserver StatefulSet pod                               │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  SQL Server 2022                                    │ │
│  │                                                     │ │
│  │  BACKUP LOG [demodb]                                │ │
│  │    TO URL = 's3://bucket/logs/log_NNN.bak'   ───────┼─┼──► S3
│  │  (run every 5 minutes via CronJob)                  │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         ▲
  CronJob (external to pod)
  fires sqlcmd BACKUP LOG command
```

Unlike the other databases, the archiver runs as a **separate CronJob** (not a sidecar), because SQL Server's `BACKUP LOG ... TO URL` is a self-contained atomic operation — there is nothing to stream continuously. The CronJob fires every 5 minutes, runs the backup, and exits.

---

## Setup

### 1. Create the S3 credentials secret

```bash
kubectl create secret generic sqlserver-s3-backup \
  --from-literal=S3_BUCKET=<your-bucket> \
  --from-literal=S3_REGION=<your-region> \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  --from-literal=SA_PASSWORD="Demo1234!Strong" \
  -n trilio-demo
```

### 2. Configure SQL Server S3 credentials

SQL Server uses its own credential store for S3 access. The init Job in this folder creates the credential inside SQL Server:

```bash
kubectl apply -f sqlserver/pitr/sqlserver-s3-init-job.yaml -n trilio-demo
```

### 3. Deploy the log backup CronJob

```bash
kubectl apply -f sqlserver/pitr/log-backup-cronjob.yaml -n trilio-demo
```

This fires every 5 minutes and runs `BACKUP LOG [demodb] TO URL = 's3://...'`.

---

## Connection to the Trilio for Kubernetes Hook

The `CHECKPOINT` pre-hook creates a clean transaction log boundary at the snapshot point. This is the anchor for the log backup chain:

- The Trilio for Kubernetes snapshot captures the data files after `CHECKPOINT`.
- The first `BACKUP LOG` after the snapshot marks the start of the PITR-recoverable window.
- All subsequent `BACKUP LOG` operations chain from there.

When restoring with PITR:
1. Restore the Trilio for Kubernetes snapshot with `WITH NORECOVERY` (leave DB in restoring state)
2. Apply each log backup from S3 in order with `WITH NORECOVERY`
3. Apply the final log with `WITH STOPAT = '...' RECOVERY` to bring the DB online

---

## PITR Recovery Procedure

### Step 1 — Trilio for Kubernetes restores the namespace

SQL Server starts with data files from the snapshot.

### Step 2 — Put the database in NORECOVERY state

```sql
-- After Trilio for Kubernetes restore, set the database to accept log restores
RESTORE DATABASE [demodb] WITH NORECOVERY;
```

### Step 3 — List available log backups from S3

```sql
-- List objects in S3 to find the log files after the snapshot timestamp
-- (use AWS CLI or S3 console to list: s3://<bucket>/sqlserver/logs/)
```

### Step 4 — Apply transaction log backups in order

```sql
-- Apply each log backup in sequence (adjust filenames to match your S3 objects)
RESTORE LOG [demodb]
  FROM URL = 's3://<bucket>/sqlserver/logs/log_20260227_140000.bak'
  WITH NORECOVERY;

RESTORE LOG [demodb]
  FROM URL = 's3://<bucket>/sqlserver/logs/log_20260227_140500.bak'
  WITH NORECOVERY;

-- Final log: stop at your target time and bring the database online
RESTORE LOG [demodb]
  FROM URL = 's3://<bucket>/sqlserver/logs/log_20260227_141000.bak'
  WITH STOPAT = '2026-02-27 14:08:30',
       RECOVERY;
```

### Step 5 — Verify

```bash
kubectl delete job sqlserver-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f sqlserver/checker/ -n trilio-demo
kubectl logs -f job/sqlserver-consistency-checker -n trilio-demo
```

---

## Production Notes

1. **Log chain integrity**: Never let the transaction log fill up — that forces SQL Server to auto-shrink or truncate, breaking the log chain. Monitor `sys.dm_db_log_space_usage` and alert when log usage exceeds 80%.

2. **Log backup frequency**: Every 5 minutes gives a 5-minute RPO maximum. For near-zero RPO, reduce to 1 minute. For less critical databases, 15 minutes is common.

3. **Credential rotation**: The S3 credential stored inside SQL Server (`CREATE CREDENTIAL`) must be rotated when AWS keys rotate. Automate this with a Job that re-runs the credential creation.

4. **RESTORE sequence**: SQL Server is strict about the restore sequence. If you skip a log file, the restore fails with a clear error. Keep all log files in S3 until the next full backup is verified.

5. **`WITH COMPRESSION`**: Always use compression for log backups. SQL Server's native compression reduces log backup size by 60–80% for typical workloads.

6. **S3 URL credential name**: The credential name in SQL Server must match exactly the S3 host (e.g., `s3.amazonaws.com` or your MinIO endpoint). One credential per S3 endpoint is required.
