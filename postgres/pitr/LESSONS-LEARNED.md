# PostgreSQL PITR — Technical Lessons Learned

Operational findings from implementing WAL-G + Trilio PITR on OpenShift 4.20 / ODF.

---

## 1. WAL-G Has No Official Container Image with Stable Tags

**What happened:** The patch originally referenced `ghcr.io/wal-g/wal-g:v3.0.3-pg17`.
The pod failed with `ErrImagePull` — the image tag does not exist.

**Fix:** Replace the sidecar container with an init container that downloads the pre-built
binary directly from GitHub releases:

```
https://github.com/wal-g/wal-g/releases/download/v3.0.0/wal-g-pg-ubuntu-20.04-amd64
```

The binary runs in the `postgres:17` container (Debian/glibc). The init container uses
`alpine:3.19` for the download — the version check (`wal-g --version`) will fail in
alpine due to musl vs glibc, but the binary itself works correctly in the postgres container.

**Check the binary works:**
```bash
kubectl exec postgres-0 -n $DEMO_NS -- /wal-g/wal-g --version
```

---

## 2. Default postgresql.conf Contains "conf.d" in a Comment

**What happened:** The init container used `grep -q "conf.d"` to check whether
`include_dir = 'conf.d'` had already been appended to `postgresql.conf`. The default
PostgreSQL 17 `postgresql.conf` contains this comment:

```
#include_dir = '...'    # include files ending in '.conf' from directory 'conf.d'
```

The word "conf.d" in the comment caused `grep -q "conf.d"` to return true, so the actual
`include_dir = 'conf.d'` line was never appended. PostgreSQL started with `archive_mode = off`.

**Fix:** Use `^include_dir` to match only an uncommented active line:

```bash
grep -q "^include_dir" "${PGDATA}/postgresql.conf" || \
  echo "include_dir = 'conf.d'" >> "${PGDATA}/postgresql.conf"
```

---

## 3. archive_mode Requires a PostgreSQL Restart

`archive_mode` is not a reload-only parameter (`SIGHUP`). It requires a full PostgreSQL
restart to take effect. Since the init container writes the config before postgres starts,
this is handled automatically on first pod start. However if you modify the config in a
running pod, you must restart the StatefulSet:

```bash
kubectl rollout restart statefulset/postgres -n $DEMO_NS
```

Verify after restart:
```bash
kubectl exec postgres-0 -n $DEMO_NS -- \
  psql -U demouser -d demodb -c "SHOW archive_mode; SHOW archive_command;"
```

---

## 4. DEMO_NS Must Be Exported for envsubst

The `kapply` function in `test.sh` uses `envsubst '${DEMO_NS}'` to substitute the
namespace in manifests before applying. `envsubst` only substitutes **exported** variables.

```bash
# Wrong — envsubst won't see this
DEMO_NS=vbns-postgres-demo

# Correct
export DEMO_NS=vbns-postgres-demo
```

Similarly, inline env vars (`S3_ENDPOINT=... ./script.sh`) set for one command persist
in the shell if accidentally exported. Always check for lingering env vars when a script
behaves unexpectedly:

```bash
echo $S3_ENDPOINT
unset S3_ENDPOINT
```

---

## 5. WAL-G Hangs Silently Before Reporting Failure

**What happened:** After fixing `archive_mode`, `pg_stat_archiver` showed
`archived_count = 0` and `failed_count = 0` even after `pg_switch_wal()`. This looked
like the archive command wasn't being called at all.

**What was actually happening:** WAL-G was being called but hanging on a TLS connection
attempt to the S3 endpoint. PostgreSQL's archiver waits for the command to return before
incrementing either counter. The counts only update after the command exits (success or failure).

**Diagnosis:** Check for a running wal-g process:
```bash
kubectl exec postgres-0 -n $DEMO_NS -- ps aux | grep wal-g
```

Check `archive_status/` for `.ready` files that never become `.done`:
```bash
kubectl exec postgres-0 -n $DEMO_NS -- \
  ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status/
```

`.ready` = waiting or in progress. `.done` = successfully archived.

---

## 6. pg_switch_wal() Is Not Enough to Diagnose Archiving

`SELECT pg_switch_wal()` forces a WAL segment boundary but does not confirm archiving
is working — it only confirms postgres wrote the segment. The archiver process picks it
up asynchronously.

**Better diagnostic sequence:**

```bash
# 1. Force a WAL switch
psql -c "SELECT pg_switch_wal();"

# 2. Check archive_status for .ready vs .done
ls pg_wal/archive_status/

# 3. Check archiver stats
psql -c "SELECT archived_count, failed_count, last_archived_wal, last_archived_time FROM pg_stat_archiver;"

# 4. If failed_count > 0, check postgres logs for the actual error
kubectl logs postgres-0 -n $DEMO_NS | grep -i "archive\|wal-g\|ERROR"
```

---

## 7. Always Specify recovery_target_time — Never Replay All Available WAL

**What happened:** Running `pitr-restore` without a target time caused PostgreSQL to
replay all available WAL segments from S3. The last archived segment was partially written
at the moment of the disaster (pod killed mid-write) and archived to S3 incomplete.
PostgreSQL fetched it, found an invalid checkpoint record, and panicked:

