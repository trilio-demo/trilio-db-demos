# Test Environment

This file documents the exact environment in which v1.0.0 of this demo repo was validated. Use it to assess compatibility with your own cluster.

---

## Cluster

| Property | Value |
|---|---|
| Platform | OpenShift <!-- e.g. OpenShift 4.17, EKS 1.31, GKE 1.30, vanilla k8s 1.29 --> |
| Kubernetes version | <!-- e.g. v1.29.x --> |
| Node count | <!-- e.g. 3 workers --> |
| Node size | <!-- e.g. m5.2xlarge, 8 vCPU / 32 GB RAM --> |
| CNI | <!-- e.g. OVN-Kubernetes, Calico --> |
| CSI driver | <!-- e.g. ebs.csi.aws.com, disk.csi.azure.com, rbd.csi.ceph.com --> |
| VolumeSnapshotClass | <!-- name of the VSC used --> |
| Storage class | <!-- e.g. gp3-csi, standard-rwo --> |

---

## Trilio for Kubernetes

| Property | Value |
|---|---|
| TVK version | <!-- e.g. 3.0.0 --> |
| Install method | <!-- Helm / OLM / OperatorHub --> |
| Target type | NFS <!-- S3 / NFS --> |
| Target name | <!-- e.g. demo-nfs-target --> |
| S3 / NFS endpoint | <!-- masked, just the type: MinIO on-cluster / AWS S3 / NFS server --> |

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
| `kubectl` | <!-- e.g. v1.29.x --> | Used for all manifest applies and polling |
| `oc` | <!-- e.g. 4.17 --> | OpenShift only — required for anyuid SCC RoleBinding |
| `bash` | <!-- e.g. 5.2.x --> | test.sh runtime |
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
