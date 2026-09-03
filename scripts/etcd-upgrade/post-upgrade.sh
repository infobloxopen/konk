#!/bin/bash
# Post-Upgrade Checks — etcd claimName Migration (bitnami → cgr.dev)
# Run AFTER the DC PR merges / the etcd chart upgrade completes.
# Every check prints [PASS] or [FAIL]. Script exits 1 if any check fails.

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
CTX="${CTX:-$(kubectl config current-context 2>/dev/null || true)}"
if [[ -z "$CTX" ]]; then
  echo "ERROR: CTX is empty. Set CTX=<cluster> or configure kubectl current-context."
  exit 1
fi
NS="${NS:-aggregate}"
STS="${STS:-bulk-konk-etcd}"
TARGET_VCT="${TARGET_VCT:-data-v2}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-3}"
# Expected operator version range: any build between j25 and j35
OPERATOR_VERSION_MIN="${OPERATOR_VERSION_MIN:-25}"
OPERATOR_VERSION_MAX="${OPERATOR_VERSION_MAX:-35}"
EXPECTED_ETCD_IMAGE="${EXPECTED_ETCD_IMAGE:-cgr.dev/infoblox.com/etcd}"
# Which side of the migration are we validating?
#   migration -> just moved onto data-v2; expect initialClusterState=new,      recreateStatefulSet=true
#   steady    -> post-migration flip done; expect initialClusterState=existing, recreateStatefulSet=false
MIGRATION_PHASE="${MIGRATION_PHASE:-migration}"
if [[ "$MIGRATION_PHASE" != "migration" && "$MIGRATION_PHASE" != "steady" ]]; then
  echo "ERROR: MIGRATION_PHASE='$MIGRATION_PHASE' is invalid. Use 'migration' or 'steady'."
  exit 1
fi

# CGR cert path (post-migration uses cgr.dev etcd image)
ETCD_CERTS_DIR="${ETCD_CERTS_DIR:-/etc/etcd/certs/client}"
ETCD_TLS="--cacert=$ETCD_CERTS_DIR/ca.crt --cert=$ETCD_CERTS_DIR/server.crt --key=$ETCD_CERTS_DIR/server.key"
ETCD_EP="--endpoints=https://localhost:2379"
OPERATOR_NS="${OPERATOR_NS:-konk}"

# ── Karpenter mitigation expectations (konk #683 / #688) ─────────────────────
EXPECTED_ETCD_CPU_REQUEST="${EXPECTED_ETCD_CPU_REQUEST:-200m}"
EXPECTED_ETCD_MEM_REQUEST="${EXPECTED_ETCD_MEM_REQUEST:-128Mi}"
EXPECTED_KONK_SERVICE_CPU="${EXPECTED_KONK_SERVICE_CPU:-100m}"
EXPECTED_PDB_MIN_AVAILABLE="${EXPECTED_PDB_MIN_AVAILABLE:-2}"
DO_NOT_DISRUPT_TAINT="${DO_NOT_DISRUPT_TAINT:-infoblox.com/do-not-disrupt}"
STABLE_NODE_LABEL="${STABLE_NODE_LABEL:-node-group-type}"
STABLE_NODE_VALUE="${STABLE_NODE_VALUE:-stable}"
MAX_EVICTIONS="${MAX_EVICTIONS:-2}"
# Namespace where the Karpenter controller runs (its presence gates the
# stable-node-pool assertion in check 21 — no Karpenter, no consolidation).
KARPENTER_NS="${KARPENTER_NS:-ib-system}"

# ── Cluster-depth / consumer thresholds ──────────────────────────────────────
# The running pod image may be rewritten to a registry mirror (e.g. Harbor
# cgr-proxy), so the pod image is matched on the repo path, not the full ref.
EXPECTED_ETCD_IMAGE_MATCH="${EXPECTED_ETCD_IMAGE_MATCH:-infoblox.com/etcd}"
ETCD_METRICS_PORT="${ETCD_METRICS_PORT:-2381}"
MAX_RAFT_INDEX_DELTA="${MAX_RAFT_INDEX_DELTA:-1000}"
MAX_APISERVER_RESTARTS="${MAX_APISERVER_RESTARTS:-5}"
APISERVER_DEPLOY="${APISERVER_DEPLOY:-bulk-konk}"

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${RESET} $*"; (( PASS_COUNT++ )); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $*"; (( FAIL_COUNT++ )); }
info() { echo -e "  ${YELLOW}[INFO]${RESET} $*"; }
section() { echo; echo -e "${CYAN}${BOLD}── $* ──${RESET}"; }

# ── Header ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        POST-UPGRADE CHECKS — etcd claimName Migration       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster : %-50s║\n" "$CTX"
printf "║  NS      : %-50s║\n" "$NS"
printf "║  STS     : %-50s║\n" "$STS"
printf "║  Phase   : %-50s║\n" "$MIGRATION_PHASE"
printf "║  Date    : %-50s║\n" "$(date)"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── 1. Operator image ─────────────────────────────────────────────────────────
section "1. konk-operator version"
OPERATOR_IMAGE=$(kubectl --context "$CTX" get deploy -n "$OPERATOR_NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
  2>/dev/null | grep -i operator | awk '{print $2}' || \
  kubectl --context "$CTX" get deploy -n vela-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
  2>/dev/null | grep -i konk | awk '{print $2}' || true)

info "Image: ${OPERATOR_IMAGE:-(not found)}"

# Extract build number (jN) from image tag
BUILD_NUM=$(echo "$OPERATOR_IMAGE" | grep -oE '\-j([0-9]+)' | grep -oE '[0-9]+' || echo "0")
if [[ "$BUILD_NUM" -ge "$OPERATOR_VERSION_MIN" && "$BUILD_NUM" -le "$OPERATOR_VERSION_MAX" ]]; then
  pass "konk-operator build j${BUILD_NUM} is within expected range (j${OPERATOR_VERSION_MIN}–j${OPERATOR_VERSION_MAX})"
else
  fail "konk-operator build j${BUILD_NUM} is OUTSIDE expected range (j${OPERATOR_VERSION_MIN}–j${OPERATOR_VERSION_MAX}) — image: ${OPERATOR_IMAGE:-(not found)}"
fi

# ── 2. etcd container image ───────────────────────────────────────────────────
section "2. etcd container image"
ETCD_IMAGE=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

info "Image: ${ETCD_IMAGE:-(not found)}"
if echo "$ETCD_IMAGE" | grep -q "$EXPECTED_ETCD_IMAGE"; then
  pass "etcd image is the expected cgr.dev image ($ETCD_IMAGE)"
