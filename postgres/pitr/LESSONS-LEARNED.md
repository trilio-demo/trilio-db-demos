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

## 7. Internal vs External NooBaa Endpoint

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
