#!/usr/bin/env bash
# e2e-konk-test.sh — End-to-end health validation for the konk stack
#
# Tests the entire konk data path:
#   konk-operator → Konk CR → bulk-konk (apiserver + etcd + init) → KonkService CRs
#   → kubeconfig secrets → kubectl-apiservice pods → APIService registration in konk
#   → bulk (atlas.bulk) connectivity to bulk-konk
#
# Sections:
#   1.  konk-operator (konk namespace)
#   2.  Core infrastructure (aggregate namespace: bulk-konk, etcd, init)
#   3.  Image version consistency (operator expected vs running)
#   4.  Konk CR + Etcd CR status (Deployed condition + ReleaseFailed detection)
#   5.  KonkService CR statuses (all namespaces)
#   6.  konk-service pods health (all namespaces)
#   7.  CA trust chain (bulk-konk CA vs kubeconfig secrets)
#   8.  APIServices inside konk (queried from a kubectl-apiservice pod)
#   9.  Deep test: sample namespace (default: tagging-v2)
#   10. Bulk (atlas.bulk) integration with konk
#   11. konk-operator log health
#   12. cert-manager CA integration
#   13. Konk API deep test — query resources in konk (tagging, dnsconfig, etc.)
#   14. External API integration — test tagging + bulk export/import via CSP endpoint
#   15. Konk APIService backend health — all pods in konk namespaces (aggregate, ddi, hostapp, ngp-cp, ntp, tagging-v2, redirect, endpoints)
#   16. Stale node containers (Helm merge ghost detection)
#   17. Stale konk-service container image (ghost detection)
#   18. Stale KonkService deployments (old chart names)
#   19. Excluded bulk-konk resources (not Helm-managed)
#
# Usage:
#   ./e2e-konk-test.sh                        # full run (sample ns = tagging-v2)
#   ./e2e-konk-test.sh --section 11           # run ONLY section 11
#   ./e2e-konk-test.sh --section 8-10         # run sections 8 through 10 (range)
#   ./e2e-konk-test.sh --section 8-           # run sections 8 to end
#   ./e2e-konk-test.sh --section 13 --section 14  # run sections 13 and 14
#   ./e2e-konk-test.sh --section 15          # run ONLY Konk APIService backend health
#   ./e2e-konk-test.sh --sample-ns atcapi     # use different sample namespace
#   ./e2e-konk-test.sh --skip-bulk            # skip bulk integration test
#   ./e2e-konk-test.sh --skip-exec            # skip kubectl exec tests (read-only)
#   ./e2e-konk-test.sh --skip-ca              # skip CA chain validation
#   ./e2e-konk-test.sh --skip-trigger-registration # section 8: skip default registration trigger test
#   ./e2e-konk-test.sh -v                     # verbose (show all passing details)
#   ./e2e-konk-test.sh -d                     # debug (show commands + full output)
#   ./e2e-konk-test.sh --csp-url URL --token TOKEN  # for section 14 (external API)
#
# Environment variables:
#   KONK_E2E_TOKEN   — Bearer token for CSP API calls (section 14). Avoids --token flag.
#   KONK_E2E_CSP_URL — CSP base URL (default: auto-detected from cluster name).
#
# Requirements: kubectl, openssl, curl (for section 14), jq (optional)

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
KONK_NAMESPACE="konk"
AGGREGATE_NAMESPACE="aggregate"
KONK_CR_NAME="bulk-konk"
SAMPLE_NS="tagging-v2"
SKIP_BULK=false
SKIP_EXEC=false
SKIP_CA=false
TRIGGER_REGISTRATION=true
CHECK_HOOKS=false
VERBOSE=false
DEBUG=false
RUN_SECTIONS=()          # empty = run all
LAST_SECTION=19          # update when adding new sections
CSP_URL="${KONK_E2E_CSP_URL:-}"
CSP_TOKEN="${KONK_E2E_TOKEN:-}"
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/token-file.txt"

# ── Cluster-to-CSP endpoint mapping ──────────────────────────────────────────
# Maps kubectl context substrings to their CSP base URLs.
# Add new clusters here — keep CLUSTER_KEYS and CLUSTER_URLS in sync.
CLUSTER_KEYS=(  "us-stg-1"  "us-dev-2"  "us-dev-5"  "gov-stg-2"  "gov-prd-2" )
CLUSTER_URLS=(
  "https://stage.csp.infoblox.com"
  "https://csp.us-dev-2.eng.test.infoblox.com"
  "https://csp.us-dev-5.eng.test.infoblox.com"
  "https://csp.gov-stg-2.stg.infoblox-fedcloud.com"
  "https://csp.gov-prd-2.infoblox-fedcloud.com"  # TODO: verify correct prod URL
)

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --section)
      if [[ "$2" == *-* ]]; then
        _from=${2%%-*}; _to=${2##*-}
        [[ -z "$_to" ]] && _to=$LAST_SECTION  # open-ended range: 7- means 7 to last
        for (( _i=_from; _i<=_to; _i++ )); do RUN_SECTIONS+=("$_i"); done
      else
        RUN_SECTIONS+=("$2")
      fi
      shift 2 ;;
    --sample-ns)   SAMPLE_NS="$2"; shift 2 ;;
    --skip-bulk)   SKIP_BULK=true; shift ;;
    --skip-exec)   SKIP_EXEC=true; shift ;;
    --skip-ca)     SKIP_CA=true;   shift ;;
    --skip-trigger-registration) TRIGGER_REGISTRATION=false; shift ;;
    --hook|--hooks) CHECK_HOOKS=true; shift ;;
    --token)       CSP_TOKEN="$2"; shift 2 ;;
    --csp-url)     CSP_URL="$2"; shift 2 ;;
    -v|--verbose)  VERBOSE=true;   shift ;;
    -d|--debug)    DEBUG=true; VERBOSE=true; shift ;;
    --help|-h)
      sed -n '2,38p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (use --help)" >&2; exit 1 ;;
  esac
done

# ── Load token from file if not set via --token or env var ────────────────────
if [[ -z "$CSP_TOKEN" && -f "$TOKEN_FILE" ]]; then
  CSP_TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
