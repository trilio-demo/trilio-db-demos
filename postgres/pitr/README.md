# PostgreSQL — PITR with WAL-G + Trilio for Kubernetes

> **⚠️ OPTIONAL**: PITR is a complementary capability — not required for T4K backups. Your T4K snapshots work perfectly without it.
>
> **☁️ S3 ONLY**: The archiving mechanisms described here require S3-compatible object storage (AWS S3, MinIO, Ceph, etc.). NFS and filesystem-based T4K targets are **not supported** for WAL/log archiving.

## The Philosophy

Trilio for Kubernetes gives you a **consistent, recoverable snapshot** of your entire Kubernetes application — the database PVC, secrets, services, config — everything needed to restore to a running state. But it is, by nature, a point-in-time event. If you take a backup every 4 hours and the cluster dies 3h59m later, you lose almost 4 hours of data.

WAL archiving fills that gap.

```
 Trilio for Kubernetes Snapshot         Trilio for Kubernetes Snapshot
        │                            │
        ▼                            ▼
────────●────────────────────────────●──────────────── time
        └──────────── WAL ──────────►└──────── WAL ──►
                     to S3                   to S3

  RPO without WAL archiving: up to the full backup interval
  RPO with WAL archiving:    seconds (the last WAL segment flushed to S3)
```

The strategy is layered:

1. **Trilio for Kubernetes** restores the namespace to a healthy running state (the base).
2. **WAL-G** replays WAL segments from S3 on top of that base to reach the exact point in time you need.

Neither tool alone is sufficient. Together, they provide enterprise-grade RPO.

---

## The Tool: WAL-G