```
LOG:  restored log file "000000010000000000000014" from archive
PANIC:  could not locate a valid checkpoint record at 0/14000028
```

The pod entered CrashLoopBackOff. Recovery requires removing the corrupt segment from S3
and re-running the restore from scratch.

**Fix:** Always provide an explicit `recovery_target_time` set to a known good point
**before** the disaster — typically a few seconds after the last confirmed good write:

```bash
./test.sh pitr-restore postgres "2026-03-18 18:22:45"
```

PostgreSQL stops replaying when it reaches that timestamp and never attempts to read
the corrupt final segment.

**Rule of thumb:** The last WAL segment at the time of a disaster is always suspect.
Use a target time that falls safely within the previous segment's range.

---

## 8. Internal vs External NooBaa Endpoint

NooBaa exposes two S3 endpoints:

| Endpoint | URL | CA |
|----------|-----|----|
| Internal service | `https://s3.openshift-storage.svc:443` | ODF service CA (`openshift-service-ca.crt` ConfigMap) |
| External route | `https://s3-openshift-storage.apps.<cluster>` | OCP ingress router CA |

WAL-G strictly verifies TLS certificates. The ODF service CA is automatically injected
into every namespace as the `openshift-service-ca.crt` ConfigMap, making it trivial to
trust. The ingress router CA requires extracting a separate secret from
`openshift-ingress-operator`.

**Always use the internal endpoint for in-cluster workloads.** It is faster, stays
in-cluster, and the CA cert is always available without extra steps.

Set `AWS_S3_FORCE_PATH_STYLE=true` — NooBaa uses path-style S3 URLs, not virtual-hosted.

---

## 9. Full Reset Requires Deleting the WAL Archive — `./test.sh nuke` Is Not Enough

**What happened:** After nuking the namespace and redeploying, the new postgres instance
started archiving WAL into the same NooBaa bucket alongside segments from the previous
run. Old WAL segments have conflicting LSN sequences, which can confuse recovery.

**Why:** `./test.sh nuke` deletes the Kubernetes namespace and Trilio Backup CRs. It
does not touch the NooBaa S3 bucket. WAL segments written by the previous postgres
instance remain in the bucket.

**Fix:** Delete the OBC before nuking the namespace. When an OBC is deleted, ODF/NooBaa
purges the provisioned bucket and all its contents.

**This is now fully automated.** `./test.sh nuke` deletes the OBC first, and
`./test.sh deploy postgres` handles the full PITR setup — OBC, secret, sidecar patch,
and archiving verification — in one command.

**Clean reset procedure:**

```bash
./test.sh nuke            # deletes OBC + WAL bucket + Trilio backups + namespace
./test.sh deploy postgres # redeploys postgres with WAL archiving fully configured and verified
```

**Rule of thumb:** For any clean PITR test, use `./test.sh nuke` — it handles the OBC
cleanup. A fresh OBC means a fresh bucket with no ambiguity about which WAL segments
belong to which postgres instance.

---

## 10. WAL Archiving Does Not Start Automatically on a Fresh Deploy

**What happened:** After `./test.sh deploy postgres`, `pg_stat_archiver` showed
`archived_count = 0` even though the sidecar patch was applied and `archive_mode = on`.
The writer had already started writing rows with no WAL coverage in S3.

**Why:** PostgreSQL only archives *completed* WAL segments. On a fresh database with
minimal activity, the current segment may sit open indefinitely — nothing triggers it
to close and be archived.

**Fix:** The deploy verification step now:
1. Inserts a dummy row into a `_wal_probe` table to guarantee WAL activity
2. Calls `pg_switch_wal()` twice — first to close the segment containing the write,
   second to give the archiver a segment to work on while polling
3. Fails hard if `archived_count` does not reach ≥ 1 within 120 seconds

This ensures WAL archiving is confirmed working before `deploy` returns. If it fails,
check `pg_stat_archiver.failed_count` and postgres logs for TLS or connectivity errors.

**Rule of thumb:** Do not start the writer until `deploy` has returned successfully.
All rows written after a confirmed archive are guaranteed to have WAL coverage in S3.

---

## 11. PostgreSQL Must Not Start in Normal Mode After a Trilio Restore

**What happened:** After a Trilio restore, PostgreSQL started normally (no
`recovery.signal` present), ran crash recovery from the local WAL in the PVC, and wrote
a new checkpoint. When `pitr-restore` was run afterwards and Phase 2 tried to fetch WAL
segment 6 from S3, PostgreSQL found an `invalid resource manager ID` at the start of the
segment and panicked:

```
PANIC: could not locate a valid checkpoint record at 0/6000028
```

**Why:** The normal startup checkpoint advanced the WAL timeline. The WAL segments in S3
were archived against the original timeline; the new local checkpoint was on a diverged
timeline. The two are incompatible.

**Fix:** Use a Trilio `transformComponents` patch in the Restore CR to set the
StatefulSet to 0 replicas during restore. PostgreSQL never starts. `pitr-restore` then
writes `recovery.signal` and `restore_command` directly to the PVC via a short-lived
debug pod, and scales postgres to 1. PostgreSQL starts exactly once — already in
recovery mode.

