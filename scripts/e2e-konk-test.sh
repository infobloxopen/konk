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
#   3.  Konk CR status
#   4.  KonkService CR statuses (all namespaces)
#   5.  konk-service pods health (all namespaces)
#   6.  CA trust chain (bulk-konk CA vs kubeconfig secrets)
#   7.  APIServices inside konk (queried from a kubectl-apiservice pod)
#   8.  Deep test: sample namespace (default: tagging-v2)
#   9.  Bulk (atlas.bulk) integration with konk
#   10. konk-operator log health
#   11. cert-manager CA integration
#   12. Konk API deep test — query resources in konk (tagging, dnsconfig, etc.)
#   13. External API integration — test tagging + bulk export/import via CSP endpoint
#
# Usage:
#   ./e2e-konk-test.sh                        # full run (sample ns = tagging-v2)
#   ./e2e-konk-test.sh --section 10           # run ONLY section 10
#   ./e2e-konk-test.sh --section 12 --section 13  # run sections 12 and 13
#   ./e2e-konk-test.sh --sample-ns atcapi     # use different sample namespace
#   ./e2e-konk-test.sh --skip-bulk            # skip bulk integration test
#   ./e2e-konk-test.sh --skip-exec            # skip kubectl exec tests (read-only)
#   ./e2e-konk-test.sh --skip-ca              # skip CA chain validation
#   ./e2e-konk-test.sh --skip-trigger-registration # section 7: skip default registration trigger test
#   ./e2e-konk-test.sh -v                     # verbose (show all passing details)
#   ./e2e-konk-test.sh -d                     # debug (show commands + full output)
#   ./e2e-konk-test.sh --csp-url URL --token TOKEN  # for section 13 (external API)
#
# Environment variables:
#   KONK_E2E_TOKEN   — Bearer token for CSP API calls (section 13). Avoids --token flag.
#   KONK_E2E_CSP_URL — CSP base URL (default: auto-detected from cluster name).
#
# Requirements: kubectl, openssl, curl (for section 13), jq (optional)

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
VERBOSE=false
DEBUG=false
RUN_SECTIONS=()          # empty = run all
CSP_URL="${KONK_E2E_CSP_URL:-}"
CSP_TOKEN="${KONK_E2E_TOKEN:-}"
TOKEN_FILE="$(cd "$(dirname "$0")" && pwd)/token-file.txt"

# ── Cluster-to-CSP endpoint mapping ──────────────────────────────────────────
# Maps kubectl context substrings to their CSP base URLs.
# Add new clusters here — keep CLUSTER_KEYS and CLUSTER_URLS in sync.
CLUSTER_KEYS=(  "us-stg-1"  "us-dev-2"  "us-dev-5" )
CLUSTER_URLS=(
  "https://stage.csp.infoblox.com"
  "https://csp.us-dev-2.eng.test.infoblox.com"
  "https://csp.us-dev-5.eng.test.infoblox.com"
)

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --section)     RUN_SECTIONS+=("$2"); shift 2 ;;
    --sample-ns)   SAMPLE_NS="$2"; shift 2 ;;
    --skip-bulk)   SKIP_BULK=true; shift ;;
    --skip-exec)   SKIP_EXEC=true; shift ;;
    --skip-ca)     SKIP_CA=true;   shift ;;
    --skip-trigger-registration) TRIGGER_REGISTRATION=false; shift ;;
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
echo -e "  Date:         $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
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
fi  # section 2

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 3: Konk CR status
# ══════════════════════════════════════════════════════════════════════════════
section "Konk CR status (${KONK_CR_NAME})"
if should_run 3; then
KONK_CR_REASON=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}')
if [[ -z "$KONK_CR_REASON" ]]; then
  fail "Konk CR '${KONK_CR_NAME}' not found or has no Deployed condition"
else
  assert_contains "Konk CR deployed reason" "$KONK_CR_REASON" "Successful"
fi

KONK_CR_STATUS=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}')
assert_equals "Konk CR Deployed=True" "${KONK_CR_STATUS:-False}" "True"

KONK_CR_SCOPE=$(kc get konk "$KONK_CR_NAME" -n "$AGGREGATE_NAMESPACE" \
  -o jsonpath='{.spec.scope}')
vinfo "Konk scope: ${KONK_CR_SCOPE:-default}"
fi  # section 3

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 4: KonkService CR statuses
# ══════════════════════════════════════════════════════════════════════════════
section "KonkService CRs (all namespaces)"
if should_run 4; then
ALL_KSVC=$(kc get konkservice -A --no-headers | awk '{print $1, $2}')
KSVC_TOTAL=0
KSVC_OK=0
KSVC_FAIL=0

