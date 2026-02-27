# MariaDB — PITR with Binary Log Archiving + Trilio for Kubernetes

> **⚠️ OPTIONAL**: PITR is a complementary capability — not required for T4K backups. Your T4K snapshots work perfectly without it.
>
> **☁️ S3 ONLY**: The archiving mechanisms described here require S3-compatible object storage (AWS S3, MinIO, Ceph, etc.). NFS and filesystem-based T4K targets are **not supported** for WAL/log archiving.

## The Philosophy

The same layered strategy applies to MariaDB. Trilio for Kubernetes restores the namespace to a running state (the base). Binary log archiving replays every transaction committed after that snapshot, up to the exact second you choose.

```
 Trilio for Kubernetes Snapshot         Trilio for Kubernetes Snapshot
        │                            │
        ▼                            ▼
────────●────────────────────────────●──────────────── time
        └─── binary logs to S3 ─────►└─── binary logs ►

  RPO without log archiving: up to the full backup interval
  RPO with binary log archiving: seconds
```

MariaDB's equivalent of PostgreSQL's WAL is the **binary log** (binlog). Every committed transaction is written to the binary log before the client receives confirmation. Shipping these log files to S3 continuously gives you the same PITR capability.

---

## The Tool

Unlike PostgreSQL where WAL-G is the clear leader, MariaDB has two practical options for Kubernetes:

### Option A — WAL-G MySQL adapter (recommended)

WAL-G supports MySQL/MariaDB via its MySQL backend. It archives binary log files to S3 with compression, encryption, and retention management — the same tool, the same philosophy as the PostgreSQL case.

### Option B — Custom binlog archiver sidecar

A simpler approach: a sidecar that runs `mysqlbinlog` to stream new binary log events and pipes them to `aws s3 cp`. Less feature-rich than WAL-G but zero external dependencies beyond the AWS CLI.

The manifests in this folder use **Option A (WAL-G)** as it provides proper retention management, encryption support, and a consistent operator experience across databases.

---

## Prerequisites

- Binary logging must be enabled on MariaDB. The StatefulSet patch adds a `my.cnf` ConfigMap that enables `log_bin`.
- An S3 bucket for binary log storage.
- AWS credentials as a Kubernetes Secret.

### Enable binary logging

Binary logging is not enabled by default in the MariaDB Docker image. The `mariadb-binlog-configmap.yaml` in this folder provides a `my.cnf` snippet that enables it. Apply the patch to the StatefulSet to mount it.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  mariadb StatefulSet pod                             │
│                                                      │
│  ┌────────────────┐    ┌────────────────────────┐   │
│  │  mariadb:11.4  │    │  wal-g sidecar         │   │
│  │                │    │                        │   │
│  │  log_bin = ON  │    │  polls for new binlog  │──►│──► S3 bucket
│  │  binlog files  │───►│  files and pushes them │   │    /binlogs/
│  └────────────────┘    └────────────────────────┘   │
│           │                                          │
│    /var/lib/mysql (shared volume)                    │
└─────────────────────────────────────────────────────┘
```

The sidecar polls the MariaDB data directory for new binary log files and pushes them to S3 using WAL-G's MySQL binlog push command.

---

## Setup

### 1. Create the WAL-G configuration secret

```bash
kubectl create secret generic walg-config-mariadb \
  --from-literal=WALG_S3_PREFIX=s3://<your-bucket>/mariadb/binlogs \
  --from-literal=AWS_REGION=<your-region> \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  -n trilio-demo
```

### 2. Apply the binary logging ConfigMap

```bash
kubectl apply -f mariadb/pitr/mariadb-binlog-configmap.yaml -n trilio-demo
```

### 3. Apply the sidecar patch

```bash
kubectl patch statefulset mariadb -n trilio-demo \
  --patch-file mariadb/pitr/walg-sidecar-statefulset-patch.yaml
```

---

## Connection to the Trilio for Kubernetes Hook

The `FLUSH BINARY LOGS` calls in both the Trilio for Kubernetes pre-hook and post-hook serve a critical PITR function:

- **Pre-hook `FLUSH BINARY LOGS`**: Closes the current binary log and starts a new one. This marks the start of the backup window in the binary log stream.
- **Post-hook `FLUSH BINARY LOGS`**: Closes the binary log that was active during the snapshot and starts a fresh one. This is the **anchor point** for PITR — WAL-G will archive this segment, and all subsequent logs can be replayed from here.

Without these flush calls, you would need to scan mid-segment binary logs to find the exact start position, which is error-prone.

---

## PITR Recovery Procedure

### Step 1 — Trilio for Kubernetes restores the namespace

The restore brings MariaDB back to the state at the time of the snapshot, including all binary log files that existed at that time.

### Step 2 — Identify the target position

```sql
-- Find the binary log position closest to your target time
SHOW BINARY LOGS;
-- Use mysqlbinlog to inspect events around your target time
mysqlbinlog --start-datetime="2026-02-27 14:30:00" \
            --stop-datetime="2026-02-27 14:35:00" \
            binlog.000042 | head -50
```

### Step 3 — Fetch and replay binary logs from S3

```bash
# Download binary logs after the snapshot point from S3
wal-g binlog-fetch --since "binlog.000040" --until-time "2026-02-27 14:35:00"

# Replay them using mysqlbinlog
mysqlbinlog --stop-datetime="2026-02-27 14:35:00+00:00" \
  /tmp/binlogs/binlog.000040 \
  /tmp/binlogs/binlog.000041 \
  /tmp/binlogs/binlog.000042 | \
  MYSQL_PWD=$MARIADB_ROOT_PASSWORD mysql -u root
```

### Step 4 — Verify

```bash
kubectl apply -f mariadb/checker/ -n trilio-demo
kubectl logs -f job/mariadb-consistency-checker -n trilio-demo
```

---

## Production Notes

1. **`log_bin` sizing**: Binary logs rotate based on `max_binlog_size` (default 1GB). For active databases, set this lower (e.g., `64M`) so segments are shipped to S3 more frequently, reducing data loss in case of node failure.

2. **`expire_logs_days`**: Set this to retain local binary logs long enough that the sidecar can always pick them up, but not so long they fill the PVC. `2` days is reasonable for most setups.

3. **`sync_binlog=1`**: Ensures every binary log event is flushed to disk before the transaction is confirmed. This is critical for durability. It has a performance cost but is the only safe setting for PITR.

4. **`innodb_flush_log_at_trx_commit=1`**: Combined with `sync_binlog=1`, this gives full ACID guarantees and ensures no committed transaction can be lost.

5. **GTID mode**: Enable `gtid_mode=ON` and `enforce_gtid_consistency=ON` for simpler, position-independent PITR. WAL-G's MySQL adapter works with GTID-based replication.
