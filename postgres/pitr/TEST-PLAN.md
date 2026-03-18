# PostgreSQL PITR — Test Plan

End-to-end walkthrough for validating Point-In-Time Recovery with Trilio + WAL-G.

---

## Prerequisites

- `DEMO_NS` exported in your shell
- Trilio for Kubernetes operator running
- ODF/NooBaa available in the cluster
- Target `sa-lab-nfs-share1` in `trilio-system` configured

---

## Step 1 — Clean Start

```bash
./test.sh nuke
./test.sh deploy postgres
```

`deploy` will confirm WAL archiving is working before returning. Do not proceed until
it passes.

---

## Step 2 — Monitor Writer and WAL Activity

In one terminal, watch the writer:

```bash
kubectl logs -f job/postgres-writer -n $DEMO_NS
```

Note the row sequence numbers as they appear.

In another terminal, watch the postgres logs for WAL archive events:

```bash
kubectl logs -f postgres-0 -n $DEMO_NS -c postgres | grep -i "archive\|wal"
```

Note the sequence numbers in the writer output that correspond to WAL archive log
entries — these are your confirmed WAL boundaries.

---

## Step 3 — Backup

```bash
./test.sh backup postgres
```

Note the writer sequence number at the time of the quiesce — this is typically the
last row written before the backup hook fires. This is your **Phase 1 anchor** — the
snapshot will recover to this point automatically.

---

## Step 4 — Let the Writer Continue, Then Stop It

Let the writer run for at least one more WAL archive cycle after the backup completes
(watch for another archive log entry). Then delete it:

```bash
kubectl delete job postgres-writer -n $DEMO_NS
```

Note:
- The sequence number of the **last confirmed WAL archive** after the backup
- The sequence number of the **last row written** before the job stopped

---

## Step 5 — Restore

```bash
./test.sh restore postgres
```

Trilio restores the PVC. The `transformComponents` patch keeps postgres at 0 replicas —
it will not start until `pitr-restore` runs.

---

## Step 6 — PITR Restore

Choose a target timestamp associated with a **confirmed WAL archive boundary** after
the backup quiesce — not the last segment (may be partial). Add 1-2 seconds to the
`written_at` timestamp of the target row to account for the exclusive boundary:

```bash
./test.sh pitr-restore postgres "YYYY-MM-DD HH:MM:SS"
```

Example:

```bash
./test.sh pitr-restore postgres "2026-03-18 22:29:50"
```

---

## Step 7 — Verify

The recovery summary printed by `pitr-restore` shows total rows recovered. It should
match the sequence number near the WAL archive boundary you targeted.

```bash
kubectl exec postgres-0 -n $DEMO_NS -c postgres -- \
  psql -U demouser -d demodb \
  -c "SELECT COUNT(*) AS total_rows, MIN(written_at) AS first, MAX(written_at) AS last FROM writes_log;"
```

Check the audit log:

```bash
kubectl exec postgres-0 -n $DEMO_NS -c postgres -- \
  psql -U demouser -d demodb \
  -c "SELECT * FROM restore_log ORDER BY restored_at DESC;"
```

---

## Expected Results

| Checkpoint | Expected |
|---|---|
| Rows at snapshot (Phase 1) | Matches sequence number at backup quiesce |
| Rows after PITR (Phase 2) | Matches sequence number near target WAL boundary |
| `pg_is_in_recovery()` | `f` (promoted to primary) |
| `restore_log` | Entry with PITR target time and completion timestamp |

---

## Key Numbers to Record During the Test

| Event | Row # | Timestamp |
|---|---|---|
| Backup quiesce (last row before snapshot) | | |
| First WAL archive after backup | | |
| Last WAL archive before writer stopped | | |
| Last row written | | |
| PITR target (WAL boundary + 1-2s) | | |
| Rows recovered after PITR | | |
