# Shared Namespace — All 4 Databases Together

This directory contains manifests for running all 4 databases in a **single shared namespace** with a single Trilio BackupPlan that backs them all up simultaneously.

## Architecture

```
trilio-demo namespace
├── postgres    (StatefulSet + PVC + Service + Hook)
├── mariadb     (StatefulSet + PVC + Service + Hook)
├── mongodb     (StatefulSet + PVC + Service + Hook)
└── sqlserver   (StatefulSet + PVC + Service + Hook)
         │
         └── all-dbs-backupplan  ← single BackupPlan, Parallel hooks
                  │
                  └── all-dbs-backup  ← one backup captures all 4 DBs
```

## Quick Start

```bash
# 1. Edit shared/trilio/backupplan.yaml — set your Target name and namespace

# 2. Deploy everything (standard mode: 1 row/sec, 10,000 rows per DB)
./test.sh deploy

# 3. Let writers run, then take a backup
./test.sh backup

# 4. Simulate a failure: delete all workloads
./test.sh cleanup

# 5. Restore everything
./test.sh restore

# 6. Verify data integrity across all 4 databases
./test.sh check

# Or run the full end-to-end test in one command:
./test.sh full
```

## Write Modes

Each database has two writer configmaps in its `writer/` folder:

| File | Mode | Rate | Rows | Duration |
|------|------|------|------|----------|
| `writer-configmap.yaml` | Standard | 1 row/sec | 10,000 | ~2.7h |
| `writer-configmap-highpressure.yaml` | High-pressure | ~100 rows/sec (postgres/mariadb/mongodb: Python+pip batch=10; sqlserver: bash+sqlcmd batches of 50, no rate cap) | 50,000 | ~8 min |

Pass `--high-pressure` to `deploy` or `full` to use the stress writers:

```bash
# High-pressure: ~100 rows/sec — stresses the hook under high I/O load
./test.sh deploy --high-pressure
./test.sh full --high-pressure

# Standard: 1 row/sec — baseline behaviour, matches the original demo
./test.sh deploy
./test.sh full
```

The `--high-pressure` flag only controls which writer configmap is applied at deploy time. Backup, restore, check, status, and cleanup commands are unaffected.

## Individual DB Operations

```bash
# Restore only PostgreSQL (other 3 DBs keep running)
./test.sh cleanup postgres
./test.sh restore postgres

# Check only MariaDB
./test.sh check mariadb
```

## Trilio Manifests

| File | Purpose |
|------|---------|
| `trilio/backupplan.yaml` | BackupPlan covering all 4 DBs, Parallel hook execution |
| `trilio/backup.yaml` | Trigger a full backup |
| `trilio/restore-all.yaml` | Restore all 4 DBs |
| `trilio/restore-<db>.yaml` | Restore a single DB (other DBs skipped via `skipIfAlreadyExists`) |

## Notes

- **Parallel hooks**: all 4 databases are quiesced simultaneously during the snapshot — PostgreSQL runs `CHECKPOINT`, MariaDB runs `FLUSH TABLES WITH READ LOCK`, MongoDB runs `fsyncLock`, SQL Server runs a log backup. This demonstrates T4K's multi-database coordination.
- **skipIfAlreadyExists**: used instead of `cleanupConfig` so operator-injected resources (e.g. `odh-kserve-custom-ca-bundle`) are left untouched.
- **OpenShift**: SQL Server requires `anyuid` SCC — `./test.sh deploy` handles this automatically if `oc` is available.
