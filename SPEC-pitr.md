# SPEC: PostgreSQL PITR on OpenShift + ODF

## Goal

Extend the existing postgres backup demo to implement full Point-In-Time Recovery (PITR)
using WAL archiving to S3-compatible object storage provided by OpenShift Data Foundation (ODF/NooBaa).

After this is complete, a restore will recover not just to the last Trilio snapshot but to
within ~60 seconds of any target time — eliminating the data loss gap between snapshots.

---

## Architecture

```
postgres container
  │
  │  archive_command = 'wal-g wal-push %p'   (every 60s or on segment fill)
  ▼
WAL-G sidecar  ──────────────────────────────►  ODF NooBaa S3 bucket
  (binary on shared emptyDir volume)              /postgres/wal/

Trilio snapshot  (base)  +  WAL segments (S3)  =  recovery to any point in time
```

---

## Requirements

### REQ-1: ODF ObjectBucketClaim for WAL storage

- Create an `ObjectBucketClaim` in the `trilio-db-demo` namespace
- ODF provisions a NooBaa bucket and injects a ConfigMap + Secret with endpoint and credentials
- The bucket name and endpoint must be extracted and used in REQ-2

**Acceptance:** `kubectl get obc -n trilio-db-demo` shows the OBC in `Bound` state

---

### REQ-2: walg-config Secret

Create a `walg-config` Secret in `trilio-db-demo` with the following keys, sourced from
the OBC-provisioned secret:

| Key | Value |
|-----|-------|
| `WALG_S3_PREFIX` | `s3://<bucket-name>/postgres/wal` |
| `AWS_ENDPOINT` | NooBaa S3 endpoint URL from OBC ConfigMap |
| `AWS_REGION` | `us-east-1` (NooBaa ignores region but WAL-G requires it) |
| `AWS_ACCESS_KEY_ID` | From OBC Secret |
| `AWS_SECRET_ACCESS_KEY` | From OBC Secret |
| `AWS_S3_FORCE_PATH_STYLE` | `true` (required — NooBaa uses path-style URLs, not virtual-hosted) |

**Acceptance:** Secret exists with all 6 keys

---

### REQ-3: Fix walg-sidecar-statefulset-patch.yaml — env vars in postgres container

**Bug:** The current patch injects S3 env vars into the `wal-g` sidecar only. The
`archive_command` runs inside the `postgres` container, which also needs the S3 env vars
to call `wal-g wal-push`.

**Fix:** Add all 6 `walg-config` secret keys as env vars on the `postgres` container in
the patch. This does not require modifying the base StatefulSet — the patch adds to it.

**Acceptance:** After patching, `kubectl exec postgres-0 -- env | grep WALG` returns
`WALG_S3_PREFIX` inside the postgres container

---

### REQ-4: Apply the WAL-G sidecar patch

Apply `postgres/pitr/walg-sidecar-statefulset-patch.yaml` to the running StatefulSet.
The pod rolls over, the init container writes the `archive_mode` config, and postgres
restarts with WAL archiving enabled.

**Acceptance:** `kubectl get pods -n trilio-db-demo` shows `postgres-0` with 2/2 containers
(postgres + wal-g sidecar)

---

### REQ-5: Verify WAL archiving is active

Confirm postgres is successfully shipping WAL segments to S3.

```bash
kubectl exec -n trilio-db-demo postgres-0 -c postgres -- \
  psql -U demouser -d demodb -c "SELECT archived_count, failed_count, last_archived_wal, last_archive_time FROM pg_stat_archiver;"
```

**Acceptance:** `archived_count > 0` and `failed_count = 0`

---

### REQ-6: Update test.sh — add `pitr-restore` command

Add a new `./test.sh pitr-restore postgres <target-time>` command that automates the
post-restore WAL replay steps currently requiring manual `kubectl exec`:

1. Wait for Trilio restore to complete (reuse existing `wait_tvk` logic)
2. Exec into `postgres-0` and append recovery config to `postgresql.conf`:
   - `restore_command = 'wal-g wal-fetch %f %p'`
   - `recovery_target_time = '<target-time>'`
   - `recovery_target_action = 'promote'`
3. Create `recovery.signal` in `$PGDATA`
4. Rollout restart the StatefulSet
5. Wait for pod to be ready
6. Verify `pg_is_in_recovery()` returns `f` (recovery complete, promoted to primary)

**Acceptance:** `./test.sh pitr-restore postgres "2026-03-17 14:35:00"` runs end-to-end
without manual steps

---

### REQ-7: Update consistency checker for PITR

The current checker only verifies no gaps up to the snapshot point. For PITR it should
also report:

- How many rows were recovered **beyond** the snapshot point (Phase 2 WAL replay)
- The timestamp of the last recovered row vs the requested `recovery_target_time`
- Whether the recovered row count exceeds what was in the snapshot (proves WAL replay worked)

**Acceptance:** After a `pitr-restore`, checker output includes a "PITR Recovery" section
showing rows recovered beyond the snapshot

---

### REQ-8: Update DEMO_NS in walg-sidecar-statefulset-patch.yaml

The patch file has hardcoded `trilio-demo` in comments. Update comments to use
`${DEMO_NS}` convention for consistency. The `kubectl patch` command in test.sh must
also pipe through `envsubst` (same pattern as `kapply`).

**Acceptance:** `./test.sh deploy postgres` followed by PITR setup works in any namespace

---

## Out of Scope

- WAL-G retention/pruning policy (future work)
- WAL-G encryption at rest (future work)
- PITR for MariaDB, MongoDB, SQL Server (separate specs)
- Streaming replication / standby (not a Trilio demo concern)

---

## Implementation Order

| # | Requirement | Depends on |
|---|-------------|------------|
| 1 | REQ-1: OBC manifest | — |
| 2 | REQ-2: walg-config secret (scripted from OBC output) | REQ-1 |
| 3 | REQ-3: Fix sidecar patch (postgres container env vars) | — |
| 4 | REQ-4: Apply sidecar patch | REQ-2, REQ-3 |
| 5 | REQ-5: Verify archiving | REQ-4 |
| 6 | REQ-6: pitr-restore command in test.sh | REQ-5 |
| 7 | REQ-7: Checker update | REQ-6 |
| 8 | REQ-8: DEMO_NS cleanup in patch | REQ-3 |