if [[ -z "$ALL_KSVC" ]]; then
  fail "No KonkService CRs found in cluster"
else
  while read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    ((KSVC_TOTAL++)) || true
    reason=$(kc get konkservice "$name" -n "$ns" \
      -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}')
    if echo "$reason" | grep -q "Successful" 2>/dev/null; then
      ((KSVC_OK++)) || true
      vinfo "KonkService ${ns}/${name}: ${reason}"
    else
      fail "KonkService ${ns}/${name}: status='${reason:-UNKNOWN}'"
      ((KSVC_FAIL++)) || true
    fi
  done <<< "$ALL_KSVC"

  if [[ $KSVC_FAIL -eq 0 ]]; then
    pass "all ${KSVC_TOTAL} KonkService CRs report Successful"
  else
    info "${KSVC_OK}/${KSVC_TOTAL} KonkService CRs ok, ${KSVC_FAIL} failing"
  fi
fi
fi  # section 4

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 5: konk-service pods health (all namespaces)
# ══════════════════════════════════════════════════════════════════════════════
section "konk-service pods health (all namespaces)"
if should_run 5; then

# --- kubectl-apiservice pods ---
APISERVICE_PODS=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice \
  | grep -v "Completed" || true)
APISERVICE_TOTAL=0
APISERVICE_BAD=0

if [[ -z "$APISERVICE_PODS" ]]; then
  # Fallback: search by name pattern (some clusters may not have labels)
  APISERVICE_PODS=$(kc get pods -A --no-headers | grep "konk-service-kubectl-apiservice" \
    | grep -v "Completed" || true)
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
    if [[ "$ready" == "1/1" && "$status" == "Running" ]]; then
      vinfo "kubectl-apiservice ${ns}/${pod}: ${ready} ${status}"
    else
      fail "kubectl-apiservice ${ns}/${pod}: ${ready} ${status}"
      ((APISERVICE_BAD++)) || true
    fi
  done <<< "$APISERVICE_PODS"

  if [[ $APISERVICE_BAD -eq 0 ]]; then
    pass "all ${APISERVICE_TOTAL} kubectl-apiservice pods are 1/1 Running"
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
    if [[ "$ready" == "1/1" && "$status" == "Running" ]]; then
      vinfo "kubeconfig ${ns}/${pod}: ${ready} ${status}"
    else
      fail "kubeconfig ${ns}/${pod}: ${ready} ${status}"
      ((KUBECONFIG_BAD++)) || true
    fi
  done <<< "$KUBECONFIG_PODS"

  if [[ $KUBECONFIG_BAD -eq 0 ]]; then
    pass "all ${KUBECONFIG_TOTAL} kubeconfig (reconcile) pods are 1/1 Running"
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
fi  # section 5

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 6: CA trust chain validation
# ══════════════════════════════════════════════════════════════════════════════
section "CA trust chain (bulk-konk CA vs kubeconfig secrets)"
if should_run 6; then
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

    # Check kubeconfig admin certs expiry (short-lived ~12h, ensure not expired)
    KC_EXPIRED=0
    while read -r ns secret; do
      [[ -z "$ns" || -z "$secret" ]] && continue

      admin_b64=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}')
      [[ -z "$admin_b64" ]] && continue

      if ! echo "$admin_b64" | base64 -d | openssl x509 -noout -checkend 0 &>/dev/null; then
        warn "admin cert EXPIRED: ${ns}/${secret}"
        ((KC_EXPIRED++)) || true
      fi
    done <<< "$KC_SECRETS"

    if [[ $KC_EXPIRED -eq 0 ]]; then
      pass "all kubeconfig admin certs are within validity period"
    fi
  fi
fi
fi  # section 6

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 7: APIServices inside konk (with detailed enumeration & error analysis)
# ══════════════════════════════════════════════════════════════════════════════
section "APIServices registered in konk"
if should_run 7; then
if [[ "$SKIP_EXEC" == true ]]; then
  skip "APIService checks via exec (--skip-exec)"
