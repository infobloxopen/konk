#!/usr/bin/env bash
# fix-ca-mismatch.sh — Fix x509 CA mismatch after konk CA rotation
#
# When the konk provision container regenerates the CA (e.g. during upgrades where
# the apiserver-cert secret was missing), the kubeconfig-cert secrets issued by
# cert-manager still embed the old CA. This script:
#   1. Detects stale kubeconfig-cert secrets (CA doesn't match bulk-konk-ca)
#   2. Deletes them (cert-manager re-issues with the new CA via ClusterIssuer)
#   3. Restarts reconcile-kubeconfig pods (propagates new CA to kubeconfig secrets)
#   4. Restarts kubectl-apiservice deployments (pods cache CA at startup)
#   5. Verifies CA matches across all namespaces
#
# Usage:
#   ./fix-ca-mismatch.sh --context teleport.services.sdp.infoblox.com-us-dev-4
#   ./fix-ca-mismatch.sh --context us-dev-4 --dry-run
#   ./fix-ca-mismatch.sh                     # uses current kubectl context
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CTX=""
DRY_RUN=false
AGGREGATE_NS="aggregate"
CA_SECRET="bulk-konk-ca"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--context <ctx>] [--dry-run]"
      echo ""
      echo "Fixes x509 CA mismatch in KonkService kubeconfig-cert secrets."
      echo "After a konk CA rotation, cert-manager-issued certs still embed"
      echo "the old CA. This script forces re-issuance and restarts affected pods."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CTX" ]]; then
  CTX=$(kubectl config current-context)
fi
info "Using context: $CTX"
if $DRY_RUN; then
  warn "DRY-RUN mode — no changes will be made"
fi

# ── Helper ────────────────────────────────────────────────────────────────────
kc() { kubectl --context "$CTX" "$@"; }

run_or_dry() {
  if $DRY_RUN; then
    warn "[DRY-RUN] kubectl --context $CTX $*"
  else
    kc "$@"
  fi
}

# ── Step 0: Get current bulk-konk CA fingerprint ──────────────────────────────
echo
info "═══ Step 0: Reading current bulk-konk CA ═══"
CURRENT_CA_FP=$(kc get secret "$CA_SECRET" -n "$AGGREGATE_NS" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')

if [[ -z "$CURRENT_CA_FP" ]]; then
  fail "Could not read bulk-konk CA from secret/$CA_SECRET in $AGGREGATE_NS"
  exit 1
fi
info "Current CA: ${CURRENT_CA_FP:0:40}..."

# ── Step 0b: Discover KonkService namespaces ──────────────────────────────────
KONKSERVICE_NAMESPACES=()
while IFS= read -r ns; do
  [[ -n "$ns" ]] && KONKSERVICE_NAMESPACES+=("$ns")
done < <(kc get konkservice -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)

if [[ ${#KONKSERVICE_NAMESPACES[@]} -eq 0 ]]; then
  fail "No KonkService namespaces found"
  exit 1
fi
info "Found ${#KONKSERVICE_NAMESPACES[@]} KonkService namespaces: ${KONKSERVICE_NAMESPACES[*]}"

# ── Step 1: Check which namespaces have stale CA ──────────────────────────────
echo
info "═══ Step 1: Checking for stale kubeconfig-cert secrets ═══"
declare -A STALE_SECRETS  # ns → space-separated list of stale secret names
ALL_MATCH=true

for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  certs=$(kc get certificate.cert-manager.io -n "$ns" --no-headers 2>/dev/null | grep kubeconfig | awk '{print $1}')
  for cert in $certs; do
    secret=$(kc get certificate.cert-manager.io "$cert" -n "$ns" -o jsonpath='{.spec.secretName}' 2>/dev/null)
    if [[ -z "$secret" ]]; then continue; fi
    cert_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | \
      openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ -z "$cert_ca" ]]; then
      warn "  $ns/$secret: no ca.crt found (may already be deleted)"
    elif [[ "$cert_ca" != "$CURRENT_CA_FP" ]]; then
      warn "  STALE: $ns/$secret (CA: ${cert_ca:0:20}...)"
      STALE_SECRETS[$ns]="${STALE_SECRETS[$ns]:-} $secret"
      ALL_MATCH=false
    else
      pass "  $ns/$secret: CA matches"
    fi
  done
done

if $ALL_MATCH; then
  pass "All kubeconfig-cert secrets already have the correct CA — nothing to fix"
  exit 0
fi

# ── Step 2: Delete stale kubeconfig-cert secrets ──────────────────────────────
echo
info "═══ Step 2: Deleting stale kubeconfig-cert secrets (cert-manager will re-issue) ═══"
for ns in "${!STALE_SECRETS[@]}"; do
  for secret in ${STALE_SECRETS[$ns]}; do
    info "  Deleting $ns/$secret"
    run_or_dry delete secret "$secret" -n "$ns"
  done
done

# ── Step 3: Wait for cert-manager to re-issue ─────────────────────────────────
echo
info "═══ Step 3: Waiting for cert-manager to re-issue certificates (25s) ═══"
if ! $DRY_RUN; then
  sleep 25
fi

# Verify re-issue
REISSUE_OK=true
for ns in "${!STALE_SECRETS[@]}"; do
  for secret in ${STALE_SECRETS[$ns]}; do
    new_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | \
      openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ "$new_ca" == "$CURRENT_CA_FP" ]]; then
      pass "  $ns/$secret: re-issued with correct CA"
    elif [[ -z "$new_ca" ]]; then
      fail "  $ns/$secret: not yet re-issued (cert-manager may need more time)"
      REISSUE_OK=false
    else
      fail "  $ns/$secret: CA still stale (got: ${new_ca:0:20}...)"
      REISSUE_OK=false
    fi
  done
