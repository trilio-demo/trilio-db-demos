# PostgreSQL PITR with Trilio for Kubernetes

## Overview

This document describes how Point-In-Time Recovery (PITR) works alongside Trilio for
Kubernetes to provide near-zero RPO for PostgreSQL on OpenShift.

---

## Two Independent Systems, One Recovery Strategy

Trilio for Kubernetes and PostgreSQL WAL archiving are **completely independent**. They
complement each other but neither needs to know about the other's internals.

| System | Responsibility | RPO |
|--------|---------------|-----|
| Trilio for Kubernetes | Consistent snapshot of the entire application (PVC, Secrets, Services, StatefulSet) | Time since last snapshot |
| PostgreSQL WAL archiving | Continuous stream of every transaction to S3 | ~60 seconds |
| **Combined** | **Trilio restores the base; WAL replay fills the gap** | **~60 seconds** |

---

## How WAL Archiving Works

Write-Ahead Logging (WAL) is a core PostgreSQL feature that has existed for decades —
nothing proprietary or bespoke is required. Every change to the database is written to
a WAL segment file before being applied to the data files. When archiving is enabled,
PostgreSQL calls an `archive_command` for every completed segment:

```
archive_command = 'wal-g wal-push %p'
```

[WAL-G](https://github.com/wal-g/wal-g) is the open source tool that handles compression
and upload to S3-compatible object storage (AWS S3, MinIO, Ceph/NooBaa, etc.). It runs
as a sidecar container alongside PostgreSQL, requiring no changes to the database itself.

```
PostgreSQL container
  │
  │  completed WAL segment every ~60 seconds (or when 16MB fills)
  ▼
WAL-G (archive_command)  ──────────────────►  S3 bucket
                                               /postgres/wal/
                                               000000010000000000000001.br
                                               000000010000000000000002.br
                                               ...
```

Archiving is **continuous and automatic** once enabled. Trilio is not involved.

---

## How Recovery Works

Recovery happens in two phases. Understanding the boundary between them is the key to
understanding the architecture.

```
Trilio snapshot                                    Target time
     │                                                  │
     ▼                                                  ▼
─────●──────────────────────────────────────────────────●──── time
     │◄─ Phase 1: local WAL inside snapshot ──►│◄─ Phase 2: WAL from S3 ──►│
     │   (PostgreSQL crash recovery, automatic) │   (WAL-G wal-fetch)       │
```

**Phase 1 — Trilio restores the base**

Trilio recreates the PVC from the volume snapshot and restores all Kubernetes resources
(StatefulSet, Services, Secrets, ConfigMaps) in a single operation. When the PostgreSQL
pod starts, it enters crash recovery and replays the WAL segments that were captured
inside the snapshot. This brings the database to the exact consistent state it was in
at snapshot time — automatically, with no intervention required.

**Phase 2 — PostgreSQL replays WAL from S3**

With a `recovery.signal` file present in `$PGDATA` and `restore_command` configured,
PostgreSQL does not stop at the end of the local WAL. It calls WAL-G to fetch the next
segment from S3, then the next, replaying transactions until it reaches the
`recovery_target_time` you specify. It then promotes to a primary and removes the
`recovery.signal` file automatically.

**Trilio's job ends when the pod is running. PostgreSQL handles everything after that.**

---

## The Role of pg_switch_wal() in the Trilio Hook

The Trilio post-hook calls `pg_switch_wal()` immediately after the volume snapshot is
taken. This is the one point where the two systems interact — and it is critical for
gap-free recovery.

Without it, the WAL segment at the moment of the snapshot may sit half-filled for up to
60 seconds before PostgreSQL completes it and WAL-G archives it to S3. This creates a
window where Phase 1 ends but Phase 2 cannot yet begin — a gap in the WAL timeline.

`pg_switch_wal()` forces PostgreSQL to close and archive the current segment immediately,
creating a clean boundary at exactly the snapshot point. Phase 2 can always pick up
exactly where Phase 1 left off.

```
Snapshot taken at T
  │
  └── pg_switch_wal() closes current WAL segment at T
        │
        └── WAL-G archives segment to S3 immediately
              │
              └── Phase 2 can replay from T with no gap  ✅
```

---

## What Is and Is Not Recovered

| Transaction | Location | Recovered? |
|-------------|----------|------------|
| Committed before snapshot | Local WAL inside PVC | ✅ Phase 1 |
| Committed after snapshot, before target time | S3 via WAL-G | ✅ Phase 2 |
| In-flight at snapshot time | No commit record anywhere | ❌ Rolled back (correct behaviour) |
| Committed after target time | Intentionally excluded | ❌ By design |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  OpenShift namespace                                         │
│                                                             │
│  ┌──────────────────────────────────┐                       │
│  │  postgres StatefulSet pod        │                       │
│  │                                  │                       │
│  │  ┌─────────────┐  ┌───────────┐  │                       │
│  │  │ postgres:17 │  │  wal-g    │  │                       │
│  │  │             │  │  sidecar  │  │                       │
│  │  │ archive_cmd─┼──► wal-push ─┼──┼──► ODF/NooBaa S3     │
│  │  └─────────────┘  └───────────┘  │      /postgres/wal/  │
│  │         │                        │                       │
│  │    5Gi PVC (WAL + data files)     │                       │
│  └──────────────────────────────────┘                       │
│                                                             │
│  Trilio for Kubernetes                                      │
│    Hook: CHECKPOINT → snapshot PVC → pg_switch_wal()        │
│    Target: NFS (snapshot storage)                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Recovery Procedure (Summary)

1. Run `./test.sh restore postgres` — Trilio restores the snapshot (Phase 1 automatic)
2. Set `recovery_target_time` and create `recovery.signal` in `$PGDATA`
3. Restart the StatefulSet — PostgreSQL fetches WAL from S3 and replays to target time
4. Verify with `SELECT pg_is_in_recovery();` — returns `f` when complete

Steps 2–4 are automated by `./test.sh pitr-restore postgres "<target-time>"`.

---

## Prerequisites

| Component | Purpose |
|-----------|---------|
| OpenShift Data Foundation (ODF) | Provides S3-compatible object storage via NooBaa |
| ObjectBucketClaim | Provisions the WAL archive bucket and credentials |
| WAL-G init container | Downloads `wal-g` binary at pod startup; placed on shared volume for postgres |
| walg-config Secret | S3 credentials and endpoint, injected into the postgres container |
| Trilio for Kubernetes | Snapshot-based backup and restore of the full application |

## TLS Certificate Requirement

WAL-G strictly verifies TLS certificates when connecting to S3. On OpenShift with ODF/NooBaa
this requires explicit CA configuration — WAL-G will fail with
`x509: certificate signed by unknown authority` otherwise.

**Use the internal NooBaa S3 service endpoint** (`s3.openshift-storage.svc:443`) rather than
the external route. ODF automatically injects its service CA certificate into every namespace
as a ConfigMap named `openshift-service-ca.crt`. The `walg-sidecar-statefulset-patch.yaml`
mounts this ConfigMap and sets `WALG_S3_CA_CERT_FILE` to point WAL-G at it.

```
WALG_S3_CA_CERT_FILE=/etc/ssl/ocp-service-ca/service-ca.crt
AWS_ENDPOINT=https://s3.openshift-storage.svc:443
AWS_S3_FORCE_PATH_STYLE=true   # NooBaa uses path-style URLs, not virtual-hosted
```

> **Note:** The external NooBaa route (`s3-openshift-storage.apps.<cluster>`) uses the OCP
> ingress router certificate which is signed by the cluster's ingress CA — not the service CA.
> Using the internal service endpoint avoids this complexity entirely.
