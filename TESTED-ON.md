# Test Environment

This file documents the exact environment in which v1.0.0 of this demo repo was validated. Use it to assess compatibility with your own cluster.

---

## Cluster

| Property | Value |
|---|---|
| Platform | Red Hat OpenShift 4.20.14 (channel: fast-4.20) |
| Kubernetes version | v1.33.6 |
| Masters | 3 × 8 vCPU / 32 GB RAM — RHEL CoreOS 9.6 |
| Workers | 4 × 16 vCPU / 64 GB RAM — RHEL CoreOS 9.6 |
| CNI | OVN-Kubernetes |
| CSI driver | `openshift-storage.rbd.csi.ceph.com` (Red Hat ODF / Ceph RBD) |
| VolumeSnapshotClass | `ocs-storagecluster-rbdplugin-snapclass` |
| Storage class | `ocs-storagecluster-ceph-rbd` (default) |

---

## Trilio for Kubernetes

| Property | Value |
|---|---|
| TVK version | 5.3.0 |
| Install method | OperatorHub (OLM) — channel `stable` |
| Target type | NFS |
| Target name | `demo-nfs-target` |
| S3 / NFS endpoint | On-cluster NFS server |

---

## Database Images Tested

| Database | Image | Version |
|---|---|---|
| PostgreSQL | `postgres:17` | 17.x |
| MariaDB | `mariadb:11.4` | 11.4 LTS |
| MongoDB | `mongo:8.0` | 8.0.x |
| SQL Server | `mcr.microsoft.com/mssql/server:2022-latest` | SQL Server 2022 |

---

## Client Tools

| Tool | Version | Notes |
|---|---|---|
| `oc` | 4.19.0 (client) | Used for all manifest applies and polling; doubles as `kubectl` |
| `bash` | 5.x | test.sh runtime |
| `bc` | any | Used in test.sh for arithmetic |

---

## What Was Tested

All tests were run using `test.sh` in the following modes:

### Solo E2E (per-DB, individual manifests)

```bash
for db in postgres mariadb mongodb sqlserver; do
  ./test.sh nuke && ./test.sh full $db
done
```

| Database | Result | Rows written | Gap check |
|---|---|---|---|
| postgres | ✅ PASSED | 194 | 0 gaps |
| mariadb | ✅ PASSED | 195 | 0 gaps |
| mongodb | ✅ PASSED | — | 0 gaps |
| sqlserver | ✅ PASSED | 315 | 0 gaps |

### Combined E2E (all 4 DBs, shared BackupPlan) — `./test.sh full`

| Result | Notes |
|---|---|
| <!-- PASSED/not run --> | <!-- any notes --> |

### High-pressure mode — `./test.sh full --high-pressure`

| Result | Notes |
|---|---|
| <!-- PASSED/not run --> | Python+pip batch writers (postgres/mariadb/mongodb) and bash+sqlcmd batch writer (sqlserver) |

---

## Known Limitations / Not Tested

- **PVC resize** — backup/restore after storage expansion not validated
- **Multi-replica** — all databases run as single-replica StatefulSets; multi-replica (replication sets, Galera, etc.) not tested
- **Encrypted PVCs** — not tested
- **Network policies** — no NetworkPolicy was applied during testing; behaviour with strict network policies is untested
- **ARM64 nodes** — not tested (SQL Server 2022 Linux supports ARM64 but was not validated)
- **Air-gapped clusters** — images pulled from public registries; air-gapped pull-through mirrors not tested

---

## How to Validate in Your Environment

1. Ensure your CSI driver has a `VolumeSnapshotClass` configured
2. Create a Trilio `Target` CR pointing to your S3 or NFS storage
3. Update `target.name` and `target.namespace` in all `*/trilio/backupplan.yaml` files (or `shared/trilio/backupplan.yaml` for the combined test)
4. Run `./test.sh full postgres` to validate a single DB first
5. If that passes, run the full loop:
   ```bash
   for db in postgres mariadb mongodb sqlserver; do ./test.sh nuke && ./test.sh full $db; done
   ```