fi

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
SKIP=0
SECTION=0

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
pass()  { echo -e "  ${GREEN}[PASS]${RESET} $*"; ((PASS++)) || true; }
fail()  { echo -e "  ${RED}[FAIL]${RESET} $*"; ((FAIL++)) || true; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; ((WARN++)) || true; }
skip()  { echo -e "  ${DIM}[SKIP]${RESET} $*"; ((SKIP++)) || true; }
info()  { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
vinfo() { [[ "$VERBOSE" == true ]] && info "$*" || true; }

# dbg CMD [ARGS...] — run a command, printing it and its output when --debug is on
dbg() {
  if [[ "$DEBUG" == true ]]; then
    echo -e "  ${DIM}  \$ $*${RESET}" >&2
    local _out
    _out=$("$@" 2>&1) || true
    if [[ -n "$_out" ]]; then
      echo "$_out" | head -20 | sed 's/^/           /' >&2
      local _lc; _lc=$(echo "$_out" | wc -l | tr -d ' ')
      [[ $_lc -gt 20 ]] && echo -e "  ${DIM}    ... ($_lc lines total)${RESET}" >&2
    fi
    echo "$_out"
  else
    "$@" 2>/dev/null || echo ""
  fi
}

# should_run N — returns 0 (true) if section N should execute
should_run() {
  local n="$1"
  if [[ ${#RUN_SECTIONS[@]} -eq 0 ]]; then
    return 0  # no filter → run all
  fi
  for s in "${RUN_SECTIONS[@]}"; do
    [[ "$s" == "$n" ]] && return 0
  done
  return 1
}

section() {
  ((SECTION++)) || true
  if ! should_run "$SECTION"; then
    return 0
  fi
  echo ""
  echo -e "${BOLD}── ${SECTION}. $* ──${RESET}"
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected: '$expected', got: '$actual')"
  fi
}

assert_contains() {
  local label="$1" actual="$2" expected="$3"
  if echo "$actual" | grep -q "$expected" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (expected to contain: '$expected', got: '$actual')"
  fi
}

assert_not_empty() {
  local label="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    pass "$label"
  else
    fail "$label (value is empty)"
  fi
}

assert_ge() {
  local label="$1" actual="$2" minimum="$3"
  if [[ "$actual" -ge "$minimum" ]] 2>/dev/null; then
    pass "$label ($actual >= $minimum)"
  else
    fail "$label (expected >= $minimum, got: '$actual')"
  fi
}

# Check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

# Safe kubectl that never fails the script
kc() {
  if [[ "$DEBUG" == true ]]; then
    echo -e "  ${DIM}  \$ kubectl $*${RESET}" >&2
    local _out
    _out=$(kubectl "$@" 2>&1) || true
    if [[ -n "$_out" ]]; then
      echo "$_out" | head -20 | sed 's/^/           /' >&2
      local _lc; _lc=$(echo "$_out" | wc -l | tr -d ' ')
      [[ $_lc -gt 20 ]] && echo -e "  ${DIM}    ... ($_lc lines total)${RESET}" >&2
    fi
    echo "$_out"
  else
    kubectl "$@" 2>/dev/null || echo ""
  fi
}

# Return namespaced Kubernetes resource refs from a live Helm release manifest.
# This avoids flagging runtime-generated resources (for example cert-manager,
# provision, kubeconfig, or Space-created Secrets) as Helm ownership issues.
helm_manifest_resource_refs() {
  local release="$1" namespace="$2"
  helm get manifest "$release" -n "$namespace" 2>/dev/null | awk '
    function emit() {
      if (kind == "" || name == "") return
      if (kind == "Service") print "service/" name
      else if (kind == "Deployment") print "deployment.apps/" name
      else if (kind == "StatefulSet") print "statefulset.apps/" name
      else if (kind == "Secret") print "secret/" name
      else if (kind == "ServiceAccount") print "serviceaccount/" name
      kind=""; name=""; inmeta=0
    }
    /^---[[:space:]]*$/ { emit(); next }
    /^kind:[[:space:]]*/ { kind=$2; next }
    /^metadata:[[:space:]]*$/ { inmeta=1; next }
    inmeta && /^  name:[[:space:]]*/ { name=$2; emit(); next }
    /^[^[:space:]]/ && $0 !~ /^metadata:/ { inmeta=0 }
    END { emit() }
  ' | sort -u
}

# Debug print for curl commands (call after curl, pass description + response file)
dbg_curl() {
  if [[ "$DEBUG" == true ]]; then
    local desc="$1" resp_file="${2:-}"
    echo -e "  ${DIM}  → ${desc}${RESET}" >&2
    if [[ -n "$resp_file" && -f "$resp_file" ]]; then
      python3 -c "import sys,json; d=json.load(open('$resp_file')); print(json.dumps(d,indent=2)[:300])" 2>/dev/null \
        | sed 's/^/           /' >&2 || cat "$resp_file" 2>/dev/null | head -5 | sed 's/^/           /' >&2
    fi
  fi
}

# ── Pre-flight checks ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}================================================================${RESET}"
echo -e "${BOLD} Konk End-to-End Health Validation${RESET}"
echo -e "${BOLD}================================================================${RESET}"
echo -e "  Cluster:      $(kubectl config current-context 2>/dev/null || echo 'unknown')"
echo -e "  Date (UTC):   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo -e "  Date (IST):   $(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S IST')"
echo -e "  Sample NS:    ${SAMPLE_NS}"
SKIP_TRIGGER_DISPLAY="false"
if [[ "$TRIGGER_REGISTRATION" != true ]]; then
  SKIP_TRIGGER_DISPLAY="true"
fi
echo -e "  Flags:        skip-bulk=${SKIP_BULK} skip-exec=${SKIP_EXEC} skip-ca=${SKIP_CA} skip-trigger-registration=${SKIP_TRIGGER_DISPLAY} debug=${DEBUG}"
if [[ ${#RUN_SECTIONS[@]} -gt 0 ]]; then
  echo -e "  Sections:     ${RUN_SECTIONS[*]}"
fi
echo ""

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster. Check kubeconfig.${RESET}"
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 0: Helm hook + init container status (only when --hook is passed)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$CHECK_HOOKS" == true ]]; then
echo ""
echo -e "${BOLD}── 0.1 Helm hook status (all charts) ──${RESET}"

# Check hook Jobs across all namespaces for each chart type
for _chart_label in "konk-service" "konk" "etcd"; do
  info "checking $_chart_label hooks..."

  # Pre-install/pre-upgrade hook Jobs — query by helm.sh/chart label (on Job metadata)
  # Note: app.kubernetes.io/component=fix-helm-orphans is on the pod template, not the Job itself
  _pre_jobs=$(dbg kubectl get jobs -A -o json -l "helm.sh/chart=${_chart_label}-0.1.0" 2>/dev/null | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for item in data.get('items',[]):
    ann=item.get('metadata',{}).get('annotations',{}) or {}
    if 'helm.sh/hook' in ann and 'pre-' in ann.get('helm.sh/hook',''):
        ns=item['metadata']['namespace']
        name=item['metadata']['name']
        conds=item.get('status',{}).get('conditions',[])
        status=conds[0]['type'] if conds else 'Unknown'
        succ=item.get('status',{}).get('succeeded',0)
        print(f'{ns}   {name}   {status}   {succ}')
" 2>/dev/null || true)
  if [[ -z "$_pre_jobs" ]]; then
    # Try broader search: all Jobs with helm.sh/hook annotation containing pre-
    _pre_jobs=$(dbg kubectl get jobs -A -o json -l "app.kubernetes.io/name=${_chart_label}" 2>/dev/null | \
      python3 -c "
import json,sys
data=json.load(sys.stdin)
for item in data.get('items',[]):
    ann=item.get('metadata',{}).get('annotations',{}) or {}
    if 'helm.sh/hook' in ann:
        ns=item['metadata']['namespace']
        name=item['metadata']['name']
        conds=item.get('status',{}).get('conditions',[])
        status=conds[0]['type'] if conds else 'Unknown'
        succ=item.get('status',{}).get('succeeded',0)
        print(f'{ns}   {name}   {status}   {succ}')
" 2>/dev/null || true)
  fi

  if [[ -z "$_pre_jobs" ]]; then
    info "no pre-install/pre-upgrade hook Jobs found for $_chart_label (cleaned up or not yet triggered)"
  else
    _failed=0; _succeeded=0; _running=0
    while IFS= read -r _line; do
      if echo "$_line" | grep -qiE "Complete|SuccessCriteriaMet"; then
        ((_succeeded++)) || true
      elif echo "$_line" | grep -qi "Running"; then
        ((_running++)) || true
        warn "hook Job still running: $_line"
      else
        ((_failed++)) || true
        fail "hook Job: $_line"
      fi
    done <<< "$_pre_jobs"
    if [[ $_failed -eq 0 && $_running -eq 0 ]]; then
      pass "$_chart_label pre-install hooks: $_succeeded completed successfully"
    elif [[ $_failed -eq 0 && $_running -gt 0 ]]; then
      info "$_chart_label pre-install hooks: $_succeeded completed, $_running still running"
    fi
  fi
done

# Post-upgrade hook Jobs (konk-service only)
info "checking post-upgrade hooks (konk-service)..."
_post_jobs=$(dbg kubectl get jobs -A -l "app.kubernetes.io/component=post-upgrade" -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,COMPLETIONS:.status.succeeded' --no-headers 2>/dev/null || true)
if [[ -z "$_post_jobs" ]]; then
  # Try by job name pattern
  _post_jobs=$(dbg kubectl get jobs -A --no-headers 2>/dev/null | grep "post-upgrade" || true)
fi

if [[ -z "$_post_jobs" ]]; then
  info "no post-upgrade hook Jobs found (cleaned up by hook-delete-policy or not yet triggered)"
else
  _failed=0; _succeeded=0; _running=0
  while IFS= read -r _line; do
    if echo "$_line" | grep -qi "complete\|1/1"; then
      ((_succeeded++)) || true
    elif echo "$_line" | grep -qi "Running"; then
      ((_running++)) || true
      warn "post-upgrade hook Job still running: $_line"
    else
      ((_failed++)) || true
      fail "post-upgrade hook Job: $_line"
    fi
  done <<< "$_post_jobs"
  if [[ $_failed -eq 0 && $_running -eq 0 ]]; then
    pass "konk-service post-upgrade hooks: $_succeeded completed successfully"
  elif [[ $_failed -eq 0 && $_running -gt 0 ]]; then
    info "konk-service post-upgrade hooks: $_succeeded completed, $_running still running"
  fi
fi

# Check for hook-related errors in operator logs
info "checking operator logs for hook failures (last 5min)..."
_hook_errors=$(dbg kubectl -n "${KONK_NAMESPACE}" logs deploy/konk-operator --since=5m 2>/dev/null | grep -i "hook.*failed\|pre-upgrade hooks failed\|post-upgrade hooks failed\|pre-install hooks failed\|post-install hooks failed" | head -5 || true)
if [[ -z "$_hook_errors" ]]; then
  pass "no hook failures in operator logs (last 5min)"
else
  fail "hook failures detected in operator logs (last 5min):"
  while IFS= read -r _line; do
    _msg=$(echo "$_line" | grep -o '"error":"[^"]*"' | head -1 || echo "$_line" | cut -c1-120)
    info "  $_msg"
  done <<< "$_hook_errors"
fi

# Check hook-delete-policy compliance (only actual Helm hook Jobs should be cleaned up)
# Note: query by helm.sh/chart label (on Job metadata), then filter by helm.sh/hook annotation
_lingering=$(dbg kubectl get jobs -A -l "helm.sh/chart=konk-service-0.1.0" -o json 2>/dev/null | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
count=0
for item in data.get('items',[]):
    ann=item.get('metadata',{}).get('annotations',{}) or {}
    if 'helm.sh/hook' in ann and 'pre-' in ann.get('helm.sh/hook',''):
        count+=1
print(count)
" 2>/dev/null || echo "0")
if [[ "$_lingering" -gt 0 ]]; then
  warn "$_lingering pre-install hook Job(s) still present (expected: cleaned up by hook-delete-policy)"
else
  pass "all pre-install hook Jobs cleaned up (hook-delete-policy working)"
fi

fi  # CHECK_HOOKS — 0.1

# ── 0.2 Init container status (fix-helm-orphans + fix-stale-ca) ──
if [[ "$CHECK_HOOKS" == true ]]; then
echo ""
echo -e "${BOLD}── 0.2 Init container status (operator pod) ──${RESET}"

# Check if operator pod has the fix-helm-orphans init container
_op_pod=$(kc get pods -n "${KONK_NAMESPACE}" -l app.kubernetes.io/name=konk-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$_op_pod" ]]; then
  fail "konk-operator pod not found"
else
  # Check init container exists
  _init_state=$(kc get pod "$_op_pod" -n "${KONK_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="fix-helm-orphans")].state}' 2>/dev/null)
  if [[ -z "$_init_state" ]]; then
    warn "operator pod '$_op_pod' has no 'fix-helm-orphans' init container (old image?)"
  else
    # Check if terminated successfully
    _exit_code=$(kc get pod "$_op_pod" -n "${KONK_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="fix-helm-orphans")].state.terminated.exitCode}' 2>/dev/null)
    _reason=$(kc get pod "$_op_pod" -n "${KONK_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="fix-helm-orphans")].state.terminated.reason}' 2>/dev/null)
    if [[ "$_exit_code" == "0" ]]; then
      pass "init container 'fix-helm-orphans' completed successfully (exit 0)"
    elif [[ -n "$_exit_code" ]]; then
      fail "init container 'fix-helm-orphans' exited with code $_exit_code (reason: $_reason)"
    else
      info "init container 'fix-helm-orphans' state: $_init_state"
    fi
  fi

  # Check init container logs for orphan fix results
  info "checking init container logs..."
  _init_logs=$(kc logs "$_op_pod" -n "${KONK_NAMESPACE}" -c fix-helm-orphans 2>/dev/null || true)
  if [[ -z "$_init_logs" ]]; then
    warn "no init container logs available"
  else
    # Orphan fix summary
    _orphan_patched=$(echo "$_init_logs" | grep -c "PATCH" || true)
    _orphan_errors=$(echo "$_init_logs" | grep -c "ERROR" || true)
    _no_orphans=$(echo "$_init_logs" | grep -c "No orphaned resources found" || true)
    if [[ "$_no_orphans" -gt 0 ]]; then
      pass "orphan fix: no orphaned resources found"
    elif [[ "$_orphan_patched" -gt 0 && "$_orphan_errors" -eq 0 ]]; then
      pass "orphan fix: $_orphan_patched resource(s) patched, 0 errors"
    elif [[ "$_orphan_errors" -gt 0 ]]; then
      fail "orphan fix: $_orphan_patched patched, $_orphan_errors errors"
      echo "$_init_logs" | grep "ERROR" | head -5 | while IFS= read -r _line; do
        info "  $_line"
      done
    fi

    # Stale CA fix summary
    _ca_stale=$(echo "$_init_logs" | grep "fix-stale-ca:" || true)
    if [[ -z "$_ca_stale" ]]; then
      info "stale CA fix: not present in logs (older image without fix-stale-ca)"
    else
      _ca_nothing=$(echo "$_ca_stale" | grep -c "nothing to fix" || true)
      _ca_deleted=$(echo "$_ca_stale" | grep -c "DELETED" || true)
      _ca_reissued=$(echo "$_ca_stale" | grep -c "re-issued with correct CA" || true)
      _ca_warning=$(echo "$_ca_stale" | grep -c "WARNING" || true)

      if [[ "$_ca_nothing" -gt 0 ]]; then
        pass "stale CA fix: all kubeconfig-cert secrets have correct CA"
      elif [[ "$_ca_reissued" -gt 0 && "$_ca_warning" -eq 0 ]]; then
        pass "stale CA fix: $_ca_deleted secret(s) deleted, all re-issued with correct CA"
      elif [[ "$_ca_deleted" -gt 0 && "$_ca_warning" -gt 0 ]]; then
        warn "stale CA fix: $_ca_deleted secret(s) deleted, but some may not have been re-issued yet"
      elif [[ "$_ca_deleted" -gt 0 ]]; then
        info "stale CA fix: $_ca_deleted secret(s) deleted, waiting for cert-manager re-issue"
      else
        info "stale CA fix: $(echo "$_ca_stale" | tail -1)"
      fi

      # List individual stale/deleted/skipped secrets
      if [[ "$VERBOSE" == true || "$_ca_deleted" -gt 0 ]]; then
        _ca_stale_list=$(echo "$_ca_stale" | grep "STALE\|DELETED" || true)
        if [[ -n "$_ca_stale_list" ]]; then
          echo "$_ca_stale_list" | while IFS= read -r _line; do
            if echo "$_line" | grep -q "DELETED"; then
              _secret=$(echo "$_line" | sed 's/.*DELETED //' | tr -d ' ')
              info "  DELETED: $_secret (cert-manager will re-issue)"
            elif echo "$_line" | grep -q "STALE"; then
              _secret=$(echo "$_line" | sed 's/.*STALE //' | sed 's/ (ca:.*//')
              info "  STALE:   $_secret"
            fi
          done
        fi
      fi

      # Show current CA used
      _ca_current=$(echo "$_ca_stale" | grep "current bulk-konk CA:" | sed 's/.*current bulk-konk CA: //' || true)
      if [[ -n "$_ca_current" ]]; then
        vinfo "current CA fingerprint: $_ca_current"
      fi
    fi
  fi
fi

fi  # CHECK_HOOKS

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 1: konk-operator
# ══════════════════════════════════════════════════════════════════════════════
section "konk-operator (namespace: ${KONK_NAMESPACE})"
if should_run 1; then
# Deployment exists and has desired replicas ready
OPERATOR_DESIRED=$(kc get deploy konk-operator -n "$KONK_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
OPERATOR_READY=$(kc get deploy konk-operator -n "$KONK_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
if [[ -z "$OPERATOR_DESIRED" ]]; then
  fail "konk-operator deployment not found in namespace '${KONK_NAMESPACE}'"
else
  assert_equals "konk-operator replicas ready" "${OPERATOR_READY:-0}" "$OPERATOR_DESIRED"
fi

# Pod is Running and Ready
OPERATOR_POD_STATUS=$(kc get pods -n "$KONK_NAMESPACE" \
  -l app.kubernetes.io/name=konk-operator \
  -o jsonpath='{.items[0].status.phase}')
assert_equals "konk-operator pod phase" "${OPERATOR_POD_STATUS:-NotFound}" "Running"

OPERATOR_POD_READY=$(kc get pods -n "$KONK_NAMESPACE" \
  -l app.kubernetes.io/name=konk-operator \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
assert_equals "konk-operator pod Ready condition" "${OPERATOR_POD_READY:-False}" "True"

# Show operator image
OPERATOR_IMG=$(kc get deploy konk-operator -n "$KONK_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
vinfo "operator image: ${OPERATOR_IMG}"

# Check konk-operator HelmRelease status (flux)
if kubectl get hr -n vela-system konk-operator &>/dev/null; then
  KONK_OP_HR_READY=$(kubectl get hr -n vela-system konk-operator -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  KONK_OP_HR_MSG=$(kubectl get hr -n vela-system konk-operator -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
  if [[ "$KONK_OP_HR_READY" == "True" ]]; then
    pass "konk-operator HelmRelease Ready: $(echo "$KONK_OP_HR_MSG" | head -c 120)"
  else
    fail "konk-operator HelmRelease NOT Ready (status=${KONK_OP_HR_READY}): $(echo "$KONK_OP_HR_MSG" | head -c 200)"
  fi
else
  skip "konk-operator HelmRelease not found in vela-system"
fi

fi  # section 1

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 2: Core infrastructure — aggregate namespace
# ══════════════════════════════════════════════════════════════════════════════
section "Core infrastructure (namespace: ${AGGREGATE_NAMESPACE})"
if should_run 2; then

# --- bulk-konk apiserver deployment ---
KONK_DESIRED=$(kc get deploy "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
KONK_READY=$(kc get deploy "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
if [[ -z "$KONK_DESIRED" ]]; then
  fail "bulk-konk deployment not found"
else
  assert_equals "bulk-konk apiserver replicas ready" "${KONK_READY:-0}" "$KONK_DESIRED"
fi

KONK_IMG=$(kc get deploy "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
vinfo "bulk-konk image: ${KONK_IMG}"

# --- bulk-konk-init (provision) deployment ---
INIT_DESIRED=$(kc get deploy "${KONK_CR_NAME}-init" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
INIT_READY=$(kc get deploy "${KONK_CR_NAME}-init" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
if [[ -z "$INIT_DESIRED" ]]; then
  warn "bulk-konk-init deployment not found (may be completed or removed)"
else
  assert_equals "bulk-konk-init replicas ready" "${INIT_READY:-0}" "$INIT_DESIRED"
fi

# --- bulk-konk-etcd statefulset ---
ETCD_DESIRED=$(kc get statefulset "${KONK_CR_NAME}-etcd" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
ETCD_READY=$(kc get statefulset "${KONK_CR_NAME}-etcd" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
if [[ -z "$ETCD_DESIRED" ]]; then
  fail "bulk-konk-etcd statefulset not found"
else
  assert_equals "bulk-konk-etcd replicas ready" "${ETCD_READY:-0}" "$ETCD_DESIRED"
fi

# --- bulk-konk service + endpoints ---
KONK_SVC_IP=$(kc get svc "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.clusterIP}')
if [[ -z "$KONK_SVC_IP" ]]; then
  fail "bulk-konk service not found"
else
  pass "bulk-konk service exists (ClusterIP: ${KONK_SVC_IP})"
fi

KONK_ENDPOINTS=$(kc get endpoints "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.subsets[0].addresses[0].ip}')
if [[ -z "$KONK_ENDPOINTS" ]]; then
  fail "bulk-konk has no ready endpoints"
else
  pass "bulk-konk has ready endpoints (${KONK_ENDPOINTS})"
fi

# --- No pods in error state ---
AGG_BAD_PODS=$(kc get pods -n "$AGGREGATE_NAMESPACE" --no-headers \
  | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull' || true)
if [[ -n "$AGG_BAD_PODS" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pod_name=$(echo "$line" | awk '{print $1}')
    pod_status=$(echo "$line" | awk '{print $3}')
    fail "aggregate pod in bad state: ${pod_name} (${pod_status})"
  done <<< "$AGG_BAD_PODS"
else
  pass "no pods in error state in aggregate namespace"
fi

# Check bulk HelmRelease status (flux)
if kubectl get hr -n vela-system bulk &>/dev/null; then
  BULK_HR_READY=$(kubectl get hr -n vela-system bulk -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  BULK_HR_MSG=$(kubectl get hr -n vela-system bulk -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
  if [[ "$BULK_HR_READY" == "True" ]]; then
    pass "bulk HelmRelease Ready: ${BULK_HR_MSG}"
  else
    fail "bulk HelmRelease NOT Ready (status=${BULK_HR_READY}): ${BULK_HR_MSG}"
  fi
else
  skip "bulk HelmRelease not found in vela-system (flux not managing bulk here)"
fi

fi  # section 2

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: Image version consistency
# ══════════════════════════════════════════════════════════════════════════════
section "Image version consistency"
if should_run 3; then
# Extract operator's expected image tags from RELATED_IMAGE env vars
OPERATOR_DEPLOY_JSON=$(kc get deploy konk-operator -n "$KONK_NAMESPACE" -o json 2>/dev/null)
OPERATOR_TAG=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_APISERVER") | .value' 2>/dev/null || echo "")
OPERATOR_PROVISION_TAG=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_PROVISION") | .value' 2>/dev/null || echo "")
OPERATOR_SERVICE_TAG=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_KIND") | .value' 2>/dev/null || echo "")
OPERATOR_APISERVER_REPO=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_APISERVER_REPO") | .value' 2>/dev/null || echo "")
OPERATOR_PROVISION_REPO=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_PROVISION_REPO") | .value' 2>/dev/null || echo "")
OPERATOR_SERVICE_REPO=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].env[]
  | select(.name=="RELATED_IMAGE_KIND_REPO") | .value' 2>/dev/null || echo "")

EXPECTED_APISERVER_IMG="${OPERATOR_APISERVER_REPO}:${OPERATOR_TAG}"
EXPECTED_PROVISION_IMG="${OPERATOR_PROVISION_REPO}:${OPERATOR_PROVISION_TAG}"
EXPECTED_SERVICE_IMG="${OPERATOR_SERVICE_REPO}:${OPERATOR_SERVICE_TAG}"

OPERATOR_IMG_TAG=$(echo "$OPERATOR_DEPLOY_JSON" | jq -r '
  .spec.template.spec.containers[0].image' 2>/dev/null || echo "")
OPERATOR_IMG_VER="${OPERATOR_IMG_TAG##*:}"

# --- 1. konk-operator ---
info "konk-operator          : ${OPERATOR_IMG_VER}"

# --- 2. bulk-konk (apiserver) ---
ACTUAL_APISERVER_IMG=$(kc get deploy "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
ACTUAL_APISERVER_TAG="${ACTUAL_APISERVER_IMG##*:}"
if [[ -z "$OPERATOR_TAG" ]]; then
  skip "bulk-konk (apiserver): cannot determine expected tag"
elif [[ -z "$ACTUAL_APISERVER_IMG" ]]; then
  skip "bulk-konk (apiserver): deployment not found"
elif [[ "$ACTUAL_APISERVER_TAG" == "$OPERATOR_TAG" ]]; then
  pass "bulk-konk (apiserver)  : ${ACTUAL_APISERVER_TAG}"
else
  warn "bulk-konk (apiserver)  : ${ACTUAL_APISERVER_TAG} — expected ${OPERATOR_TAG} (reconcile failing)"
fi

# --- 3. bulk-konk-init (provision) ---
ACTUAL_PROVISION_IMG=$(kc get deploy "${KONK_CR_NAME}-init" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
ACTUAL_PROVISION_TAG="${ACTUAL_PROVISION_IMG##*:}"
if [[ -z "$OPERATOR_PROVISION_TAG" ]]; then
  skip "bulk-konk (provision) : cannot determine expected tag"
elif [[ -z "$ACTUAL_PROVISION_IMG" ]]; then
  skip "bulk-konk (provision) : deployment not found"
elif [[ "$ACTUAL_PROVISION_TAG" == "$OPERATOR_PROVISION_TAG" ]]; then
  pass "bulk-konk (provision)  : ${ACTUAL_PROVISION_TAG}"
else
  warn "bulk-konk (provision)  : ${ACTUAL_PROVISION_TAG} — expected ${OPERATOR_PROVISION_TAG} (reconcile failing)"
fi

# --- 4. konk-service pods (per namespace) ---
if [[ -n "$OPERATOR_SERVICE_TAG" && -n "$OPERATOR_SERVICE_REPO" ]]; then
  KONK_SVC_NAMESPACES=("$SAMPLE_NS" "ddi" "atcapi" "hostapp" "ngp-cp" "ntp" "endpoints")
  SVC_VERSION_SUMMARY=""
  SVC_MISMATCH=0
  SVC_FOUND=0

  for _ns in "${KONK_SVC_NAMESPACES[@]}"; do
    _img=$(kc get deploy -n "$_ns" -l app.kubernetes.io/name=konk-service \
      -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
    [[ -z "$_img" ]] && continue
    ((SVC_FOUND++)) || true
    _tag="${_img##*:}"
    if [[ "$_tag" != "$OPERATOR_SERVICE_TAG" ]]; then
      ((SVC_MISMATCH++)) || true
      SVC_VERSION_SUMMARY="${SVC_VERSION_SUMMARY}    ${_ns}: ${_tag} (expected ${OPERATOR_SERVICE_TAG})\n"
    else
      SVC_VERSION_SUMMARY="${SVC_VERSION_SUMMARY}    ${_ns}: ${_tag}\n"
    fi
  done

  if [[ "$SVC_FOUND" -eq 0 ]]; then
    skip "konk-service          : no deployments found"
  elif [[ "$SVC_MISMATCH" -eq 0 ]]; then
    pass "konk-service (${SVC_FOUND}/${#KONK_SVC_NAMESPACES[@]} namespaces) : ${OPERATOR_SERVICE_TAG}"
  else
    warn "konk-service (${SVC_FOUND}/${#KONK_SVC_NAMESPACES[@]} namespaces) : ${SVC_MISMATCH}/${SVC_FOUND} namespace(s) have version mismatch"
  fi
  if [[ "$VERBOSE" == true && -n "$SVC_VERSION_SUMMARY" ]]; then
    echo -e "$SVC_VERSION_SUMMARY"
  fi
else
  skip "konk-service          : cannot determine expected tag (RELATED_IMAGE_KIND not set)"
fi
fi  # section 3

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4: Konk CR + Etcd CR status
# ══════════════════════════════════════════════════════════════════════════════
section "Konk CR + Etcd CR status (${KONK_CR_NAME})"
if should_run 4; then
KONK_CR_REASON=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}')
if [[ -z "$KONK_CR_REASON" ]]; then
  fail "Konk CR '${KONK_CR_NAME}' not found or has no Deployed condition"
else
  assert_contains "Konk CR reason=Successful" "$KONK_CR_REASON" "Successful"
fi

KONK_CR_STATUS=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}')
assert_equals "Konk CR Deployed=True" "${KONK_CR_STATUS:-False}" "True"

# Check for InstallError / helm release errors in Konk CR status message
KONK_CR_MSG=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].message}')
if echo "$KONK_CR_MSG" | grep -qiE 'InstallError|UpgradeError|failed to install release|failed to upgrade release|cannot be imported|invalid ownership' 2>/dev/null; then
  fail "Konk CR has helm release error: $(echo "$KONK_CR_MSG" | head -c 200)"
else
  pass "Konk CR: no helm InstallError/UpgradeError in status message"
fi

KONK_CR_SCOPE=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.scope}')
vinfo "Konk scope: ${KONK_CR_SCOPE:-default}"

# Proactive ownership check: resources in the bulk-konk Helm release manifest
# should carry Helm ownership annotations. This intentionally follows Helm's
# manifest instead of loose name matching so runtime-generated resources (for
# example provision, cert-manager, kubeconfig, or Space-created Secrets) do not
# show as false Helm adoption risks.
KONK_OWNERSHIP_MISSING=0
KONK_OWNERSHIP_CHECKED=0
KONK_OWNERSHIP_MISSING_LIST=""
KONK_CANDIDATE_RES=$(helm_manifest_resource_refs "$KONK_CR_NAME" "$AGGREGATE_NAMESPACE" || true)
if [[ -n "$KONK_CANDIDATE_RES" ]]; then
  while IFS= read -r _res; do
    [[ -z "$_res" ]] && continue
    KONK_OWNERSHIP_CHECKED=$((KONK_OWNERSHIP_CHECKED + 1))
    _ann_rel=$(kc get "$_res" -n "$AGGREGATE_NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
    _ann_ns=$(kc get "$_res" -n "$AGGREGATE_NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)
    if [[ -z "$_ann_rel" || -z "$_ann_ns" ]]; then
      KONK_OWNERSHIP_MISSING=$((KONK_OWNERSHIP_MISSING + 1))
      KONK_OWNERSHIP_MISSING_LIST+="$_res\n"
    fi
  done <<< "$KONK_CANDIDATE_RES"
fi
if [[ "$KONK_OWNERSHIP_CHECKED" -eq 0 ]]; then
  warn "Konk ownership check: no Helm-managed ${KONK_CR_NAME} resources found in ${AGGREGATE_NAMESPACE}"
elif [[ "$KONK_OWNERSHIP_MISSING" -eq 0 ]]; then
  pass "Konk ownership check: all ${KONK_OWNERSHIP_CHECKED} Helm-managed ${KONK_CR_NAME} resources have Helm annotations"
else
  fail "Konk ownership check: ${KONK_OWNERSHIP_MISSING}/${KONK_OWNERSHIP_CHECKED} Helm-managed ${KONK_CR_NAME} resources missing meta.helm.sh ownership annotations"
  echo -e "$KONK_OWNERSHIP_MISSING_LIST" | head -10 | sed 's/^/       [WARN]   /'
fi

# ── Etcd CR status ──
ETCD_CR_NAME="${KONK_CR_NAME}-etcd"
ETCD_CR_REASON=$(kc get etcds.konk.infoblox.com "$ETCD_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null || true)
if [[ -z "$ETCD_CR_REASON" ]]; then
  warn "Etcd CR '${ETCD_CR_NAME}' not found or has no Deployed condition"
else
  assert_contains "Etcd CR reason=Successful" "$ETCD_CR_REASON" "Successful"
fi

ETCD_CR_STATUS=$(kc get etcds.konk.infoblox.com "$ETCD_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || true)
assert_equals "Etcd CR Deployed=True" "${ETCD_CR_STATUS:-False}" "True"

# Check for ReleaseFailed condition on Etcd CR
ETCD_RF_STATUS=$(kc get etcds.konk.infoblox.com "$ETCD_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)
if [[ "$ETCD_RF_STATUS" == "True" ]]; then
  ETCD_RF_REASON=$(kc get etcds.konk.infoblox.com "$ETCD_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].reason}' 2>/dev/null || true)
  ETCD_RF_MSG=$(kc get etcds.konk.infoblox.com "$ETCD_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}' 2>/dev/null || true)
  fail "Etcd CR '${ETCD_CR_NAME}': ReleaseFailed=True reason='${ETCD_RF_REASON}'"
  echo "       Message: $(echo "$ETCD_RF_MSG" | head -c 300)"
  if echo "$ETCD_RF_MSG" | grep -q "meta.helm.sh/release-name"; then
    ETCD_BAD_RESOURCE=$(echo "$ETCD_RF_MSG" | sed -n 's/.*with install: \([^ ]* "[^"]*"\).*/\1/p')
    echo "       Fix:     kubectl annotate ${ETCD_BAD_RESOURCE} -n ${AGGREGATE_NAMESPACE} meta.helm.sh/release-name=${ETCD_CR_NAME} meta.helm.sh/release-namespace=${AGGREGATE_NAMESPACE} --overwrite"
  fi
else
  pass "Etcd CR '${ETCD_CR_NAME}': no ReleaseFailed condition"
fi

# Check for ReleaseFailed condition on Konk CR too
KONK_RF_STATUS=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)
if [[ "$KONK_RF_STATUS" == "True" ]]; then
  KONK_RF_REASON=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].reason}' 2>/dev/null || true)
  KONK_RF_MSG=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}' 2>/dev/null || true)
  fail "Konk CR '${KONK_CR_NAME}': ReleaseFailed=True reason='${KONK_RF_REASON}'"
  echo "       Message: $(echo "$KONK_RF_MSG" | head -c 300)"
  if echo "$KONK_RF_MSG" | grep -q "meta.helm.sh/release-name"; then
    KONK_BAD_RESOURCE=$(echo "$KONK_RF_MSG" | sed -n 's/.*with install: \([^ ]* "[^"]*"\).*/\1/p')
    echo "       Fix:     kubectl annotate ${KONK_BAD_RESOURCE} -n ${AGGREGATE_NAMESPACE} meta.helm.sh/release-name=${KONK_CR_NAME} meta.helm.sh/release-namespace=${AGGREGATE_NAMESPACE} --overwrite"
  fi
else
  pass "Konk CR '${KONK_CR_NAME}': no ReleaseFailed condition"
fi
fi  # section 4

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5: KonkService CR statuses
# ══════════════════════════════════════════════════════════════════════════════
section "KonkService CRs (all namespaces)"
if should_run 5; then
# Fetch all KonkServices and Deployments once (much faster than per-resource calls
# through high-latency proxies like Teleport).
info "fetching KonkService CRs and Deployments..."
ALL_KSVC_JSON=$(kc get konkservice -A -o json 2>/dev/null)
ALL_DEPLOY_JSON=$(kc get deploy -A -o json 2>/dev/null)

KSVC_TOTAL=0
KSVC_OK=0
KSVC_FAIL=0

if [[ -z "$ALL_KSVC_JSON" ]] || [[ "$(echo "$ALL_KSVC_JSON" | jq '.items | length')" == "0" ]]; then
  fail "No KonkService CRs found in cluster"
else
  KSVC_RELEASE_FAILED=0
  KSVC_OWNERSHIP_ERR=0
  KSVC_KUBECONFIG_SCALED_DOWN=0

  # Single jq pass to derive ns, name, deployed-reason, ReleaseFailed status/reason/time/message.
  # Format: TAB-separated; message is base64-encoded so newlines don't break the loop.
  KSVC_ROWS=$(echo "$ALL_KSVC_JSON" | jq -r '
    .items[] |
    [
      .metadata.namespace,
      .metadata.name,
      ((.status.conditions // [])[] | select(.type=="Deployed") | .reason) // "UNKNOWN",
      ((.status.conditions // [])[] | select(.type=="ReleaseFailed") | .status) // "",
      ((.status.conditions // [])[] | select(.type=="ReleaseFailed") | .reason) // "",
      ((.status.conditions // [])[] | select(.type=="ReleaseFailed") | .lastTransitionTime) // "",
      (((.status.conditions // [])[] | select(.type=="ReleaseFailed") | .message) // "" | @base64)
    ] | @tsv')

  while IFS=$'\t' read -r ns name reason rf_status rf_reason rf_time rf_msg_b64; do
    [[ -z "$ns" || -z "$name" ]] && continue
    ((KSVC_TOTAL++)) || true

    if [[ "$reason" == *"Successful"* ]]; then
      ((KSVC_OK++)) || true
      vinfo "KonkService ${ns}/${name}: ${reason}"
    else
      fail "KonkService ${ns}/${name}: Deployed='${reason:-UNKNOWN}'"
      ((KSVC_FAIL++)) || true
    fi

    if [[ "$rf_status" == "True" ]]; then
      ((KSVC_RELEASE_FAILED++)) || true
      fail "KonkService ${ns}/${name}: ReleaseFailed=True reason='${rf_reason}' since=${rf_time}"
      rf_msg=$(echo "$rf_msg_b64" | base64 -d 2>/dev/null || true)
      if echo "$rf_msg" | grep -qiE 'cannot be imported|invalid ownership|missing key "meta.helm.sh/release-name"|missing key "meta.helm.sh/release-namespace"'; then
        ((KSVC_OWNERSHIP_ERR++)) || true
        fail "KonkService ${ns}/${name}: Helm ownership conflict — fix annotations on the named Deployment(s) so Helm can adopt them"
        info "  message: $(echo "$rf_msg" | head -c 300)"
      elif [[ -n "$rf_msg" ]]; then
        info "  message: $(echo "$rf_msg" | head -c 300)"
      fi
    fi

    # Check kubeconfig renewal Deployment from cached JSON.
    # Look up by labels (resilient to chart name truncation).
    kc_state=$(echo "$ALL_DEPLOY_JSON" | jq -r --arg ns "$ns" --arg inst "$name" '
      .items[]
      | select(.metadata.namespace==$ns
               and .metadata.labels["app.kubernetes.io/instance"]==$inst
               and .metadata.labels["app.kubernetes.io/component"]=="kubeconfig")
      | "\(.metadata.name)\t\(.spec.replicas // 0)\t\(.status.availableReplicas // 0)"' \
      | head -1)
    if [[ -n "$kc_state" ]]; then
      kc_deploy="${kc_state%%$'\t'*}"
      rest="${kc_state#*$'\t'}"
      kc_desired="${rest%%$'\t'*}"
      kc_avail="${rest##*$'\t'}"
      if [[ "${kc_desired:-0}" -eq 0 ]]; then
        ((KSVC_KUBECONFIG_SCALED_DOWN++)) || true
        fail "KonkService ${ns}/${name}: kubeconfig renewal Deployment '${kc_deploy}' is scaled to 0 — client cert will expire (12h TTL)"
      elif [[ "$kc_avail" -lt 1 ]]; then
        ((KSVC_KUBECONFIG_SCALED_DOWN++)) || true
        fail "KonkService ${ns}/${name}: kubeconfig Deployment '${kc_deploy}' has 0 available replicas (desired=${kc_desired})"
      else
        vinfo "KonkService ${ns}/${name}: kubeconfig Deployment '${kc_deploy}' has ${kc_avail}/${kc_desired} replicas"
      fi
    fi
  done <<< "$KSVC_ROWS"

  if [[ $KSVC_FAIL -eq 0 && $KSVC_RELEASE_FAILED -eq 0 && $KSVC_KUBECONFIG_SCALED_DOWN -eq 0 ]]; then
    pass "all ${KSVC_TOTAL} KonkService CRs report Successful with no ReleaseFailed and kubeconfig Deployments scaled up"
  else
    info "${KSVC_OK}/${KSVC_TOTAL} KonkService CRs ok | ${KSVC_FAIL} not Successful | ${KSVC_RELEASE_FAILED} ReleaseFailed | ${KSVC_OWNERSHIP_ERR} with Helm ownership conflict | ${KSVC_KUBECONFIG_SCALED_DOWN} kubeconfig Deployments scaled to 0"
  fi

  # ── Proactive Helm ownership annotation check ──
  # Check only Deployments that are in each current KonkService Helm release
  # manifest. Old chart-name leftovers (for example *-kubectl-apiservice*) are
  # reported separately in the stale deployment inventory section.
  HELM_KSVC_DEPLOYMENTS=""
  while IFS=$'\t' read -r ns name _reason _rf_status _rf_reason _rf_time _rf_msg_b64; do
    [[ -z "$ns" || -z "$name" ]] && continue
    _release_deploys=$(helm_manifest_resource_refs "$name" "$ns" \
      | grep '^deployment\.apps/' \
      | sed "s#^deployment\.apps/#${ns}/#" || true)
    if [[ -n "$_release_deploys" ]]; then
      HELM_KSVC_DEPLOYMENTS+="$_release_deploys"$'\n'
    else
      vinfo "KonkService ${ns}/${name}: no Helm manifest Deployments found for ownership check"
    fi
  done <<< "$KSVC_ROWS"
  HELM_KSVC_DEPLOYMENTS=$(echo "$HELM_KSVC_DEPLOYMENTS" | grep -v '^$' | sort -u || true)

  MISSING_ANN=""
  if [[ -n "$HELM_KSVC_DEPLOYMENTS" ]]; then
    while IFS= read -r deploy_ref; do
      [[ -z "$deploy_ref" ]] && continue
      deploy_ns="${deploy_ref%%/*}"
      deploy_name="${deploy_ref#*/}"
      ann_state=$(echo "$ALL_DEPLOY_JSON" | jq -r --arg ns "$deploy_ns" --arg name "$deploy_name" '
        ([.items[]
          | select(.metadata.namespace == $ns and .metadata.name == $name)
          | ((.metadata.annotations["meta.helm.sh/release-name"] // "") + ":" + (.metadata.annotations["meta.helm.sh/release-namespace"] // ""))][0]) // "MISSING_RESOURCE"' 2>/dev/null || true)
      if [[ "$ann_state" == "MISSING_RESOURCE" ]]; then
        MISSING_ANN+="${deploy_ref} (missing live Deployment)"$'\n'
      elif [[ "$ann_state" == ":" || "$ann_state" == :* || "$ann_state" == *: ]]; then
        MISSING_ANN+="${deploy_ref}"$'\n'
      fi
    done <<< "$HELM_KSVC_DEPLOYMENTS"
  fi

  if [[ -z "$MISSING_ANN" ]]; then
    pass "Konk ownership check: all current Helm-managed konk-service Deployments have Helm ownership annotations"
  else
    MISSING_COUNT=$(echo "$MISSING_ANN" | wc -l | tr -d ' ')
    fail "Konk ownership check: ${MISSING_COUNT} current Helm-managed konk-service Deployment(s) missing meta.helm.sh ownership annotations"
    echo "$MISSING_ANN" | head -5 | while IFS= read -r line; do
      warn "  ${line}"
    done
    if [[ $MISSING_COUNT -gt 5 ]]; then
      info "  ... and $((MISSING_COUNT - 5)) more"
    fi
  fi
fi
fi  # section 5

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6: konk-service pods health (all namespaces)
# ══════════════════════════════════════════════════════════════════════════════
section "konk-service pods health (all namespaces)"
if should_run 6; then

# --- kubectl-apiservice pods ---
APISERVICE_PODS=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice \
  | grep -v "Completed" || true)
APISERVICE_TOTAL=0
APISERVICE_BAD=0

if [[ -z "$APISERVICE_PODS" ]]; then
  # Fallback: search by name pattern (some clusters may not have labels)
  # v2 chart names pods as *-konk-service-apiservice-*; v1 used *-kubectl-apiservice-*
  APISERVICE_PODS=$(kc get pods -A --no-headers | grep -E "konk-service-apiservice|kubectl-apiservice" \
    | grep -v "\-test" | grep -v "Completed" || true)
fi

if [[ -z "$APISERVICE_PODS" ]]; then
  warn "no kubectl-apiservice pods found"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ((APISERVICE_TOTAL++)) || true
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    ready=$(echo "$line" | awk '{print $3}')
    status=$(echo "$line" | awk '{print $4}')
    total=$(echo "$ready" | cut -d/ -f2)
    if [[ "$ready" == "${total}/${total}" && "$status" == "Running" ]]; then
      vinfo "kubectl-apiservice ${ns}/${pod}: ${ready} ${status}"
    else
      fail "kubectl-apiservice ${ns}/${pod}: ${ready} ${status}"
      ((APISERVICE_BAD++)) || true
    fi
  done <<< "$APISERVICE_PODS"

  if [[ $APISERVICE_BAD -eq 0 ]]; then
    pass "all ${APISERVICE_TOTAL} kubectl-apiservice pods are Running and all containers ready"
  fi
fi

# --- kubeconfig (reconcile-kubeconfig) pods ---
KUBECONFIG_PODS=$(kc get pods -A --no-headers -l app.kubernetes.io/component=kubeconfig \
  | grep -v "Completed" || true)
KUBECONFIG_TOTAL=0
KUBECONFIG_BAD=0

if [[ -z "$KUBECONFIG_PODS" ]]; then
  KUBECONFIG_PODS=$(kc get pods -A --no-headers | grep "konk-service-kubeconfig" \
    | grep -v "Completed" || true)
fi

if [[ -z "$KUBECONFIG_PODS" ]]; then
  warn "no kubeconfig pods found"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ((KUBECONFIG_TOTAL++)) || true
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    ready=$(echo "$line" | awk '{print $3}')
    status=$(echo "$line" | awk '{print $4}')
    total=$(echo "$ready" | cut -d/ -f2)
    if [[ "$ready" == "${total}/${total}" && "$status" == "Running" ]]; then
      vinfo "kubeconfig ${ns}/${pod}: ${ready} ${status}"
    else
      fail "kubeconfig ${ns}/${pod}: ${ready} ${status}"
      ((KUBECONFIG_BAD++)) || true
    fi
  done <<< "$KUBECONFIG_PODS"

  if [[ $KUBECONFIG_BAD -eq 0 ]]; then
    pass "all ${KUBECONFIG_TOTAL} kubeconfig (reconcile) pods are Running and all containers ready"
  fi
fi

# --- apiservice-test pods ---
# Note: test-apiservice pods typically run as 0/1 Running (no readiness probe) — this is normal.
# We only flag CrashLoopBackOff or Error states.
TEST_PODS=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice-test \
  | grep -v "Completed" || true)

if [[ -z "$TEST_PODS" ]]; then
  TEST_PODS=$(kc get pods -A --no-headers | grep "apiservice-test" \
    | grep -v "Completed" || true)
fi

TEST_TOTAL=0
TEST_CRASH=0

if [[ -n "$TEST_PODS" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ((TEST_TOTAL++)) || true
    ns=$(echo "$line" | awk '{print $1}')
    pod=$(echo "$line" | awk '{print $2}')
    ready=$(echo "$line" | awk '{print $3}')
    status=$(echo "$line" | awk '{print $4}')
    if echo "$status" | grep -qE 'CrashLoopBackOff|Error|ImagePullBackOff' 2>/dev/null; then
      fail "apiservice-test ${ns}/${pod}: ${ready} ${status}"
      ((TEST_CRASH++)) || true
    else
      vinfo "apiservice-test ${ns}/${pod}: ${ready} ${status}"
    fi
  done <<< "$TEST_PODS"

  if [[ $TEST_CRASH -eq 0 ]]; then
    pass "${TEST_TOTAL} apiservice-test pods present, none in error state (0/1 Running is normal)"
  fi
else
  vinfo "no apiservice-test pods found (may be normal)"
fi

# --- per-KonkService Deployment completeness ---
# Each KonkService must have these Deployments with ≥1 available replica:
#   component=kubeconfig  (renews 12h client cert in kubeconfig secret)
#   component=apiservice  (registers/maintains the APIService inside konk; aka "kubectl-apiservice")
# component=apiservice-test is optional and not enforced.
# Primary lookup: `app.kubernetes.io/instance=<ks>,app.kubernetes.io/component=<comp>`.
# Fallback: if the component label is absent, match by Deployment name suffix.
# v1 chart used -kubectl-apiservice; v2 chart uses -konk-service-apiservice.
# The chart truncates names to fit K8s' 63-char DNS-1123 limit but always preserves the suffix.
ALL_KSVC_FOR_DEPLOY_CHECK=$(kc get konkservice -A --no-headers | awk '{print $1, $2}')
KSVC_INCOMPLETE=0
KSVC_CHECKED=0
# Map of required components: label-component-name → name-suffix-pattern(s)
# Format: component-label:display-name:suffix1|suffix2
REQUIRED_COMPONENTS=("kubeconfig:kubeconfig:kubeconfig" "apiservice:kubectl-apiservice:konk-service-apiservice|kubectl-apiservice")

if [[ -n "$ALL_KSVC_FOR_DEPLOY_CHECK" ]]; then
  # Fetch all Deployments once and filter in jq (avoids ~3 kubectl calls per KonkService)
  ALL_DEPLOY_FOR_CHECK=$(kc get deploy -A -o json 2>/dev/null)
  while read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    ((KSVC_CHECKED++)) || true
    missing=()
    scaled_zero=()
    unavailable=()

    for entry in "${REQUIRED_COMPONENTS[@]}"; do
      comp="${entry%%:*}"
      rest="${entry#*:}"
      display="${rest%%:*}"
      suffixes="${rest##*:}"
      # Look up by labels first (resilient to chart name truncation), then fall back
      # to name-based matching since the chart may not set app.kubernetes.io/component.
      # Supports multiple suffix patterns separated by | (v1: -kubectl-apiservice, v2: -konk-service-apiservice).
      dep_info=$(echo "$ALL_DEPLOY_FOR_CHECK" | jq -r --arg ns "$ns" --arg inst "$name" --arg comp "$comp" --arg suffixes "$suffixes" '
        .items[]
        | select(.metadata.namespace==$ns
                 and .metadata.labels["app.kubernetes.io/instance"]==$inst
                 and (.metadata.labels["app.kubernetes.io/component"]==$comp
                      or (.metadata.labels["app.kubernetes.io/component"] == null
                          and (.metadata.name as $n | [ $suffixes | split("|")[] | . as $s | $n | endswith("-" + $s) ] | any))))
        | "\(.metadata.name)\t\(.spec.replicas // 0)\t\(.status.availableReplicas // 0)"' \
        | head -1)
      if [[ -z "$dep_info" ]]; then
        missing+=("${display}")
        continue
      fi
      dep_name="${dep_info%%$'\t'*}"
      rest="${dep_info#*$'\t'}"
      desired="${rest%%$'\t'*}"
      avail="${rest##*$'\t'}"
      if [[ "${desired:-0}" -eq 0 ]]; then
        scaled_zero+=("${dep_name}")
      elif [[ "${avail:-0}" -lt 1 ]]; then
        unavailable+=("${dep_name}(0/${desired})")
      fi
    done

    if [[ ${#missing[@]} -gt 0 || ${#scaled_zero[@]} -gt 0 || ${#unavailable[@]} -gt 0 ]]; then
      ((KSVC_INCOMPLETE++)) || true
      [[ ${#missing[@]} -gt 0 ]]    && fail "KonkService ${ns}/${name}: missing component Deployments: ${missing[*]}"
      [[ ${#scaled_zero[@]} -gt 0 ]] && fail "KonkService ${ns}/${name}: Deployments scaled to 0: ${scaled_zero[*]}"
      [[ ${#unavailable[@]} -gt 0 ]] && fail "KonkService ${ns}/${name}: Deployments with no available replicas: ${unavailable[*]}"
    else
      vinfo "KonkService ${ns}/${name}: all required konk-service Deployments present and ready"
    fi
  done <<< "$ALL_KSVC_FOR_DEPLOY_CHECK"

  if [[ $KSVC_INCOMPLETE -eq 0 && $KSVC_CHECKED -gt 0 ]]; then
    pass "all ${KSVC_CHECKED} KonkServices have their required konk-service Deployments running (kubeconfig + kubectl-apiservice)"
  elif [[ $KSVC_INCOMPLETE -gt 0 ]]; then
    info "${KSVC_INCOMPLETE}/${KSVC_CHECKED} KonkServices have missing/unavailable konk-service Deployments"
  fi
fi
fi  # section 6

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 7: CA trust chain validation
# ══════════════════════════════════════════════════════════════════════════════
section "CA trust chain (bulk-konk CA vs kubeconfig secrets)"
if should_run 7; then
if [[ "$SKIP_CA" == true ]]; then
  skip "CA chain validation (--skip-ca)"
else
  # Get bulk-konk CA fingerprint (source of truth)
  KONK_CA_B64=$(kc get secret bulk-konk-ca -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.data.tls\.crt}')

  if [[ -z "$KONK_CA_B64" ]]; then
    fail "cannot read bulk-konk-ca secret from ${AGGREGATE_NAMESPACE}"
  else
    KONK_CA_PEM=$(echo "$KONK_CA_B64" | base64 -d)
    KONK_FP=$(echo "$KONK_CA_PEM" | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
      | cut -d= -f2)
    KONK_CA_EXPIRY=$(echo "$KONK_CA_PEM" | openssl x509 -noout -enddate 2>/dev/null \
      | cut -d= -f2)

    assert_not_empty "bulk-konk CA fingerprint readable" "$KONK_FP"
    vinfo "bulk-konk CA fingerprint: ${KONK_FP}"
    vinfo "bulk-konk CA expires: ${KONK_CA_EXPIRY}"

    # Check CA is not expired
    if echo "$KONK_CA_PEM" | openssl x509 -noout -checkend 0 &>/dev/null; then
      pass "bulk-konk CA certificate is not expired"
    else
      fail "bulk-konk CA certificate is EXPIRED"
    fi

    # Compare with all kubeconfig secrets
    KC_SECRETS=$(kc get secrets -A --no-headers \
      | grep 'konk-service-kubeconfig[[:space:]]' \
      | grep -v '\-cert[[:space:]]' \
      | awk '{print $1, $2}' || true)

    CA_MATCH=0
    CA_MISMATCH=0
    CA_MISSING=0

    while read -r ns secret; do
      [[ -z "$ns" || -z "$secret" ]] && continue

      ca_b64=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}')
      if [[ -z "$ca_b64" ]]; then
        warn "CA MISSING in ${ns}/${secret}"
        ((CA_MISSING++)) || true
        continue
      fi

      fp=$(echo "$ca_b64" | base64 -d | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
        | cut -d= -f2 || echo "PARSE_ERROR")

      if [[ "$fp" == "$KONK_FP" ]]; then
        ((CA_MATCH++)) || true
        vinfo "CA MATCH: ${ns}/${secret}"
      else
        fail "CA MISMATCH: ${ns}/${secret} (got: ${fp:0:30}...)"
        ((CA_MISMATCH++)) || true
      fi
    done <<< "$KC_SECRETS"

    if [[ $CA_MISMATCH -eq 0 && $CA_MISSING -eq 0 ]]; then
      pass "all ${CA_MATCH} kubeconfig secrets have correct bulk-konk CA"
    else
      info "CA chain: ${CA_MATCH} match, ${CA_MISMATCH} mismatch, ${CA_MISSING} missing"
    fi

    # Check kubeconfig client certs (tls.crt) expiry — short-lived ~12h TTL
    # Flags: EXPIRED (already past), EXPIRING_SOON (within 1 hour)
    KC_EXPIRED=0
    KC_EXPIRING=0
    KC_TOTAL=0
    while read -r ns secret; do
      [[ -z "$ns" || -z "$secret" ]] && continue

      client_b64=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}')
      [[ -z "$client_b64" ]] && continue
      ((KC_TOTAL++)) || true

      cert_pem=$(echo "$client_b64" | base64 -d 2>/dev/null)
      [[ -z "$cert_pem" ]] && continue

      expiry=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      issued=$(echo "$cert_pem" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)

      if ! echo "$cert_pem" | openssl x509 -noout -checkend 0 &>/dev/null; then
        fail "client cert EXPIRED: ${ns}/${secret}  (issued=${issued}  expired=${expiry})"
        ((KC_EXPIRED++)) || true
      elif ! echo "$cert_pem" | openssl x509 -noout -checkend 3600 &>/dev/null; then
        warn "client cert EXPIRING SOON (<1h): ${ns}/${secret}  (expires=${expiry})"
        ((KC_EXPIRING++)) || true
      else
        vinfo "client cert ok: ${ns}/${secret}  issued=${issued}  expires=${expiry}"
      fi
    done <<< "$KC_SECRETS"

    if [[ $KC_EXPIRED -eq 0 && $KC_EXPIRING -eq 0 ]]; then
      pass "all ${KC_TOTAL} kubeconfig client certs (tls.crt) are valid and not expiring soon"
    fi
  fi
fi
fi  # section 7

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 8: APIServices inside konk (with detailed enumeration & error analysis)
# ══════════════════════════════════════════════════════════════════════════════
section "APIServices registered in konk"
if should_run 8; then
if [[ "$SKIP_EXEC" == true ]]; then
  skip "APIService checks via exec (--skip-exec)"
else
  # 7.0: Establish direct access to konk API via port-forward + extracted kubeconfig.
  #      The konk-service image is distroless (no kubectl binary), so we extract the
  #      kubeconfig secret and use the local kubectl to query konk directly.
  KONK_TMPDIR=""
  KONK_PF_PID=""
  KONK_KUBECTL=""   # will be set to the kubectl command prefix for konk queries

  # Find a kubeconfig secret (any namespace works — they all point to the same bulk-konk)
  KUBECONFIG_SECRET=$(kc get secrets -A --no-headers \
    -l app.kubernetes.io/name=konk-service \
    --field-selector type=Opaque 2>/dev/null \
    | grep "konk-service-kubeconfig " | head -1 || true)

  if [[ -z "$KUBECONFIG_SECRET" ]]; then
    # Fallback: search by name pattern
    KUBECONFIG_SECRET=$(kc get secrets -A --no-headers 2>/dev/null \
      | grep "konk-service-kubeconfig " | grep -v "cert" | head -1 || true)
  fi

  if [[ -n "$KUBECONFIG_SECRET" ]]; then
    KC_SECRET_NS=$(echo "$KUBECONFIG_SECRET" | awk '{print $1}')
    KC_SECRET_NAME=$(echo "$KUBECONFIG_SECRET" | awk '{print $2}')

    KONK_TMPDIR=$(mktemp -d)
    # Extract secret data (use plain kubectl to avoid kc wrapper affecting pipe output)
    kubectl get secret "$KC_SECRET_NAME" -n "$KC_SECRET_NS" -o "jsonpath={.data.tls\.crt}" 2>/dev/null | base64 -d > "$KONK_TMPDIR/tls.crt"
    kubectl get secret "$KC_SECRET_NAME" -n "$KC_SECRET_NS" -o "jsonpath={.data.tls\.key}" 2>/dev/null | base64 -d > "$KONK_TMPDIR/tls.key"

    if [[ ! -s "$KONK_TMPDIR/tls.crt" || ! -s "$KONK_TMPDIR/tls.key" ]]; then
      warn "failed to extract client certs from secret ${KC_SECRET_NS}/${KC_SECRET_NAME}"
    else
      # Start port-forward to bulk-konk service
      LOCAL_PORT=$(( (RANDOM % 10000) + 30000 ))
      kubectl port-forward "svc/${KONK_CR_NAME}" -n "$AGGREGATE_NAMESPACE" "${LOCAL_PORT}:6443" >/dev/null 2>&1 &
      KONK_PF_PID=$!
      disown "$KONK_PF_PID" 2>/dev/null  # suppress shell 'Terminated' message on cleanup
      # Wait for port-forward to be ready (Teleport-proxied clusters can take 5+ seconds)
      PF_READY=false
      for i in $(seq 1 10); do
        if ! kill -0 "$KONK_PF_PID" 2>/dev/null; then
          break
        fi
        if nc -z -w 1 localhost "$LOCAL_PORT" 2>/dev/null; then
          PF_READY=true
          break
        fi
        sleep 1
      done

    if [[ "$PF_READY" == "true" ]] && kill -0 "$KONK_PF_PID" 2>/dev/null; then
      # Build kubeconfig pointing to localhost.
      # insecure-skip-tls-verify is needed because konk's server cert has SANs for
      # bulk-konk.aggregate.svc, not localhost. Client certs are still used for auth.
      cat > "$KONK_TMPDIR/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:${LOCAL_PORT}
  name: bulk-konk
contexts:
- context:
    cluster: bulk-konk
    user: kubernetes-admin
  name: bulk-konk
current-context: bulk-konk
users:
- name: kubernetes-admin
  user:
    client-certificate: ${KONK_TMPDIR}/tls.crt
    client-key: ${KONK_TMPDIR}/tls.key
EOF
      # Verify connectivity
      if kubectl --kubeconfig="$KONK_TMPDIR/kubeconfig" get --raw /healthz >/dev/null 2>&1; then
        KONK_KUBECTL="kubectl --kubeconfig=${KONK_TMPDIR}/kubeconfig"
        info "connected to konk API via port-forward (localhost:${LOCAL_PORT})"
      else
        warn "port-forward established but konk API not reachable (TLS handshake or auth failed)"
      fi
    else
      warn "port-forward to ${KONK_CR_NAME}.${AGGREGATE_NAMESPACE}:6443 failed to start"
    fi
    fi  # end cert extraction check
  fi

  # Cleanup function for port-forward and temp dir
  cleanup_konk_pf() {
    [[ -n "$KONK_PF_PID" ]] && kill "$KONK_PF_PID" 2>/dev/null || true
    [[ -n "$KONK_TMPDIR" && -d "$KONK_TMPDIR" ]] && rm -rf "$KONK_TMPDIR" || true
  }
  trap 'cleanup_konk_pf' EXIT

  if [[ -z "$KONK_KUBECTL" ]]; then
    warn "no healthy konk API access available for API queries (no kubeconfig secret found or port-forward failed)"
    info "Ensure a kubeconfig secret exists: kubectl get secrets -A | grep konk-service-kubeconfig"
  else

    # 7.1: List all APIServices in konk (non-Local ones)
    # Capture both stdout and stderr to detect and report connection errors
    if [[ "$DEBUG" == true ]]; then
      info "command: ${KONK_KUBECTL} get apiservices -o wide --no-headers"
    fi
    APISERVICES_OUT=$($KONK_KUBECTL get apiservices -o wide --no-headers 2>&1 || true)
    APISERVICES_RAW=$(echo "$APISERVICES_OUT" | grep -v "^error:" | grep -v "^[EWI][0-9]" | grep -v "Local" || true)
    APISERVICES_ERRORS=$(echo "$APISERVICES_OUT" | grep -E "^error:|^[EWI][0-9]" || true)

    if [[ -n "$APISERVICES_ERRORS" ]]; then
      warn "errors while querying APIServices from konk:"
      echo "$APISERVICES_ERRORS" | sed 's/^/       /'
    fi

    if [[ -z "$APISERVICES_RAW" ]]; then
      warn "no non-Local APIServices returned from konk (could be a connectivity issue)"
    else
      APISVC_TOTAL=0
      APISVC_AVAIL=0
      APISVC_UNAVAIL=0
      APISVC_UNAVAIL_LIST=()

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((APISVC_TOTAL++)) || true
        name=$(echo "$line" | awk '{print $1}')
        svc=$(echo "$line" | awk '{print $2}')
        avail=$(echo "$line" | awk '{print $3}')

        if [[ "$avail" == "True" ]]; then
          ((APISVC_AVAIL++)) || true
          vinfo "APIService ${name} → ${svc}: Available=True"
        else
          ((APISVC_UNAVAIL++)) || true
          APISVC_UNAVAIL_LIST+=("${name} → ${svc}: Available=${avail}")
          vinfo "APIService ${name} → ${svc}: Available=${avail}"
        fi
      done <<< "$APISERVICES_RAW"

      if [[ $APISVC_UNAVAIL -eq 0 ]]; then
        pass "all ${APISVC_TOTAL} non-Local APIServices in konk are Available=True"
      else
        info "konk APIServices: ${APISVC_AVAIL}/${APISVC_TOTAL} available=True, ${APISVC_UNAVAIL} available=False"
        if [[ "$DEBUG" == true || "$VERBOSE" == true ]]; then
          echo "       Unavailable APIServices:"
          for item in "${APISVC_UNAVAIL_LIST[@]}"; do
            echo "       - ${item}"
          done
        fi
      fi
    fi

    # 7.2: List all API resources (this will show which APIs are working)
    if [[ "$DEBUG" == true ]]; then
      info "command: ${KONK_KUBECTL} api-resources --no-headers"
    fi
    API_RESOURCES_OUT=$($KONK_KUBECTL api-resources --no-headers 2>&1 || true)
    API_RESOURCES_ERRORS=$(echo "$API_RESOURCES_OUT" | grep "^error:" || true)

    if [[ -n "$API_RESOURCES_ERRORS" ]]; then
      warn "errors while querying api-resources from konk:"
      echo "$API_RESOURCES_ERRORS" | sed 's/^/       /'
    fi

    # 7.3: Check api-versions are reachable (bulk APIs only)
    if [[ "$DEBUG" == true ]]; then
      info "command: ${KONK_KUBECTL} api-versions"
    fi
    API_VERSIONS=$($KONK_KUBECTL api-versions 2>/dev/null || true)
    API_VERSION_COUNT=$(echo "$API_VERSIONS" | grep -c "bulk.infoblox.com" || true)
    API_VERSION_COUNT=${API_VERSION_COUNT:-0}
    if [[ "$API_VERSION_COUNT" -gt 0 ]]; then
      pass "konk serves ${API_VERSION_COUNT} bulk.infoblox.com API version(s)"
      if [[ "$VERBOSE" == true ]]; then
        echo "$API_VERSIONS" | grep "bulk.infoblox.com" | sed 's/^/         /'
      fi
    else
      warn "no bulk.infoblox.com API versions found in konk"
    fi

    # 7.4: Optional trigger test — restart one existing registration pod and verify reconcile
    if [[ "$TRIGGER_REGISTRATION" == true ]]; then
      info "trigger-registration enabled: forcing reconcile for an existing APIService"

      # Find a kubectl-apiservice (or konk-service-apiservice) pod to restart
      TARGET_LINE=$(kc get pods -A --no-headers 2>/dev/null \
        | grep -E "konk-service-apiservice|kubectl-ap" | grep -v "test" \
        | awk '$4=="Running"{split($3,a,"/"); if(a[1]==a[2]) print}' | head -1 || true)
      TARGET_NS=$(echo "$TARGET_LINE" | awk '{print $1}')
      TARGET_POD=$(echo "$TARGET_LINE" | awk '{print $2}')

      if [[ -z "$TARGET_POD" ]]; then
        skip "no suitable kubectl-apiservice pod found for trigger test"
      else
        RS_NAME=$(kc get pod "$TARGET_POD" -n "$TARGET_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
        DEPLOY_NAME=""
        if [[ -n "$RS_NAME" ]]; then
          DEPLOY_NAME=$(kc get rs "$RS_NAME" -n "$TARGET_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
        fi

        if [[ -z "$DEPLOY_NAME" ]]; then
          warn "unable to determine deployment owner for ${TARGET_NS}/${TARGET_POD}; skipping trigger test"
      else
        # Pre-check: verify deployment is already ready before triggering a restart
        DEPLOY_READY=$(kubectl get deploy "$DEPLOY_NAME" -n "$TARGET_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${DEPLOY_READY:-0}" -lt 1 ]]; then
          skip "deployment/${DEPLOY_NAME} in ${TARGET_NS} is not ready (readyReplicas=${DEPLOY_READY:-0}); skipping trigger test"
        else
        if [[ "$DEBUG" == true ]]; then
          info "command: kubectl delete pod -n ${TARGET_NS} ${TARGET_POD}"
        fi
        if kubectl delete pod -n "$TARGET_NS" "$TARGET_POD" >/dev/null 2>&1; then
          info "deleted pod ${TARGET_NS}/${TARGET_POD}; waiting for deployment/${DEPLOY_NAME} rollout"

          if kubectl rollout status deploy/"$DEPLOY_NAME" -n "$TARGET_NS" --timeout=180s >/dev/null 2>&1; then
            NEW_POD=$(kubectl get pods -n "$TARGET_NS" \
              -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase \
              --no-headers 2>/dev/null \
              | awk -v rs="$RS_NAME" '$2 == rs && $3 == "true" && $4 == "Running" {print $1; exit}' || true)

            if [[ -z "$NEW_POD" ]]; then
              warn "rollout completed but could not identify new running pod for ReplicaSet/${RS_NAME}"
            else
              if [[ "$DEBUG" == true ]]; then
                info "command: kubectl logs -n ${TARGET_NS} ${NEW_POD} --since=5m"
              fi

              RECONCILE_HITS=$(kubectl logs -n "$TARGET_NS" "$NEW_POD" --since=5m 2>/dev/null \
                | grep -c -E 'Applied APIService|APIService reconciliation complete' || true)

              if [[ "${RECONCILE_HITS:-0}" -gt 0 ]]; then
                pass "trigger reconcile successful: deployment/${DEPLOY_NAME} reapplied APIService (${RECONCILE_HITS} log hit(s))"
              else
                pass "trigger reconcile: deployment/${DEPLOY_NAME} restarted cleanly — all APIServices already registered, no re-apply needed"
              fi

              # 7.4b: Delete an APIService from inside konk and verify it gets re-registered
              # Find a True (healthy) APIService to use as the delete target
              DELETE_TARGET=$($KONK_KUBECTL get apiservices --no-headers 2>/dev/null \
                | grep 'True' | grep 'bulk.infoblox.com' \
                | grep -v 'FailedDiscovery' \
                | awk '{print $1}' | head -1 || true)

              if [[ -z "$DELETE_TARGET" ]]; then
                warn "no healthy konk APIService found to delete for re-registration test"
              else
                info "deleting konk APIService ${DELETE_TARGET} to trigger re-registration ..."
                if $KONK_KUBECTL delete apiservice "$DELETE_TARGET" >/dev/null 2>&1; then

                  # Wait up to 60s for the APIService to be re-registered
                  RESTORED=false
                  for _i in $(seq 1 12); do
                    sleep 5
                    STATE=$($KONK_KUBECTL get apiservice "$DELETE_TARGET" --no-headers 2>/dev/null | awk '{print $2}' || true)
                    if [[ -n "$STATE" ]]; then
                      RESTORED=true
                      break
                    fi
                  done

                  if [[ "$RESTORED" == true ]]; then
                    pass "APIService ${DELETE_TARGET} re-registered by konk-service after deletion (state: ${STATE})"
                  else
                    fail "APIService ${DELETE_TARGET} was NOT re-registered within 60s after deletion"
                  fi
                else
                  warn "could not delete APIService ${DELETE_TARGET} from konk (exec failed)"
                fi
              fi
            fi
          else
            fail "trigger reconcile failed: deployment/${DEPLOY_NAME} did not become ready within timeout"
          fi
        else
          fail "failed to delete pod ${TARGET_NS}/${TARGET_POD} for trigger test"
        fi
        fi  # deploy ready check
      fi
      fi  # if TARGET_POD not empty
    fi
  fi
fi
fi  # section 8

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 9: Deep test — sample namespace
# ══════════════════════════════════════════════════════════════════════════════
section "Deep test: ${SAMPLE_NS} namespace"
if should_run 9; then
# 8a. KonkService CR exists and is healthy
# With -n (not -A), columns are: NAME  KONK  APISERVICE  AGE → name is $1
SAMPLE_KSVC_NAME=$(kc get konkservice -n "$SAMPLE_NS" --no-headers | awk '{print $1}' | head -1)

if [[ -z "$SAMPLE_KSVC_NAME" ]]; then
  fail "no KonkService found in namespace '${SAMPLE_NS}'"
else
  SAMPLE_KSVC_REASON=$(kc get konkservice "$SAMPLE_KSVC_NAME" -n "$SAMPLE_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}')
  assert_contains "KonkService ${SAMPLE_NS}/${SAMPLE_KSVC_NAME} deployed" \
    "$SAMPLE_KSVC_REASON" "Successful"

  SAMPLE_KSVC_KONK=$(kc get konkservice "$SAMPLE_KSVC_NAME" -n "$SAMPLE_NS" \
    -o jsonpath='{.spec.konk.name}')
  vinfo "KonkService points to konk: ${SAMPLE_KSVC_KONK:-default}"
fi

# 8b. kubectl-apiservice pod is Running
SAMPLE_APIPOD=$(kc get pods -n "$SAMPLE_NS" --no-headers \
  -l app.kubernetes.io/component=apiservice | grep "Running" | head -1 || true)
if [[ -z "$SAMPLE_APIPOD" ]]; then
  # Fallback: v2 chart uses *-konk-service-apiservice-*, v1 used *-kubectl-apiservice-*
  SAMPLE_APIPOD=$(kc get pods -n "$SAMPLE_NS" --no-headers \
    | grep -E "konk-service-apiservice|kubectl-apiservice" | grep -v "\-test" | grep "Running" | head -1 || true)
fi

SAMPLE_APIPOD_NAME=$(echo "$SAMPLE_APIPOD" | awk '{print $1}')
SAMPLE_APIPOD_READY=$(echo "$SAMPLE_APIPOD" | awk '{print $2}')
SAMPLE_APIPOD_STATUS=$(echo "$SAMPLE_APIPOD" | awk '{print $3}')

if [[ -z "$SAMPLE_APIPOD_NAME" ]]; then
  fail "no kubectl-apiservice pod found running in ${SAMPLE_NS}"
else
  # Pod may have a linkerd sidecar (2/2) or not (1/1) — check all containers are ready
  _ready_num=$(echo "$SAMPLE_APIPOD_READY" | cut -d/ -f1)
  _ready_tot=$(echo "$SAMPLE_APIPOD_READY" | cut -d/ -f2)
  if [[ "$_ready_num" == "$_ready_tot" && "$_ready_num" -gt 0 ]] 2>/dev/null; then
    pass "${SAMPLE_NS} kubectl-apiservice pod ready (${SAMPLE_APIPOD_READY})"
  else
    fail "${SAMPLE_NS} kubectl-apiservice pod not fully ready (${SAMPLE_APIPOD_READY})"
  fi

  # Check no restarts (indicates stability)
  SAMPLE_APIPOD_RESTARTS=$(echo "$SAMPLE_APIPOD" | awk '{print $4}')
  if [[ "${SAMPLE_APIPOD_RESTARTS:-0}" -eq 0 ]]; then
    pass "${SAMPLE_NS} kubectl-apiservice pod: 0 restarts"
  else
    warn "${SAMPLE_NS} kubectl-apiservice pod: ${SAMPLE_APIPOD_RESTARTS} restart(s)"
  fi
fi

# 8c. kubeconfig secret CA chain
if [[ "$SKIP_CA" != true && -n "${KONK_FP:-}" ]]; then
    SAMPLE_KC_SECRET="$(kc get secrets -n "$SAMPLE_NS" --no-headers \
      | awk '$1 ~ /konk-service-kubeconfig/ && $1 !~ /-cert$/ {print $1; exit}' || true)"
  if [[ -n "$SAMPLE_KC_SECRET" ]]; then
    SAMPLE_CA_B64=$(kc get secret "$SAMPLE_KC_SECRET" -n "$SAMPLE_NS" \
      -o jsonpath='{.data.ca\.crt}')
    SAMPLE_FP=$(echo "$SAMPLE_CA_B64" | base64 -d \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo "")
    assert_equals "${SAMPLE_NS} kubeconfig CA matches bulk-konk" "$SAMPLE_FP" "$KONK_FP"
  else
    warn "kubeconfig secret not found in ${SAMPLE_NS}"
  fi
fi

# 8d. Exec into pod — check reconciliation is working (no x509 errors in logs)
if [[ "$SKIP_EXEC" != true && -n "$SAMPLE_APIPOD_NAME" ]]; then
  SAMPLE_LOGS=$(kubectl logs "$SAMPLE_APIPOD_NAME" -n "$SAMPLE_NS" --tail=20 2>/dev/null || true)
  if echo "$SAMPLE_LOGS" | grep -qi "x509\|certificate.*unknown\|tls.*failed" 2>/dev/null; then
    fail "${SAMPLE_NS} kubectl-apiservice logs contain TLS/x509 errors"
    echo "$SAMPLE_LOGS" | grep -i "x509\|certificate.*unknown\|tls.*failed" | head -3 | sed 's/^/         /'
  else
    pass "${SAMPLE_NS} kubectl-apiservice logs: no x509/TLS errors"
  fi

  # Check that APIService reconciliation completed
  if echo "$SAMPLE_LOGS" | grep -qi "APIService reconciliation complete\|Applied APIService" 2>/dev/null; then
    pass "${SAMPLE_NS} kubectl-apiservice: APIService reconciliation succeeded"
  else
    warn "${SAMPLE_NS} kubectl-apiservice: no recent reconciliation log entry"
  fi
fi

# 8e. Verify konk connectivity from the sample namespace
#     The konk-service pod uses distroless (no kubectl/shell), so we validate
#     connectivity by: (1) checking pod logs for successful APIService apply,
#     (2) querying the APIService object from the host cluster, and
#     (3) optionally using a pod with kubectl (from section 7) for deep checks.
if [[ "$SKIP_EXEC" != true && -n "$SAMPLE_APIPOD_NAME" ]]; then

  # 8f-i. Log-based connectivity check — the pod logs "Applied APIService" on success
  SAMPLE_APPLY_LOG=$(kubectl logs "$SAMPLE_APIPOD_NAME" -n "$SAMPLE_NS" --tail=50 2>/dev/null \
    | grep -c -E 'Applied APIService|APIService reconciliation complete|successfully applied' || true)
  if [[ "${SAMPLE_APPLY_LOG:-0}" -gt 0 ]]; then
    pass "${SAMPLE_NS} konk-service pod: ${SAMPLE_APPLY_LOG} successful APIService apply(s) in recent logs"
  else
    # Check for errors that indicate konk connectivity failure
    SAMPLE_KONK_ERRORS=$(kubectl logs "$SAMPLE_APIPOD_NAME" -n "$SAMPLE_NS" --tail=50 2>/dev/null \
      | grep -c -iE 'connection refused|x509|dial tcp.*timeout|unauthorized|cannot reach' || true)
    if [[ "${SAMPLE_KONK_ERRORS:-0}" -gt 0 ]]; then
      fail "${SAMPLE_NS} konk-service pod: ${SAMPLE_KONK_ERRORS} konk connectivity error(s) in recent logs"
      kubectl logs "$SAMPLE_APIPOD_NAME" -n "$SAMPLE_NS" --tail=50 2>/dev/null \
        | grep -iE 'connection refused|x509|dial tcp.*timeout|unauthorized|cannot reach' | head -3 | sed 's/^/         /' || true
    else
      warn "${SAMPLE_NS} konk-service pod: no recent APIService apply log entries (pod may not have reconciled yet)"
    fi
  fi

  # 8f-ii. Host-side check — query the APIService in konk via section 7's exec pod
  SAMPLE_GROUP=$(kc get konkservice "$SAMPLE_KSVC_NAME" -n "$SAMPLE_NS" \
    -o jsonpath='{.spec.group.name}' 2>/dev/null)
  SAMPLE_VERSION=$(kc get konkservice "$SAMPLE_KSVC_NAME" -n "$SAMPLE_NS" \
    -o jsonpath='{.spec.version}' 2>/dev/null)

  # Refresh EXEC_POD in case section 7 deleted it during trigger-registration
  if [[ -n "${EXEC_POD:-}" ]] && ! kubectl get pod -n "${EXEC_NS:-}" "$EXEC_POD" >/dev/null 2>&1; then
    EXEC_POD=""
    EXEC_NS=""
    _fresh=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice 2>/dev/null \
      | awk '$4=="Running"{split($3,a,"/"); if(a[1]==a[2]) print}' | head -1 || true)
    if [[ -n "$_fresh" ]]; then
      EXEC_NS=$(echo "$_fresh" | awk '{print $1}')
      EXEC_POD=$(echo "$_fresh" | awk '{print $2}')
    fi
  fi
  # Ensure EXEC_C_FLAG is set (may not be if section 7 didn't run)
  EXEC_C_FLAG="${EXEC_C_FLAG:-}"

  if [[ -n "${EXEC_POD:-}" && -n "$SAMPLE_GROUP" && -n "$SAMPLE_VERSION" ]]; then
    EXPECTED_APISVC="${SAMPLE_VERSION}.${SAMPLE_GROUP}"
    # shellcheck disable=SC2086
    APISVC_STATUS=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl get apiservice "${EXPECTED_APISVC}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
      2>/dev/null || echo "")
    # Strip any "Defaulted container" noise that may appear on stdout
    APISVC_STATUS=$(echo "$APISVC_STATUS" | grep -v '^Defaulted container' | tr -d '\n' || true)
    if echo "$APISVC_STATUS" | grep -qE '^error:|not found|x509|refused' 2>/dev/null; then
      APISVC_STATUS=""
    fi
    if [[ "$APISVC_STATUS" == "True" ]]; then
      pass "APIService ${EXPECTED_APISVC} in konk: Available=True"
    elif [[ -z "$APISVC_STATUS" ]]; then
      warn "APIService ${EXPECTED_APISVC} not found in konk (section 7 may not have run)"
    else
      fail "APIService ${EXPECTED_APISVC} in konk: Available=${APISVC_STATUS}"
    fi
  elif [[ -n "$SAMPLE_GROUP" && -n "$SAMPLE_VERSION" ]]; then
    vinfo "skipping APIService availability check — no exec pod available (run section 7 first)"
  fi

  # 8f-iii. If section 7 found a pod with kubectl, also list api-resources
  if [[ -n "${EXEC_POD:-}" ]]; then
    API_RESOURCES=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
      kubectl api-resources --no-headers 2>&1 | grep -v '^error:' | head -5 || true)
    if [[ -n "$API_RESOURCES" ]]; then
      pass "${SAMPLE_NS}: kubectl api-resources works against konk (via ${EXEC_NS}/${EXEC_POD})"
    else
      warn "${SAMPLE_NS}: kubectl api-resources returned empty"
    fi
  fi
fi

# 8f. TLS server secret — verify the konk-service server TLS secret exists
SAMPLE_TLS_SECRET=$(kc get secrets -n "$SAMPLE_NS" --no-headers \
  | grep 'konk-service-server[[:space:]]' | awk '{print $1}' | head -1)
if [[ -n "$SAMPLE_TLS_SECRET" ]]; then
  # Check it has tls.crt and tls.key keys
  TLS_KEYS=$(kc get secret "$SAMPLE_TLS_SECRET" -n "$SAMPLE_NS" \
    -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(sorted(d.keys())))" 2>/dev/null || echo "")
  if echo "$TLS_KEYS" | grep -q "tls.crt" 2>/dev/null && echo "$TLS_KEYS" | grep -q "tls.key" 2>/dev/null; then
    pass "${SAMPLE_NS} TLS server secret '${SAMPLE_TLS_SECRET}': has tls.crt + tls.key"

    # Also check server cert is not expired or expiring soon (1 week warning)
    server_crt_b64=$(kc get secret "$SAMPLE_TLS_SECRET" -n "$SAMPLE_NS" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
    if [[ -n "$server_crt_b64" ]]; then
      server_crt_pem=$(echo "$server_crt_b64" | base64 -d 2>/dev/null)
      srv_expiry=$(echo "$server_crt_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if ! echo "$server_crt_pem" | openssl x509 -noout -checkend 0 &>/dev/null; then
        fail "${SAMPLE_NS} server cert EXPIRED: ${SAMPLE_TLS_SECRET} (expired=${srv_expiry})"
      elif ! echo "$server_crt_pem" | openssl x509 -noout -checkend 604800 &>/dev/null; then
        warn "${SAMPLE_NS} server cert EXPIRING within 7 days: ${SAMPLE_TLS_SECRET} (expires=${srv_expiry})"
      else
        vinfo "${SAMPLE_NS} server cert ok: expires=${srv_expiry}"
      fi
    fi
  else
    warn "${SAMPLE_NS} TLS server secret '${SAMPLE_TLS_SECRET}': missing expected keys (got: ${TLS_KEYS})"
  fi
else
  warn "TLS server secret not found in ${SAMPLE_NS} (expected *-konk-service-server)"
fi

# 8g-ii. APIService backend endpoint readiness — detect notReadyAddresses (503 precursor)
# A pod can be 2/3 Running but in notReadyAddresses, making the APIService backend unreachable.
# This was the root cause of 503 errors in the gov-stg-2 cert expiry incident.
APISVC_ENDPOINT_BAD=0
APISVC_ENDPOINT_TOTAL=0
KONKSVC_LIST=$(kc get konkservice -A --no-headers 2>/dev/null \
  | awk '{print $1, $2}' || true)
if [[ -n "$KONKSVC_LIST" ]]; then
  while read -r svc_ns svc_name; do
    [[ -z "$svc_ns" || -z "$svc_name" ]] && continue
    # The KonkService's APIService backend is the service named <svc_name>-apiservice (or just svc_name)
    # Try the most common naming pattern: <konkservice-name> (service name == CR name)
    for ep_name in "${svc_name}" "${svc_name}-apiservice"; do
      EP_JSON=$(kc get endpoints "$ep_name" -n "$svc_ns" -o json 2>/dev/null || true)
      [[ -z "$EP_JSON" ]] && continue
      ((APISVC_ENDPOINT_TOTAL++)) || true
      NOT_READY=$(echo "$EP_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
not_ready = []
for subset in data.get('subsets', []):
    for addr in subset.get('notReadyAddresses', []):
        not_ready.append(addr.get('targetRef', {}).get('name', addr.get('ip', '?')))
if not_ready:
    print(' '.join(not_ready))
" 2>/dev/null || true)
      if [[ -n "$NOT_READY" ]]; then
        warn "APIService endpoint ${svc_ns}/${ep_name}: service endpoint has no ready backends — pod(s) in notReadyAddresses: ${NOT_READY}. konk's available_controller will get 503 probing this APIService and log 'service unavailable' (same pattern as gov-stg-2 cert expiry incident)"
        ((APISVC_ENDPOINT_BAD++)) || true
      else
        vinfo "APIService endpoint ${svc_ns}/${ep_name}: all addresses ready"
      fi
      break
    done
  done <<< "$KONKSVC_LIST"
  if [[ $APISVC_ENDPOINT_BAD -eq 0 && $APISVC_ENDPOINT_TOTAL -gt 0 ]]; then
    pass "all ${APISVC_ENDPOINT_TOTAL} APIService backend endpoints have ready addresses (no 503 risk)"
  fi
fi

# 8g. Pod events on failure — show describe + logs when pod is unhealthy
if [[ -z "$SAMPLE_APIPOD_NAME" || "$SAMPLE_APIPOD_READY" != "1/1" ]]; then
  TARGET_POD=${SAMPLE_APIPOD_NAME:-}
  if [[ -z "$TARGET_POD" ]]; then
    TARGET_POD=$(kc get pods -n "$SAMPLE_NS" --no-headers \
      | grep "konk-service-kubectl-apiservice" | head -1 | awk '{print $1}')
  fi
  if [[ -n "$TARGET_POD" ]]; then
    info "${SAMPLE_NS} pod '${TARGET_POD}' is unhealthy — showing events:"
    kubectl describe pod "$TARGET_POD" -n "$SAMPLE_NS" 2>/dev/null | tail -15 | sed 's/^/         /' || true
    info "${SAMPLE_NS} pod logs (last 10 lines):"
    kubectl logs "$TARGET_POD" -n "$SAMPLE_NS" --tail=10 2>/dev/null | sed 's/^/         /' || true
  fi
fi
fi  # section 9

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 10: Bulk (atlas.bulk) integration
# ══════════════════════════════════════════════════════════════════════════════
section "Bulk (atlas.bulk) integration with konk"
if should_run 10; then
if [[ "$SKIP_BULK" == true ]]; then
  skip "bulk integration test (--skip-bulk)"
else
  # 9a. bulk deployment exists and is healthy
  BULK_DESIRED=$(kc get deploy bulk -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.spec.replicas}')
  BULK_READY=$(kc get deploy bulk -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}')

  if [[ -z "$BULK_DESIRED" ]]; then
    warn "bulk deployment not found in ${AGGREGATE_NAMESPACE} (may not be deployed on this cluster)"
  else
    assert_equals "bulk deployment replicas ready" "${BULK_READY:-0}" "$BULK_DESIRED"

    # 9b. bulk pod is Running
    BULK_POD=$(kc get pods -n "$AGGREGATE_NAMESPACE" -l app.kubernetes.io/name=bulk \
      --no-headers | grep "Running" | head -1 || true)
    if [[ -z "$BULK_POD" ]]; then
      # Fallback: try by deployment label
      BULK_POD=$(kc get pods -n "$AGGREGATE_NAMESPACE" --no-headers \
        | grep -E "^bulk-[a-z0-9]+-[a-z0-9]+ " | grep "Running" | head -1 || true)
    fi

    BULK_POD_NAME=$(echo "$BULK_POD" | awk '{print $1}')
    if [[ -z "$BULK_POD_NAME" ]]; then
      warn "no Running bulk pod found"
    else
      BULK_POD_READY=$(echo "$BULK_POD" | awk '{print $2}')
      # bulk pod may have multiple containers (e.g. 2/2) — check X/X pattern (all ready)
      BULK_READY_NUM=$(echo "$BULK_POD_READY" | cut -d/ -f1)
      BULK_TOTAL_NUM=$(echo "$BULK_POD_READY" | cut -d/ -f2)
      if [[ "$BULK_READY_NUM" == "$BULK_TOTAL_NUM" && "$BULK_READY_NUM" -gt 0 ]] 2>/dev/null; then
        pass "bulk pod ready (${BULK_POD_READY})"
      else
        fail "bulk pod not fully ready (${BULK_POD_READY})"
      fi

      # 9c. bulk→konk connectivity is validated indirectly via bulk pod logs (9e)
      # and from the apiservice pod (9d) — no wget/curl in bulk image.
    fi
  fi

  # 9d. konk apiserver /healthz — already validated by section 2 (bulk-konk pod readiness probe IS /healthz).
  # If port-forward from section 7 is still alive, do a direct check as a bonus.
  if [[ -n "${KONK_KUBECTL:-}" ]]; then
    if [[ -n "${KONK_PF_PID:-}" ]] && ! kill -0 "$KONK_PF_PID" 2>/dev/null; then
      info "port-forward from section 7 is no longer active; healthz already covered by section 2"
    else
      KONK_HEALTHZ=$($KONK_KUBECTL get --raw /healthz --request-timeout=10s 2>/dev/null || true)
      if [[ "$KONK_HEALTHZ" == "ok" ]]; then
        pass "konk apiserver /healthz returns 'ok' (via port-forward)"
      elif [[ -n "$KONK_HEALTHZ" ]]; then
        warn "konk apiserver /healthz returned: ${KONK_HEALTHZ:0:50}"
      else
        info "konk apiserver /healthz unreachable via port-forward (health covered by section 2 pod readiness)"
      fi
    fi
  fi

  # 9e. bulk-konk proxy-client secret — used by bulk to authenticate to konk apiserver
  PROXY_CLIENT_SECRET=$(kc get secrets -n "$AGGREGATE_NAMESPACE" --no-headers \
    | grep 'bulk-konk-proxy-client' | awk '{print $1}' | head -1)
  if [[ -n "$PROXY_CLIENT_SECRET" ]]; then
    PROXY_KEYS=$(kc get secret "$PROXY_CLIENT_SECRET" -n "$AGGREGATE_NAMESPACE" \
      -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(sorted(d.keys())))" 2>/dev/null || echo "")
    if echo "$PROXY_KEYS" | grep -q "tls.crt\|client" 2>/dev/null; then
      pass "bulk-konk proxy-client secret exists (keys: ${PROXY_KEYS})"
    else
      warn "bulk-konk proxy-client secret exists but has unexpected keys: ${PROXY_KEYS}"
    fi
  else
    warn "bulk-konk-proxy-client secret not found in ${AGGREGATE_NAMESPACE}"
  fi

  # 9f. bulk deployment --konk.host argument — verify it points to the correct konk apiserver
  BULK_KONK_HOST=$(kc get deploy bulk -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | python3 -c "
import sys, json
try:
    args = json.load(sys.stdin)
    for a in args:
        if a.startswith('--konk.host='):
            print(a.split('=',1)[1])
            break
except: pass
" 2>/dev/null || echo "")
  if [[ -n "$BULK_KONK_HOST" ]]; then
    if [[ "$BULK_KONK_HOST" == *"bulk-konk"* ]]; then
      pass "bulk --konk.host points to konk apiserver: ${BULK_KONK_HOST}"
    else
      info "bulk --konk.host is: ${BULK_KONK_HOST} (not default bulk-konk — check if intentional)"
    fi
  else
    # may be set via env or configmap instead of args
    vinfo "bulk --konk.host not found in deployment args (may use env/configmap)"
  fi

  # 9g. bulk pod log errors — check for x509, connection refused, timeout in recent logs
  if [[ -n "${BULK_POD_NAME:-}" ]]; then
    # Get the bulk application container name (skip linkerd sidecar)
    BULK_CONTAINER=$(kc get pod "$BULK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
      -o jsonpath='{.spec.containers[*].name}' \
      | tr ' ' '\n' | grep -v linkerd | head -1)
    BULK_CONTAINER_FLAG=""
    if [[ -n "$BULK_CONTAINER" ]]; then
      BULK_CONTAINER_FLAG="-c $BULK_CONTAINER"
    fi
      BULK_LOG_ERRORS=$({ kubectl logs "$BULK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
        $BULK_CONTAINER_FLAG --tail=50 2>/dev/null || true; } \
        | grep -Eic "error|x509|connection refused|timeout" 2>/dev/null || true)
      BULK_LOG_ERRORS=${BULK_LOG_ERRORS:-0}
    if [[ "${BULK_LOG_ERRORS}" -eq 0 ]] 2>/dev/null; then
      pass "bulk pod logs: no errors in last 50 lines"
    else
      warn "bulk pod logs: ${BULK_LOG_ERRORS} potential error(s) in last 50 lines"
      if [[ "$VERBOSE" == true ]]; then
        kubectl logs "$BULK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
          $BULK_CONTAINER_FLAG --tail=50 2>/dev/null \
          | grep -i "error\|x509\|connection refused\|timeout" | head -5 | sed 's/^/         /' || true
      fi
    fi
  fi

  # 9h. bulk-konk apiserver logs — check for "x509: certificate has expired" rejections
  # This is the direct signal for the cert expiry incident pattern (gov-stg-2 Apr 2026):
  # clients holding stale certs → apiserver logs "Unable to authenticate the request"
  # err="x509: certificate has expired or is not yet valid"
  KONK_POD_NAME=$(kc get pods -n "$AGGREGATE_NAMESPACE" --no-headers \
    -l "app.kubernetes.io/name=${KONK_CR_NAME}" 2>/dev/null \
    | awk '$3=="Running"{print $1; exit}' || true)
  if [[ -z "$KONK_POD_NAME" ]]; then
    KONK_POD_NAME=$(kc get pods -n "$AGGREGATE_NAMESPACE" --no-headers 2>/dev/null \
      | grep "^${KONK_CR_NAME}-" | awk '$3=="Running"{print $1; exit}' || true)
  fi

  if [[ -n "$KONK_POD_NAME" ]]; then
    KONK_APISERVER_CONTAINER=$(kc get pod "$KONK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
      -o jsonpath='{.spec.containers[*].name}' 2>/dev/null \
      | tr ' ' '\n' | grep -v linkerd | head -1 || true)
    KONK_CONTAINER_FLAG=""
    [[ -n "$KONK_APISERVER_CONTAINER" ]] && KONK_CONTAINER_FLAG="-c $KONK_APISERVER_CONTAINER"

    CERT_EXPIRED_COUNT=$({ kubectl logs "$KONK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
      $KONK_CONTAINER_FLAG --since=2m 2>/dev/null || true; } \
      | (grep "certificate has expired" || true) | wc -l | tr -d ' ')

    if [[ "${CERT_EXPIRED_COUNT}" -eq 0 ]]; then
      pass "bulk-konk apiserver logs: no 'certificate has expired' rejections in last 2 min"
    else
      fail "bulk-konk apiserver: ${CERT_EXPIRED_COUNT} 'certificate has expired' rejection(s) in last 2 min — clients holding stale certs"
      if [[ "$VERBOSE" == true ]]; then
        kubectl logs "$KONK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
          $KONK_CONTAINER_FLAG --since=2m 2>/dev/null \
          | grep "certificate has expired" | tail -5 | sed 's/^/         /' || true
      fi
    fi
  else
    vinfo "bulk-konk apiserver pod not found — skipping expired cert log check"
  fi
fi
fi  # section 10

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 11: konk-operator log health
# ══════════════════════════════════════════════════════════════════════════════
section "konk-operator log health"
if should_run 11; then
# Collect logs from the operator container only (pod may have linkerd sidecar)
OPERATOR_POD_NAME=$(kc get pods -n "$KONK_NAMESPACE" -l app.kubernetes.io/name=konk-operator \
  -o jsonpath='{.items[0].metadata.name}')
OPERATOR_CONTAINER=$(kc get pods -n "$KONK_NAMESPACE" -l app.kubernetes.io/name=konk-operator \
  -o jsonpath='{.items[0].spec.containers[0].name}')
OPERATOR_LOGS=""
if [[ -n "$OPERATOR_POD_NAME" && -n "$OPERATOR_CONTAINER" ]]; then
  OPERATOR_LOGS=$(kubectl logs -n "$KONK_NAMESPACE" "$OPERATOR_POD_NAME" \
    -c "$OPERATOR_CONTAINER" --tail=100 2>/dev/null || true)
elif [[ -n "$OPERATOR_POD_NAME" ]]; then
  OPERATOR_LOGS=$(kubectl logs -n "$KONK_NAMESPACE" "$OPERATOR_POD_NAME" --tail=100 2>/dev/null || true)
fi
OPERATOR_ERROR_COUNT=$(echo "$OPERATOR_LOGS" | { grep -ic '"level":"error"' || true; } | tr -d ' ')
if [[ "$OPERATOR_ERROR_COUNT" -eq 0 ]]; then
  pass "konk-operator: no errors in last 100 log lines"
else
  warn "konk-operator: ${OPERATOR_ERROR_COUNT} error(s) in last 100 log lines"
  if [[ "$VERBOSE" == true ]]; then
    echo "$OPERATOR_LOGS" | grep -i '"level":"error"' | tail -3 | sed 's/^/         /'
  fi
fi

# Check for reconcile errors
RECONCILE_ERRORS=$(echo "$OPERATOR_LOGS" | { grep -ic 'reconcile.*error\|error.*reconcil' || true; } | tr -d ' ')
if [[ "$RECONCILE_ERRORS" -gt 0 ]]; then
  warn "konk-operator: ${RECONCILE_ERRORS} reconcile error(s) in recent logs"
fi

# Check for Helm "Release failed" — indicates operator cannot apply the chart
# Pull more logs (last 500) to catch failures that might be outside the tail-100 window
# (bulk-konk-etcd reconciles every ~60s which pushes bulk-konk failures out quickly)
OPERATOR_LOGS_EXTENDED=""
if [[ -n "$OPERATOR_POD_NAME" && -n "$OPERATOR_CONTAINER" ]]; then
  OPERATOR_LOGS_EXTENDED=$(kubectl logs -n "$KONK_NAMESPACE" "$OPERATOR_POD_NAME" \
    -c "$OPERATOR_CONTAINER" --tail=500 2>/dev/null || true)
elif [[ -n "$OPERATOR_POD_NAME" ]]; then
  OPERATOR_LOGS_EXTENDED=$(kubectl logs -n "$KONK_NAMESPACE" "$OPERATOR_POD_NAME" --tail=500 2>/dev/null || true)
fi

# Check each release separately: bulk-konk (Konk CR) and bulk-konk-etcd (Etcd CR)
for RELEASE_CHECK in "$KONK_CR_NAME" "${KONK_CR_NAME}-etcd"; do
  RELEASE_FAILED_LINES=$(echo "$OPERATOR_LOGS_EXTENDED" | grep '"Release failed"' | grep "\"release\":\"${RELEASE_CHECK}\"" || true)
  if [[ -n "$RELEASE_FAILED_LINES" ]]; then
    RELEASE_FAILED_COUNT=$(echo "$RELEASE_FAILED_LINES" | wc -l | tr -d ' ')
    # Get timestamps of first and last failure
    FIRST_TS=$(echo "$RELEASE_FAILED_LINES" | head -1 | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
    LAST_TS=$(echo "$RELEASE_FAILED_LINES" | tail -1 | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
    fail "konk-operator: release '${RELEASE_CHECK}' has ${RELEASE_FAILED_COUNT} 'Release failed' error(s)"
    # Extract the error reason from the most recent failure
    RELEASE_ERROR=$(echo "$RELEASE_FAILED_LINES" | tail -1 | sed 's/.*"error":"//;s/","stacktrace".*//;s/"}.*//')
    RELEASE_NS=$(echo "$RELEASE_FAILED_LINES" | tail -1 | sed -n 's/.*"namespace":"\([^"]*\)".*/\1/p')
    if [[ -n "$RELEASE_ERROR" ]]; then
      echo "       Release: ${RELEASE_CHECK} (ns: ${RELEASE_NS:-unknown})"
      echo "       Period:  ${FIRST_TS} → ${LAST_TS} (${RELEASE_FAILED_COUNT} retries)"
      echo "       Reason:  ${RELEASE_ERROR}"
      # Suggest fix if it's the common ownership annotation issue
      if echo "$RELEASE_ERROR" | grep -q "meta.helm.sh/release-name"; then
        RESOURCE_INFO=$(echo "$RELEASE_ERROR" | sed -n 's/.*with install: \([^ ]* "[^"]*"\).*/\1/p')
        echo "       Fix:     kubectl annotate ${RESOURCE_INFO:-serviceaccount ${RELEASE_CHECK}} -n ${RELEASE_NS} meta.helm.sh/release-name=${RELEASE_CHECK} meta.helm.sh/release-namespace=${RELEASE_NS} --overwrite"
      fi
      echo "       Check:   kubectl logs -n konk -l app.kubernetes.io/name=konk-operator --tail=50 | grep '\"release\":\"${RELEASE_CHECK}\"' | grep 'Release failed'"
    fi
  else
    pass "konk-operator: release '${RELEASE_CHECK}' — no 'Release failed' errors"
  fi
done

# Check actual Helm release status and last-deployed time for all Konk-related releases
# NOTE: CR condition lastTransitionTime is unreliable (only updates on status flip True↔False).
# Helm release 'updated' timestamp is the real source of truth for when a release was last deployed.
vinfo "Checking Helm release status for all Konk CRs..."
HELM_RELEASE_ISSUES=0
# Get unique namespaces from konk CRs, then query helm per-namespace (avoids slow helm list -A with 776+ releases)
KONK_NS_LIST=$(kubectl get konks.konk.infoblox.com,etcds.konk.infoblox.com,konkservices.konk.infoblox.com \
  -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
for HELM_NS in $KONK_NS_LIST; do
  # --deployed --failed --pending covers all actionable states (skip superseded/uninstalled)
  helm list -n "$HELM_NS" --deployed --failed --pending -o json 2>/dev/null | python3 -c "
import sys, json
try:
    releases = json.load(sys.stdin)
except:
    sys.exit(0)
konk_charts = ('konk-', 'etcd-', 'konk-service-')
for rel in releases:
    chart = rel.get('chart', '')
    if any(chart.startswith(prefix) for prefix in konk_charts):
        updated_raw = rel.get('updated', '')
        updated = updated_raw[:19] if len(updated_raw) >= 19 else updated_raw
        print(f\"{rel.get('namespace','')}\t{rel.get('name','')}\t{rel.get('status','')}\t{chart}\t{updated}\t{rel.get('app_version','')}\")
" | while IFS=$'\t' read -r REL_NS REL_NAME REL_STATUS REL_CHART REL_UPDATED REL_APP_VER; do
    if [[ -z "$REL_NAME" ]]; then
      continue
    fi
    # Pad release label to align columns (longest konk release name ~50 chars)
    REL_LABEL=$(printf "%-55s" "${REL_NAME} (${REL_NS})")
    if [[ "$REL_STATUS" == "deployed" ]]; then
      pass "${REL_LABEL} —  deployed   — updated ${REL_UPDATED}"
    elif [[ "$REL_STATUS" == "failed" ]]; then
      fail "${REL_LABEL} —  FAILED    — last attempt ${REL_UPDATED}"
      HELM_RELEASE_ISSUES=$((HELM_RELEASE_ISSUES + 1))
    elif [[ "$REL_STATUS" == "pending-upgrade" || "$REL_STATUS" == "pending-install" ]]; then
      warn "${REL_LABEL} —  ${REL_STATUS} — stuck since ${REL_UPDATED}"
      HELM_RELEASE_ISSUES=$((HELM_RELEASE_ISSUES + 1))
    else
      warn "${REL_LABEL} —  ${REL_STATUS} — updated ${REL_UPDATED}"
      HELM_RELEASE_ISSUES=$((HELM_RELEASE_ISSUES + 1))
    fi
  done
done  # for HELM_NS
[[ "$HELM_RELEASE_ISSUES" -gt 0 ]] && vinfo "${HELM_RELEASE_ISSUES} release(s) not in 'deployed' state"
fi  # section 11

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 12: cert-manager CA integration
# ══════════════════════════════════════════════════════════════════════════════
section "cert-manager CA integration"
if should_run 12; then
# Check that CA Certificate resource exists and is Ready
# Certificate name may vary: bulk-konk-ca, bulk-konk-ca-cert, etc.
CA_CERT_STATUS=$(kc get certificate -n "$AGGREGATE_NAMESPACE" --no-headers \
  | grep -E "${KONK_CR_NAME}.*ca|ca.*${KONK_CR_NAME}" | head -1 || true)

if [[ -z "$CA_CERT_STATUS" ]]; then
  # Check if cert-manager CRDs exist at all
  if kubectl api-resources 2>/dev/null | grep -q "certificates.*cert-manager" 2>/dev/null; then
    warn "cert-manager is available but no CA Certificate found for ${KONK_CR_NAME} in ${AGGREGATE_NAMESPACE}"
  fi
else
  CA_CERT_NAME=$(echo "$CA_CERT_STATUS" | awk '{print $1}')
  CA_CERT_READY=$(echo "$CA_CERT_STATUS" | awk '{print $2}')
  if [[ "$CA_CERT_READY" == "True" ]]; then
    pass "cert-manager Certificate ${CA_CERT_NAME}: Ready=True"
  else
    fail "cert-manager Certificate ${CA_CERT_NAME}: Ready=${CA_CERT_READY:-Unknown}"
  fi

  # Check helm.sh/resource-policy: keep annotation (prevents accidental CA rotation)
  KEEP_POLICY=$(kc get certificate "$CA_CERT_NAME" -n "$AGGREGATE_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}')
  if [[ "$KEEP_POLICY" == "keep" ]]; then
    pass "CA Certificate has helm.sh/resource-policy=keep (rotation protection)"
  else
    warn "CA Certificate MISSING helm.sh/resource-policy=keep annotation (risk of accidental rotation)"
  fi
fi

# Check cert-manager Issuer
CA_ISSUER=$(kc get issuer -n "$AGGREGATE_NAMESPACE" --no-headers \
  | grep "${KONK_CR_NAME}" | head -1 || true)
if [[ -n "$CA_ISSUER" ]]; then
  ISSUER_READY=$(echo "$CA_ISSUER" | awk '{print $2}')
  ISSUER_NAME=$(echo "$CA_ISSUER" | awk '{print $1}')
  if [[ "$ISSUER_READY" == "True" ]]; then
    pass "cert-manager Issuer ${ISSUER_NAME}: Ready=True"
  else
    warn "cert-manager Issuer ${ISSUER_NAME}: Ready=${ISSUER_READY:-Unknown}"
  fi
else
  vinfo "no konk-related Issuer found (may use ClusterIssuer)"
fi

# Check all konk-service certificates across all namespaces for Ready=False
if kubectl api-resources 2>/dev/null | grep -q 'certificates.*cert-manager' 2>/dev/null; then
  ALL_KONK_CERTS=$(kubectl get certificate -A --no-headers 2>/dev/null \
    | grep 'konk-service' || true)
  CERT_NOT_READY=0
  CERT_READY_COUNT=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    cert_ns=$(echo "$line" | awk '{print $1}')
    cert_name=$(echo "$line" | awk '{print $2}')
    cert_ready=$(echo "$line" | awk '{print $3}')
    if [[ "$cert_ready" == "True" ]]; then
      ((CERT_READY_COUNT++)) || true
      vinfo "Certificate ${cert_ns}/${cert_name}: Ready=True"
    else
      fail "Certificate ${cert_ns}/${cert_name}: Ready=${cert_ready:-Unknown}"
      ((CERT_NOT_READY++)) || true
    fi
  done <<< "$ALL_KONK_CERTS"
  if [[ $CERT_NOT_READY -eq 0 && $CERT_READY_COUNT -gt 0 ]]; then
    pass "all ${CERT_READY_COUNT} konk-service Certificate(s) are Ready=True"
  elif [[ $CERT_READY_COUNT -eq 0 && $CERT_NOT_READY -eq 0 ]]; then
    vinfo "no konk-service certificates found in cluster"
  fi
fi
fi  # section 12

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 13: Konk API deep test — query actual resources via konk
# ══════════════════════════════════════════════════════════════════════════════
section "Konk API deep test (query resources inside konk)"
if should_run 13; then
if [[ "$SKIP_EXEC" == true ]]; then
  skip "konk API deep test (--skip-exec)"
else
  # Reuse $KONK_KUBECTL from section 7 if available, otherwise set up port-forward now
  if [[ -z "${KONK_KUBECTL:-}" ]]; then
    # Try to establish konk access (same logic as section 7)
    KUBECONFIG_SECRET=$(kc get secrets -A --no-headers \
      -l app.kubernetes.io/name=konk-service \
      --field-selector type=Opaque 2>/dev/null \
      | grep "konk-service-kubeconfig " | head -1 || true)
    if [[ -z "$KUBECONFIG_SECRET" ]]; then
      KUBECONFIG_SECRET=$(kc get secrets -A --no-headers 2>/dev/null \
        | grep "konk-service-kubeconfig " | grep -v "cert" | head -1 || true)
    fi
    if [[ -n "$KUBECONFIG_SECRET" ]]; then
      KC_SECRET_NS=$(echo "$KUBECONFIG_SECRET" | awk '{print $1}')
      KC_SECRET_NAME=$(echo "$KUBECONFIG_SECRET" | awk '{print $2}')
      KONK_TMPDIR=$(mktemp -d)
      kubectl get secret "$KC_SECRET_NAME" -n "$KC_SECRET_NS" -o "jsonpath={.data.tls\.crt}" 2>/dev/null | base64 -d > "$KONK_TMPDIR/tls.crt"
      kubectl get secret "$KC_SECRET_NAME" -n "$KC_SECRET_NS" -o "jsonpath={.data.tls\.key}" 2>/dev/null | base64 -d > "$KONK_TMPDIR/tls.key"

      if [[ -s "$KONK_TMPDIR/tls.crt" && -s "$KONK_TMPDIR/tls.key" ]]; then
        LOCAL_PORT=$(( (RANDOM % 10000) + 30000 ))
        kubectl port-forward "svc/${KONK_CR_NAME}" -n "$AGGREGATE_NAMESPACE" "${LOCAL_PORT}:6443" >/dev/null 2>&1 &
        KONK_PF_PID=$!
        disown "$KONK_PF_PID" 2>/dev/null
        # Wait for port-forward to be ready
        PF_READY=false
        for i in $(seq 1 10); do
          if ! kill -0 "$KONK_PF_PID" 2>/dev/null; then
            break
          fi
          if nc -z -w 1 localhost "$LOCAL_PORT" 2>/dev/null; then
            PF_READY=true
            break
          fi
          sleep 1
        done
        if [[ "$PF_READY" == "true" ]] && kill -0 "$KONK_PF_PID" 2>/dev/null; then
          cat > "$KONK_TMPDIR/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:${LOCAL_PORT}
  name: bulk-konk
contexts:
- context:
    cluster: bulk-konk
    user: kubernetes-admin
  name: bulk-konk
current-context: bulk-konk
users:
- name: kubernetes-admin
  user:
    client-certificate: ${KONK_TMPDIR}/tls.crt
    client-key: ${KONK_TMPDIR}/tls.key
EOF
          if kubectl --kubeconfig="$KONK_TMPDIR/kubeconfig" get --raw /healthz >/dev/null 2>&1; then
            KONK_KUBECTL="kubectl --kubeconfig=${KONK_TMPDIR}/kubeconfig"
          fi
        fi
      fi
    fi
  fi

  if [[ -z "${KONK_KUBECTL:-}" ]]; then
    warn "no konk API access available for deep test (no kubeconfig secret or port-forward failed)"
  else
    info "using konk API via port-forward for deep queries"

    # 12a. List api-resources in konk — verify bulk API groups are registered
    KONK_API_RESOURCES=$($KONK_KUBECTL api-resources --no-headers 2>/dev/null || true)

    if [[ -z "$KONK_API_RESOURCES" ]]; then
      fail "konk api-resources returned empty — konk connectivity issue"
    else
      # Check for expected API groups
      EXPECTED_GROUPS=("tagging.bulk.infoblox.com" "dnsconfig.bulk.infoblox.com" "dnsdata.bulk.infoblox.com")
      # Pre-fetch all APIService statuses from konk once for cross-referencing
      _ALL_APSVCS=$($KONK_KUBECTL get apiservices --no-headers 2>/dev/null || true)
      for grp in "${EXPECTED_GROUPS[@]}"; do
        if echo "$KONK_API_RESOURCES" | grep -q "$grp" 2>/dev/null; then
          pass "konk api-resources contains group: ${grp}"
        else
          # Check if the group is registered but FailedDiscovery vs truly absent
          _APISVC_ENTRY=$(echo "$_ALL_APSVCS" | grep "$grp" | head -1 || true)
          if [[ -n "$_APISVC_ENTRY" ]]; then
            _APISVC_STATE=$(echo "$_APISVC_ENTRY" | awk '{print $3, $4}')
            warn "konk api-resources missing group: ${grp} — registered but unavailable (${_APISVC_STATE})"
          else
            warn "konk api-resources missing group: ${grp} (service may not be deployed)"
          fi
        fi
      done
    fi

    # 12b. Query specific resources inside konk via the tagging API
    TAGGING_TAGS=$($KONK_KUBECTL get tags.tagging.bulk.infoblox.com --all-namespaces --no-headers 2>/dev/null || true)

    if [[ -n "$TAGGING_TAGS" ]]; then
      TAG_COUNT=$(echo "$TAGGING_TAGS" | wc -l | tr -d ' ')
      pass "konk: kubectl get tags returned ${TAG_COUNT} tag(s) from tagging API"
      if [[ "$VERBOSE" == true ]]; then
        echo "$TAGGING_TAGS" | head -5 | sed 's/^/         /'
        [[ $TAG_COUNT -gt 5 ]] && echo "         ... (${TAG_COUNT} total)"
      fi
    else
      TAG_TEST=$($KONK_KUBECTL get tags.tagging.bulk.infoblox.com --all-namespaces 2>&1 || true)
      if echo "$TAG_TEST" | grep -qi "No resources found\|^$" 2>/dev/null; then
        pass "konk: tagging API reachable (no tags exist — OK)"
      elif echo "$TAG_TEST" | grep -qi "x509\|tls\|connection refused\|unauthorized" 2>/dev/null; then
        fail "konk: tagging API returned error: $(echo "$TAG_TEST" | head -1)"
      else
        pass "konk: tagging API reachable (response: $(echo "$TAG_TEST" | head -1 | cut -c1-80))"
      fi
    fi

    # 12c. Query values from tagging API
    TAGGING_VALUES=$($KONK_KUBECTL get values.tagging.bulk.infoblox.com --all-namespaces --no-headers 2>/dev/null || true)
    if [[ -n "$TAGGING_VALUES" ]]; then
      VALUE_COUNT=$(echo "$TAGGING_VALUES" | wc -l | tr -d ' ')
      pass "konk: kubectl get values returned ${VALUE_COUNT} value(s) from tagging API"
    else
      TAG_VAL_TEST=$($KONK_KUBECTL get values.tagging.bulk.infoblox.com --all-namespaces 2>&1 || true)
      if echo "$TAG_VAL_TEST" | grep -qi "No resources found\|^$" 2>/dev/null; then
        pass "konk: tagging values API reachable (no values — OK)"
      elif echo "$TAG_VAL_TEST" | grep -qi "x509\|tls\|connection refused\|unauthorized" 2>/dev/null; then
        fail "konk: tagging values API error: $(echo "$TAG_VAL_TEST" | head -1)"
      else
        pass "konk: tagging values API reachable"
      fi
    fi

    # 12d. Test konk api-resources for specific resource types
    for res_type in "tags" "values" "records" "hosts"; do
      if echo "$KONK_API_RESOURCES" | awk '{print $1}' | grep -qw "$res_type" 2>/dev/null; then
        grp=$(echo "$KONK_API_RESOURCES" | awk -v r="$res_type" '$1==r {print $NF}' | head -1)
        pass "konk resource type '${res_type}' registered (group: ${grp})"
      else
        vinfo "konk resource type '${res_type}' not registered"
      fi
    done

    # 12e. Verify konk /healthz and /livez
    KONK_LIVEZ=$($KONK_KUBECTL get --raw /livez 2>/dev/null || true)
    if [[ "$KONK_LIVEZ" == "ok" ]]; then
      pass "konk apiserver /livez returns 'ok'"
    else
      warn "konk apiserver /livez returned: ${KONK_LIVEZ:-empty}"
    fi

    # 12f. In-cluster health check — not possible via port-forward (service DNS is cluster-internal)
    # This check is skipped when using port-forward mode; section 8 covers in-cluster connectivity.
    vinfo "in-cluster healthz skipped (using port-forward mode; see section 8 for in-cluster tests)"
  fi
fi
fi  # section 13

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 14: External API integration — tagging + bulk via CSP endpoint
# ══════════════════════════════════════════════════════════════════════════════
section "External API integration (tagging + bulk via CSP)"
if should_run 14; then

# Skip on production clusters (com-prod, gov-prd)
_ctx_14=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$_ctx_14" == *"-com-"* || "$_ctx_14" == *"-prd-"* ]]; then
  skip "production cluster detected (${_ctx_14}) — skipping external API tests"
else

# Auto-detect CSP URL from cluster context using CLUSTER_KEYS/CLUSTER_URLS
if [[ -z "$CSP_URL" ]]; then
  CLUSTER_CTX=$(kubectl config current-context 2>/dev/null || echo "")
  for i in "${!CLUSTER_KEYS[@]}"; do
    if [[ "$CLUSTER_CTX" == *"${CLUSTER_KEYS[$i]}"* ]]; then
      CSP_URL="${CLUSTER_URLS[$i]}"
      break
    fi
  done
fi

# Auto-fetch JWT from tagging-v2-k6-smoke-test-credentials if no token provided
if [[ -z "$CSP_TOKEN" ]]; then
  K6_SECRET="tagging-v2-k6-smoke-test-credentials"
  K6_NS="tagging-v2"
  if kubectl get secret "$K6_SECRET" -n "$K6_NS" &>/dev/null; then
    _k6_url=$(kubectl get secret "$K6_SECRET" -n "$K6_NS" -o jsonpath='{.data.BASE_URL}' 2>/dev/null | base64 -d)
    _k6_email=$(kubectl get secret "$K6_SECRET" -n "$K6_NS" -o jsonpath='{.data.USER_EMAIL}' 2>/dev/null | base64 -d)
    _k6_pass=$(kubectl get secret "$K6_SECRET" -n "$K6_NS" -o jsonpath='{.data.USER_PASSWORD}' 2>/dev/null | base64 -d)
    # Use secret's BASE_URL if no CSP_URL detected yet
    [[ -z "$CSP_URL" && -n "$_k6_url" ]] && CSP_URL="$_k6_url"
    info "auto-fetching CSP token via ${_k6_url:-$CSP_URL}/v2/session/users/sign_in (${_k6_email})"
    _login_resp=$(curl -s --connect-timeout 10 --max-time 20 \
      "${_k6_url:-$CSP_URL}/v2/session/users/sign_in" \
      -X POST -H "Content-Type: application/json" \
      -d "{\"email\":\"${_k6_email}\",\"password\":\"${_k6_pass}\"}" 2>/dev/null)
    CSP_TOKEN=$(echo "$_login_resp" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('jwt') or d.get('access_token') or d.get('token',''))" 2>/dev/null || echo "")
    if [[ -n "$CSP_TOKEN" ]]; then
      pass "auto-fetched CSP JWT from cluster secret (${K6_NS}/${K6_SECRET})"
    else
      skip "sign_in to ${_k6_url:-$CSP_URL} failed — skipping external API tests (use --token TOKEN or export KONK_E2E_TOKEN)"
    fi
  else
    skip "secret ${K6_NS}/${K6_SECRET} not found on this cluster — skipping external API tests (use --token TOKEN)"
  fi
fi

if [[ -n "$CSP_TOKEN" && -z "$CSP_URL" ]]; then
  warn "cannot determine CSP URL from cluster context — use --csp-url URL"
elif [[ -n "$CSP_TOKEN" && -n "$CSP_URL" ]]; then
  info "CSP URL: ${CSP_URL}"

  # 13a. Tagging API — list tags via REST
  info "testing tagging API via ${CSP_URL}/api/atlas-tagging/v2/tags ..."
  TAG_HTTP_CODE=$(curl -s -o /tmp/konk-e2e-tag-resp.json -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    "${CSP_URL}/api/atlas-tagging/v2/tags" \
    -H "Authorization: Bearer ${CSP_TOKEN}" \
    -H "Content-Type: application/json" \
    2>/dev/null || echo "000")
  dbg_curl "GET ${CSP_URL}/api/atlas-tagging/v2/tags → HTTP ${TAG_HTTP_CODE}" /tmp/konk-e2e-tag-resp.json

  if [[ "$TAG_HTTP_CODE" == "200" ]]; then
    TAG_RESULT_COUNT=$(cat /tmp/konk-e2e-tag-resp.json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('results',d.get('tags',[]))))" 2>/dev/null || echo "?")
    pass "tagging API GET /tags: HTTP 200 (${TAG_RESULT_COUNT} results)"
  elif [[ "$TAG_HTTP_CODE" == "401" ]]; then
    fail "tagging API GET /tags: HTTP 401 Unauthorized — token expired or invalid"
  elif [[ "$TAG_HTTP_CODE" == "000" ]]; then
    fail "tagging API GET /tags: connection failed to ${CSP_URL}"
  else
    warn "tagging API GET /tags: HTTP ${TAG_HTTP_CODE}"
    if [[ "$VERBOSE" == true ]]; then
      cat /tmp/konk-e2e-tag-resp.json 2>/dev/null | head -5 | sed 's/^/         /'
    fi
  fi

  # 13b. Tagging API — create a tag (POST) to validate write path through konk
  info "testing tagging API write path (create + delete tag) ..."
  TAG_KEY="konk-e2e-test-$(date +%s)"
  CREATE_HTTP_CODE=$(curl -s -o /tmp/konk-e2e-tag-create.json -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    "${CSP_URL}/api/atlas-tagging/v2/tags" \
    -X POST \
    -H "Authorization: Bearer ${CSP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"${TAG_KEY}\",\"type\":\"freeform\",\"values\":[{\"value\":\"e2e-test-val\"}]}" \
    2>/dev/null || echo "000")
  dbg_curl "POST ${CSP_URL}/api/atlas-tagging/v2/tags → HTTP ${CREATE_HTTP_CODE}" /tmp/konk-e2e-tag-create.json

  if [[ "$CREATE_HTTP_CODE" == "201" || "$CREATE_HTTP_CODE" == "200" ]]; then
    pass "tagging API POST /tags: HTTP ${CREATE_HTTP_CODE} — tag '${TAG_KEY}' created successfully"

    # Clean up — delete the test tag
    # The ID is like "atlas.tagging/tags/UUID" — extract just the UUID for the delete URL
    TAG_ID=$(cat /tmp/konk-e2e-tag-create.json 2>/dev/null \
      | python3 -c "import sys,json; tid=json.load(sys.stdin).get('result',{}).get('id',''); print(tid.split('/')[-1] if '/' in tid else tid)" 2>/dev/null || echo "")
    if [[ -n "$TAG_ID" ]]; then
      DEL_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 15 \
        "${CSP_URL}/api/atlas-tagging/v2/tags/${TAG_ID}" \
        -X DELETE \
        -H "Authorization: Bearer ${CSP_TOKEN}" \
        2>/dev/null || echo "000")
      if [[ "$DEL_CODE" == "200" || "$DEL_CODE" == "204" ]]; then
        pass "tagging API cleanup: test tag deleted (HTTP ${DEL_CODE})"
      else
        warn "tagging API cleanup: delete returned HTTP ${DEL_CODE} (tag '${TAG_KEY}' may remain)"
      fi
    else
      warn "could not extract tag ID for cleanup — test tag '${TAG_KEY}' may remain"
    fi
  elif [[ "$CREATE_HTTP_CODE" == "401" ]]; then
    fail "tagging API POST /tags: HTTP 401 Unauthorized — token expired"
  elif [[ "$CREATE_HTTP_CODE" == "409" ]]; then
    pass "tagging API POST /tags: HTTP 409 Conflict — tag already exists (API responding)"
  else
    warn "tagging API POST /tags: HTTP ${CREATE_HTTP_CODE}"
    if [[ "$VERBOSE" == true ]]; then
      cat /tmp/konk-e2e-tag-create.json 2>/dev/null | head -3 | sed 's/^/         /'
    fi
  fi

  # 13c. Bulk export API — trigger an export to verify bulk → konk → aggregate API path
  # The data path: CSP → bulk service → bulk-konk apiserver → tagging-aggregate-api → tagging backend
  info "testing bulk export API ..."
  EXPORT_HTTP_CODE=$(curl -s -D /tmp/konk-e2e-export-headers.txt \
    -o /tmp/konk-e2e-export-resp.json -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    "${CSP_URL}/bulk/v1/export" \
    -X POST \
    -H "Authorization: Bearer ${CSP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "tags": {},
      "name": "konk-e2e-export-'"$(date +%s)"'",
      "export_format": "json",
      "data_types": [
        "tagging.bulk.infoblox.com/v1alpha1/tags.v1alpha1.tagging.bulk.infoblox.com"
      ],
      "error_handling_id": 1
    }' \
    2>/dev/null || echo "000")
  dbg_curl "POST ${CSP_URL}/bulk/v1/export → HTTP ${EXPORT_HTTP_CODE}" /tmp/konk-e2e-export-resp.json

  EXPORT_OP_ID=""
  if [[ "$EXPORT_HTTP_CODE" == "200" || "$EXPORT_HTTP_CODE" == "201" || "$EXPORT_HTTP_CODE" == "202" ]]; then
    EXPORT_MSG=$(cat /tmp/konk-e2e-export-resp.json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',{}).get('message', d.get('id', json.dumps(d)[:60])))" 2>/dev/null || echo "accepted")
    # Extract operation ID from response header: x-http-location: operation/{id}
    EXPORT_OP_ID=$(grep -i 'x-http-location' /tmp/konk-e2e-export-headers.txt 2>/dev/null \
      | head -1 | sed 's/.*operation\///' | tr -d '[:space:]' || true)
    if [[ -n "$EXPORT_OP_ID" ]]; then
      pass "bulk export API: HTTP ${EXPORT_HTTP_CODE} (${EXPORT_MSG}) — operation ID: ${EXPORT_OP_ID}"
    else
      pass "bulk export API: HTTP ${EXPORT_HTTP_CODE} (${EXPORT_MSG})"
    fi
    info "export flow: CSP → bulk → bulk-konk → tagging-aggregate-api — WORKING"
  elif [[ "$EXPORT_HTTP_CODE" == "401" ]]; then
    fail "bulk export API: HTTP 401 Unauthorized — token expired"
  elif [[ "$EXPORT_HTTP_CODE" == "000" ]]; then
    fail "bulk export API: connection failed to ${CSP_URL}"
  else
    warn "bulk export API: HTTP ${EXPORT_HTTP_CODE}"
    if [[ "$VERBOSE" == true ]]; then
      cat /tmp/konk-e2e-export-resp.json 2>/dev/null | head -5 | sed 's/^/         /'
    fi
  fi

  # 13d. Bulk operation tracking — verify GET /operation/{id} returns status for the export we just created
  if [[ -n "$EXPORT_OP_ID" ]]; then
    info "testing bulk operation tracking (GET /operation/${EXPORT_OP_ID}) ..."
    OP_STATUS_CODE=$(curl -s -o /tmp/konk-e2e-op-status.json -w '%{http_code}' \
      --connect-timeout 10 --max-time 15 \
      "${CSP_URL}/bulk/v1/operation/${EXPORT_OP_ID}" \
      -H "Authorization: Bearer ${CSP_TOKEN}" \
      2>/dev/null || echo "000")
    dbg_curl "GET ${CSP_URL}/bulk/v1/operation/${EXPORT_OP_ID} → HTTP ${OP_STATUS_CODE}" /tmp/konk-e2e-op-status.json

    if [[ "$OP_STATUS_CODE" == "200" ]]; then
      OP_STATUS=$(cat /tmp/konk-e2e-op-status.json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result',d); print(r.get('overall_status','unknown'))" 2>/dev/null || echo "unknown")
      pass "bulk operation GET /operation/{id}: HTTP 200 (status: ${OP_STATUS})"
    elif [[ "$OP_STATUS_CODE" == "401" ]]; then
      fail "bulk operation GET /operation/{id}: HTTP 401 Unauthorized"
    else
      warn "bulk operation GET /operation/{id}: HTTP ${OP_STATUS_CODE}"
    fi
  else
    vinfo "skipping operation tracking — no operation ID from export"
  fi

  # 13e. Bulk operation list — verify GET /operation lists recent operations
  info "testing bulk operation list API (GET /operation) ..."
  OP_LIST_CODE=$(curl -s -o /tmp/konk-e2e-op-list.json -w '%{http_code}' \
    --connect-timeout 10 --max-time 15 \
    "${CSP_URL}/bulk/v1/operation?_limit=3" \
    -H "Authorization: Bearer ${CSP_TOKEN}" \
    2>/dev/null || echo "000")
  dbg_curl "GET ${CSP_URL}/bulk/v1/operation?_limit=3 → HTTP ${OP_LIST_CODE}" /tmp/konk-e2e-op-list.json

  if [[ "$OP_LIST_CODE" == "200" ]]; then
    OP_LIST_COUNT=$(cat /tmp/konk-e2e-op-list.json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('results',[])))" 2>/dev/null || echo "?")
    pass "bulk operation list: GET /operation HTTP 200 (${OP_LIST_COUNT} recent operation(s))"
  elif [[ "$OP_LIST_CODE" == "401" ]]; then
    fail "bulk operation list API: HTTP 401 Unauthorized"
  elif [[ "$OP_LIST_CODE" == "000" ]]; then
    fail "bulk operation list API: connection failed"
  else
    warn "bulk operation list API: HTTP ${OP_LIST_CODE}"
  fi

  # Cleanup temp files
  rm -f /tmp/konk-e2e-tag-resp.json /tmp/konk-e2e-tag-create.json \
        /tmp/konk-e2e-export-resp.json /tmp/konk-e2e-export-headers.txt \
        /tmp/konk-e2e-op-status.json /tmp/konk-e2e-op-list.json 2>/dev/null
fi
fi  # else (non-prod)
fi  # section 14

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 15: Konk APIService backend health
# ══════════════════════════════════════════════════════════════════════════════
# Checks ONLY the aggregate API server pods that are actual APIService backends —
# i.e. the pods backing each KonkService's spec.service.name.
# These are the pods whose notReady state causes 503s in konk's available_controller
# (gov-stg-2 cert expiry incident pattern).
#
# NOT checked here (covered by section 6): konk-service-managed pods
# (kubectl-apiservice, kubeconfig, apiservice-test).
section "Konk APIService backend health"
if should_run 15; then
  # Fetch all KonkService CRs once
  ALL_KSVC_15=$(kc get konkservice -A -o json 2>/dev/null)

  if [[ -z "$ALL_KSVC_15" ]] || [[ "$(echo "$ALL_KSVC_15" | jq '.items | length' 2>/dev/null)" == "0" ]]; then
    warn "no KonkService CRs found — skipping backend health check"
  else
    BACKEND_TOTAL=0
    BACKEND_NOT_READY=0
    BACKEND_MISSING_SVC=0

    # For each KonkService, find spec.service.name and check the pods behind it
    while IFS=$'\t' read -r ns name svc_name; do
      [[ -z "$ns" || -z "$name" ]] && continue

      # Fall back to CR name if spec.service.name is empty
      [[ -z "$svc_name" || "$svc_name" == "null" ]] && svc_name="$name"

      # Get endpoints for the backend service
      EP_JSON=$(kc get endpoints "$svc_name" -n "$ns" -o json 2>/dev/null || true)
      if [[ -z "$EP_JSON" ]]; then
        fail "KonkService ${ns}/${name}: backend service '${svc_name}' has no Endpoints object"
        ((BACKEND_MISSING_SVC++)) || true
        continue
      fi

      # Extract ready and not-ready pod names from endpoints
      READY_PODS=$(echo "$EP_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
names = []
for subset in data.get('subsets', []):
    for addr in subset.get('addresses', []):
        ref = addr.get('targetRef', {})
        if ref.get('kind') == 'Pod':
            names.append(ref.get('name', addr.get('ip', '?')))
print('\n'.join(names))
" 2>/dev/null || true)

      NOT_READY_PODS=$(echo "$EP_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
names = []
for subset in data.get('subsets', []):
    for addr in subset.get('notReadyAddresses', []):
        ref = addr.get('targetRef', {})
        if ref.get('kind') == 'Pod':
            names.append(ref.get('name', addr.get('ip', '?')))
print('\n'.join(names))
" 2>/dev/null || true)

      READY_COUNT=$(echo "$READY_PODS" | grep -c '[^[:space:]]' 2>/dev/null || true); READY_COUNT=${READY_COUNT:-0}
      NOT_READY_COUNT=$(echo "$NOT_READY_PODS" | grep -c '[^[:space:]]' 2>/dev/null || true); NOT_READY_COUNT=${NOT_READY_COUNT:-0}
      BACKEND_TOTAL=$((BACKEND_TOTAL + READY_COUNT + NOT_READY_COUNT))

      if [[ "$NOT_READY_COUNT" -gt 0 ]]; then
        fail "KonkService ${ns}/${name}: backend service '${svc_name}' has ${NOT_READY_COUNT} pod(s) in notReadyAddresses — konk will get 503 probing this APIService"
        echo "$NOT_READY_PODS" | grep -v '^$' | while IFS= read -r pod; do
          # Get pod status for context
          pod_status=$(kc get pod "$pod" -n "$ns" --no-headers 2>/dev/null | awk '{print $2, $3}' || true)
          warn "  not-ready: ${ns}/${pod} ${pod_status}"
        done
        ((BACKEND_NOT_READY++)) || true
      elif [[ "$READY_COUNT" -eq 0 ]]; then
        fail "KonkService ${ns}/${name}: backend service '${svc_name}' has NO ready endpoints — APIService backend completely down"
        ((BACKEND_NOT_READY++)) || true
      else
        vinfo "KonkService ${ns}/${name}: backend '${svc_name}' — ${READY_COUNT} ready pod(s)"
        pass "KonkService ${ns}/${name}: backend '${svc_name}' has ${READY_COUNT} ready pod(s)"
      fi
    done < <(echo "$ALL_KSVC_15" | jq -r '
      .items[] |
      [.metadata.namespace, .metadata.name, (.spec.service.name // "")] | @tsv')

    if [[ $BACKEND_NOT_READY -eq 0 && $BACKEND_MISSING_SVC -eq 0 ]]; then
      info "${BACKEND_TOTAL} backend pod(s) checked across all KonkService APIService endpoints"
    else
      info "${BACKEND_NOT_READY} KonkService(s) with not-ready backend pods — these cause 503s in konk's available_controller"
    fi
  fi
fi  # section 15

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 16: Stale node containers (Helm adopt/merge ghost detection)
# ══════════════════════════════════════════════════════════════════════════════
# ETCD-MIGRATION-SPECIFIC: remove after etcd migration is complete
# kindest/node) to the new chart (single "kubeconfig" container using konk-service),
# Helm's strategic merge on fresh install can leave ghost "kind" containers.
# These cause "permission denied" errors because the node container (running as root)
# writes to the shared emptyDir before the kubeconfig container (nonroot) tries to.
#
# NOTE: Only relevant for operator versions < j191. Operators >= j191 no longer
# have the old kind/node container in the chart, so this check can be skipped.
section "Stale node containers (Helm merge ghost detection)"
if should_run 16; then
  # Get operator image to check if this section is relevant
  OPERATOR_IMG_16=${OPERATOR_IMG:-$(kc get deploy konk-operator -n "$KONK_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)}
  # Extract Jenkins build number (e.g. v0.2.1-155-gd4614c2-j191 → 191)
  OPERATOR_JOB_NUM=$(echo "$OPERATOR_IMG_16" | grep -oE 'j[0-9]+' | tail -1 | tr -d 'j' || true)

  if [[ -n "$OPERATOR_JOB_NUM" && "$OPERATOR_JOB_NUM" -lt 191 ]] 2>/dev/null; then
    skip "operator < j191 — still uses kindest/node legitimately; ghost containers not possible"
  else
    NODE_PODS=$(kubectl get pods -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGES:.spec.containers[*].image,INIT-IMAGES:.spec.initContainers[*].image' 2>&1 | grep "/node:" || true)

    if [[ -z "$NODE_PODS" ]]; then
      pass "no pods running stale node container images"
    else
      NODE_POD_COUNT=$(echo "$NODE_PODS" | wc -l | tr -d ' ')
      fail "${NODE_POD_COUNT} pod(s) still have stale /node: container images (ghost from Helm adopt/merge)"
      echo "$NODE_PODS" | head -5 | while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        pod=$(echo "$line" | awk '{print $2}')
        warn "  ${ns}/${pod}"
      done
      if [[ $NODE_POD_COUNT -gt 5 ]]; then
        info "  ... and $((NODE_POD_COUNT - 5)) more"
      fi
      echo ""
      info "Fix: delete the Helm release secret + deployment, let the operator re-create cleanly:"
      info "  kubectl delete secret -n <ns> sh.helm.release.v1.<release>.v1"
      info "  kubectl delete deploy -n <ns> <deployment-name>"
    fi
  fi
fi  # section 16

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 17: Wrong konk-service image (ghcr.io/infobloxopen/konk-service)
# ══════════════════════════════════════════════════════════════════════════════
# ETCD-MIGRATION-SPECIFIC: remove after etcd migration is complete
# ETCD-MIGRATION-SPECIFIC: remove after etcd migration is complete
# The konk-service chart uses kindest/node:<K8S_RELEASE> (or harbor .../node:<K8S_RELEASE>)
# as the "kind" container image. After the distroless migration (j191+), the image
# changed to konk-service. On clusters still running older operator versions, the
# konk-service image is a ghost container left by Helm strategic merge — the pod
# should only have the node image.
section "Stale konk-service container image (ghost detection)"
if should_run 17; then
  # Get operator image to check if this section is relevant
  OPERATOR_IMG_17=${OPERATOR_IMG:-$(kc get deploy konk-operator -n "$KONK_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)}
  OPERATOR_JOB_NUM_17=$(echo "$OPERATOR_IMG_17" | grep -oE 'j[0-9]+' | tail -1 | tr -d 'j' || true)

  # Also detect post-migration via git-describe tags (v0.2.1-NNN-gXXX format)
  # These are GHCR-built images that don't use Jenkins j-numbers
  OPERATOR_GIT_DESC_17=$(echo "$OPERATOR_IMG_17" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' || true)

  if [[ -n "$OPERATOR_JOB_NUM_17" && "$OPERATOR_JOB_NUM_17" -ge 191 ]] 2>/dev/null; then
    skip "operator >= j191 — uses konk-service image legitimately; check not applicable"
  elif [[ -n "$OPERATOR_GIT_DESC_17" ]]; then
    skip "operator uses git-describe tag ($OPERATOR_GIT_DESC_17) — post-migration; check not applicable"
  else
    # On pre-j191 operators, pods should only have /node: image, NOT /konk-service: image
    # The /konk-service: container is a ghost from Helm strategic merge after chart change
    BAD_IMG_PODS=$(kubectl get pods -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGES:.spec.containers[*].image' --no-headers 2>/dev/null \
      | grep "konk-service-kubeconfig" | grep "/konk-service:" || true)

    if [[ -z "$BAD_IMG_PODS" ]]; then
      pass "no konk-service-kubeconfig pods with stale /konk-service: container image"
    else
      BAD_IMG_COUNT=$(echo "$BAD_IMG_PODS" | wc -l | tr -d ' ')
      fail "${BAD_IMG_COUNT} pod(s) have ghost konk-service container (Helm strategic merge leftover)"
      echo "$BAD_IMG_PODS" | head -10 | while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        pod=$(echo "$line" | awk '{print $2}')
        ready=$(echo "$line" | awk '{print $3}')
        warn "  ${ns}/${pod}  ready=${ready}"
      done
      if [[ $BAD_IMG_COUNT -gt 10 ]]; then
        info "  ... and $((BAD_IMG_COUNT - 10)) more"
      fi
      echo ""
      info "Expected: only /node:v1.25.8 container"
      info "Found:    ghost /konk-service:<operator-version> container from Helm merge"
      info "Fix: delete the deployment (operator will recreate with correct single container):"
      info "  kubectl delete deploy -n <ns> <deployment-name>"
    fi

    # Check for ghost konk-app container in apiserver pods (aggregate namespace)
    # Pre-j191: apiserver should use /kube-apiserver:v1.25.8, NOT /konk-app:
    BAD_APP_PODS=$(kubectl get pods -n "${AGGREGATE_NAMESPACE}" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGES:.spec.containers[*].image' --no-headers 2>/dev/null \
      | grep "/konk-app:" || true)

    if [[ -z "$BAD_APP_PODS" ]]; then
      pass "no pods with stale /konk-app: container image in ${AGGREGATE_NAMESPACE}"
    else
      BAD_APP_COUNT=$(echo "$BAD_APP_PODS" | wc -l | tr -d ' ')
      fail "${BAD_APP_COUNT} pod(s) have ghost /konk-app: image in ${AGGREGATE_NAMESPACE} (expected /kube-apiserver:v1.25.8)"
      echo "$BAD_APP_PODS" | head -5 | while IFS= read -r line; do
        pod=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        warn "  ${AGGREGATE_NAMESPACE}/${pod}  ready=${ready}"
      done
      echo ""
      info "Expected: /kube-apiserver:v1.25.8"
      info "Found:    ghost /konk-app:<operator-version> from Helm merge"
      info "Fix: kubectl delete deploy -n ${AGGREGATE_NAMESPACE} <deployment-name>"
    fi

    # Check for ghost konk-provision container in provision/init pods (aggregate namespace)
    # Pre-j191: provision should use /node:v1.25.8, NOT /konk-provision:
    BAD_PROV_PODS=$(kubectl get pods -n "${AGGREGATE_NAMESPACE}" -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGES:.spec.containers[*].image' --no-headers 2>/dev/null \
      | grep "/konk-provision:" || true)

    if [[ -z "$BAD_PROV_PODS" ]]; then
      pass "no pods with stale /konk-provision: container image in ${AGGREGATE_NAMESPACE}"
    else
      BAD_PROV_COUNT=$(echo "$BAD_PROV_PODS" | wc -l | tr -d ' ')
      fail "${BAD_PROV_COUNT} pod(s) have ghost /konk-provision: image in ${AGGREGATE_NAMESPACE} (expected /node:v1.25.8)"
      echo "$BAD_PROV_PODS" | head -5 | while IFS= read -r line; do
        pod=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        warn "  ${AGGREGATE_NAMESPACE}/${pod}  ready=${ready}"
      done
      echo ""
      info "Expected: /node:v1.25.8"
      info "Found:    ghost /konk-provision:<operator-version> from Helm merge"
      info "Fix: kubectl delete deploy -n ${AGGREGATE_NAMESPACE} <deployment-name>"
    fi
  fi
fi  # section 17

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 18: Stale KonkService deployments (old chart names)
# ══════════════════════════════════════════════════════════════════════════════
# These are live konk-service Deployments that are not present in the current
# Helm release manifests for their KonkService CRs. They commonly appear after
# chart resource names change (for example old *-kubectl-apiservice names). They
# should not be reported as current Helm ownership failures, but they are useful
# to list for cleanup because they can keep duplicate apiservice pods running.
section "Stale KonkService deployments (old chart names)"
if should_run 18; then
  ALL_KSVC_18=$(kc get konkservice -A -o json 2>/dev/null)
  ALL_DEPLOY_18=$(kc get deploy -A -l app.kubernetes.io/name=konk-service -o json 2>/dev/null)

  if [[ -z "$ALL_KSVC_18" ]] || [[ "$(echo "$ALL_KSVC_18" | jq '.items | length' 2>/dev/null)" == "0" ]]; then
    warn "no KonkService CRs found — cannot compare live deployments to Helm manifests"
  elif [[ -z "$ALL_DEPLOY_18" ]] || [[ "$(echo "$ALL_DEPLOY_18" | jq '.items | length' 2>/dev/null)" == "0" ]]; then
    pass "no konk-service Deployments found"
  else
    CURRENT_KSVC_DEPLOYMENTS=""
    while IFS=$'\t' read -r ns name; do
      [[ -z "$ns" || -z "$name" ]] && continue
      _release_deploys=$(helm_manifest_resource_refs "$name" "$ns" \
        | grep '^deployment\.apps/' \
        | sed "s#^deployment\.apps/#${ns}/#" || true)
      if [[ -n "$_release_deploys" ]]; then
        CURRENT_KSVC_DEPLOYMENTS+="$_release_deploys"$'\n'
      else
        # Helm manifest empty (release secret lost). Compute valid names from
        # the chart template naming convention to avoid false positives.
        _fullname="${name}-konk-service"
        _fullname="${_fullname:0:63}"; _fullname="${_fullname%-}"
        _fn52="${_fullname:0:52}"; _fn52="${_fn52%-}"
        _fn51="${_fullname:0:51}"; _fn51="${_fn51%-}"
        _fn46="${_fullname:0:46}"; _fn46="${_fn46%-}"
        CURRENT_KSVC_DEPLOYMENTS+="${ns}/${_fn52}-kubeconfig"$'\n'
        CURRENT_KSVC_DEPLOYMENTS+="${ns}/${_fn51}-apiservice"$'\n'
        CURRENT_KSVC_DEPLOYMENTS+="${ns}/${_fn46}-apiservice-test"$'\n'
      fi
    done < <(echo "$ALL_KSVC_18" | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' 2>/dev/null)
    CURRENT_KSVC_DEPLOYMENTS=$(echo "$CURRENT_KSVC_DEPLOYMENTS" | grep -v '^$' | sort -u || true)

    STALE_DEPLOYS=$(echo "$ALL_DEPLOY_18" | jq -r '
      .items[] |
      [
        .metadata.namespace,
        .metadata.name,
        (.metadata.labels["app.kubernetes.io/instance"] // "unknown"),
        (.metadata.labels["app.kubernetes.io/component"] // "unknown"),
        ((.spec.replicas // 0) | tostring),
        ((.status.availableReplicas // 0) | tostring),
        (.metadata.creationTimestamp // "unknown")
      ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r ns name inst component replicas available created; do
        [[ -z "$ns" || -z "$name" ]] && continue
        ref="${ns}/${name}"
        if [[ -z "$CURRENT_KSVC_DEPLOYMENTS" ]] || ! echo "$CURRENT_KSVC_DEPLOYMENTS" | grep -Fxq "$ref"; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ref" "$inst" "$component" "$replicas" "$available" "$created"
        fi
      done)

    if [[ -z "$STALE_DEPLOYS" ]]; then
      pass "no stale KonkService Deployments found outside current Helm manifests"
    else
      STALE_COUNT=$(echo "$STALE_DEPLOYS" | wc -l | tr -d ' ')
      warn "${STALE_COUNT} stale KonkService Deployment(s) found outside current Helm manifests"
      echo "$STALE_DEPLOYS" | while IFS=$'\t' read -r ref inst component replicas available created; do
        warn "  ${ref}  instance=${inst:-unknown} component=${component:-unknown} replicas=${replicas:-0} available=${available:-0} created=${created:-unknown}"
      done
      echo ""
      info "Cleanup after confirming the replacement *-konk-service-* Deployments are healthy:"
      info "  kubectl delete deploy -n <namespace> <stale-deployment-name>"
      echo ""
      _current_ctx=$(kubectl config current-context 2>/dev/null || echo '<your-context>')
      info "Or use the automated cleanup script (dry-run first, then --apply to delete):"
      info "  /Users/rsatal/Documents/Issues/konk/scripts/cleanup-stale-konkservice-deployments.sh --context ${_current_ctx}"
      info "  /Users/rsatal/Documents/Issues/konk/scripts/cleanup-stale-konkservice-deployments.sh --context ${_current_ctx} --apply"
    fi
  fi
fi  # section 18

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 19: Excluded bulk-konk resources (not Helm-managed)
# ══════════════════════════════════════════════════════════════════════════════
# Section 4 checks Helm ownership only for resources present in the live
# bulk-konk Helm manifest. This section lists same-name resources that were
# excluded from that ownership check because Helm does not currently manage them.
section "Excluded bulk-konk resources (not Helm-managed)"
if should_run 19; then
  BULK_HELM_RES=$(helm_manifest_resource_refs "$KONK_CR_NAME" "$AGGREGATE_NAMESPACE" || true)
  BULK_LIVE_RES_JSON=$(kc get svc,deploy,sts,secret,sa -n "$AGGREGATE_NAMESPACE" -o json 2>/dev/null)

  if [[ -z "$BULK_LIVE_RES_JSON" ]]; then
    warn "could not fetch bulk-konk candidate resources from ${AGGREGATE_NAMESPACE}"
  else
    EXCLUDED_BULK_RES=$(echo "$BULK_LIVE_RES_JSON" | jq -r --arg prefix "$KONK_CR_NAME" '
      .items[]
      | select(.metadata.name | contains($prefix))
      | select(.kind != "Secret" or (.metadata.name | startswith("sh.helm.release.v1.") | not))
      | [
          .kind,
          .metadata.name,
          (.metadata.annotations["meta.helm.sh/release-name"] // "MISSING"),
          (.metadata.annotations["meta.helm.sh/release-namespace"] // "MISSING"),
          (((.metadata.ownerReferences // []) | map(.kind + ":" + .name) | join(",")) as $owners | if $owners == "" then "none" else $owners end),
          (.metadata.creationTimestamp // "unknown")
        ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r kind name ann_rel ann_ns owners created; do
        [[ -z "$kind" || -z "$name" ]] && continue
        if [[ "$kind" == "Service" ]]; then
          ref="service/${name}"
        elif [[ "$kind" == "Deployment" ]]; then
          ref="deployment.apps/${name}"
        elif [[ "$kind" == "StatefulSet" ]]; then
          ref="statefulset.apps/${name}"
        elif [[ "$kind" == "Secret" ]]; then
          ref="secret/${name}"
        elif [[ "$kind" == "ServiceAccount" ]]; then
          ref="serviceaccount/${name}"
        else
          ref="${kind}/${name}"
        fi
        if [[ -z "$BULK_HELM_RES" ]] || ! echo "$BULK_HELM_RES" | grep -Fxq "$ref"; then
          printf '%s\t%s\t%s\t%s\t%s\n' "$ref" "$ann_rel" "$ann_ns" "${owners:-none}" "$created"
        fi
      done)

    if [[ -z "$EXCLUDED_BULK_RES" ]]; then
      pass "no bulk-konk candidate resources were excluded from the Helm ownership check"
    else
      EXCLUDED_COUNT=$(echo "$EXCLUDED_BULK_RES" | wc -l | tr -d ' ')
      warn "${EXCLUDED_COUNT} bulk-konk resource(s) excluded from Helm ownership check because they are not in helm get manifest"
      echo "$EXCLUDED_BULK_RES" | while IFS=$'\t' read -r ref ann_rel ann_ns owners created; do
        warn "  ${ref}  annotations=${ann_rel}/${ann_ns} ownerRefs=${owners:-none} created=${created:-unknown}"
      done
      echo ""
      info "Reason: Helm import/adoption only checks resources rendered in the release manifest."
      info "These resources are generated by controllers or runtime jobs, so missing meta.helm.sh annotations here is informational, not a Helm ownership failure."
    fi
  fi
fi  # section 19

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}================================================================${RESET}"
echo -e "${BOLD} Results${RESET}"
echo -e "${BOLD}================================================================${RESET}"
echo -e "  ${GREEN}Passed:   ${PASS}${RESET}"
echo -e "  ${RED}Failed:   ${FAIL}${RESET}"
echo -e "  ${YELLOW}Warnings: ${WARN}${RESET}"
echo -e "  ${DIM}Skipped:  ${SKIP}${RESET}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}${BOLD}END-TO-END VALIDATION FAILED${RESET} — ${FAIL} check(s) failed. Review failures above."
  echo ""
  echo -e "Suggested next steps:"
  echo -e "  1. For x509/CA issues:  ./rahul/scripts/check-konk-ca.sh --fix --restart"
  echo -e "  2. For failing pods:    kubectl get pods -A | grep -v '1/1\|Completed'"
  echo -e "  3. For KonkService CRs: kubectl get konkservice -A"
  echo ""
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}END-TO-END VALIDATION PASSED WITH WARNINGS${RESET} — review warnings above."
  echo ""
  exit 0
else
  echo -e "${GREEN}${BOLD}END-TO-END VALIDATION PASSED${RESET} — all checks green."
  echo ""
  exit 0
fi