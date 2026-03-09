# Trilio for Kubernetes Database Backup Demo

> **⚠️ DEMO PURPOSES ONLY**
> This repository is intended for demonstration and evaluation. The hooks, manifests, and configurations have not been validated for production workloads. **Customer validation and testing in your own environment is required before using any of this in production.**

A collection of ready-to-use Kubernetes manifests demonstrating **application-consistent database backups** with [Trilio for Kubernetes](https://trilio.io). Each database shows continuous writes surviving a backup with zero data loss, verified post-restore.

---

## Why This Matters

A naive volume snapshot of a running database can capture dirty buffers, uncommitted transactions, and half-written pages — leaving you with a **corrupt backup** you discover only when you need it most.

Trilio for Kubernetes's Hook mechanism runs quiesce/unquiesce commands **inside the database container** immediately before and after the volume snapshot, ensuring the database engine flushes its state to disk at exactly the right moment.

This repo proves it: a **writer Job** inserts numbered rows continuously, and a **consistency checker** verifies zero sequence gaps, correct data format, storage-level integrity, and full read-write capability after restore.

> **Branch `feat/high-pressure-writes`** (this branch): writers default to **10 rows/sec** (50,000 rows, ~83 min) to stress the hook under realistic I/O pressure. The checkers adapt their stall-detection threshold to the measured write rate (2× p50 latency), and timeline charts auto-scale. See [High-Pressure Write Mode](#high-pressure-write-mode) below.

---

## Databases Covered

| Database | Version | Hook Strategy | PITR Tool | Production-Ready? |
|---|---|---|---|---|
| [PostgreSQL](./postgres/) | 17 | `CHECKPOINT` + `pg_switch_wal()` | WAL-G (WAL segments → S3) | ✅ Yes |
| [MariaDB](./mariadb/) | 11.4 LTS | `FLUSH TABLES` + `FLUSH BINARY LOGS` | WAL-G (binary logs → S3) | ✅ Yes |
| [MongoDB](./mongodb/) | 8.0 | `fsyncLock` / `fsyncUnlock` | WAL-G (oplog → S3) | ✅ Yes |
| [SQL Server](./sqlserver/) | 2022 | `CHECKPOINT` | Native `BACKUP LOG TO URL` → S3 | ✅ Yes |

---

## Prerequisites

- Kubernetes cluster (1.25+)
- Trilio for Kubernetes installed
- A Trilio for Kubernetes **Target** pre-configured in your cluster (S3, NFS, or other)
- `kubectl` configured for your cluster

---

## Repository Structure

```
trilio-db-demos/
├── README.md                   ← You are here
├── postgres/
│   ├── README.md               ← PostgreSQL-specific guide & hook rationale
│   ├── deploy/                 ← StatefulSet, Service, Secret
│   ├── writer/                 ← Writer Job (10k rows, auto-terminates) + ConfigMap
│   ├── checker/                ← Post-restore consistency verifier (Job)
│   ├── trilio/                 ← Hook, BackupPlan, Backup CRs
│   └── pitr/                   ← WAL archiving to S3 (WAL-G sidecar + docs)
├── mariadb/
│   └── pitr/                   ← Binary log archiving to S3 (WAL-G sidecar + docs)
├── mongodb/
│   └── pitr/                   ← Oplog archiving to S3 (WAL-G sidecar + docs)
└── sqlserver/
    └── pitr/                   ← Native BACKUP LOG TO S3 (CronJob + docs)
```

---

## Quick Start (PostgreSQL example)

```bash
# 1. Create a namespace
kubectl create namespace trilio-demo

# 2. Deploy the database
kubectl apply -f postgres/deploy/ -n trilio-demo

# 3. Wait for the database to be ready (~30s)
kubectl rollout status statefulset/postgres -n trilio-demo

# 4. Start the writer Job (writes 10,000 rows then exits automatically)
kubectl apply -f postgres/writer/ -n trilio-demo

# 5. Watch the writes in one terminal (keep this open!)
kubectl logs -f deployment/postgres-writer -n trilio-demo

# 6. Apply Trilio for Kubernetes resources (edit target name in backupplan.yaml first)
kubectl apply -f postgres/trilio/ -n trilio-demo

# 7. Trigger a backup — watch writes continue uninterrupted
kubectl apply -f postgres/trilio/backup.yaml -n trilio-demo
kubectl get backup postgres-demo-backup -n trilio-demo -w

# 8. After a restore, verify consistency
kubectl apply -f postgres/checker/ -n trilio-demo
kubectl logs -f job/postgres-consistency-checker -n trilio-demo
```

Repeat the same pattern for `mariadb/`, `mongodb/`, or `sqlserver/`.

---

## The Demo Story

```
Timeline ──────────────────────────────────────────────────────────────────▶

  [Writer running]  row#1  row#2  row#3  ...  row#60  row#61  ...  row#120
                                              │                    │
                                        PRE-HOOK              POST-HOOK
                                        (quiesce)           (unquiesce)
                                              │◄── SNAPSHOT ──►│
                                              └─── ~5 seconds ──┘

  Post-restore check:  SELECT MIN(seq), MAX(seq), COUNT(*) FROM writes_log;
  Result:  min=1, max=120, count=120 → zero gaps → ✅ CONSISTENT
```

The writer never pauses. The hook runs in milliseconds. The snapshot captures a clean, consistent state.

---

## Using These Hooks in Production

The hooks in this repo are **not just for demos** — they are designed to be production-safe:

- Commands are validated against the latest database documentation
- Credentials use environment variables (no command-line password exposure)
- `ignoreFailure: false` ensures the backup fails rather than silently proceeding with an inconsistent snapshot
- `timeoutSeconds` and `maxRetryCount` are set conservatively
- Each database's hook rationale is documented in its `README.md`

See each database folder's `README.md` for production usage notes and any caveats.

---

## PITR Philosophy — Layering on Top of Trilio for Kubernetes

Trilio for Kubernetes answers the question: **"Can I restore my entire application to a known-good state?"**

PITR answers the question: **"Can I recover to the exact second before the incident?"**

They are complementary, not competing. The relationship is:

```
Without PITR:
  Last Trilio for Kubernetes backup ──────────────────── Incident
                          ◄──── data loss ─────►
                            (hours, if unlucky)

With PITR:
  Last Trilio for Kubernetes backup ── WAL/logs → S3 ── Incident
                                         ◄──►
                                    seconds of data loss
```

**The restore procedure** always starts with Trilio for Kubernetes — it handles the heavy lifting of restoring the PVC, Secrets, Services, StatefulSet, and all other Kubernetes resources in a single operation. WAL-G (or SQL Server's native log restore) then replays the transaction log on top of that base to reach the precise recovery point.

**Trilio for Kubernetes is the foundation. PITR is the precision layer.**

### PITR tool by database

| Database | Continuous log mechanism | Archival tool | Replay command |
|---|---|---|---|
| PostgreSQL | WAL segments (files) | WAL-G `wal-push` | `wal-g wal-fetch` + `recovery.signal` |
| MariaDB | Binary log files | WAL-G MySQL `binlog-push` | `wal-g binlog-fetch` + `mysqlbinlog` pipe |
| MongoDB | Oplog (capped collection) | WAL-G `oplog-push` | `wal-g oplog-replay` |
| SQL Server | Transaction log (scheduled) | Native `BACKUP LOG TO URL` | `RESTORE LOG ... STOPAT` |

Each database's `pitr/` folder contains the manifests and a full recovery procedure.

---

## High-Pressure Write Mode

This branch increases write throughput to stress the hook and snapshot mechanism under realistic I/O pressure.

| Parameter | `main` (baseline) | `feat/high-pressure-writes` |
|---|---|---|
| `WRITE_INTERVAL` | `1.0s` (1 row/sec) | `0.1s` (10 rows/sec) |
| `STOP_AFTER_ROWS` | `10,000` (~2.7h) | `50,000` (~83 min) |
| Checker stall threshold | hardcoded `>2000ms` | adaptive: `>2× p50` latency |
| Timeline bar scale | `1█ = 1 row` | `1█ = N rows` (auto-scales for 50k rows) |

### Why This Matters

At 10 rows/sec, the database is doing **10× more I/O** during the hook window. This tests:
- Whether `CHECKPOINT` / `FLUSH TABLES` / `fsyncLock` complete fast enough under load
- Whether the snapshot window widens perceptibly (visible in ③ Write Stalls)
- Whether the consistency checker correctly identifies the restore boundary when there are thousands of rows around it

### Override at Runtime

Both parameters are environment variables — override them without changing manifests:

```bash
# 100 rows/sec stress test
kubectl set env job/postgres-writer WRITE_INTERVAL=0.01 STOP_AFTER_ROWS=100000 -n trilio-demo
```

### Adaptive Checker Behavior

The stall detection section (③) now shows the actual p50 latency as the reference point:

```
─── ③ Write Stalls (interval > 2× p50 = >200ms) ──────────────────
   ✅ No stalls detected — hook and snapshot did not delay writes.
```

If the hook causes a write pause (expected for MongoDB `fsyncLock` and MariaDB `FLUSH TABLES`), it appears here clearly — and is capped at `30× stall_threshold` so the restore gap doesn't pollute the stall list.

---

## Hook Design Philosophy

The hook strategy differs per database because each engine has a different consistency model:

- **PostgreSQL & SQL Server** use Write-Ahead Logs (WAL/transaction log) for crash recovery. A `CHECKPOINT` is sufficient — no lock needed.
- **MariaDB (InnoDB)** is crash-safe via its redo log. `FLUSH TABLES` flushes the buffer pool without holding a session-scoped lock that would release before the snapshot.
- **MongoDB** `fsyncLock` is *global* (not session-scoped), so it survives the pre-hook command exit and remains active until the post-hook explicitly unlocks it — giving true write quiescing during the snapshot window.

Details and rationale in each database's `README.md`.