else
  fail "etcd image is NOT the expected cgr.dev image — got '${ETCD_IMAGE:-(not found)}', expected pattern '$EXPECTED_ETCD_IMAGE'"
fi

# ── 3. StatefulSet VCT migrated to 'data-v2' ─────────────────────────────────
section "3. StatefulSet volumeClaimTemplate name"
VCT=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)

info "VCT claim name: '${VCT:-(not found)}'"
if [[ "$VCT" == "$TARGET_VCT" ]]; then
  pass "VCT is '$TARGET_VCT' — StatefulSet migration succeeded"
else
  fail "VCT is '${VCT}' (expected '$TARGET_VCT') — StatefulSet was NOT recreated"
fi

# ── 4. ETCD_INITIAL_CLUSTER_STATE ─────────────────────────────────────────────
section "4. ETCD_INITIAL_CLUSTER_STATE"
STATE=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ETCD_INITIAL_CLUSTER_STATE")]}{.value}{end}' \
  2>/dev/null || true)

HOOK=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.spec.recreateStatefulSet.enabled}' 2>/dev/null || true)
STS_REPLICAS=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || true)

if [[ "$MIGRATION_PHASE" == "migration" ]]; then
  EXPECTED_STATE="new";      EXPECTED_HOOK="true"
else
  EXPECTED_STATE="existing"; EXPECTED_HOOK="false"
fi

info "Phase '$MIGRATION_PHASE' expects ETCD_INITIAL_CLUSTER_STATE=$EXPECTED_STATE, recreateStatefulSet.enabled=$EXPECTED_HOOK"
info "ETCD_INITIAL_CLUSTER_STATE=${STATE:-(absent)}"
info "recreateStatefulSet.enabled=${HOOK:-(not set)}"

if [[ -z "$STATE" ]]; then
  if [[ -n "$STS_REPLICAS" && "$STS_REPLICAS" -le 1 ]]; then
    fail "ETCD_INITIAL_CLUSTER_STATE is absent — the chart only emits it when statefulset.replicaCount > 1, and the StatefulSet has $STS_REPLICAS replica. Any initialClusterState set in DC values is being silently dropped."
  else
    fail "ETCD_INITIAL_CLUSTER_STATE is absent — expected '$EXPECTED_STATE' for phase '$MIGRATION_PHASE'"
  fi
elif [[ "$STATE" == "$EXPECTED_STATE" ]]; then
  pass "ETCD_INITIAL_CLUSTER_STATE=$STATE — correct for phase '$MIGRATION_PHASE'"
elif [[ "$MIGRATION_PHASE" == "migration" && "$STATE" == "existing" ]]; then
  fail "ETCD_INITIAL_CLUSTER_STATE=existing during a 'migration' run — the release rendered 'existing' (in-place helm upgrade rather than a fresh install). Members bootstrapping on empty data-v2 volumes cannot join a cluster they cannot see; expect CrashLoopBackOff."
else
  fail "ETCD_INITIAL_CLUSTER_STATE=$STATE but phase '$MIGRATION_PHASE' expects '$EXPECTED_STATE' — the post-migration flip is missing or was applied prematurely"
fi

# 4b. The two migration flags must flip together — initialClusterState and
#     recreateStatefulSet. A mismatch means a half-applied phase change.
HOOK_NORM="${HOOK:-false}"
if [[ "$HOOK_NORM" == "$EXPECTED_HOOK" ]]; then
  pass "recreateStatefulSet.enabled=$HOOK_NORM — consistent with phase '$MIGRATION_PHASE'"
elif [[ "$MIGRATION_PHASE" == "steady" ]]; then
  fail "recreateStatefulSet.enabled=$HOOK_NORM but phase is 'steady' — the STS-deleting hook is still armed. It must be set to false alongside initialClusterState=existing."
else
  fail "recreateStatefulSet.enabled=$HOOK_NORM but phase is 'migration' — expected true, so the recreate hook may never have run and the StatefulSet may not have been rebuilt on $TARGET_VCT."
fi

# ── 5. PVC check — data-v2-* must exist, data-* (old) should be retained ──────
section "5. PVC state"
DATA_V2_PVCS=$(kubectl --context "$CTX" get pvc -n "$NS" --no-headers 2>/dev/null \
  | grep "data-v2-${STS}" || true)
OLD_PVCS=$(kubectl --context "$CTX" get pvc -n "$NS" --no-headers 2>/dev/null \
  | grep "data-${STS}-" | grep -v "data-v2" || true)
DATA_V2_COUNT=$(echo "$DATA_V2_PVCS" | grep -c . || echo 0)

info "data-v2-* PVCs (expected post-upgrade):"
if [[ -n "$DATA_V2_PVCS" ]]; then
  echo "$DATA_V2_PVCS" | while read -r line; do info "  $line"; done
else
  info "  (none found)"
fi
info "data-* old PVCs (retained for safety):"
if [[ -n "$OLD_PVCS" ]]; then
  echo "$OLD_PVCS" | while read -r line; do info "  $line"; done
else
  info "  (none — may have been cleaned up)"
fi

if [[ "$DATA_V2_COUNT" -eq "$EXPECTED_REPLICAS" ]]; then
  pass "$DATA_V2_COUNT data-v2-* PVCs exist — matches expected replica count ($EXPECTED_REPLICAS)"
else
  fail "$DATA_V2_COUNT data-v2-* PVCs found (expected $EXPECTED_REPLICAS)"
fi

# ── 6. Replicas ready ─────────────────────────────────────────────────────────
section "6. StatefulSet replicas"
READY=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
TOTAL=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
STS_CREATED=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)

info "Replicas: $READY/$TOTAL ready"
info "StatefulSet created: ${STS_CREATED:-(unknown)}"

kubectl --context "$CTX" get pods -n "$NS" --no-headers 2>/dev/null | grep "$STS" \
  | while read -r line; do info "  $line"; done

if [[ "$READY" -eq "$EXPECTED_REPLICAS" && "$TOTAL" -eq "$EXPECTED_REPLICAS" ]]; then
  pass "All $READY/$TOTAL replicas ready (expected $EXPECTED_REPLICAS)"
else
  fail "Replicas not ready: $READY/$TOTAL (expected $EXPECTED_REPLICAS/$EXPECTED_REPLICAS)"
fi