done

if ! $REISSUE_OK; then
  fail "Some certs not re-issued. Waiting 30s more..."
  if ! $DRY_RUN; then
    sleep 30
    # retry check
    for ns in "${!STALE_SECRETS[@]}"; do
      for secret in ${STALE_SECRETS[$ns]}; do
        new_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | \
          openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
        if [[ "$new_ca" != "$CURRENT_CA_FP" ]]; then
          fail "  $ns/$secret: STILL stale after 55s — cert-manager issue?"
        fi
      done
    done
  fi
fi

# ── Step 4: Restart reconcile-kubeconfig pods ─────────────────────────────────
echo
info "═══ Step 4: Restarting reconcile-kubeconfig pods ═══"
for ns in "${!STALE_SECRETS[@]}"; do
  deploys=$(kc get deploy -n "$ns" --no-headers 2>/dev/null | grep 'konk-service-kubeconfig' | awk '{print $1}')
  for d in $deploys; do
    info "  Restarting $ns/$d"
    run_or_dry rollout restart deploy "$d" -n "$ns"
  done
done

# ── Step 5: Wait for kubeconfig secrets to be updated ─────────────────────────
echo
info "═══ Step 5: Waiting for kubeconfig secrets to be updated (35s) ═══"
if ! $DRY_RUN; then
  sleep 35
fi

# Verify kubeconfig secrets
KC_OK=true
for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  for secret in $(kc get secret -n "$ns" --no-headers 2>/dev/null | grep 'konk-service-kubeconfig ' | awk '{print $1}'); do
    kc_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | \
      openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ "$kc_ca" == "$CURRENT_CA_FP" ]]; then
      pass "  $ns/$secret: CA matches"
    else
      fail "  $ns/$secret: CA mismatch (got: ${kc_ca:0:20}...)"
      KC_OK=false
    fi
  done
done

if ! $KC_OK; then
  warn "Some kubeconfig secrets not yet updated — reconcile-kubeconfig may need more time"
fi

# ── Step 6: Restart kubectl-apiservice deployments ────────────────────────────
echo
info "═══ Step 6: Restarting kubectl-apiservice deployments (pods cache CA at startup) ═══"
for ns in "${!STALE_SECRETS[@]}"; do
  deploys=$(kc get deploy -n "$ns" --no-headers 2>/dev/null | \
    grep -E 'apiservice.*konk|konk.*apiservice' | grep -v test | grep -v kubeconfig | awk '{print $1}')
  for d in $deploys; do
    info "  Restarting $ns/$d"
    run_or_dry rollout restart deploy "$d" -n "$ns"
  done
done

# ── Step 7: Final verification ────────────────────────────────────────────────
echo
info "═══ Step 7: Waiting for pods to restart (45s) ═══"
if ! $DRY_RUN; then
  sleep 45
fi

echo
info "═══ Final verification ═══"
ALL_OK=true
for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  # Check kubeconfig secret CA
  for secret in $(kc get secret -n "$ns" --no-headers 2>/dev/null | grep 'konk-service-kubeconfig ' | awk '{print $1}'); do
    kc_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | \
      openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ "$kc_ca" == "$CURRENT_CA_FP" ]]; then
      pass "$ns/$secret: CA matches ✓"
    else
      fail "$ns/$secret: CA still stale"
      ALL_OK=false
    fi
  done

  # Check for x509 errors in recent logs
  x509_errors=$(kc logs -n "$ns" -l app.kubernetes.io/component=kubectl-apiservice --since=1m --tail=50 2>/dev/null | grep -c "x509\|certificate signed by unknown" || true)
  if [[ "$x509_errors" -eq 0 ]]; then
    pass "$ns: no x509 errors in last 1min"
  else
    fail "$ns: $x509_errors x509 error(s) in last 1min"
    ALL_OK=false
  fi
done

echo
if $ALL_OK; then
  pass "═══ CA mismatch fixed — all namespaces healthy ═══"
else
  warn "═══ Some issues remain — pods may need more startup time ═══"
  warn "Re-run the script to check again, or investigate manually."
  exit 1
fi
