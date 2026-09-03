#!/bin/bash
# Pre-Upgrade Checks — etcd claimName Migration (bitnami → cgr.dev)
# Run BEFORE merging the DC PR / triggering the etcd chart upgrade.
# Every check prints [PASS], [FAIL] or [WARN]. Script exits 1 if any check fails;
# [WARN] is advisory only and does not fail the run.

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
CTX="${CTX:-$(kubectl config current-context 2>/dev/null || true)}"
if [[ -z "$CTX" ]]; then
  echo "ERROR: CTX is empty. Set CTX=<cluster> or configure kubectl current-context."
  exit 1
fi
NS="${NS:-aggregate}"
STS="${STS:-bulk-konk-etcd}"
EXPECTED_OPERATOR_VERSION="${EXPECTED_OPERATOR_VERSION:-v0.2.1-138-g8b64bf7-j170}"
ETCD_CERTS_DIR="${ETCD_CERTS_DIR:-/opt/bitnami/etcd/certs/client}"
ETCD_TLS="--cacert=$ETCD_CERTS_DIR/ca.crt --cert=$ETCD_CERTS_DIR/server.crt --key=$ETCD_CERTS_DIR/server.key"
ETCD_EP="--endpoints=https://localhost:2379"
KARPENTER_NS="${KARPENTER_NS:-ib-system}"
STABLE_NODEPOOL="${STABLE_NODEPOOL:-stable-node-pool}"

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${RESET} $*"; (( PASS_COUNT++ )); }
fail() { echo -e "  ${RED}[FAIL]${RESET} $*"; (( FAIL_COUNT++ )); }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; (( WARN_COUNT++ )); }
info() { echo -e "  ${YELLOW}[INFO]${RESET} $*"; }
section() { echo; echo -e "${CYAN}${BOLD}── $* ──${RESET}"; }

# ── Header ────────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         PRE-UPGRADE CHECKS — etcd claimName Migration       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Cluster : %-50s║\n" "$CTX"
printf "║  NS      : %-50s║\n" "$NS"
printf "║  STS     : %-50s║\n" "$STS"
printf "║  Date    : %-50s║\n" "$(date)"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── 1. Operator ───────────────────────────────────────────────────────────────
section "1. konk-operator"
OPERATOR_IMAGE=$(kubectl --context "$CTX" get deploy -n konk \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
  2>/dev/null | grep -i operator | awk '{print $2}' || true)
OPERATOR_RUNNING=$(kubectl --context "$CTX" get pods -n konk \
  -l app.kubernetes.io/name=konk-operator --no-headers 2>/dev/null | grep -c "Running" || echo 0)

info "Image: ${OPERATOR_IMAGE:-(not found)}"
if [[ "$OPERATOR_RUNNING" -gt 0 ]]; then
  pass "konk-operator pod is Running"
else
  fail "konk-operator pod is NOT Running"
fi
if echo "$OPERATOR_IMAGE" | grep -q "$EXPECTED_OPERATOR_VERSION"; then
  pass "konk-operator version is the expected prod baseline ($EXPECTED_OPERATOR_VERSION)"
else
  fail "konk-operator version mismatch — expected '$EXPECTED_OPERATOR_VERSION', got '${OPERATOR_IMAGE:-(not found)}'"
fi

# ── 2. Konk CR status ─────────────────────────────────────────────────────────
section "2. KonK CR (bulk-konk)"
KONK_DEPLOYED=$(kubectl --context "$CTX" get konk.konk.infoblox.com bulk-konk -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || true)
KONK_REASON=$(kubectl --context "$CTX" get konk.konk.infoblox.com bulk-konk -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null || true)
KONK_FAILED=$(kubectl --context "$CTX" get konk.konk.infoblox.com bulk-konk -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)

info "Deployed=$KONK_DEPLOYED reason=$KONK_REASON ReleaseFailed=$KONK_FAILED"
if [[ "$KONK_DEPLOYED" == "True" && "$KONK_FAILED" != "True" ]]; then
  pass "KonK CR is deployed and healthy"
else
  fail "KonK CR is NOT healthy (Deployed=$KONK_DEPLOYED, ReleaseFailed=$KONK_FAILED)"
fi

# ── 3. Etcd CR status ─────────────────────────────────────────────────────────
section "3. Etcd CR ($STS)"
ETCD_DEPLOYED=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null || true)
ETCD_REASON=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null || true)
ETCD_FAILED=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}' 2>/dev/null || true)

info "Deployed=$ETCD_DEPLOYED reason=$ETCD_REASON ReleaseFailed=$ETCD_FAILED"
if [[ "$ETCD_DEPLOYED" == "True" && "$ETCD_FAILED" != "True" ]]; then
  pass "Etcd CR is deployed and healthy"
else
  fail "Etcd CR is NOT healthy (Deployed=$ETCD_DEPLOYED, ReleaseFailed=$ETCD_FAILED)"
fi