else
  # 7.0: Find a healthy kubectl-apiservice pod to exec into
  #      This is cluster-agnostic and progressively searches multiple patterns
  EXEC_POD=""
  EXEC_NS=""
  
  # Try 1: Label-based discovery (most reliable)
  EXEC_CANDIDATES=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice \
    2>/dev/null | grep "1/1" | grep "Running" || true)

  # Try 2: Name pattern fallback (if labels not present on some clusters)
  if [[ -z "$EXEC_CANDIDATES" ]]; then
    EXEC_CANDIDATES=$(kc get pods -A --no-headers 2>/dev/null \
      | grep "konk-service-kubectl-apiservice" | grep "1/1" | grep "Running" || true)
  fi

  # Try 3: Any pod with "apiservice" in name (final fallback)
  if [[ -z "$EXEC_CANDIDATES" ]]; then
    EXEC_CANDIDATES=$(kc get pods -A --no-headers 2>/dev/null \
      | grep -i "apiservice" | grep "1/1" | grep "Running" || true)
  fi

  if [[ -n "$EXEC_CANDIDATES" ]]; then
    # Prefer sample namespace pods first, then test each candidate for kubectl availability.
    ORDERED_CANDIDATES=$( {
      echo "$EXEC_CANDIDATES" | grep "^${SAMPLE_NS}" || true
      echo "$EXEC_CANDIDATES" | grep -v "^${SAMPLE_NS}" || true
    } )

    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      cand_ns=$(echo "$candidate" | awk '{print $1}')
      cand_pod=$(echo "$candidate" | awk '{print $2}')

      if kubectl exec -n "$cand_ns" "$cand_pod" -- kubectl version --client >/dev/null 2>&1; then
        EXEC_NS="$cand_ns"
        EXEC_POD="$cand_pod"
        break
      fi
    done <<< "$ORDERED_CANDIDATES"
  fi

  if [[ -z "$EXEC_POD" ]]; then
    warn "no healthy kubectl-apiservice pod with kubectl binary available for konk API queries"
    info "To find a suitable pod: kubectl get pods -A | grep 'konk-service-kubectl-apiservice' | grep '1/1'"
    info "Pod images can vary by cluster; check that at least one selected pod contains kubectl"
  else
    info "using pod ${EXEC_NS}/${EXEC_POD} for konk API queries"

    # 7.1: List all APIServices in konk (non-Local ones)
    # Capture both stdout and stderr to detect and report connection errors
    if [[ "$DEBUG" == true ]]; then
      info "command: kubectl exec -n ${EXEC_NS} ${EXEC_POD} -- kubectl get apiservices -o wide --no-headers"
    fi
    APISERVICES_OUT=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
      kubectl get apiservices -o wide --no-headers 2>&1 || true)
    APISERVICES_RAW=$(echo "$APISERVICES_OUT" | grep -v "^error:" | grep -v "Local" || true)
    APISERVICES_ERRORS=$(echo "$APISERVICES_OUT" | grep "^error:" || true)

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
      info "command: kubectl exec -n ${EXEC_NS} ${EXEC_POD} -- kubectl api-resources --no-headers"
    fi
    API_RESOURCES_OUT=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
      kubectl api-resources --no-headers 2>&1 || true)
    API_RESOURCES_ERRORS=$(echo "$API_RESOURCES_OUT" | grep "^error:" || true)

    if [[ -n "$API_RESOURCES_ERRORS" ]]; then
      warn "errors while querying api-resources from konk:"
      echo "$API_RESOURCES_ERRORS" | sed 's/^/       /'
    fi

    # 7.3: Check api-versions are reachable (bulk APIs only)
    if [[ "$DEBUG" == true ]]; then
      info "command: kubectl exec -n ${EXEC_NS} ${EXEC_POD} -- kubectl api-versions"
    fi
    API_VERSIONS=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
      kubectl api-versions 2>/dev/null || true)
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

      TARGET_NS="$EXEC_NS"
      TARGET_POD="$EXEC_POD"

      RS_NAME=$(kc get pod "$TARGET_POD" -n "$TARGET_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
      DEPLOY_NAME=""
      if [[ -n "$RS_NAME" ]]; then
        DEPLOY_NAME=$(kc get rs "$RS_NAME" -n "$TARGET_NS" -o jsonpath='{.metadata.ownerReferences[0].name}')
      fi

      if [[ -z "$DEPLOY_NAME" ]]; then
        warn "unable to determine deployment owner for ${TARGET_NS}/${TARGET_POD}; skipping trigger test"
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
                warn "trigger executed but no recent APIService apply logs found in ${TARGET_NS}/${NEW_POD}"
              fi
            fi
          else
            fail "trigger reconcile failed: deployment/${DEPLOY_NAME} did not become ready within timeout"
          fi
        else
          fail "failed to delete pod ${TARGET_NS}/${TARGET_POD} for trigger test"
        fi
      fi
    fi
  fi
fi
fi  # section 7

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 8: Deep test — sample namespace
# ══════════════════════════════════════════════════════════════════════════════
section "Deep test: ${SAMPLE_NS} namespace"
if should_run 8; then
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
  SAMPLE_APIPOD=$(kc get pods -n "$SAMPLE_NS" --no-headers \
    | grep "konk-service-kubectl-apiservice" | grep "Running" | head -1 || true)
fi

SAMPLE_APIPOD_NAME=$(echo "$SAMPLE_APIPOD" | awk '{print $1}')
SAMPLE_APIPOD_READY=$(echo "$SAMPLE_APIPOD" | awk '{print $2}')
SAMPLE_APIPOD_STATUS=$(echo "$SAMPLE_APIPOD" | awk '{print $3}')

if [[ -z "$SAMPLE_APIPOD_NAME" ]]; then
  fail "no kubectl-apiservice pod found running in ${SAMPLE_NS}"
else
  assert_equals "${SAMPLE_NS} kubectl-apiservice pod ready" "$SAMPLE_APIPOD_READY" "1/1"

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

# 8d. RBAC — kubeconfig Role has 'update' verb (issue #23 regression check)
SAMPLE_ROLE="$(kc get roles -n "$SAMPLE_NS" --no-headers \
  | awk '$1 ~ /konk-service-kubeconfig/ {print $1; exit}' || true)"
if [[ -n "$SAMPLE_ROLE" ]]; then
  ROLE_VERBS=$(kc get role "$SAMPLE_ROLE" -n "$SAMPLE_NS" -o json \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for rule in data.get('rules', []):
    if 'secrets' in rule.get('resources', []):
        print(' '.join(rule.get('verbs', [])))
        break
" 2>/dev/null || echo "")
  if echo "$ROLE_VERBS" | grep -q "update" 2>/dev/null; then
    pass "${SAMPLE_NS} kubeconfig Role has 'update' verb on secrets"
  else
    fail "${SAMPLE_NS} kubeconfig Role MISSING 'update' verb on secrets (issue #23)"
    vinfo "current verbs: ${ROLE_VERBS}"
  fi
else
  warn "kubeconfig Role not found in ${SAMPLE_NS}"
fi

# 8e. Exec into pod — check reconciliation is working (no x509 errors in logs)
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

# 8f. Verify konk connectivity from the sample namespace
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

  if [[ -n "${EXEC_POD:-}" && -n "$SAMPLE_GROUP" && -n "$SAMPLE_VERSION" ]]; then
    EXPECTED_APISVC="${SAMPLE_VERSION}.${SAMPLE_GROUP}"
    APISVC_STATUS=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" -- \
      kubectl get apiservice "${EXPECTED_APISVC}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
      2>&1 || echo "")
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

# 8g. TLS server secret — verify the konk-service server TLS secret exists
SAMPLE_TLS_SECRET=$(kc get secrets -n "$SAMPLE_NS" --no-headers \
  | grep 'konk-service-server[[:space:]]' | awk '{print $1}' | head -1)
if [[ -n "$SAMPLE_TLS_SECRET" ]]; then
  # Check it has tls.crt and tls.key keys
  TLS_KEYS=$(kc get secret "$SAMPLE_TLS_SECRET" -n "$SAMPLE_NS" \
    -o jsonpath='{.data}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(sorted(d.keys())))" 2>/dev/null || echo "")
  if echo "$TLS_KEYS" | grep -q "tls.crt" 2>/dev/null && echo "$TLS_KEYS" | grep -q "tls.key" 2>/dev/null; then
    pass "${SAMPLE_NS} TLS server secret '${SAMPLE_TLS_SECRET}': has tls.crt + tls.key"
  else
    warn "${SAMPLE_NS} TLS server secret '${SAMPLE_TLS_SECRET}': missing expected keys (got: ${TLS_KEYS})"
  fi
else
  warn "TLS server secret not found in ${SAMPLE_NS} (expected *-konk-service-server)"
fi

# 8h. Pod events on failure — show describe + logs when pod is unhealthy
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
fi  # section 8

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 9: Bulk (atlas.bulk) integration
# ══════════════════════════════════════════════════════════════════════════════
section "Bulk (atlas.bulk) integration with konk"
if should_run 9; then
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

      # 9c. Test bulk → konk connectivity
      # bulk communicates with bulk-konk via bulk-konk.aggregate.svc:6443
      # We check if the bulk pod can resolve and reach the konk service
      if [[ "$SKIP_EXEC" != true ]]; then
        BULK_CONTAINER=$(kc get pod "$BULK_POD_NAME" -n "$AGGREGATE_NAMESPACE" \
          -o jsonpath='{.spec.containers[*].name}' \
          | tr ' ' '\n' | grep -v linkerd | head -1)
        BULK_CONTAINER_FLAG=""
        if [[ -n "$BULK_CONTAINER" ]]; then
          BULK_CONTAINER_FLAG="-c $BULK_CONTAINER"
        fi

        # Try to run a connectivity check from bulk pod with wget.
        BULK_WGET_OUT=$(kubectl exec -n "$AGGREGATE_NAMESPACE" "$BULK_POD_NAME" -- \
          wget -q -O- --timeout=5 "https://bulk-konk.aggregate.svc:6443/healthz" \
          --no-check-certificate 2>&1 || true)
        BULK_WGET_MISSING=false
        if echo "$BULK_WGET_OUT" | grep -qi "executable file not found" 2>/dev/null; then
          BULK_WGET_MISSING=true
        fi

        BULK_KONK_CHECK="$BULK_WGET_OUT"
        BULK_CURL_MISSING=false
        if [[ -z "$BULK_KONK_CHECK" || "$BULK_WGET_MISSING" == true ]]; then
          # Try curl as fallback when wget is unavailable or returns no output.
          BULK_CURL_OUT=$(kubectl exec -n "$AGGREGATE_NAMESPACE" "$BULK_POD_NAME" -- \
            curl -sk --connect-timeout 5 "https://bulk-konk.aggregate.svc:6443/healthz" 2>&1 || true)
          if echo "$BULK_CURL_OUT" | grep -qi "executable file not found" 2>/dev/null; then
            BULK_CURL_MISSING=true
          fi
          BULK_KONK_CHECK="$BULK_CURL_OUT"
        fi

        if [[ "$BULK_KONK_CHECK" == "ok" ]]; then
          pass "bulk pod can reach bulk-konk healthz endpoint"
        elif [[ "$BULK_WGET_MISSING" == true && "$BULK_CURL_MISSING" == true ]]; then
          skip "bulk→konk healthz check skipped (wget/curl not present in bulk image)"
        elif [[ -n "$BULK_KONK_CHECK" ]]; then
          # Got some response (might be auth error but connectivity works)
          pass "bulk pod has network connectivity to bulk-konk (response: ${BULK_KONK_CHECK:0:50})"
        else
          warn "bulk pod could not reach bulk-konk healthz"
        fi
      fi
    fi
  fi

  # 9d. bulk-konk /healthz check from an apiservice pod
  # Refresh EXEC_POD if section 7 deleted/restarted the previously selected pod.
  if [[ "$SKIP_EXEC" != true ]]; then
    if [[ -n "${EXEC_POD:-}" ]] && ! kubectl get pod -n "${EXEC_NS:-}" "$EXEC_POD" >/dev/null 2>&1; then
      EXEC_POD=""
      EXEC_NS=""
    fi

    if [[ -z "${EXEC_POD:-}" ]]; then
      EXEC_CANDIDATES=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice \
        | grep "1/1" | grep "Running" || true)
      if [[ -z "$EXEC_CANDIDATES" ]]; then
        EXEC_CANDIDATES=$(kc get pods -A --no-headers \
          | grep "konk-service-kubectl-apiservice" | grep "1/1" | grep "Running" || true)
      fi

      if [[ -n "$EXEC_CANDIDATES" ]]; then
        ORDERED_CANDIDATES=$( {
          echo "$EXEC_CANDIDATES" | grep "^${SAMPLE_NS}" || true
          echo "$EXEC_CANDIDATES" | grep -v "^${SAMPLE_NS}" || true
        } )

        while IFS= read -r candidate; do
          [[ -z "$candidate" ]] && continue
          cand_ns=$(echo "$candidate" | awk '{print $1}')
          cand_pod=$(echo "$candidate" | awk '{print $2}')
          if kubectl exec -n "$cand_ns" "$cand_pod" -- kubectl version --client >/dev/null 2>&1; then
            EXEC_NS="$cand_ns"
            EXEC_POD="$cand_pod"
            break
          fi
        done <<< "$ORDERED_CANDIDATES"
      fi
    fi
  fi

  # We can check if konk apiserver responds to direct API calls
  if [[ "$SKIP_EXEC" != true && -n "${EXEC_POD:-}" ]]; then
    KONK_HEALTHZ=$(kubectl exec -n "${EXEC_NS:-}" "$EXEC_POD" -- \
      kubectl get --raw /healthz 2>/dev/null || true)
    if [[ "$KONK_HEALTHZ" == "ok" ]]; then
      pass "konk apiserver /healthz returns 'ok'"
    elif [[ -n "$KONK_HEALTHZ" ]]; then
      warn "konk apiserver /healthz returned: ${KONK_HEALTHZ:0:50}"
    else
      KONK_APISVC_AVAIL=$(kc get apiservices --no-headers 2>/dev/null \
        | grep 'bulk.infoblox.com' | awk '$3=="True" {c++} END {print c+0}' || true)
      KONK_APISVC_AVAIL=${KONK_APISVC_AVAIL:-0}
      if [[ "$KONK_APISVC_AVAIL" -gt 0 ]] 2>/dev/null; then
        pass "konk health inferred from APIService availability (${KONK_APISVC_AVAIL} bulk APIService(s) Available=True)"
      else
        warn "could not check konk /healthz and no Available=True bulk APIServices found"
      fi
    fi
  elif [[ "$SKIP_EXEC" != true ]]; then
    KONK_APISVC_AVAIL=$(kc get apiservices --no-headers 2>/dev/null \
      | grep 'bulk.infoblox.com' | awk '$3=="True" {c++} END {print c+0}' || true)
    KONK_APISVC_AVAIL=${KONK_APISVC_AVAIL:-0}
    if [[ "$KONK_APISVC_AVAIL" -gt 0 ]] 2>/dev/null; then
      pass "konk health inferred from APIService availability (${KONK_APISVC_AVAIL} bulk APIService(s) Available=True)"
    else
      warn "could not find a live kubectl-apiservice pod for /healthz check and no Available bulk APIServices"
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
fi
fi  # section 9

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 10: konk-operator log health
# ══════════════════════════════════════════════════════════════════════════════
section "konk-operator log health"
if should_run 10; then
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
fi  # section 10

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 11: cert-manager CA integration
# ══════════════════════════════════════════════════════════════════════════════
section "cert-manager CA integration"
if should_run 11; then
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
fi  # section 11

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 12: Konk API deep test — query actual resources via konk
# ══════════════════════════════════════════════════════════════════════════════
section "Konk API deep test (query resources inside konk)"
if should_run 12; then
if [[ "$SKIP_EXEC" == true ]]; then
  skip "konk API deep test (--skip-exec)"
else
  # Find a healthy kubectl-apiservice pod for exec (reuse from section 7 if available)
  EXEC_CONTAINER=""
  if [[ -z "${EXEC_POD:-}" ]]; then
    # Prefer 2/2 pods (have 'kind' sidecar with kubectl) then fall back to 1/1
    EXEC_CANDIDATES=$(kc get pods -A --no-headers \
      | grep "konk-service-kubectl-apiservice" | grep "Running" \
      | sort -t'/' -k1 -rn || true)  # 2/2 sorts before 1/1
    if [[ -z "$EXEC_CANDIDATES" ]]; then
      EXEC_CANDIDATES=$(kc get pods -A --no-headers -l app.kubernetes.io/component=apiservice \
        | grep "Running" || true)
    fi
    if [[ -n "$EXEC_CANDIDATES" ]]; then
      # Find a pod where kubectl is actually available, probing the 'kind' container first
      _find_kubectl_pod() {
        local candidates="$1"
        while IFS= read -r line; do
          local ns pod
          ns=$(echo "$line" | awk '{print $1}')
          pod=$(echo "$line" | awk '{print $2}')
          # Try 'kind' container first (older 2/2 pods), then default container
          if kubectl exec -n "$ns" "$pod" -c kind -- kubectl version --client >/dev/null 2>&1; then
            echo "$ns $pod kind"
            return 0
          elif kubectl exec -n "$ns" "$pod" -- kubectl version --client >/dev/null 2>&1; then
            echo "$ns $pod"
            return 0
          fi
        done <<< "$candidates"
        return 1
      }
      # First try SAMPLE_NS candidates, then fall back to any namespace
      SAMPLE_CANDIDATES=$(echo "$EXEC_CANDIDATES" | grep "^${SAMPLE_NS}" || true)
      OTHER_CANDIDATES=$(echo "$EXEC_CANDIDATES" | grep -v "^${SAMPLE_NS}" || true)
      ORDERED_CANDIDATES=$(printf '%s\n%s' "$SAMPLE_CANDIDATES" "$OTHER_CANDIDATES" | grep -v '^$' || true)
      if FOUND=$(_find_kubectl_pod "$ORDERED_CANDIDATES" 2>/dev/null); then
        EXEC_NS=$(echo "$FOUND" | awk '{print $1}')
        EXEC_POD=$(echo "$FOUND" | awk '{print $2}')
        EXEC_CONTAINER=$(echo "$FOUND" | awk '{print $3}')  # 'kind' or empty
      else
        # Fallback: pick first candidate even if distroless (api-resources may still fail)
        EXEC_NS=$(echo "$EXEC_CANDIDATES" | head -1 | awk '{print $1}')
        EXEC_POD=$(echo "$EXEC_CANDIDATES" | head -1 | awk '{print $2}')
        EXEC_CONTAINER=""
      fi
    fi
  fi
  # Build -c flag if a specific container was found
  EXEC_C_FLAG=""
  [[ -n "${EXEC_CONTAINER:-}" ]] && EXEC_C_FLAG="-c ${EXEC_CONTAINER}"

  if [[ -z "${EXEC_POD:-}" ]]; then
    warn "no healthy kubectl-apiservice pod for konk API deep test"
  else
    _EXEC_CONTAINER_INFO="${EXEC_CONTAINER:+ (container: ${EXEC_CONTAINER})}"
    info "using pod ${EXEC_NS}/${EXEC_POD}${_EXEC_CONTAINER_INFO} for konk API deep queries"

    # 12a. List api-resources in konk — verify bulk API groups are registered
    # shellcheck disable=SC2086
    KONK_API_RESOURCES=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl api-resources --no-headers 2>/dev/null || true)

    if [[ -z "$KONK_API_RESOURCES" ]]; then
      fail "konk api-resources returned empty — konk connectivity issue"
    else
      # Check for expected API groups
      EXPECTED_GROUPS=("tagging.bulk.infoblox.com" "dnsconfig.bulk.infoblox.com" "dnsdata.bulk.infoblox.com")
      for grp in "${EXPECTED_GROUPS[@]}"; do
        if echo "$KONK_API_RESOURCES" | grep -q "$grp" 2>/dev/null; then
          pass "konk api-resources contains group: ${grp}"
        else
          warn "konk api-resources missing group: ${grp} (service may not be deployed)"
        fi
      done
    fi

    # 12b. Query specific resources inside konk via the tagging API
    # This tests the full data path: kubectl-apiservice pod → konk apiserver → tagging aggregate API
    # shellcheck disable=SC2086
    TAGGING_TAGS=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl get tags.tagging.bulk.infoblox.com --all-namespaces --no-headers 2>/dev/null || true)
    TAGGING_ERR=$?

    if [[ -n "$TAGGING_TAGS" ]]; then
      TAG_COUNT=$(echo "$TAGGING_TAGS" | wc -l | tr -d ' ')
      pass "konk: kubectl get tags returned ${TAG_COUNT} tag(s) from tagging API"
      if [[ "$VERBOSE" == true ]]; then
        echo "$TAGGING_TAGS" | head -5 | sed 's/^/         /'
        [[ $TAG_COUNT -gt 5 ]] && echo "         ... (${TAG_COUNT} total)"
      fi
    else
      # Empty is not necessarily an error — could be no tags exist
      # Check if the API itself responds (vs connection error)
      # shellcheck disable=SC2086
      TAG_TEST=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
        kubectl get tags.tagging.bulk.infoblox.com --all-namespaces 2>&1 || true)
      if echo "$TAG_TEST" | grep -qi "No resources found\|^$" 2>/dev/null; then
        pass "konk: tagging API reachable (no tags exist — OK)"
      elif echo "$TAG_TEST" | grep -qi "x509\|tls\|connection refused\|unauthorized" 2>/dev/null; then
        fail "konk: tagging API returned error: $(echo "$TAG_TEST" | head -1)"
      else
        pass "konk: tagging API reachable (response: $(echo "$TAG_TEST" | head -1 | cut -c1-80))"
      fi
    fi

    # 12c. Query values from tagging API
    # shellcheck disable=SC2086
    TAGGING_VALUES=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl get values.tagging.bulk.infoblox.com --all-namespaces --no-headers 2>/dev/null || true)
    if [[ -n "$TAGGING_VALUES" ]]; then
      VALUE_COUNT=$(echo "$TAGGING_VALUES" | wc -l | tr -d ' ')
      pass "konk: kubectl get values returned ${VALUE_COUNT} value(s) from tagging API"
    else
      # shellcheck disable=SC2086
      TAG_VAL_TEST=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
        kubectl get values.tagging.bulk.infoblox.com --all-namespaces 2>&1 || true)
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
    # shellcheck disable=SC2086
    KONK_LIVEZ=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl get --raw /livez 2>/dev/null || true)
    if [[ "$KONK_LIVEZ" == "ok" ]]; then
      pass "konk apiserver /livez returns 'ok'"
    else
      warn "konk apiserver /livez returned: ${KONK_LIVEZ:-empty}"
    fi

    # shellcheck disable=SC2086
    KONK_READYZ=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
      kubectl get --raw /readyz 2>/dev/null || true)
    if [[ "$KONK_READYZ" == "ok" ]]; then
      pass "konk apiserver /readyz returns 'ok'"
    else
      warn "konk apiserver /readyz returned: ${KONK_READYZ:-empty}"
    fi

    # 12f. In-cluster health check — call aggregate-api service healthz directly
    # Tests the TLS serving cert + service DNS + network path inside the cluster
    SAMPLE_SVC=$(kc get svc -n "$SAMPLE_NS" --no-headers \
      | grep 'apiservice' | awk '{print $1}' | head -1)
    if [[ -n "$SAMPLE_SVC" ]]; then
      SVC_FQDN="${SAMPLE_SVC}.${SAMPLE_NS}.svc.cluster.local"
      # shellcheck disable=SC2086
      HEALTHZ_RESP=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
        wget -q -O- --timeout=5 "https://${SVC_FQDN}:443/healthz" \
        --no-check-certificate 2>/dev/null || true)
      if [[ -z "$HEALTHZ_RESP" ]]; then
        # Try curl if wget is not available
        # shellcheck disable=SC2086
        HEALTHZ_RESP=$(kubectl exec -n "$EXEC_NS" "$EXEC_POD" $EXEC_C_FLAG -- \
          curl -sk --connect-timeout 5 "https://${SVC_FQDN}:443/healthz" \
          2>/dev/null || true)
      fi
      if [[ "$HEALTHZ_RESP" == "ok" || "$HEALTHZ_RESP" == *"healthy"* || "$HEALTHZ_RESP" == *"200"* ]]; then
        pass "in-cluster healthz: ${SVC_FQDN}/healthz returns ok"
      elif [[ -n "$HEALTHZ_RESP" ]]; then
        # Got some response — endpoint is reachable even if it returns a different body
        pass "in-cluster healthz: ${SVC_FQDN} reachable (response: ${HEALTHZ_RESP:0:60})"
      else
        warn "in-cluster healthz: could not reach ${SVC_FQDN}/healthz (wget/curl may not be in pod)"
      fi
    else
      vinfo "no apiservice service found in ${SAMPLE_NS} for health check"
    fi
  fi