[WAL-G](https://github.com/wal-g/wal-g) is the de facto standard for PostgreSQL WAL archiving. It runs as a sidecar container alongside PostgreSQL and:

- Continuously ships WAL segment files to S3 (or GCS, Azure Blob, filesystem)
- Compresses and optionally encrypts segments before upload
- Cleans up old segments automatically based on retention policy
- Takes its own base backups (optional — in our case Trilio for Kubernetes does this)

The `pg_switch_wal()` call in the Trilio for Kubernetes **post-hook** creates a clean WAL segment boundary at the exact moment of the snapshot, which is the anchor point for WAL replay.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  postgres StatefulSet pod                            │
│                                                      │
│  ┌────────────────┐    ┌────────────────────────┐   │
│  │   postgres:17  │    │  wal-g sidecar         │   │
│  │                │    │                        │   │
│  │  archive_mode  │───►│  wal_archive_command   │──►│──► S3 bucket
│  │  = on          │    │  = wal-g wal-push %p   │   │    /wal-segments/
│  └────────────────┘    └────────────────────────┘   │
│           │                                          │
│    /var/lib/postgresql/data (shared volume)          │
└─────────────────────────────────────────────────────┘
```

PostgreSQL's `archive_command` calls WAL-G for every completed WAL segment. WAL-G compresses it and uploads to S3. This happens continuously, independent of Trilio for Kubernetes.

---

## Setup

### 1. Prerequisites

- An S3 bucket (or compatible: MinIO, Ceph, etc.) for WAL storage
- AWS credentials accessible to the pod (IAM role, secret, or IRSA)

### 2. Create the WAL-G configuration secret

```bash
kubectl create secret generic walg-config \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  --from-literal=AWS_REGION=<your-region> \
  --from-literal=WALG_S3_PREFIX=s3://<your-bucket>/postgres/wal \
  -n trilio-demo
```

### 3. Apply the WAL-G sidecar manifest

```bash
kubectl apply -f postgres/pitr/walg-sidecar-statefulset-patch.yaml -n trilio-demo
```

This patches the existing StatefulSet to add the WAL-G sidecar and configure PostgreSQL's `archive_command`.

---

## Manifests

### `walg-sidecar-statefulset-patch.yaml`

This is a **strategic merge patch** that adds the WAL-G sidecar to the existing postgres StatefulSet. Apply it with:

```bash
kubectl patch statefulset postgres -n trilio-demo \
  --patch-file postgres/pitr/walg-sidecar-statefulset-patch.yaml
```

See the file for the full configuration.

### `postgres-pitr-configmap.yaml`

ConfigMap with the PostgreSQL configuration parameters that enable WAL archiving (`archive_mode`, `archive_command`, `wal_level`).

---

## How Recovery Works

Recovery happens in two phases. Understanding the boundary between them is key.

**Phase 1 — T4K restores the base**

T4K recreates the PVC from the snapshot and starts the pod. PostgreSQL enters crash recovery and replays the WAL files that were captured inside the snapshot. This brings the database to the exact state it was in at snapshot time — no more, no less.

**Phase 2 — WAL-G replays from S3**

If you configure `restore_command`, PostgreSQL doesn't stop at the end of the local WAL. It calls WAL-G to fetch the next WAL segment from S3, then the next, and keeps replaying until it reaches your `recovery_target_time`. This is how you recover past the snapshot point.

```
T4K snapshot                                  target time
     │                                              │
     ▼                                              ▼
─────●──────────────────────────────────────────────●──── time
     │◄── Phase 1: local WAL in snapshot ──►│◄─ Phase 2: WAL from S3 ──►│
     │    (crash recovery, automatic)        │   (wal-g wal-fetch)        │
```

**The pg_switch_wal() connection**

The post-hook forces a WAL segment boundary at the exact moment of the snapshot. WAL-G archives that segment to S3 immediately. Without this, the segment at snapshot time might sit half-filled for minutes before being archived, creating a gap between Phase 1 and Phase 2 where no WAL is available in S3.

**What you recover**

| Transaction | Where | Recovered? |
|---|---|---|
| Committed before snapshot | Local WAL in PVC | ✅ Phase 1 |
| Committed after snapshot, before target time | S3 via WAL-G | ✅ Phase 2 |
| In-flight at snapshot time | No commit record anywhere | ❌ Rolled back |
| Committed after target time | Intentionally excluded | ❌ By design |

---

## PITR Recovery Procedure

After a Trilio for Kubernetes restore, PostgreSQL will start with the state from the snapshot. To replay WAL forward to a specific point:

### Step 1 — Identify the target time

```bash
# The restore target timestamp (UTC)
TARGET_TIME="2026-02-27 14:35:00"
```

### Step 2 — Create a recovery configuration

After the Trilio for Kubernetes restore completes, exec into the postgres pod and create a `recovery.signal` file plus configure `restore_command`:

```bash
kubectl exec -it postgres-0 -n trilio-demo -- bash

# Inside the pod:
cat >> $PGDATA/postgresql.conf << 'EOF'
restore_command = 'wal-g wal-fetch %f %p'
recovery_target_time = '2026-02-27 14:35:00+00'
recovery_target_action = 'promote'
EOF

touch $PGDATA/recovery.signal
```

### Step 3 — Restart PostgreSQL

```bash
kubectl rollout restart statefulset/postgres -n trilio-demo
```

PostgreSQL will start in recovery mode, fetch WAL segments from S3 via WAL-G, replay them up to the target time, and promote to primary. The `recovery.signal` file is automatically removed when recovery completes.

### Step 4 — Verify

```bash
# Run the consistency checker to confirm data integrity
kubectl apply -f postgres/checker/ -n trilio-demo
kubectl logs -f job/postgres-consistency-checker -n trilio-demo

# Also check the recovery was complete
kubectl exec -it postgres-0 -n trilio-demo -- \
  psql -U demouser -d demodb -c "SELECT pg_is_in_recovery();"
# Should return: f (false = primary, recovery complete)
```

---

## Connection to the Trilio for Kubernetes Hook

The `pg_switch_wal()` call in the Trilio for Kubernetes post-hook is not just cosmetic — it creates the WAL segment that acts as the **anchor** for PITR:

```
Trilio for Kubernetes snapshot taken at T
  │
  └── pg_switch_wal() forces a new WAL segment at T
        │
        └── WAL-G archives segment ending at T to S3
              │
              └── PITR can replay from T forward with no gaps
```

Without `pg_switch_wal()`, the snapshot might end mid-WAL-segment. The segment would not be shipped to S3 until it fills up naturally (default: 16 MB), creating a gap between the snapshot and the first available WAL in S3.

---

## Production Notes

- **Retention**: WAL-G respects a retention policy. Configure `WALG_RETAIN_EXTRAPOLATED_WAL_SEGMENTS` and prune with `wal-g delete retain FULL 7` (keep 7 days).
- **Encryption**: WAL-G supports AES-256 encryption via `WALG_LIBSODIUM_KEY` or PGP. Highly recommended for production.
- **Monitoring**: Alert if WAL archiving falls behind. The metric `pg_stat_archiver.failed_count` should be 0. Also monitor S3 upload lag.
- **Base backup vs WAL only**: WAL-G can also take its own base backups (`wal-g backup-push`). You can use either Trilio for Kubernetes OR WAL-G base backups as the restore foundation — they are complementary, not exclusive.