# ── 4. recreateStatefulSet flag ───────────────────────────────────────────────
section "4. recreateStatefulSet flag"
HOOK=$(kubectl --context "$CTX" get etcds.konk.infoblox.com "$STS" -n "$NS" \
  -o jsonpath='{.spec.recreateStatefulSet.enabled}' 2>/dev/null || true)
info "recreateStatefulSet.enabled=${HOOK:-(not set)}"
if [[ -z "$HOOK" || "$HOOK" == "false" ]]; then
  pass "recreateStatefulSet is not set — correct prod baseline state"
else
  fail "recreateStatefulSet is already set to '$HOOK' — cluster may be in a partially upgraded state"
fi

# ── 5. StatefulSet VCT (must be 'data', not 'data-v2') ───────────────────────
section "5. StatefulSet volumeClaimTemplate name"
VCT=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)
info "Current VCT claim name: '${VCT:-(not found)}'"
if [[ "$VCT" == "data" ]]; then
  pass "VCT is 'data' — correct pre-upgrade state (bitnami PVCs)"
elif [[ "$VCT" == "data-v2" ]]; then
  fail "VCT is already 'data-v2' — migration may already be done or cluster is in a partially upgraded state"
else
  fail "VCT is '${VCT}' — unexpected value"
fi

# ── 6. PVC check — must have 'data-*' PVCs, must NOT have 'data-v2-*' ────────
section "6. PVC state"
DATA_PVCS=$(kubectl --context "$CTX" get pvc -n "$NS" --no-headers 2>/dev/null \
  | grep "data-${STS}" | grep -v "data-v2" || true)
DATA_V2_PVCS=$(kubectl --context "$CTX" get pvc -n "$NS" --no-headers 2>/dev/null \
  | grep "data-v2-${STS}" || true)
DATA_PVC_COUNT=0
[[ -n "$DATA_PVCS" ]] && DATA_PVC_COUNT=$(echo "$DATA_PVCS" | grep -c .)
DATA_V2_PVC_COUNT=0
[[ -n "$DATA_V2_PVCS" ]] && DATA_V2_PVC_COUNT=$(echo "$DATA_V2_PVCS" | grep -c .)

info "data-* PVCs (expected pre-upgrade):"
if [[ -n "$DATA_PVCS" ]]; then
  echo "$DATA_PVCS" | while read -r line; do info "  $line"; done
else
  info "  (none found)"
fi
info "data-v2-* PVCs (must NOT exist pre-upgrade):"
if [[ -n "$DATA_V2_PVCS" ]]; then
  echo "$DATA_V2_PVCS" | while read -r line; do info "  $line"; done
else
  info "  (none found)"
fi

if [[ "$DATA_PVC_COUNT" -gt 0 ]]; then
  pass "data-* PVCs exist ($DATA_PVC_COUNT found) — bitnami PVCs present as expected"
else
  fail "No data-* PVCs found — etcd may not have persistent storage"
fi

if [[ "$DATA_V2_PVC_COUNT" -eq 0 ]]; then
  pass "No data-v2-* PVCs exist — clean pre-upgrade state"
else
  fail "Found $DATA_V2_PVC_COUNT data-v2-* PVC(s) — these must be deleted before upgrading (stale data from previous attempt)"
fi

# ── 7. StatefulSet replicas ready ────────────────────────────────────────────
section "7. StatefulSet replicas"
READY=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
TOTAL=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)
ETCD_IMAGE=$(kubectl --context "$CTX" get sts "$STS" -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

info "Replicas: $READY/$TOTAL ready"
info "Image:    ${ETCD_IMAGE:-(not found)}"
if [[ "$READY" -gt 0 && "$READY" == "$TOTAL" ]]; then
  pass "All $READY/$TOTAL replicas are ready"
else
  fail "Replicas not fully ready ($READY/$TOTAL)"
fi

# ── 8. Helm release stable ────────────────────────────────────────────────────
section "8. Helm release stability"
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
  pass "Helm release is stable (status=deployed)"
else
  fail "Helm release is NOT stable (status=${LAST_STATUS:-(unknown)})"
fi

# ── 9. etcd health ───────────────────────────────────────────────────────────
section "9. etcd cluster health"
HEALTH_OUT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl endpoint health $ETCD_EP $ETCD_TLS 2>&1 || true)
info "$HEALTH_OUT"
if echo "$HEALTH_OUT" | grep -q "is healthy"; then
  pass "etcd endpoint is healthy"
else
  fail "etcd endpoint health check failed"
fi

# ── 10. etcd members ──────────────────────────────────────────────────────────
section "10. etcd cluster members"
MEMBER_OUT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl member list -w table $ETCD_EP $ETCD_TLS 2>&1 || true)
MEMBER_COUNT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl member list $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . || echo 0)
info "$MEMBER_OUT"
if [[ "$MEMBER_COUNT" -eq "$TOTAL" ]]; then
  pass "etcd member count ($MEMBER_COUNT) matches StatefulSet replicas ($TOTAL)"
else
  fail "etcd member count ($MEMBER_COUNT) does NOT match StatefulSet replicas ($TOTAL)"
fi

