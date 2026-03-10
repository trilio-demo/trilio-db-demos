#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Trilio for Kubernetes — DB Demos Integration Test
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    ./test.sh deploy              Deploy all 4 databases + writers (1 row/sec, 10k rows)
#    ./test.sh deploy --high-pressure
#                                  Deploy with high-pressure writers (10 rows/sec, 50k rows)
#    ./test.sh backup              Create backup, wait for completion
#    ./test.sh restore [db]        Cleanup workloads, restore, wait
#                                    db = postgres|mariadb|mongodb|sqlserver|all (default: all)
#    ./test.sh check [db]          Run consistency checkers, report pass/fail
#                                    db = postgres|mariadb|mongodb|sqlserver|all (default: all)
#    ./test.sh status              Show pods, writers, backup/restore state
#    ./test.sh cleanup [db]        Delete workload resources (keep namespace + data at rest)
#                                    db = postgres|mariadb|mongodb|sqlserver|all (default: all)
#    ./test.sh nuke                Delete the entire namespace (start fresh)
#    ./test.sh full                deploy → backup → restore all → check all (E2E)
#    ./test.sh full --high-pressure
#                                  Full E2E test with high-pressure writers
#
#  Environment overrides:
#    NAMESPACE      (default: trilio-demo)
#    BACKUP_NAME    (default: all-dbs-backup)
#    TIMEOUT_READY  pod ready timeout in seconds  (default: 300)
#    TIMEOUT_BACKUP backup completion timeout     (default: 1800)
#    TIMEOUT_RESTORE restore completion timeout   (default: 1800)
#    TIMEOUT_CHECK  checker job timeout           (default: 300)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NS="${NAMESPACE:-trilio-demo}"
BACKUP_NAME="${BACKUP_NAME:-all-dbs-backup}"
TIMEOUT_READY="${TIMEOUT_READY:-300}"
TIMEOUT_BACKUP="${TIMEOUT_BACKUP:-1800}"
TIMEOUT_RESTORE="${TIMEOUT_RESTORE:-1800}"
TIMEOUT_CHECK="${TIMEOUT_CHECK:-300}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBS=(postgres mariadb mongodb sqlserver)
HIGH_PRESSURE=0   # set to 1 via --high-pressure flag

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0