fi
fi  # section 12

# ══════════════════════════════════════════════════════════════════════════════
# SECTION 13: External API integration — tagging + bulk via CSP endpoint
# ══════════════════════════════════════════════════════════════════════════════
section "External API integration (tagging + bulk via CSP)"
if should_run 13; then

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

if [[ -z "$CSP_TOKEN" ]]; then
  warn "no bearer token provided — skip external API tests (use --token TOKEN or export KONK_E2E_TOKEN)"
elif [[ -z "$CSP_URL" ]]; then
  warn "cannot determine CSP URL from cluster context — use --csp-url URL"
else
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

  # 13f. Bulk analyze API — verify GET /analyze endpoint is reachable
  # This endpoint analyzes an uploaded file before import. We call it with a dummy
  # data_ref; a 500 with "Improper JSON" proves the endpoint is alive and processing.
  info "testing bulk analyze API (GET /analyze) ..."
  ANALYZE_CODE=$(curl -s -o /tmp/konk-e2e-analyze.json -w '%{http_code}' \
    --connect-timeout 10 --max-time 15 \
    "${CSP_URL}/bulk/v1/analyze?data_ref=konk-e2e-probe.json&format=json" \
    -H "Authorization: Bearer ${CSP_TOKEN}" \
    -H "Content-Type: application/json" \
    2>/dev/null || echo "000")
  dbg_curl "GET ${CSP_URL}/bulk/v1/analyze?data_ref=konk-e2e-probe.json → HTTP ${ANALYZE_CODE}" /tmp/konk-e2e-analyze.json

  ANALYZE_BODY=$(cat /tmp/konk-e2e-analyze.json 2>/dev/null || echo "")
  if [[ "$ANALYZE_CODE" == "200" ]]; then
    pass "bulk analyze API: GET /analyze HTTP 200 (endpoint reachable)"
  elif [[ "$ANALYZE_CODE" == "500" ]]; then
    # 500 with "Improper JSON" or file-not-found error means the endpoint is alive,
    # it just can't find our dummy file in S3 — that's expected
    if echo "$ANALYZE_BODY" | grep -qi "Improper JSON\|import file\|data_ref\|file not found\|NoSuchKey" 2>/dev/null; then
      pass "bulk analyze API: GET /analyze HTTP 500 (endpoint reachable — dummy file rejected as expected)"
    else
      warn "bulk analyze API: GET /analyze HTTP 500 (unexpected error: $(echo "$ANALYZE_BODY" | head -1 | cut -c1-80))"
    fi
  elif [[ "$ANALYZE_CODE" == "401" ]]; then
    fail "bulk analyze API: HTTP 401 Unauthorized"
  elif [[ "$ANALYZE_CODE" == "000" ]]; then
    fail "bulk analyze API: connection failed"
  else
    warn "bulk analyze API: HTTP ${ANALYZE_CODE}"
  fi

  # Cleanup temp files
  rm -f /tmp/konk-e2e-tag-resp.json /tmp/konk-e2e-tag-create.json \
        /tmp/konk-e2e-export-resp.json /tmp/konk-e2e-export-headers.txt \
        /tmp/konk-e2e-op-status.json /tmp/konk-e2e-op-list.json \
        /tmp/konk-e2e-analyze.json 2>/dev/null
fi
fi  # section 13

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
  echo -e "  4. For RBAC issues:     check kubeconfig Role 'update' verb (issue #23)"
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