# ── 7. Konk CR status ─────────────────────────────────────────────────────────
section "7. KonK CR (bulk-konk)"
KONK_REASON=$(kubectl --context "$CTX" get konk.konk.infoblox.com bulk-konk -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null || true)
KONK_FAILED=$(kubectl --context "$CTX" get konk.konk.infoblox.com bulk-konk -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)

info "reason=$KONK_REASON ReleaseFailed=$KONK_FAILED"
if [[ "$KONK_REASON" == "UpgradeSuccessful" || "$KONK_REASON" == "InstallSuccessful" ]] && [[ "$KONK_FAILED" != "True" ]]; then
  pass "KonK CR is healthy ($KONK_REASON)"
else
  fail "KonK CR is NOT healthy (reason=$KONK_REASON, ReleaseFailed=$KONK_FAILED)"
fi

# ── 8. Etcd CR status ─────────────────────────────────────────────────────────
section "8. Etcd CR ($STS)"
ETCD_REASON=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null || true)
ETCD_FAILED=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)

info "reason=$ETCD_REASON ReleaseFailed=$ETCD_FAILED"
if [[ "$ETCD_REASON" == "UpgradeSuccessful" || "$ETCD_REASON" == "InstallSuccessful" ]] && [[ "$ETCD_FAILED" != "True" ]]; then
  pass "Etcd CR is healthy ($ETCD_REASON)"
else
  fail "Etcd CR is NOT healthy (reason=$ETCD_REASON, ReleaseFailed=$ETCD_FAILED)"
fi

# ── 9. Helm release stable ────────────────────────────────────────────────────
section "9. Helm release stability"
LAST_STATUS=$(kubectl --context "$CTX" get secret -n "$NS" \
  -l owner=helm,name="$STS" --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].metadata.labels.status}' 2>/dev/null || true)
HELM_REVS=$(kubectl --context "$CTX" get secret -n "$NS" \
  -l owner=helm,name="$STS" --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{range .items[*]}rev={.metadata.labels.version} status={.metadata.labels.status}{"\n"}{end}' \
  2>/dev/null | tail -3 || true)

info "Last 3 helm revisions:"
echo "$HELM_REVS" | while read -r line; do info "  $line"; done
if [[ "$LAST_STATUS" == "deployed" ]]; then
  pass "Helm release is stable (status=deployed) — no fail loop"
else
  fail "Helm release is NOT stable (status=${LAST_STATUS:-(unknown)})"
fi

# ── 10. etcd health ───────────────────────────────────────────────────────────
section "10. etcd cluster health"
HEALTH_OUT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl endpoint health $ETCD_EP $ETCD_TLS 2>&1 || true)
info "$HEALTH_OUT"
if echo "$HEALTH_OUT" | grep -q "is healthy"; then
  pass "etcd endpoint is healthy"
else
  fail "etcd endpoint health check failed"
fi

# ── 11. etcd members ──────────────────────────────────────────────────────────
section "11. etcd cluster members"
MEMBER_OUT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl member list -w table $ETCD_EP $ETCD_TLS 2>&1 || true)
MEMBER_COUNT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl member list $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . || echo 0)

info "$MEMBER_OUT"
if [[ "$MEMBER_COUNT" -eq "$EXPECTED_REPLICAS" ]]; then
  pass "etcd member count ($MEMBER_COUNT) matches expected replicas ($EXPECTED_REPLICAS)"
else
  fail "etcd member count ($MEMBER_COUNT) does NOT match expected replicas ($EXPECTED_REPLICAS)"
fi

# ── 12. etcd key count (data integrity) ───────────────────────────────────────
section "12. etcd data integrity"
KEY_COUNT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . || echo 0)
ETCD_STATUS=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl endpoint status -w table $ETCD_EP $ETCD_TLS 2>&1 || true)

info "Key count: $KEY_COUNT"
info "$ETCD_STATUS"
if [[ "$KEY_COUNT" -gt 0 ]]; then
  pass "$KEY_COUNT keys present — etcd data is populated"
else
  fail "0 keys found — KonkServices may not have repopulated etcd"
fi

# ── 13. etcd data readable ────────────────────────────────────────────────────
section "13. etcd /registry readability"
REGISTRY_KEYS=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl get /registry --prefix --keys-only --limit=5 $ETCD_EP $ETCD_TLS 2>/dev/null || true)
info "Sample /registry keys:"
if [[ -n "$REGISTRY_KEYS" ]]; then
  echo "$REGISTRY_KEYS" | while read -r line; do info "  $line"; done
  pass "/registry keys are readable"
else
  fail "No /registry keys found — embedded Kubernetes state may be missing"
fi

# ── 14. Hook cleanup ──────────────────────────────────────────────────────────
section "14. Hook resource cleanup"
STALE=$(kubectl --context "$CTX" get job,sa,role,rolebinding -n "$NS" 2>/dev/null \
  | grep -i recreate || true)
if [[ -z "$STALE" ]]; then
  pass "No stale recreate hook resources — cleanup complete"
else
  fail "Stale hook resources still present:"
  echo "$STALE" | while read -r line; do info "  $line"; done
fi

# ── 15. bulk-konk apiserver ───────────────────────────────────────────────────
section "15. bulk-konk apiserver"
APISERVER=$(kubectl --context "$CTX" get pods -n "$NS" --no-headers 2>/dev/null \
  | grep 'bulk-konk-[a-z0-9]*-' | grep -v etcd | grep -v init || true)
info "${APISERVER:-(not found)}"
if echo "$APISERVER" | grep -q "Running"; then
  pass "bulk-konk apiserver pod is Running"
else
  fail "bulk-konk apiserver pod is NOT Running"
fi

# ── 16. KonkServices reconciled ───────────────────────────────────────────────
section "16. KonkServices"
KS_COUNT=$(kubectl --context "$CTX" get konkservice -A --no-headers 2>/dev/null \
  | grep -c bulk-konk || echo 0)
info "$KS_COUNT KonkServices registered to bulk-konk"
if [[ "$KS_COUNT" -gt 0 ]]; then
  pass "$KS_COUNT KonkServices are registered"
else
  fail "0 KonkServices registered — apiserver may not have recovered yet"
fi

# ── 17. Recent warning events ─────────────────────────────────────────────────
section "17. Recent warning events (informational)"
EVENTS=$(kubectl --context "$CTX" get events -n "$NS" \
  --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true)
if [[ -n "$EVENTS" ]]; then
  info "Last 5 warnings:"
  echo "$EVENTS" | while read -r line; do info "  $line"; done
else
  info "No warning events"
fi

