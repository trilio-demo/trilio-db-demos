# Trilio for Kubernetes Database Backup Demo

> **⚠️ DEMO PURPOSES ONLY**
> This repository is intended for demonstration and evaluation. The hooks, manifests, and configurations have not been validated for production workloads. **Customer validation and testing in your own environment is required before using any of this in production.**

A collection of ready-to-use Kubernetes manifests demonstrating **application-consistent database backups** with [Trilio for Kubernetes](https://trilio.io). Each database shows continuous writes surviving a backup with zero data loss, verified post-restore.

---

## Why This Matters

A naive volume snapshot of a running database can capture dirty buffers, uncommitted transactions, and half-written pages — leaving you with a **corrupt backup** you discover only when you need it most.

Trilio for Kubernetes's Hook mechanism runs quiesce/unquiesce commands **inside the database container** immediately before and after the volume snapshot, ensuring the database engine flushes its state to disk at exactly the right moment.

This repo proves it: a **writer Job** inserts numbered rows at 1 row/sec (10,000 rows total, ~2.7h) then exits automatically, and a **consistency checker** verifies zero gaps in the sequence after restore.

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

- Kubernetes cluster (1.25+) with a **CSI driver that supports VolumeSnapshots** (e.g. `ebs.csi.aws.com`, `disk.csi.azure.com`, `pd.csi.storage.gke.io`, or any driver with a `VolumeSnapshotClass`)
- Trilio for Kubernetes installed
- A Trilio for Kubernetes **Target** pre-configured in your cluster (S3, NFS, or other)
- `kubectl` configured for your cluster
- For OpenShift: `oc` CLI available (used by `test.sh` for SCC configuration)

---

## Repository Structure

```
trilio-db-demos/
├── README.md                   ← You are here
├── test.sh                     ← Automated E2E test: deploy / backup / restore / check
├── shared/
│   ├── README.md               ← Shared-namespace workflow (recommended entry point)
│   └── trilio/                 ← Combined BackupPlan, Backup, Restore CRs (all 4 DBs)
├── postgres/
│   ├── README.md               ← PostgreSQL-specific guide & hook rationale
│   ├── deploy/                 ← StatefulSet, Service, Secret
│   ├── writer/                 ← Writer Job (10k rows, auto-terminates) + ConfigMaps
│   ├── checker/                ← Post-restore consistency verifier (Job)
│   ├── trilio/                 ← Hook + per-DB BackupPlan/Backup CRs
│   └── pitr/                   ← WAL archiving to S3 (WAL-G sidecar + docs)
├── mariadb/
│   ├── ...                     ← Same structure as postgres/
│   └── pitr/                   ← Binary log archiving to S3 (WAL-G sidecar + docs)
├── mongodb/
│   ├── ...                     ← Same structure as postgres/
│   └── pitr/                   ← Oplog archiving to S3 (WAL-G sidecar + docs)
└── sqlserver/
    ├── ...                     ← Same structure as postgres/
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
kubectl logs -f job/postgres-writer -n trilio-demo

# 6. Apply Trilio for Kubernetes resources (edit target name in backupplan.yaml first)
#    ⚠️  Apply individually — backup.yaml triggers a backup immediately if applied
kubectl apply -f postgres/trilio/hook.yaml -n trilio-demo
kubectl apply -f postgres/trilio/backupplan.yaml -n trilio-demo

# 7. Trigger a backup — watch writes continue uninterrupted
kubectl apply -f postgres/trilio/backup.yaml -n trilio-demo
kubectl get backup postgres-demo-backup -n trilio-demo -w

# 8. After a restore, verify consistency
kubectl apply -f postgres/checker/ -n trilio-demo
kubectl logs -f job/postgres-consistency-checker -n trilio-demo
```

Repeat the same pattern for `mariadb/`, `mongodb/`, or `sqlserver/`.

> **Shared namespace (recommended):** `test.sh` at the repo root automates the full workflow — deploy, backup, restore, and check all 4 databases in a single namespace with one command. See [shared/README.md](./shared/README.md) for the quickest path.

---

## Write Modes

Each database has two writer configmaps:

| File | Mode | Rate | Rows | ~Duration |
|------|------|------|------|-----------|
| `writer-configmap.yaml` | Standard | 1 row/sec | 10,000 | 2.7h |
| `writer-configmap-highpressure.yaml` | High-pressure | 10 rows/sec | 50,000 | 83 min |

Using `test.sh`, select the mode at deploy time:

```bash
./test.sh deploy                  # standard
./test.sh deploy --high-pressure  # stress — 10× the I/O during the hook window
./test.sh full --high-pressure    # full E2E with stress writers
```

The flag only affects which writer configmap is applied. All other commands (backup, restore, check) work identically in both modes.

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

## Hook Design Philosophy

The hook strategy differs per database because each engine has a different consistency model:

- **PostgreSQL & SQL Server** use Write-Ahead Logs (WAL/transaction log) for crash recovery. A `CHECKPOINT` is sufficient — no lock needed.
- **MariaDB (InnoDB)** is crash-safe via its redo log. `FLUSH TABLES` flushes the buffer pool without holding a session-scoped lock that would release before the snapshot.
- **MongoDB** `fsyncLock` is *global* (not session-scoped), so it survives the pre-hook command exit and remains active until the post-hook explicitly unlocks it — giving true write quiescing during the snapshot window.

Details and rationale in each database's `README.md`.
