# MongoDB — PITR with Oplog Archiving + Trilio for Kubernetes

> **⚠️ OPTIONAL**: PITR is a complementary capability — not required for T4K backups. Your T4K snapshots work perfectly without it.
>
> **☁️ S3 ONLY**: The archiving mechanisms described here require S3-compatible object storage (AWS S3, MinIO, Ceph, etc.). NFS and filesystem-based T4K targets are **not supported** for WAL/log archiving.

## The Philosophy

MongoDB's equivalent of PostgreSQL's WAL is the **oplog** (operations log). The oplog is a capped collection in the `local` database that records every write operation applied to the database — in order, with timestamps. On a replica set, secondaries use the oplog to replicate from the primary. For PITR, we use the same mechanism to replay operations up to a specific point in time.

```
 Trilio for Kubernetes Snapshot         Trilio for Kubernetes Snapshot
        │                            │
        ▼                            ▼
────────●────────────────────────────●──────────────── time
        └─── oplog entries to S3 ───►└─── oplog ──────►

  RPO without oplog archiving: up to the full backup interval
  RPO with oplog archiving:    seconds (last oplog batch pushed to S3)
```

---

## The Tool: WAL-G (MongoDB backend)

WAL-G supports MongoDB oplog archiving — the same tool used for PostgreSQL and MariaDB. It continuously archives oplog batches to S3, compressed and optionally encrypted.

> **Important**: MongoDB oplog archiving requires the instance to be running as a **replica set**, even if it is a single node. A standalone MongoDB node does not maintain an oplog that can be used for PITR. The manifest in this folder converts the single-node deployment to a single-node replica set.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  mongodb StatefulSet pod                             │
│                                                      │
│  ┌────────────────┐    ┌────────────────────────┐   │
│  │   mongo:8.0    │    │  wal-g sidecar         │   │
│  │                │    │                        │   │
│  │  Replica Set   │    │  streams oplog batches │──►│──► S3 bucket
│  │  (single node) │───►│  to S3 continuously   │   │    /oplog/
│  └────────────────┘    └────────────────────────┘   │
│           │                                          │
│    /data/db (shared volume)                          │
└─────────────────────────────────────────────────────┘
```

---

## Key Difference from PostgreSQL

PostgreSQL writes WAL for every change and archives complete segment files. MongoDB's oplog is a **capped collection** — it overwrites oldest entries when it fills up. This means:

1. The oplog size must be large enough to retain entries until WAL-G archives them.
2. WAL-G polls the oplog continuously and archives batches, not segment files.
3. The oplog is not stored as files on disk that can be directly copied — WAL-G uses a MongoDB change stream to read and archive oplog entries in real time.

The `fsyncLock` pre-hook creates a clean oplog anchor point: all operations before the snapshot are in the frozen state; WAL-G can replay from the snapshot's oplog timestamp forward.

---

## Setup

### 1. Enable replica set mode (required for oplog)

The StatefulSet patch converts the single-node MongoDB to a replica set named `rs0`:

```bash
kubectl apply -f mongodb/pitr/mongodb-replset-configmap.yaml -n trilio-demo
kubectl patch statefulset mongodb -n trilio-demo \
  --patch-file mongodb/pitr/walg-sidecar-statefulset-patch.yaml
```

After the pod restarts, initialize the replica set:

```bash
kubectl exec -it mongodb-0 -n trilio-demo -- mongosh --quiet \
  -u root -p RootDemo1234! --authenticationDatabase admin \
  --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:27017'}]})"
```

### 2. Create the WAL-G configuration secret

```bash
kubectl create secret generic walg-config-mongodb \
  --from-literal=WALG_S3_PREFIX=s3://<your-bucket>/mongodb/oplog \
  --from-literal=AWS_REGION=<your-region> \
  --from-literal=AWS_ACCESS_KEY_ID=<your-key-id> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret> \
  -n trilio-demo
```

---

## Connection to the Trilio for Kubernetes Hook

MongoDB's `fsyncLock` pre-hook freezes the database at an exact oplog timestamp. WAL-G records this timestamp and uses it as the base for oplog archiving. After a Trilio for Kubernetes restore:

1. The snapshot is restored (frozen state from `fsyncLock` time T)
2. WAL-G fetches oplog entries from S3 starting at timestamp T
3. Replays them up to the target time

The oplog timestamp at the snapshot point is stored in the Trilio for Kubernetes backup metadata (via the `fsyncLock` response, which includes the oplog timestamp). Document this timestamp when you take demo backups for reference.

---

## PITR Recovery Procedure

### Step 1 — Trilio for Kubernetes restores the namespace

MongoDB starts from the frozen snapshot state.

### Step 2 — Identify the target time

```bash
# Convert your target datetime to a MongoDB Timestamp
# MongoDB uses seconds-since-epoch as the first component
python3 -c "from datetime import datetime; \
  t = datetime(2026, 2, 27, 14, 35, 0); \
  print(int(t.timestamp()))"
# Output: 1772145300
```

### Step 3 — Replay oplog from S3

```bash
# WAL-G fetches and replays oplog entries up to the target timestamp
kubectl exec -it mongodb-0 -n trilio-demo -- \
  wal-g oplog-replay \
    --since "Timestamp(1772141700, 1)" \
    --until "Timestamp(1772145300, 1)"
```

### Step 4 — Verify

```bash
kubectl delete job mongodb-consistency-checker -n trilio-demo --ignore-not-found
kubectl apply -f mongodb/checker/ -n trilio-demo
kubectl logs -f job/mongodb-consistency-checker -n trilio-demo
```

---

## Production Notes

1. **Oplog size**: The oplog must be large enough to buffer entries between WAL-G archive runs. For a busy database, a 5–10 GB oplog is common. Set with `--oplogSize` in MB when starting `mongod`, or adjust `rs.conf()`.

2. **Single-node replica set**: A single-node replica set has no automatic failover, but it enables the oplog and allows WAL-G archiving. For production, use a 3-node replica set.

3. **Sharded clusters**: For sharded MongoDB, each shard's oplog must be archived independently. WAL-G handles this but requires one sidecar per shard.

4. **Atlas / Ops Manager**: MongoDB Atlas provides native continuous backup with PITR. If your customers use Atlas, the oplog archiving approach is replaced by Atlas's built-in continuous backup feature.

5. **Oplog replay vs. mongorestore**: WAL-G's oplog replay is more efficient than using `mongorestore --oplogReplay` for large oplog windows, as it streams directly from S3 without downloading everything first.