# ── 18. Grafana dashboards ────────────────────────────────────────────────────
# The konk charts create GrafanaDashboard on integreatly.org/v1alpha1 -- the v4
# grafana-operator running in ns appinfra-grafana. These clusters ALSO register
# grafana.integreatly.org/v1beta1 (the v5 operator in ns appinfra-grafana-v2).
#
# An unqualified `kubectl get grafanadashboard` resolves to the v1beta1 group and
# returns NOTHING from konk, which looks exactly like "dashboards were never
# created". Always use the fully-qualified resource name below.
section "18. Grafana dashboards"

DASH_CRD="${DASH_CRD:-grafanadashboards.integreatly.org}"
DASH_OPERATOR_LABEL="${DASH_OPERATOR_LABEL:-appinfra-grafana}"
DASH_FOLDER="${DASH_FOLDER:-konk}"

check_dashboard() {
  local _ns="$1" _name="$2" _json _op _folder
  _json=$(kubectl --context "$CTX" get "$DASH_CRD" "$_name" -n "$_ns" -o json 2>/dev/null || true)
  if [[ -z "$_json" ]]; then
    fail "GrafanaDashboard $_ns/$_name is MISSING (looked in $DASH_CRD)"
    return
  fi
  _op=$(echo "$_json" | python3 -c "import json,sys;print((json.load(sys.stdin).get('metadata',{}).get('labels') or {}).get('integreatly.org/operator',''))" 2>/dev/null || true)
  _folder=$(echo "$_json" | python3 -c "import json,sys;print(json.load(sys.stdin).get('spec',{}).get('customFolderName',''))" 2>/dev/null || true)
  if [[ "$_op" != "$DASH_OPERATOR_LABEL" ]]; then
    fail "GrafanaDashboard $_ns/$_name has integreatly.org/operator='${_op:-(none)}' (expected '$DASH_OPERATOR_LABEL') — the operator ignores unlabelled dashboards, so it exists but never reaches Grafana"
  elif [[ "$_folder" != "$DASH_FOLDER" ]]; then
    fail "GrafanaDashboard $_ns/$_name has customFolderName='${_folder:-(none)}' (expected '$DASH_FOLDER')"
  else
    pass "GrafanaDashboard $_ns/$_name present (operator=$_op, folder=$_folder)"
  fi
}

DASH_CREATE=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.spec.dashboards.create}' 2>/dev/null || true)
info "Etcd CR dashboards.create=${DASH_CREATE:-(not set)}"
info "Querying CRD: $DASH_CRD (NOT the bare 'grafanadashboard', which resolves to the v1beta1 group)"

if ! kubectl --context "$CTX" get crd "$DASH_CRD" >/dev/null 2>&1; then
  fail "CRD $DASH_CRD is not registered on this cluster — the konk charts' dashboards cannot be created at all"
elif [[ "$DASH_CREATE" != "true" ]]; then
  info "dashboards.create is not true — dashboards are not expected"
  pass "Dashboards not requested; nothing to verify"
else
  # etcd chart
  check_dashboard "$NS" "$STS"
  # konk-operator chart (konk-operator.fullname + the konk-services board from #690)
  check_dashboard "$OPERATOR_NS" "konk-operator"
  check_dashboard "$OPERATOR_NS" "konk-operator-konk-services"

  DASH_TOTAL=$(kubectl --context "$CTX" get "$DASH_CRD" -A \
    -l "integreatly.org/operator=$DASH_OPERATOR_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  info "$DASH_TOTAL dashboards cluster-wide carry integreatly.org/operator=$DASH_OPERATOR_LABEL"
fi

# ══════════════════════════════════════════════════════════════════════════════
# A. KARPENTER EVICTION MITIGATION (konk #683 / #688)
# ══════════════════════════════════════════════════════════════════════════════

# ── 19. etcd resource requests ────────────────────────────────────────────────
# The root cause of the Karpenter consolidation loop: at cpu=10m every node
# hosting etcd looked empty to WhenEmptyOrUnderutilized, so Karpenter evicted it.
# NOTE: the effective value comes from helm-charts/konk/values.yaml (via the Etcd
# CR spec), NOT helm-charts/etcd/values.yaml -- the operator passes the CR spec in
# as helm values and overrides the subchart defaults.
section "19. etcd resource requests (Karpenter root cause)"
REQ_JSON=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null || true)
REQ_CPU=$(echo "$REQ_JSON" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(json.loads(d).get('cpu','') if d else '')" 2>/dev/null || true)
REQ_MEM=$(echo "$REQ_JSON" | python3 -c "import json,sys;d=sys.stdin.read().strip();print(json.loads(d).get('memory','') if d else '')" 2>/dev/null || true)
info "requests: cpu=${REQ_CPU:-(unset)} memory=${REQ_MEM:-(unset)}"
if [[ "$REQ_CPU" == "$EXPECTED_ETCD_CPU_REQUEST" && "$REQ_MEM" == "$EXPECTED_ETCD_MEM_REQUEST" ]]; then
  pass "etcd requests are $EXPECTED_ETCD_CPU_REQUEST / $EXPECTED_ETCD_MEM_REQUEST — Karpenter fix applied"
elif [[ "$REQ_CPU" == "10m" || "$REQ_MEM" == "64Mi" ]]; then
  fail "etcd requests are still the pre-fix values (cpu=$REQ_CPU memory=$REQ_MEM) — the Karpenter consolidation loop WILL recur. Check helm-charts/konk/values.yaml reached the Etcd CR."
else
  fail "etcd requests are cpu=${REQ_CPU:-(unset)} memory=${REQ_MEM:-(unset)}, expected $EXPECTED_ETCD_CPU_REQUEST / $EXPECTED_ETCD_MEM_REQUEST"
fi

# ── 20. PodDisruptionBudget ───────────────────────────────────────────────────
# The etcd PDB template is gated on `gt (int .Values.statefulset.replicaCount) 1`,
# so single-member clusters legitimately have NO PDB.
section "20. etcd PodDisruptionBudget"
PDB_JSON=$(kubectl --context "$CTX" get pdb "$STS" -n "$NS" -o json 2>/dev/null || true)
if [[ "$EXPECTED_REPLICAS" -le 1 ]]; then
  if [[ -z "$PDB_JSON" ]]; then
    pass "No PDB, correct for a single-member cluster (template gated on replicaCount > 1)"
  else
    fail "A PDB exists but EXPECTED_REPLICAS=$EXPECTED_REPLICAS — the chart should not have rendered one"
  fi
elif [[ -z "$PDB_JSON" ]]; then
  fail "PDB $NS/$STS is MISSING — etcd evictions are unguarded at the Kubernetes API level (konk #682/#683)"
else
  PDB_MIN=$(echo "$PDB_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['spec'].get('minAvailable',''))" 2>/dev/null || true)
  PDB_ALLOWED=$(echo "$PDB_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status',{}).get('disruptionsAllowed',''))" 2>/dev/null || true)
  info "minAvailable=$PDB_MIN disruptionsAllowed=$PDB_ALLOWED"
  if [[ "$PDB_MIN" == "$EXPECTED_PDB_MIN_AVAILABLE" && "${PDB_ALLOWED:-0}" -ge 1 ]]; then
    pass "PDB present: minAvailable=$PDB_MIN, disruptionsAllowed=$PDB_ALLOWED — quorum-safe evictions"
  elif [[ "${PDB_ALLOWED:-0}" -lt 1 ]]; then
    fail "PDB disruptionsAllowed=$PDB_ALLOWED — no member may be evicted; a member is likely unhealthy"
  else
    fail "PDB minAvailable=$PDB_MIN, expected $EXPECTED_PDB_MIN_AVAILABLE"
  fi
fi

# ── 21. Scheduling: toleration + stable-node affinity + real placement ───────
section "21. etcd scheduling (toleration + affinity + placement)"
TOL=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null || true)
AFF=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.affinity}' 2>/dev/null || true)
info "tolerations=${TOL:-(none)}"
info "affinity=${AFF:-(none)}"
if echo "$TOL" | grep -q "$DO_NOT_DISRUPT_TAINT"; then
  pass "toleration for $DO_NOT_DISRUPT_TAINT present — etcd can schedule onto the stable node pool"
