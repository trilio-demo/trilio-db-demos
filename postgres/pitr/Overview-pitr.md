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
archive_command = '/wal-g/wal-g wal-push %p'
```

[WAL-G](https://github.com/wal-g/wal-g) is the open source tool that handles compression
and upload to S3-compatible object storage (AWS S3, MinIO, Ceph/NooBaa, etc.). The binary
is downloaded at pod startup by an init container and placed on a shared volume, requiring
no changes to the base PostgreSQL image.

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
(StatefulSet, Services, Secrets, ConfigMaps) in a single operation.

**Critical:** The Trilio Restore CR uses a `transformComponents` patch to set the
StatefulSet to 0 replicas during restore. This prevents PostgreSQL from starting in
normal mode before recovery configuration is in place. If PostgreSQL were allowed to
start normally after restore it would write a new checkpoint, contaminating the WAL
timeline and making Phase 2 impossible.

**Phase 2 — PostgreSQL replays WAL from S3**

`./test.sh pitr-restore` injects `recovery.signal` and `restore_command` directly into
`$PGDATA` via a short-lived debug pod while postgres is still at 0 replicas. It then
scales postgres to 1. PostgreSQL starts for the first time post-restore already in
recovery mode: it runs Phase 1 crash recovery from local WAL, then seamlessly continues
to Phase 2, fetching segments from S3 via WAL-G until it reaches the
`recovery_target_time`. It then promotes to a primary and removes `recovery.signal`
automatically.

**PostgreSQL starts exactly once after a restore — directly in recovery mode.**

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
│  │  init: walg-install              │                       │
│  │  init: postgres-pitr-init        │                       │
│  │                                  │                       │
│  │  ┌─────────────┐                 │                       │
│  │  │ postgres:17 │                 │                       │
│  │  │             │                 │                       │
│  │  │ archive_cmd─┼─/wal-g/wal-g───┼──► ODF/NooBaa S3     │
│  │  └─────────────┘  (emptyDir)    │      /postgres/wal/  │
│  │         │                        │                       │
│  │    5Gi PVC (WAL + data files)     │                       │
│  └──────────────────────────────────┘                       │
│                                                             │
│  Trilio for Kubernetes                                      │
│    Backup hook: CHECKPOINT → snapshot PVC → pg_switch_wal() │
│    Restore transform: StatefulSet replicas → 0              │
│    Target: NFS (snapshot storage)                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## WAL-G Deployment: Sidecar vs Init Container

This implementation uses an **init container** to deliver the WAL-G binary. A sidecar
is equally valid and arguably more correct architecturally. The choice here was pragmatic:
the published WAL-G container image tags did not exist at the time of implementation
(`ghcr.io/wal-g/wal-g:v3.0.3-pg17` returned 404), so an init container downloading the
binary from GitHub releases was used instead.

### Init Container (this implementation)

```
┌─ Pod startup ──────────────────────────────────────────────────┐
│  init: walg-install                                            │
│    wget wal-g binary from GitHub releases → /shared/wal-g      │
│  init: postgres-pitr-init                                      │
│    writes conf.d/pitr.conf (archive_mode, archive_command)     │
│  container: postgres                                           │
│    archive_command = '/wal-g/wal-g wal-push %p'               │
│    (binary on shared emptyDir, available at container start)   │
└────────────────────────────────────────────────────────────────┘
```

### Sidecar Container (alternative)

The sidecar pattern runs WAL-G as a long-lived container alongside postgres. The binary
is shared to the postgres container via an emptyDir volume (same mechanism as above, but
delivered by a running sidecar rather than a one-shot init container). A more advanced
variant has the sidecar monitor `pg_wal/` directly and ship segments independently of
`archive_command`.

```
┌─ Pod ──────────────────────────────────────────────────────────┐
│  container: postgres                                           │
│    archive_command = '/wal-g/wal-g wal-push %p'               │
│                                                                │
│  container: wal-g-sidecar                                      │
│    image: <custom or official wal-g image>                     │
│    shares /wal-g emptyDir with postgres                        │
│    can provide: health probes, log streaming, monitoring       │
└────────────────────────────────────────────────────────────────┘
```

### Comparison

| | Init Container | Sidecar |
|---|---|---|
| **Binary delivery** | One-shot at pod start | Long-running process |
| **Upgrade WAL-G** | Requires pod restart | Requires pod restart (same PVC) |
| **Pod complexity** | 1 container running | 2 containers running (2/2) |
| **Logs** | Mixed into postgres container | Separate container logs |
| **Health probes** | Not possible | Sidecar can expose liveness probe |
| **Image requirement** | None — downloads binary at runtime | Requires a working container image |
| **Kubernetes native sidecars (1.29+)** | N/A | Guaranteed startup order — sidecar starts before main container |
| **Best for** | Simple setups, no private registry | Production, monitoring, independent lifecycle |

### Using a Sidecar in Practice

To switch to a sidecar, you need a container image that contains the WAL-G binary for
the correct platform (glibc, not musl). Options:

1. **Build your own** — `FROM postgres:17` + download the binary, push to your registry
2. **Official image** — check [github.com/wal-g/wal-g](https://github.com/wal-g/wal-g)
   for current published tags before referencing them
3. **Kubernetes 1.29+ native sidecar** — use `initContainers` with `restartPolicy: Always`
   to get a sidecar that starts before the main container and runs for the pod lifetime

The `walg-sidecar-statefulset-patch.yaml` in this repo can be adapted to either pattern
by changing the init container to a regular container with a persistent run loop.

---

## Recovery Procedure (Summary)

1. Run `./test.sh restore postgres` — Trilio restores the snapshot with postgres at 0 replicas
2. Run `./test.sh pitr-restore postgres "<target-time>"` — injects recovery config into
   the PVC via a debug pod, scales postgres to 1, and waits for promotion
3. Verify with `SELECT pg_is_in_recovery();` — returns `f` when complete

> **Always specify a `recovery_target_time`** — a timestamp safely before the incident,
> within the range of a fully-archived WAL segment. Do not omit the target time: the last
> archived WAL segment at the time of a disaster is frequently incomplete, causing
> PostgreSQL to panic with `could not locate a valid checkpoint record`. Use a timestamp
> a few seconds after the last known good write, well before the incident.

---

## Choosing a Safe Target Time

After a restore, postgres is at 0 replicas. You cannot query the database directly.
Use the row timestamps you noted before the incident:

- Note the `MAX(written_at)` from `writes_log` just before the disaster
- Choose a target time a few seconds **after** a confirmed WAL archive boundary
- Avoid the most recent WAL segment — it may have been partially written

A WAL segment boundary occurs when:
- The segment fills to 16 MB (automatic)
- `archive_timeout = 60` expires (configured in `pitr.conf`)
- `pg_switch_wal()` is called (done by the Trilio backup hook)

---

## Prerequisites

| Component | Purpose |
|-----------|---------|
| OpenShift Data Foundation (ODF) | Provides S3-compatible object storage via NooBaa |
| ObjectBucketClaim | Provisions the WAL archive bucket and credentials |
| WAL-G init container | Downloads `wal-g` binary at pod startup; placed on shared emptyDir volume |
| walg-config Secret | S3 credentials and endpoint, injected into the postgres container |
| Trilio for Kubernetes | Snapshot-based backup and restore of the full application |

All prerequisites are provisioned automatically by `./test.sh deploy postgres`.

---

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