pass() { echo -e "${GREEN}  ✅  $1${NC}"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "${RED}  ❌  $1${NC}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo -e "${YELLOW}  ⚠️   $1${NC}"; WARN_COUNT=$((WARN_COUNT + 1)); }
info() { echo -e "${BLUE}  ℹ️   $1${NC}"; }
step() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }
div()  { echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

die()  { echo -e "${RED}${BOLD}FATAL: $1${NC}" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Validate DB arg
resolve_dbs() {
  local arg="${1:-all}"
  if [[ "$arg" == "all" ]]; then
    echo "${DBS[@]}"
  elif [[ " ${DBS[*]} " == *" $arg "* ]]; then
    echo "$arg"
  else
    die "Unknown database '$arg'. Use: postgres|mariadb|mongodb|sqlserver|all"
  fi
}

# Apply a manifest and report
kapply() {
  local file="$1"
  if kubectl apply -f "$file" -n "$NS" > /dev/null 2>&1; then
    pass "Applied $(basename $file)"
  else
    fail "Failed to apply $(basename $file)"
    kubectl apply -f "$file" -n "$NS" 2>&1 | sed 's/^/    /'
  fi
}

# Wait for a StatefulSet to have all pods ready
wait_sts_ready() {
  local name="$1" timeout="$TIMEOUT_READY" elapsed=0
  info "Waiting for StatefulSet/$name to be ready (timeout ${timeout}s)..."
  while true; do
    local ready
    ready=$(kubectl get sts "$name" -n "$NS" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired
    desired=$(kubectl get sts "$name" -n "$NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
      pass "StatefulSet/$name is ready ($ready/$desired)"
      return 0
    fi
    if (( elapsed >= timeout )); then
      fail "StatefulSet/$name not ready after ${timeout}s (${ready:-0}/${desired:-?})"
      kubectl describe sts "$name" -n "$NS" 2>&1 | grep -A5 "Events:" | tail -6 | sed 's/^/    /'
      return 1
    fi
    sleep 5; (( elapsed += 5 ))
    printf "    %3ds  ready=%s/%s\r" "$elapsed" "${ready:-0}" "${desired:-1}"
  done
}

# Wait for a Job to complete (succeeded or failed)
wait_job() {
  local name="$1" timeout="${2:-$TIMEOUT_CHECK}" elapsed=0
  while true; do
    local succeeded failed
    succeeded=$(kubectl get job "$name" -n "$NS" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    failed=$(kubectl get job "$name" -n "$NS" \
      -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
    if [[ "${succeeded:-0}" -ge 1 ]]; then return 0; fi
    if [[ "${failed:-0}" -ge 1 ]]; then return 1; fi
    if (( elapsed >= timeout )); then return 2; fi
    sleep 5; (( elapsed += 5 ))
    printf "    %3ds  waiting for job/%s...\r" "$elapsed" "$name"
  done
}

# Wait for a T4K resource to reach a terminal phase
wait_tvk() {
  local kind="$1" name="$2" timeout="$3" elapsed=0
  local ok_phase="${4:-Available}"
  # Use fully-qualified API group to avoid conflicts with other operators
  # (e.g. CloudNativePG also registers a 'backup' CRD)
  local fqkind
  case "$kind" in
    backup)       fqkind="backups.triliovault.trilio.io" ;;
    restore)      fqkind="restores.triliovault.trilio.io" ;;
    backupplan)   fqkind="backupplans.triliovault.trilio.io" ;;
    *)            fqkind="$kind" ;;
  esac
  info "Waiting for $kind/$name → $ok_phase (timeout ${timeout}s)..."
  while true; do
    local phase
    phase=$(kubectl get "$fqkind" "$name" -n "$NS" \
      -o jsonpath='{.status.status}' 2>/dev/null || echo "Unknown")
    if [[ "$phase" == "$ok_phase" ]]; then
      pass "$kind/$name reached phase: $phase"
      return 0
    fi
    if [[ "$phase" == "Failed" ]]; then
      fail "$kind/$name failed"
      kubectl get "$fqkind" "$name" -n "$NS" \
        -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
        | grep -E '"reason"|"message"' | head -10 | sed 's/^/    /'
      return 1
    fi
    if (( elapsed >= timeout )); then
      fail "$kind/$name did not reach $ok_phase after ${timeout}s (current: $phase)"
      return 1
    fi
    sleep 10; (( elapsed += 10 ))
    printf "    %3ds  phase=%s\r" "$elapsed" "$phase"
  done
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_deploy() {
  div
  echo -e "${BOLD}  DEPLOY — All 4 databases to namespace: $NS${NC}"
  div

  step "Namespace"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
  pass "Namespace $NS ready"

  for db in "${DBS[@]}"; do
    step "Deploy: $db"
    local dir="$SCRIPT_DIR/$db"
    # Apply all manifests in deploy/ in sorted order (handles extra files like serviceaccounts)
    for f in $(ls "$dir/deploy/"*.yaml 2>/dev/null | sort); do
      kapply "$f"
    done
  done

  # OpenShift: grant anyuid SCC to sqlserver SA so it can run as uid 10001 (mssql)
  if kubectl api-resources | grep -q "securitycontextconstraints"; then
    step "OpenShift SCC (SQL Server needs anyuid for UID 10001)"
    if oc adm policy add-scc-to-serviceaccount anyuid -z sqlserver -n "$NS" > /dev/null 2>&1; then
      pass "anyuid SCC granted to sqlserver ServiceAccount"
    else
      warn "Could not grant anyuid SCC — SQL Server may fail to start (are you cluster-admin?)"
    fi
  fi

  step "Waiting for all StatefulSets to be ready"
  for db in "${DBS[@]}"; do
    wait_sts_ready "$db" || true
  done

  step "Deploying writers"
  if [[ "$HIGH_PRESSURE" -eq 1 ]]; then
    info "High-pressure mode: 10 rows/sec, 50,000 rows per database"
  else
    info "Standard mode: 1 row/sec, 10,000 rows per database"
  fi
  for db in "${DBS[@]}"; do
    local dir="$SCRIPT_DIR/$db"
    if [[ "$HIGH_PRESSURE" -eq 1 ]]; then
      kapply "$dir/writer/writer-configmap-highpressure.yaml"
    else
      kapply "$dir/writer/writer-configmap.yaml"
    fi
    # Delete existing writer job if present (jobs are immutable)
    kubectl delete job "${db}-writer" -n "$NS" --ignore-not-found > /dev/null 2>&1
    kapply "$dir/writer/writer-job.yaml"
  done

  step "Deploying Trilio hooks"
  for db in "${DBS[@]}"; do
    kapply "$SCRIPT_DIR/$db/trilio/hook.yaml"
  done

  step "Deploying combined BackupPlan"
  kapply "$SCRIPT_DIR/shared/trilio/backupplan.yaml"

  div
  summary
}

cmd_backup() {
  div
  echo -e "${BOLD}  BACKUP — $BACKUP_NAME${NC}"
  div

  step "Checking BackupPlan target is configured"
  if grep -q '<YOUR_TARGET' "$SCRIPT_DIR/shared/trilio/backupplan.yaml" 2>/dev/null; then
    die "shared/trilio/backupplan.yaml still has placeholder values.\nEdit it and replace <YOUR_TARGET_NAME> and <YOUR_TARGET_NS> with your Trilio Target CR name/namespace."
  fi
  pass "BackupPlan target is configured"

  step "Checking writers are running"
  for db in "${DBS[@]}"; do
    local running
    running=$(kubectl get job "${db}-writer" -n "$NS" \
      -o jsonpath='{.status.active}' 2>/dev/null || echo "0")
    if [[ "${running:-0}" -ge 1 ]]; then
      pass "Writer job ${db}-writer is active"
    else
      warn "Writer job ${db}-writer is NOT active — backup will still work but no live writes"
    fi
  done

  step "Creating backup"
  # Delete existing backup object if present
  kubectl delete backup "$BACKUP_NAME" -n "$NS" --ignore-not-found > /dev/null 2>&1
  sleep 2
  kapply "$SCRIPT_DIR/shared/trilio/backup.yaml"

  step "Waiting for backup to complete"
  wait_tvk backup "$BACKUP_NAME" "$TIMEOUT_BACKUP" "Available" || true

  div
  summary
}

cmd_restore() {
  local target="${1:-all}"
  local dbs_to_restore
  read -ra dbs_to_restore <<< "$(resolve_dbs "$target")"

  div
  echo -e "${BOLD}  RESTORE — ${dbs_to_restore[*]}${NC}"
  div

  step "Cleaning up workload resources for: ${dbs_to_restore[*]}"
  for db in "${dbs_to_restore[@]}"; do
    _cleanup_db "$db"
  done

  step "Triggering restore"
  if [[ "$target" == "all" ]]; then
    local restore_name="all-dbs-restore"
    kubectl delete restore "$restore_name" -n "$NS" --ignore-not-found > /dev/null 2>&1
    sleep 2
    kapply "$SCRIPT_DIR/shared/trilio/restore-all.yaml"
    wait_tvk restore "$restore_name" "$TIMEOUT_RESTORE" "Completed" || true
  else
    local restore_name="${target}-restore"
    kubectl delete restore "$restore_name" -n "$NS" --ignore-not-found > /dev/null 2>&1
    sleep 2
    kapply "$SCRIPT_DIR/shared/trilio/restore-${target}.yaml"
    wait_tvk restore "$restore_name" "$TIMEOUT_RESTORE" "Completed" || true
  fi

  step "Waiting for StatefulSets to recover"
  for db in "${dbs_to_restore[@]}"; do
    wait_sts_ready "$db" || true
  done

  div
  summary
}

cmd_check() {
  local target="${1:-all}"
  local dbs_to_check
  read -ra dbs_to_check <<< "$(resolve_dbs "$target")"

  div
  echo -e "${BOLD}  CONSISTENCY CHECK — ${dbs_to_check[*]}${NC}"
  div

  step "Deploying checker jobs"
  for db in "${dbs_to_check[@]}"; do
    local dir="$SCRIPT_DIR/$db/checker"
    # Delete completed/failed checker jobs
    kubectl delete job "${db}-consistency-checker" -n "$NS" --ignore-not-found > /dev/null 2>&1
    sleep 1
    kapply "$dir/checker-configmap.yaml"
    kapply "$dir/consistency-checker-job.yaml"
  done

  step "Waiting for checkers to complete"
  local checker_results=()
  for db in "${dbs_to_check[@]}"; do
    local job="${db}-consistency-checker"
    printf "  Waiting for %s..." "$job"
    local rc=0
    wait_job "$job" "$TIMEOUT_CHECK" || rc=$?
    echo ""  # newline after the \r progress

    if [[ $rc -eq 0 ]]; then
      pass "Checker job $job completed"
      checker_results+=("${db}:PASS")
    elif [[ $rc -eq 1 ]]; then
      fail "Checker job $job FAILED (job reported failure)"
      checker_results+=("${db}:FAIL")
    else
      fail "Checker job $job timed out after ${TIMEOUT_CHECK}s"
      checker_results+=("${db}:TIMEOUT")
    fi
  done

  step "Checker output"
  for db in "${dbs_to_check[@]}"; do
    echo ""
    echo -e "${BOLD}  ┌── $db ─────────────────────────────────────────────────────${NC}"
    kubectl logs "job/${db}-consistency-checker" -n "$NS" 2>/dev/null \
      | sed 's/^/  │  /' || echo "  │  (no logs)"
    echo -e "${BOLD}  └──────────────────────────────────────────────────────────────${NC}"
  done

  step "Check summary"
  for result in "${checker_results[@]}"; do
    local db="${result%%:*}"
    local status="${result##*:}"
    if [[ "$status" == "PASS" ]]; then
      pass "$db — consistency check PASSED"
    else
      fail "$db — consistency check $status"
    fi
  done

  div
  summary
}

cmd_status() {
  div
  echo -e "${BOLD}  STATUS — namespace: $NS${NC}"
  div

  echo -e "\n${BOLD}Pods:${NC}"
  kubectl get pods -n "$NS" \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' \
    2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo -e "\n${BOLD}StatefulSets:${NC}"
  kubectl get sts -n "$NS" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo -e "\n${BOLD}PersistentVolumeClaims:${NC}"
  kubectl get pvc -n "$NS" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo -e "\n${BOLD}Writer Jobs:${NC}"
  kubectl get job -n "$NS" \
    -l 'app in (postgres-writer,mariadb-writer,mongodb-writer,sqlserver-writer)' \
    2>/dev/null | sed 's/^/  /' || \
  kubectl get job -n "$NS" 2>/dev/null | grep -E "writer|checker" | sed 's/^/  /' || \
  echo "  (none)"

  echo -e "\n${BOLD}Trilio Backups:${NC}"
  kubectl get backup -n "$NS" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo -e "\n${BOLD}Trilio Restores:${NC}"
  kubectl get restore -n "$NS" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo -e "\n${BOLD}Trilio Hooks:${NC}"
  kubectl get hook -n "$NS" 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  div
}

cmd_cleanup() {
  local target="${1:-all}"
  local dbs_to_clean
  read -ra dbs_to_clean <<< "$(resolve_dbs "$target")"

  div
  echo -e "${BOLD}  CLEANUP — workloads for: ${dbs_to_clean[*]}${NC}"
  div

  for db in "${dbs_to_clean[@]}"; do
    step "Cleaning $db"
    _cleanup_db "$db"
  done

  div
  info "Namespace $NS and Trilio objects (hooks, backupplan, backup, restore) preserved."
  info "Run './test.sh restore' to restore from the last backup."
}

cmd_nuke() {
  div
  echo -e "${RED}${BOLD}  NUKE — deleting namespace $NS entirely${NC}"
  div
  read -r -p "  Are you sure? This deletes the namespace and all Kubernetes objects (Backup CRs, PVCs, etc.). Backup data already written to the Target (S3/NFS) is NOT deleted. [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    kubectl delete namespace "$NS" --ignore-not-found
    pass "Namespace $NS deleted"
  else
    info "Aborted."
  fi
}

cmd_full() {
  div
  echo -e "${BOLD}  FULL E2E TEST${NC}"
  echo -e "  deploy → wait 2min → backup → wait 1min → restore all → check all"
  div

  cmd_deploy

  step "Letting writers run for 2 minutes before backup"
  for i in $(seq 120 -10 10); do
    printf "  %3ds remaining...\r" "$i"
    sleep 10
  done
  echo ""

  cmd_backup

  step "Letting writers continue for 1 minute post-backup"
  for i in $(seq 60 -10 10); do
    printf "  %3ds remaining...\r" "$i"
    sleep 10
  done
  echo ""

  cmd_restore "all"
  cmd_check "all"
}

# ── Internal: delete one DB's workload resources ──────────────────────────────
_cleanup_db() {
  local db="$1"
  # Stop writer job first
  kubectl delete job "${db}-writer" -n "$NS" --ignore-not-found > /dev/null 2>&1 && \
    info "Deleted job/${db}-writer" || true

  # Delete StatefulSet (pods follow)
  kubectl delete sts "$db" -n "$NS" --ignore-not-found > /dev/null 2>&1 && \
    info "Deleted sts/$db" || true

  # Wait for pods to terminate
  local elapsed=0
  while kubectl get pods -n "$NS" -l "app=$db" --no-headers 2>/dev/null | grep -q .; do
    if (( elapsed >= 120 )); then
      warn "Pods for $db still terminating after 120s — proceeding anyway"
      break
    fi
    printf "    Waiting for %s pods to terminate... %ds\r" "$db" "$elapsed"
    sleep 5; (( elapsed += 5 ))
  done
  echo ""

  # Delete PVCs
  kubectl delete pvc -n "$NS" -l "app=$db" --ignore-not-found > /dev/null 2>&1 && \
    info "Deleted PVCs for $db" || true

  # Fallback: delete PVCs by name pattern
  kubectl get pvc -n "$NS" --no-headers 2>/dev/null \
    | awk '{print $1}' | grep "^${db}" \
    | xargs -r kubectl delete pvc -n "$NS" > /dev/null 2>&1 || true

  pass "Cleaned up $db workloads"
}

# ── Summary ───────────────────────────────────────────────────────────────────
summary() {
  echo ""
  if (( FAIL_COUNT == 0 )); then
    echo -e "${GREEN}${BOLD}  ✅  All checks passed  (${PASS_COUNT} passed, ${WARN_COUNT} warnings)${NC}"
  else
    echo -e "${RED}${BOLD}  ❌  ${FAIL_COUNT} failure(s)  (${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings)${NC}"
  fi
  div
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Parse flags (--high-pressure can appear anywhere after the command)
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --high-pressure) HIGH_PRESSURE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

CMD="${ARGS[0]:-help}"
ARG2="${ARGS[1]:-all}"

case "$CMD" in
  deploy)   cmd_deploy ;;
  backup)   cmd_backup ;;
  restore)  cmd_restore "$ARG2" ;;
  check)    cmd_check   "$ARG2" ;;
  status)   cmd_status ;;
  cleanup)  cmd_cleanup "$ARG2" ;;
  nuke)     cmd_nuke ;;
  full)     cmd_full ;;
  help|--help|-h)
    sed -n '/^#  Usage:/,/^# ━/p' "$0" | head -25
    ;;
  *)
    die "Unknown command '$CMD'. Run './test.sh help' for usage."
    ;;
esac
