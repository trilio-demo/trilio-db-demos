# PostgreSQL PITR — WAL-G + Trilio for Kubernetes

> **Optional capability** — PITR extends Trilio snapshot recovery with near-zero RPO.
> Standard Trilio backups work without it.
>
> **Requires S3-compatible object storage** — ODF/NooBaa, AWS S3, MinIO, or Ceph.
> NFS-only environments cannot use WAL archiving.

---

## Quick Start

Everything is automated. Deploy postgres with PITR enabled in a single command:

```bash
export DEMO_NS=your-namespace
./test.sh deploy postgres
```

This provisions the OBC, creates the `walg-config` secret, applies the WAL-G init
container patch, and verifies archiving is working before returning.

To recover to a point in time after a restore:

```bash
./test.sh restore postgres
./test.sh pitr-restore postgres "2026-03-18 20:39:32"
```

---

## How It Works

See [Overview-pitr.md](Overview-pitr.md) for the full architecture. In brief:

- **Backup**: WAL-G archives PostgreSQL WAL segments continuously to S3. The Trilio
  backup hook calls `pg_switch_wal()` after the snapshot to create a clean WAL boundary.
- **Restore**: Trilio restores the PVC and sets postgres to 0 replicas (via a
  `transformComponents` patch). `pitr-restore` writes `recovery.signal` + `restore_command`
  directly to `$PGDATA` via a debug pod, then scales postgres to 1. PostgreSQL starts
  once — directly in recovery mode — replaying local WAL (Phase 1) then S3 WAL (Phase 2).

---

## Files

```
postgres/pitr/
├── 01-obc.yaml                         ObjectBucketClaim for WAL archive bucket
├── 02-walg-secret.sh                   Script to create walg-config secret from OBC credentials
│                                         (called automatically by ./test.sh deploy postgres)
├── walg-sidecar-statefulset-patch.yaml Strategic merge patch — adds WAL-G init containers
│                                         to the postgres StatefulSet
│   Init containers:
│     walg-install       downloads wal-g binary from GitHub releases → /wal-g/wal-g
│     postgres-pitr-init writes archive_mode config to $PGDATA/conf.d/pitr.conf
│
├── Overview-pitr.md                    Customer-facing architecture document
└── LESSONS-LEARNED.md                  Operational findings from testing on OCP 4.20 / ODF
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  OpenShift namespace                                          │
│                                                              │
│  ┌───────────────────────────────────┐                       │
│  │  postgres StatefulSet pod         │                       │
│  │                                   │                       │
│  │  init: walg-install               │                       │
│  │    └─ downloads /wal-g/wal-g      │                       │
│  │  init: postgres-pitr-init         │                       │
│  │    └─ writes conf.d/pitr.conf     │                       │
│  │                                   │                       │
│  │  container: postgres:17           │                       │
│  │    archive_command = /wal-g/wal-g wal-push %p             │
│  │    WALG_S3_CA_CERT_FILE = /etc/ssl/ocp-service-ca/...     │
│  │         │                         │                       │
│  │         └──────────────────────────────► NooBaa S3        │
│  │    5Gi PVC (data + WAL files)     │      /postgres/wal/   │
│  └───────────────────────────────────┘                       │
│                                                              │
│  Trilio for Kubernetes                                       │
│    Backup hook:  CHECKPOINT → snapshot PVC → pg_switch_wal() │
│    Restore xfrm: StatefulSet replicas → 0                    │
│    Target: NFS (snapshot storage)                            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Recovery Procedure

### 1. Run restore (postgres stays at 0 replicas)

```bash
./test.sh restore postgres
```

Trilio restores the PVC. The `transformComponents` patch keeps postgres at 0 replicas —
it never starts in normal mode, preserving a clean WAL state for Phase 2.

### 2. Run pitr-restore

```bash
./test.sh pitr-restore postgres "YYYY-MM-DD HH:MM:SS"
```

Target time is UTC. Use a timestamp a few seconds after the last known good write, safely
within a confirmed WAL archive boundary — not the most recent segment (may be incomplete).

`pitr-restore` will:
1. Verify postgres is at 0 replicas (scales down if not)
2. Re-apply the WAL-G sidecar patch
3. Ensure `walg-config` secret exists
4. Spin up a `postgres:17` debug pod to write `recovery.signal` + recovery config to the PVC
5. Scale postgres to 1
6. Wait for pod ready and `pg_is_in_recovery() = f`
7. Write a `restore_log` audit entry

### 3. Verify

```bash
kubectl exec postgres-0 -n $DEMO_NS -c postgres -- \
  psql -U demouser -d demodb \
  -c "SELECT COUNT(*), MAX(written_at) FROM writes_log;"

kubectl exec postgres-0 -n $DEMO_NS -c postgres -- \
  psql -U demouser -d demodb \
  -c "SELECT * FROM restore_log ORDER BY restored_at DESC LIMIT 5;"
```

---

## Choosing a Target Time

PostgreSQL panics if asked to replay past the last complete WAL segment. Always choose
a target time that falls **within a fully-archived segment** — not at or after the last
one (which may be partial if postgres was killed mid-write).

WAL segment boundaries occur when:
- The segment fills to 16 MB (automatic)
- `archive_timeout = 60` fires (configured in `pitr.conf`)
- `pg_switch_wal()` is called by the Trilio backup hook

A safe target is a timestamp a few seconds **after** a mid-run WAL archive, well before
the incident.

> See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for a full list of operational findings,
> including the segment corruption issue and the transform approach that solved it.

---

## TLS — Internal NooBaa Endpoint

WAL-G strictly verifies TLS. Use the internal service endpoint, not the external route:

| | Internal (use this) | External (avoid) |
|---|---|---|
| URL | `https://s3.openshift-storage.svc:443` | `https://s3-openshift-storage.apps.<cluster>` |
| CA cert | `openshift-service-ca.crt` ConfigMap (auto-injected) | Ingress router CA (requires manual extraction) |

The sidecar patch mounts `openshift-service-ca.crt` and sets `WALG_S3_CA_CERT_FILE`
automatically. Set `AWS_S3_FORCE_PATH_STYLE=true` — NooBaa uses path-style S3 URLs.

---

## Clean Reset

```bash
./test.sh nuke            # deletes OBC (purges WAL bucket) + Trilio backups + namespace
./test.sh deploy postgres # redeploys with fresh WAL archive and archiving verified
```

`nuke` deletes the OBC first so NooBaa purges the bucket. Old WAL segments from a
previous run would otherwise conflict with new ones.