```yaml
transformComponents:
  custom:
    - transformName: scale-down-postgres
      resources:
        groupVersionKind:
          group: apps
          kind: StatefulSet
          version: v1
        objects:
          - postgres
      jsonPatches:
        - op: replace
          path: /spec/replicas
          value: 0
```

**Rule of thumb:** For PITR, the restore and the recovery configuration are a single
atomic operation. Never let postgres start between them.

---

## 12. Write Recovery Config to the PVC via a Debug Pod, Not kubectl exec

**What happened:** The original `pitr-restore` implementation used `kubectl exec` to
write `recovery.signal` and `restore_command` into a running postgres container, then
did a rollout restart. This failed because:

1. After restart, the init containers re-ran and the `postgres-pitr-init` init container
   overwrote `postgresql.conf` entries
2. If the pod was crashlooping (from a previous failed attempt), `kubectl exec` could
   not reach it

**Fix:** With postgres at 0 replicas (from the restore transform), spin up a temporary
`postgres:17` debug pod that mounts the same PVC and writes directly to `$PGDATA`:

```bash
kubectl run pitr-config-writer -n $DEMO_NS --image=postgres:17 --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":
    {"claimName":"postgres-data-postgres-0"}}],"containers":[{"name":"writer",
    "image":"postgres:17","command":["sleep","120"],
    "volumeMounts":[{"name":"data","mountPath":"/var/lib/postgresql/data"}]}]}}'

kubectl exec pitr-config-writer -n $DEMO_NS -- bash -c "
  sed -i '/^restore_command/d; /^recovery_target/d' \$PGDATA/postgresql.conf
  echo \"restore_command = '/wal-g/wal-g wal-fetch %f %p'\" >> \$PGDATA/postgresql.conf
  echo \"recovery_target_time = '2026-03-18 20:39:32+00'\" >> \$PGDATA/postgresql.conf
  echo \"recovery_target_action = 'promote'\" >> \$PGDATA/postgresql.conf
  touch \$PGDATA/recovery.signal
"
kubectl delete pod pitr-config-writer -n $DEMO_NS
```

Then scale postgres to 1. All of this is automated by `./test.sh pitr-restore`.

**Rule of thumb:** When you need to modify `$PGDATA` and the StatefulSet is at 0
replicas, a debug pod mounting the PVC is the correct tool — not a rollout restart.

---

## 13. The Debug Pod Pattern — Direct PVC Access Without a Running StatefulSet

When a StatefulSet is scaled to 0, there is no pod to `kubectl exec` into. But the PVC
still exists and its data is intact. A temporary debug pod mounting the PVC provides
full shell access to `$PGDATA` without starting the application.

**General pattern:**

```bash
kubectl run pgdebug -n $DEMO_NS --image=postgres:17 --restart=Never \
  --overrides='{
    "spec": {
      "volumes": [{"name":"data","persistentVolumeClaim":{"claimName":"postgres-data-postgres-0"}}],
      "containers": [{"name":"debug","image":"postgres:17","command":["sleep","300"],
        "volumeMounts":[{"name":"data","mountPath":"/var/lib/postgresql/data"}]}]
    }
  }'

kubectl wait --for=condition=Ready pod/pgdebug -n $DEMO_NS --timeout=60s
kubectl exec pgdebug -n $DEMO_NS -- bash   # interactive shell into $PGDATA
kubectl delete pod pgdebug -n $DEMO_NS
```

**Use the same image as the StatefulSet** (`postgres:17`) — file ownership and
permissions on the PVC match that UID. A different image may hit permission errors.

**Useful for:**
- Inspecting or editing `postgresql.conf` / `pg_hba.conf`
- Creating or removing `recovery.signal`
- Reading postgres logs from a crashed pod (`$PGDATA/log/`)
- Removing corrupt WAL segments from `pg_wal/`
- Any situation where the pod is crashlooping too fast to `kubectl exec` into

**On OpenShift:** the pod may land on a node that applies a different UID via SCC. If
you hit permission errors, add `"securityContext":{"runAsUser":999}` to the overrides
(999 is the postgres user UID in the official image).

---

## 14. recovery_target_time Is an Exclusive Boundary

**What happened:** Running `pitr-restore` with target time `2026-03-18 22:29:48`
(the `written_at` timestamp of row 218) recovered to row 217 — not 218.

**Why:** PostgreSQL treats `recovery_target_time` as an **exclusive** upper bound.
Transactions that committed *at* the exact target timestamp are not replayed. Only
transactions committed strictly before it are included.

**Fix:** To include a specific row, add one or two seconds to its `written_at`
timestamp when specifying the target time:

```bash
# Row 218 written_at = 2026-03-18 22:29:48
# To include row 218:
./test.sh pitr-restore postgres "2026-03-18 22:29:50"
```

**Rule of thumb:** When targeting a known row, use a timestamp 1-2 seconds *after*
that row's `written_at`. When targeting a safe recovery point before an incident,
use a timestamp 1-2 seconds *before* the first bad write.