# ── 11. etcd baseline key count (informational) ───────────────────────────────
section "11. etcd baseline (informational)"
KEY_COUNT=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . || echo 0)
ETCD_STATUS=$(kubectl --context "$CTX" exec -n "$NS" "$STS-0" -- \
  etcdctl endpoint status -w table $ETCD_EP $ETCD_TLS 2>&1 || true)
info "Key count: $KEY_COUNT (record this as baseline)"
info "$ETCD_STATUS"

# ── 12. Stale hook resources ──────────────────────────────────────────────────
section "12. Stale hook resources"
STALE=$(kubectl --context "$CTX" get job,sa,role,rolebinding -n "$NS" 2>/dev/null \
  | grep -i recreate || true)
if [[ -z "$STALE" ]]; then
  pass "No stale recreate hook resources found"
else
  fail "Stale hook resources found — clean these up before upgrading:"
  echo "$STALE" | while read -r line; do info "  $line"; done
fi

# ── 13. Karpenter + stable-node-pool ─────────────────────────────────────────
section "13. Karpenter & stable-node-pool"
KARPENTER_DEPLOY=$(kubectl --context "$CTX" get deploy -n "$KARPENTER_NS" --no-headers 2>/dev/null \
  | grep -i karpenter || true)
KARPENTER_PODS=$(kubectl --context "$CTX" get pods -n "$KARPENTER_NS" --no-headers 2>/dev/null \
  | grep -i karpenter || true)
KARPENTER_READY=$(echo "$KARPENTER_DEPLOY" | awk '{split($2,a,"/"); if (a[1]>0 && a[1]==a[2]) c++} END {print c+0}')

info "Namespace: $KARPENTER_NS"
if [[ -n "$KARPENTER_DEPLOY" ]]; then
  echo "$KARPENTER_DEPLOY" | while read -r line; do info "  deploy/$line"; done
else
  info "  (no karpenter deployment found)"
fi
if [[ -n "$KARPENTER_PODS" ]]; then
  echo "$KARPENTER_PODS" | while read -r line; do info "  pod/$line"; done
else
  info "  (no karpenter pods found)"
fi

if [[ -z "$KARPENTER_DEPLOY" ]]; then
  fail "Karpenter deployment not found in namespace '$KARPENTER_NS' — node provisioning will not happen during the rollout"
elif [[ "$KARPENTER_READY" -gt 0 ]]; then
  pass "Karpenter deployment is Ready ($KARPENTER_READY ready deploy(s) in $KARPENTER_NS)"
else
  fail "Karpenter deployment exists but has no ready replicas — etcd pods may stay Pending if a new node is needed"
fi

# stable-node-pool: konk etcd uses a soft node affinity + do-not-disrupt toleration
# for this pool. It is optional — clusters without it rely on the PDB alone.
NODEPOOL_LINE=$(kubectl --context "$CTX" get nodepools.karpenter.sh --no-headers 2>/dev/null \
  | grep "^${STABLE_NODEPOOL}[[:space:]]" || true)
NODEPOOL_READY=$(kubectl --context "$CTX" get nodepools.karpenter.sh "$STABLE_NODEPOOL" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
NODEPOOL_NODES=$(kubectl --context "$CTX" get nodes \
  -l karpenter.sh/nodepool="$STABLE_NODEPOOL" --no-headers 2>/dev/null | grep -c . || echo 0)

if [[ -n "$NODEPOOL_LINE" ]]; then
  info "nodepool/$NODEPOOL_LINE"
  info "Nodes currently in '$STABLE_NODEPOOL': $NODEPOOL_NODES"
fi

if [[ -z "$NODEPOOL_LINE" ]]; then
  warn "NodePool '$STABLE_NODEPOOL' does NOT exist on this cluster — konk's stable-pool node affinity and do-not-disrupt toleration are inert here; only the etcd PDB protects quorum during the rollout"
elif [[ "$NODEPOOL_READY" == "True" ]]; then
  pass "NodePool '$STABLE_NODEPOOL' exists and is Ready ($NODEPOOL_NODES node(s))"
else
  fail "NodePool '$STABLE_NODEPOOL' exists but is not Ready (Ready=${NODEPOOL_READY:-unknown})"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_CHECKS=$(( PASS_COUNT + FAIL_COUNT ))
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                     SUMMARY                                 ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Total checks : %-44s║\n" "$TOTAL_CHECKS"
printf "║  Passed       : %-44s║\n" "$PASS_COUNT"
printf "║  Failed       : %-44s║\n" "$FAIL_COUNT"
printf "║  Warnings     : %-44s║\n" "$WARN_COUNT"
echo "╠══════════════════════════════════════════════════════════════╣"
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo -e "║  ${GREEN}${BOLD}       ✓  ALL CHECKS PASSED — safe to upgrade${RESET}              ║"
else
  echo -e "║  ${RED}${BOLD}       ✗  $FAIL_COUNT CHECK(S) FAILED — DO NOT upgrade yet${RESET}          ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo

[[ "$FAIL_COUNT" -eq 0 ]]