else
  fail "toleration for $DO_NOT_DISRUPT_TAINT is MISSING — etcd cannot land on nodes carrying that taint"
fi
if echo "$AFF" | grep -q "$STABLE_NODE_LABEL" && echo "$AFF" | grep -q "$STABLE_NODE_VALUE"; then
  if echo "$AFF" | grep -q 'preferredDuringSchedulingIgnoredDuringExecution'; then
    pass "soft node affinity for $STABLE_NODE_LABEL=$STABLE_NODE_VALUE present"
  else
    fail "node affinity for $STABLE_NODE_LABEL=$STABLE_NODE_VALUE is HARD (required...) — etcd will be unschedulable on clusters without a stable node pool"
  fi
else
  fail "soft node affinity for $STABLE_NODE_LABEL=$STABLE_NODE_VALUE is MISSING"
fi
# ── 21c. Actual placement: stable node pool + one member per node ────────────
# The affinity above is *soft* (preferred), so a pod can still land off the
# stable pool — assert on where the pods really are, not just on the template.
NODE_POOLS=$(kubectl --context "$CTX" get nodes -o json 2>/dev/null | python3 -c "
import json,sys
lbl='$STABLE_NODE_LABEL'
try: d=json.load(sys.stdin)
except Exception: d={'items':[]}
for n in d.get('items',[]):
    print(n['metadata']['name']+'\t'+(n['metadata'].get('labels',{}).get(lbl) or '(unset)'))
" 2>/dev/null || true)

POD_ROWS=$(kubectl --context "$CTX" get pods -n "$NS" -l app.kubernetes.io/name=etcd -o json 2>/dev/null | python3 -c "
import json,sys,datetime
try: d=json.load(sys.stdin)
except Exception: d={'items':[]}
now=datetime.datetime.now(datetime.timezone.utc)
def age(ts):
    if not ts: return '?'
    t=datetime.datetime.strptime(ts,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    s=int((now-t).total_seconds())
    if s < 3600:   return '%dm' % (s//60)
    if s < 172800: return '%dh' % (s//3600)
    return '%dd%dh' % (s//86400, (s%86400)//3600)
for p in sorted(d.get('items',[]), key=lambda x: x['metadata']['name']):
    m=p['metadata']; st=p.get('status',{})
    print('\t'.join([m['name'],
                     st.get('phase','?'),
                     age(st.get('startTime') or m.get('creationTimestamp')),
                     st.get('podIP') or '-',
                     p['spec'].get('nodeName') or '(unscheduled)']))
" 2>/dev/null || true)

# Is Karpenter actually deployed? Without it nothing consolidates nodes, so
# being off the stable pool is harmless — this gates the FAIL further down.
KARPENTER_DEPLOYS=$(kubectl --context "$CTX" get deploy -n "$KARPENTER_NS" --no-headers 2>/dev/null | grep -i karpenter || true)
KARPENTER_PODS=$(kubectl --context "$CTX" get pods -n "$KARPENTER_NS" --no-headers 2>/dev/null | grep -i karpenter || true)
if [[ -n "$KARPENTER_DEPLOYS" || -n "$KARPENTER_PODS" ]]; then
  KARPENTER_PRESENT=yes
  info "Karpenter IS deployed in $KARPENTER_NS — node consolidation is active:"
  printf '%s\n%s\n' "$KARPENTER_DEPLOYS" "$KARPENTER_PODS" \
    | grep -v '^[[:space:]]*$' | awk '{print "  "$1"  "$2"  "$3}' \
    | while read -r l; do info "$l"; done
else
  KARPENTER_PRESENT=no
  info "Karpenter is NOT deployed in $KARPENTER_NS — no consolidation pressure on this cluster"
fi

info "etcd pod placement:"
ETCD_NODES=""
NOT_STABLE=""
POD_TOTAL=0
while IFS=$'\t' read -r P_NAME P_STATUS P_AGE P_IP P_NODE; do
  [[ -z "${P_NAME:-}" ]] && continue
  (( POD_TOTAL++ ))
  P_POOL=$(printf '%s\n' "$NODE_POOLS" | awk -F'\t' -v n="$P_NODE" '$1==n{print $2}')
  P_POOL="${P_POOL:-(unknown)}"
  info "$(printf '  %-20s %-9s %-6s %-16s %-32s %s' \
      "$P_NAME" "$P_STATUS" "$P_AGE" "$P_IP" "${P_NODE%.compute.internal}" \
      "${STABLE_NODE_LABEL}=${P_POOL}")"
  ETCD_NODES+="${P_NODE}"$'\n'
  if [[ "$P_POOL" != "$STABLE_NODE_VALUE" ]]; then
    NOT_STABLE+="${P_NAME}@${P_NODE%.compute.internal}(${P_POOL}) "
  fi
done <<< "$POD_ROWS"

UNIQ_NODES=$(printf '%s\n' "$ETCD_NODES" | grep -v '^[[:space:]]*$' | sort -u | wc -l | tr -d ' ')
DUP_NODES=$(printf '%s\n'  "$ETCD_NODES" | grep -v '^[[:space:]]*$' | sort | uniq -d | tr '\n' ' ')

if [[ "$POD_TOTAL" -eq 0 ]]; then
  fail "no etcd pods found in $NS (label app.kubernetes.io/name=etcd) — cannot verify placement"
else
  # one member per node — co-location means a single node loss can cost quorum
  if [[ "$UNIQ_NODES" -eq "$POD_TOTAL" ]]; then
    pass "all $POD_TOTAL etcd pods are on distinct nodes ($UNIQ_NODES unique) — no member co-location"
  else
    fail "etcd members are CO-LOCATED: $POD_TOTAL pods on $UNIQ_NODES node(s) (shared: ${DUP_NODES:-?}) — losing one node can break quorum"
  fi
  # running on the stable (non-consolidated) node pool — only enforced when
  # Karpenter is deployed, since that is the only thing that would evict them
  STABLE_POOL_SIZE=$(printf '%s\n' "$NODE_POOLS" | awk -F'\t' -v v="$STABLE_NODE_VALUE" '$2==v' | grep -c . || true)
  if [[ -z "$NOT_STABLE" ]]; then
    pass "all $POD_TOTAL etcd pods are running on $STABLE_NODE_LABEL=$STABLE_NODE_VALUE nodes"
  elif [[ "$KARPENTER_PRESENT" != "yes" ]]; then
    pass "etcd pods are off the stable pool (${NOT_STABLE}) but Karpenter is not deployed in $KARPENTER_NS — nothing will consolidate them, placement is advisory here"
  else
    fail "etcd pods are NOT on the stable node pool: ${NOT_STABLE}— Karpenter is deployed in $KARPENTER_NS, so they are exposed to consolidation (cluster has ${STABLE_POOL_SIZE:-0} node(s) labelled $STABLE_NODE_LABEL=$STABLE_NODE_VALUE)"
  fi
fi

# ── 22. konk-service CPU requests ─────────────────────────────────────────────
# Karpenter was also evicting KonkService pods directly (observed on gov-stg-2).
section "22. konk-service CPU requests"
KS_BAD=$(kubectl --context "$CTX" get deploy -A -o json 2>/dev/null | python3 -c "
import json,sys
want='$EXPECTED_KONK_SERVICE_CPU'
d=json.load(sys.stdin); bad=[]; tot=0
for i in d.get('items',[]):
    nm=i['metadata']['name']
    if 'konk-service' not in nm: continue
    tot+=1
    c=i['spec']['template']['spec']['containers'][0]
    cpu=((c.get('resources') or {}).get('requests') or {}).get('cpu')
    if cpu!=want: bad.append(f\"{i['metadata']['namespace']}/{nm}={cpu}\")
print(tot); print('|'.join(bad[:5])); print(len(bad))
" 2>/dev/null || true)
KS_TOTAL=$(echo "$KS_BAD" | sed -n '1p')
KS_SAMPLE=$(echo "$KS_BAD" | sed -n '2p')
KS_NBAD=$(echo "$KS_BAD" | sed -n '3p')
info "${KS_TOTAL:-0} konk-service deployments found; ${KS_NBAD:-?} not at $EXPECTED_KONK_SERVICE_CPU"
if [[ "${KS_TOTAL:-0}" -eq 0 ]]; then
  info "no konk-service deployments on this cluster"
  pass "nothing to verify"
elif [[ "${KS_NBAD:-1}" -eq 0 ]]; then
  pass "all ${KS_TOTAL} konk-service deployments request $EXPECTED_KONK_SERVICE_CPU"
else
  fail "${KS_NBAD} konk-service deployments are not at $EXPECTED_KONK_SERVICE_CPU (e.g. ${KS_SAMPLE}) — Karpenter may still evict them"
fi

# ── 23. Karpenter eviction events ─────────────────────────────────────────────
section "23. Karpenter eviction events"
EVICTED=$(kubectl --context "$CTX" get events -A --field-selector reason=Evicted \
  --sort-by=.lastTimestamp --no-headers 2>/dev/null | grep -Ei 'etcd|konk' || true)
EV_COUNT=$(echo "$EVICTED" | grep -c . || true)
UNDER=$(echo "$EVICTED" | grep -ci 'Underutilized' || true)
info "$EV_COUNT etcd/konk Evicted events in the event window ($UNDER citing Underutilized)"
if [[ -n "$EVICTED" ]]; then
  echo "$EVICTED" | tail -5 | while read -r line; do info "  $line"; done
fi
if [[ "${UNDER:-0}" -gt "$MAX_EVICTIONS" ]]; then
  fail "$UNDER 'Underutilized' evictions exceed the threshold of $MAX_EVICTIONS — the consolidation loop may still be active. Re-check check 19."
else
  pass "$UNDER 'Underutilized' evictions (threshold $MAX_EVICTIONS) — no active consolidation loop"
fi

# ══════════════════════════════════════════════════════════════════════════════
# B. OBSERVABILITY (konk #688 / #689 / #690)
# ══════════════════════════════════════════════════════════════════════════════

# ── 24. PodMonitors ───────────────────────────────────────────────────────────
section "24. PodMonitors"
PM_ETCD=$(kubectl --context "$CTX" get podmonitor "$STS" -n "$NS" -o name 2>/dev/null || true)
PM_OP=$(kubectl --context "$CTX" get podmonitor konk-operator -n "$OPERATOR_NS" -o name 2>/dev/null || true)
if [[ -n "$PM_ETCD" ]]; then
  pass "PodMonitor $NS/$STS present"
else
  fail "PodMonitor $NS/$STS is MISSING — etcd metrics are not being discovered"
fi
if [[ -n "$PM_OP" ]]; then
  pass "PodMonitor $OPERATOR_NS/konk-operator present"
else
  fail "PodMonitor $OPERATOR_NS/konk-operator is MISSING — the operator dashboard panels scoped by namespace=\"konk\" will be empty"
fi

# ── 25. Scrape-path hygiene (no double scrape) ────────────────────────────────
# konk #689 gates the chart's etcd metrics.podAnnotations behind
# `not metrics.podMonitor.enabled`. Alloy discovers BOTH PodMonitors and
# prometheus.io/scrape annotations with no selector, so if both are present every
# series is collected twice and rate()/count() read ~2x.
section "25. Scrape-path hygiene (no double scrape)"
ETCD_SCRAPE=$(kubectl --context "$CTX" get pod "$STS-0" -n "$NS" \
  -o jsonpath='{.metadata.annotations.prometheus\.io/scrape}' 2>/dev/null || true)
OP_SCRAPE=$(kubectl --context "$CTX" get pods -n "$OPERATOR_NS" \
  -o jsonpath='{.items[0].metadata.annotations.prometheus\.io/scrape}' 2>/dev/null || true)
info "etcd pod prometheus.io/scrape=${ETCD_SCRAPE:-(absent)}"
info "konk-operator pod prometheus.io/scrape=${OP_SCRAPE:-(absent)}"
if [[ -n "$PM_ETCD" && "$ETCD_SCRAPE" == "true" ]]; then
  fail "etcd has BOTH a PodMonitor and prometheus.io/scrape=true — double-scraped, every etcd series reads ~2x (konk #689 should have gated the annotation)"
else
  pass "etcd has a single scrape path"
fi
if [[ -n "$PM_OP" && "$OP_SCRAPE" == "true" ]]; then
  fail "konk-operator has BOTH a PodMonitor and prometheus.io/scrape=true — double-scraped. Set podAnnotations: null (not {}) in konk-operator-values.yaml."
else
  pass "konk-operator has a single scrape path"
fi

# ── 26. etcd metrics port ─────────────────────────────────────────────────────
section "26. etcd metrics port"
PORTS=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].ports[*].containerPort}' 2>/dev/null || true)
info "containerPorts: ${PORTS:-(none)}"
if echo "$PORTS" | grep -qw "$ETCD_METRICS_PORT"; then
  pass "metrics port $ETCD_METRICS_PORT exposed on the etcd container"
else
  fail "metrics port $ETCD_METRICS_PORT is NOT exposed — the PodMonitor has nothing to scrape"
fi

# ══════════════════════════════════════════════════════════════════════════════
# C. ETCD CLUSTER DEPTH
# ══════════════════════════════════════════════════════════════════════════════

# ── 27. Per-member health ─────────────────────────────────────────────────────
# Check 10 only tests $STS-0. The server cert covers only the headless service
# name and localhost -- NOT the per-member FQDNs -- so cross-member client TLS
# from one pod fails verification. The only reliable way to test every member is
# to exec into each pod and hit its own localhost.
section "27. Per-member etcd health"
MEMBER_UNHEALTHY=0
for idx in $(seq 0 $(( EXPECTED_REPLICAS - 1 ))); do
  _pod="$STS-$idx"
  _h=$(kubectl --context "$CTX" exec -n "$NS" "$_pod" -- \
    etcdctl endpoint health $ETCD_EP $ETCD_TLS 2>&1 || true)
  if echo "$_h" | grep -q "is healthy"; then
    info "  $_pod: healthy"
  else
    info "  $_pod: $(echo "$_h" | tail -1)"
    MEMBER_UNHEALTHY=$(( MEMBER_UNHEALTHY + 1 ))
  fi
done
if [[ "$MEMBER_UNHEALTHY" -eq 0 ]]; then
  pass "all $EXPECTED_REPLICAS members report healthy on their own endpoint"
else
  fail "$MEMBER_UNHEALTHY of $EXPECTED_REPLICAS members are UNHEALTHY"
fi

# ── 28. Leader election + raft convergence ────────────────────────────────────
section "28. Leader election + raft convergence"
LEADERS=0
RAFT_MIN=""
RAFT_MAX=""
VERSIONS=""
for idx in $(seq 0 $(( EXPECTED_REPLICAS - 1 ))); do
  _pod="$STS-$idx"
  _st=$(kubectl --context "$CTX" exec -n "$NS" "$_pod" -- \
    etcdctl endpoint status $ETCD_EP $ETCD_TLS -w json 2>/dev/null || true)
  _parsed=$(echo "$_st" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)[0]
except Exception: print('||'); raise SystemExit
st=d.get('Status',{}); hdr=st.get('header',{})
isldr = str(hdr.get('member_id')) == str(st.get('leader'))
print(f\"{isldr}|{st.get('raftIndex','')}|{st.get('version','')}\")
" 2>/dev/null || true)
  _isldr=$(echo "$_parsed" | cut -d'|' -f1)
  _raft=$(echo "$_parsed" | cut -d'|' -f2)
  _ver=$(echo "$_parsed" | cut -d'|' -f3)
  info "  $_pod: leader=$_isldr raftIndex=$_raft version=$_ver"
  [[ "$_isldr" == "True" ]] && LEADERS=$(( LEADERS + 1 ))
  if [[ -n "$_raft" ]]; then
    [[ -z "$RAFT_MIN" || "$_raft" -lt "$RAFT_MIN" ]] && RAFT_MIN="$_raft"
    [[ -z "$RAFT_MAX" || "$_raft" -gt "$RAFT_MAX" ]] && RAFT_MAX="$_raft"
  fi
  VERSIONS="$VERSIONS $_ver"
done
if [[ "$LEADERS" -eq 1 ]]; then
  pass "exactly one leader across $EXPECTED_REPLICAS members"
else
  fail "$LEADERS leaders found (expected 1) — split brain or no quorum"
fi
if [[ -n "$RAFT_MIN" && -n "$RAFT_MAX" ]]; then
  _delta=$(( RAFT_MAX - RAFT_MIN ))
  info "raftIndex spread: $RAFT_MIN..$RAFT_MAX (delta $_delta, threshold $MAX_RAFT_INDEX_DELTA)"
  if [[ "$_delta" -le "$MAX_RAFT_INDEX_DELTA" ]]; then
    pass "raft indices converged (delta $_delta)"
  else
    fail "raftIndex delta $_delta exceeds $MAX_RAFT_INDEX_DELTA — a member is lagging"
  fi
fi
_uniq_ver=$(echo "$VERSIONS" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
if [[ "$(echo "$_uniq_ver" | wc -w | tr -d ' ')" -eq 1 ]]; then
  pass "all members report the same etcd version ($_uniq_ver)"
else
  fail "members report MIXED etcd versions ($_uniq_ver) — partial rollout"
fi

# ── 29. etcd alarms ───────────────────────────────────────────────────────────
section "29. etcd alarms"
ALARMS=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl alarm list $ETCD_EP $ETCD_TLS 2>/dev/null || true)
if [[ -z "$(echo "$ALARMS" | tr -d '[:space:]')" ]]; then
  pass "no etcd alarms raised (no NOSPACE / CORRUPT)"
else
  fail "etcd alarms are active:"
  echo "$ALARMS" | while read -r line; do info "  $line"; done
fi

# ── 30. etcd image consistency across pods ────────────────────────────────────
# Check 2 reads only the StatefulSet template, so a partial rollout passes it.
section "30. etcd image consistency across running pods"
IMGS=$(kubectl --context "$CTX" get pods -n "$NS" -l app.kubernetes.io/name=etcd \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)
IMG_UNIQ=$(echo "$IMGS" | sort -u)
IMG_N=$(echo "$IMG_UNIQ" | grep -c . || true)
info "$(echo "$IMGS" | grep -c .) etcd pods, $IMG_N distinct image(s)"
echo "$IMG_UNIQ" | while read -r line; do info "  $line"; done
STS_IMG=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ "$IMG_N" -ne 1 ]]; then
  fail "etcd pods run $IMG_N different images — partial rollout / mixed pod state"
elif echo "$IMG_UNIQ" | grep -q "$EXPECTED_ETCD_IMAGE_MATCH"; then
  pass "all etcd pods run the same image matching $EXPECTED_ETCD_IMAGE_MATCH"
  if [[ -n "$STS_IMG" ]] && [[ "$IMG_UNIQ" != "$STS_IMG" ]]; then
    info "NOTE: pod image differs from the StatefulSet template — a registry mirror is rewriting it"
    info "  template: $STS_IMG"
    info "  running:  $IMG_UNIQ"
  fi
else
  fail "etcd pods run an unexpected image (expected repo path to contain $EXPECTED_ETCD_IMAGE_MATCH)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# D. MIGRATION INTEGRITY
# ══════════════════════════════════════════════════════════════════════════════

# ── 31. Old PVC retention (rollback path) ─────────────────────────────────────
section "31. Old PVC retention (rollback path)"
OLD_PVC_N=$(kubectl --context "$CTX" get pvc -n "$NS" --no-headers 2>/dev/null \
  | awk '{print $1}' | grep -E "^data-$STS-[0-9]+$" | grep -c . || true)
info "${OLD_PVC_N:-0} old data-* PVC(s) retained"
if [[ "${OLD_PVC_N:-0}" -ge 1 ]]; then
  pass "$OLD_PVC_N pre-migration PVC(s) retained — rollback path intact"
else
  fail "no pre-migration data-* PVCs remain — the rollback path is GONE. Reverting would need a restore, not a reattach."
fi

# ── 32. etcd startup provenance (informational) ───────────────────────────────
# Captures whether this member bootstrapped fresh or recovered a pre-existing
# member/ directory, and whether the orphaned bitnami data/ dir was seen.
section "32. etcd startup provenance (informational)"
LOG=$(kubectl --context "$CTX" logs -n "$NS" "$STS-0" 2>/dev/null | head -400 || true)
if [[ -z "$LOG" ]]; then
  info "could not read $STS-0 logs (rotated or pod restarted)"
else
  echo "$LOG" | grep -oE '"found invalid file under data directory"[^}]*"filename":"[^"]*"' \
    | grep -oE '"filename":"[^"]*"' | sort -u | while read -r line; do info "orphaned on volume: $line"; done
  _init=$(echo "$LOG" | grep -oE '"member-initialized":(true|false)' | head -1 || true)
  _cid=$(echo "$LOG"  | grep -oE '"cluster-id":"[^"]*"' | head -1 || true)
  _ci=$(echo "$LOG"   | grep -oE '"commit-index":[0-9]+' | head -1 || true)
  _mode=$(echo "$LOG" | grep -oE 'restarting local member|bootstrapping cluster|starting from fresh' | head -1 || true)
  info "${_init:-(member-initialized not logged)}  ${_cid:-}  ${_ci:-}"
  info "start mode: ${_mode:-(not logged)}"
  if echo "$LOG" | grep -q '"member-initialized":true'; then
    info "NOTE: recovered an existing member/ dir — this volume was used by an etcd 3.7.x run before."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# E. CONSUMER HEALTH
# ══════════════════════════════════════════════════════════════════════════════

# ── 33. bulk-konk apiserver readiness ─────────────────────────────────────────
# Check 15 only asserts STATUS=Running, which passes while readiness probes fail
# and the pod restarts reconnecting to the new etcd cluster.
section "33. bulk-konk apiserver readiness"
AS_JSON=$(kubectl --context "$CTX" get pods -n "$NS" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('items',[]):
    n=i['metadata']['name']
    if not n.startswith('$APISERVER_DEPLOY-') : continue
    if 'etcd' in n or 'init' in n: continue
    cs=i.get('status',{}).get('containerStatuses') or []
    ready=sum(1 for c in cs if c.get('ready'))
    rs=sum(c.get('restartCount',0) for c in cs)
    print(f\"{n}|{ready}|{len(cs)}|{rs}\")
" 2>/dev/null || true)
if [[ -z "$AS_JSON" ]]; then
  fail "no $APISERVER_DEPLOY apiserver pod found"
else
  AS_BAD=0
  while IFS='|' read -r _n _r _t _rs; do
    [[ -z "$_n" ]] && continue
    info "  $_n: ready=$_r/$_t restarts=$_rs"
    [[ "$_r" != "$_t" ]] && AS_BAD=$(( AS_BAD + 1 ))
    if [[ "${_rs:-0}" -gt "$MAX_APISERVER_RESTARTS" ]]; then
      info "    restarts exceed threshold $MAX_APISERVER_RESTARTS"
      AS_BAD=$(( AS_BAD + 1 ))
    fi
  done <<< "$AS_JSON"
  if [[ "$AS_BAD" -eq 0 ]]; then
    pass "$APISERVER_DEPLOY apiserver fully Ready, restarts within threshold ($MAX_APISERVER_RESTARTS)"
  else
    fail "$APISERVER_DEPLOY apiserver not fully Ready or restarting excessively — it may still be reconnecting to etcd"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_CHECKS=$(( PASS_COUNT + FAIL_COUNT ))
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        SUMMARY                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Total checks : %-44s║\n" "$TOTAL_CHECKS"
printf "║  Passed       : %-44s║\n" "$PASS_COUNT"
printf "║  Failed       : %-44s║\n" "$FAIL_COUNT"
echo "╠══════════════════════════════════════════════════════════════╣"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo -e "║  ${GREEN}${BOLD}       ✓  ALL CHECKS PASSED — migration successful${RESET}          ║"
else
  echo -e "║  ${RED}${BOLD}       ✗  $FAIL_COUNT CHECK(S) FAILED — investigate above${RESET}          ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo

[[ "$FAIL_COUNT" -eq 0 ]]
