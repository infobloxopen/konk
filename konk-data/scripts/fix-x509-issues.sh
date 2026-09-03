#!/usr/bin/env bash
# fix-x509-issues.sh — Fix x509 CA mismatch after etcd fresh bootstrap
#
# After a fresh etcd bootstrap (e.g. claimName migration), the bulk-konk CA
# rotates but KonkService kubeconfig-cert secrets still embed the old CA.
# This script:
#   1. Deletes stale kubeconfig-cert secrets (cert-manager re-issues with new CA)
#   2. Restarts reconcile-kubeconfig pods (to pick up re-issued certs)
#   3. Restarts stale kubectl-apiservice pods (to use updated kubeconfig)
#   4. Verifies CA matches across all namespaces
#
# Usage:
#   ./fix-x509-issues.sh                    # uses current kubectl context
#   ./fix-x509-issues.sh --context us-dev-5 # explicit context
#   ./fix-x509-issues.sh --dry-run          # show what would be done
#
set -eo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CTX=""
DRY_RUN=false
AGGREGATE_NS="aggregate"
CA_SECRET="bulk-konk-ca"
KONKSERVICE_NAMESPACES=()

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
      echo "  Fixes x509 CA mismatch in KonkService kubeconfig-cert secrets"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Resolve context
if [[ -z "$CTX" ]]; then
  CTX=$(kubectl config current-context)
fi
CTX_FLAG="--context $CTX"
info "Using context: $CTX"

# ── Helper ────────────────────────────────────────────────────────────────────
kc() { kubectl $CTX_FLAG "$@"; }

run_or_dry() {
  if $DRY_RUN; then
    warn "[DRY-RUN] kubectl $CTX_FLAG $*"
  else
    kc "$@"
  fi
}

# ── Step 0: Get current bulk-konk CA fingerprint ──────────────────────────────
info "Reading current bulk-konk CA fingerprint..."
CURRENT_CA_FP=$(kc get secret "$CA_SECRET" -n "$AGGREGATE_NS" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -fingerprint -sha256 -noout 2>/dev/null \
  | sed 's/sha256 Fingerprint=//')

if [[ -z "$CURRENT_CA_FP" ]]; then
  fail "Could not read bulk-konk CA from secret/$CA_SECRET in $AGGREGATE_NS"
  exit 1
fi
info "Current CA: $CURRENT_CA_FP"

# ── Step 0b: Discover KonkService namespaces ──────────────────────────────────
info "Discovering KonkService namespaces..."
while IFS= read -r ns; do
  [[ -n "$ns" ]] && KONKSERVICE_NAMESPACES+=("$ns")
done < <(kc get konkservice -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)

if [[ ${#KONKSERVICE_NAMESPACES[@]} -eq 0 ]]; then
  fail "No KonkService namespaces found"
  exit 1
fi
info "Found ${#KONKSERVICE_NAMESPACES[@]} namespaces: ${KONKSERVICE_NAMESPACES[*]}"

# ── Step 1: Check which namespaces have stale CA ──────────────────────────────
echo
info "═══ Step 1: Checking for stale kubeconfig-cert secrets ═══"
STALE_NAMESPACES=()
for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  certs=$(kc get certificate.cert-manager.io -n "$ns" --no-headers 2>/dev/null | grep kubeconfig | awk '{print $1}')
  for cert in $certs; do
    secret=$(kc get certificate.cert-manager.io "$cert" -n "$ns" -o jsonpath='{.spec.secretName}' 2>/dev/null)
    if [[ -z "$secret" ]]; then continue; fi
    cert_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ -n "$cert_ca" && "$cert_ca" != "$CURRENT_CA_FP" ]]; then
      warn "STALE: $ns/$secret (CA: ${cert_ca:0:20}...)"
      STALE_NAMESPACES+=("$ns")
      break
    fi
  done
done

if [[ ${#STALE_NAMESPACES[@]} -gt 0 ]]; then
  STALE_NAMESPACES=($(printf '%s\n' "${STALE_NAMESPACES[@]}" | sort -u))
fi

if [[ ${#STALE_NAMESPACES[@]} -eq 0 ]]; then
  pass "All kubeconfig-cert secrets have the correct CA — nothing to fix"
  exit 0
fi

warn "${#STALE_NAMESPACES[@]} namespaces with stale CA: ${STALE_NAMESPACES[*]}"

# ── Step 2: Delete stale kubeconfig-cert secrets ──────────────────────────────
echo
info "═══ Step 2: Deleting stale kubeconfig-cert secrets (cert-manager will re-issue) ═══"
DELETED=0
for ns in "${STALE_NAMESPACES[@]}"; do
  kc get certificate.cert-manager.io -n "$ns" --no-headers 2>/dev/null | grep kubeconfig | awk '{print $1}' | while read -r cert; do
    secret=$(kc get certificate.cert-manager.io "$cert" -n "$ns" -o jsonpath='{.spec.secretName}' 2>/dev/null)
    if [[ -n "$secret" ]]; then
      run_or_dry delete secret "$secret" -n "$ns" && info "  Deleted $ns/$secret"
    fi
  done
  DELETED=$((DELETED + 1))
done

# ── Step 3: Wait for cert-manager to re-issue ─────────────────────────────────
echo
info "═══ Step 3: Waiting for cert-manager to re-issue certificates (30s) ═══"
if ! $DRY_RUN; then
  sleep 30
fi

# Verify re-issue
REISSUE_OK=true
for ns in "${STALE_NAMESPACES[@]}"; do
  cert_secret=$(kc get certificate.cert-manager.io -n "$ns" --no-headers 2>/dev/null | grep kubeconfig | head -1 | awk '{print $1}')
  if [[ -z "$cert_secret" ]]; then continue; fi
  secret=$(kc get certificate.cert-manager.io "$cert_secret" -n "$ns" -o jsonpath='{.spec.secretName}' 2>/dev/null)
  new_ca=$(kc get secret "$secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
  if [[ "$new_ca" == "$CURRENT_CA_FP" ]]; then
    pass "  $ns: CA re-issued correctly"
  else
    fail "  $ns: CA still stale (got: ${new_ca:-empty})"
    REISSUE_OK=false
  fi
done

if ! $REISSUE_OK; then
  fail "Some certs not re-issued. cert-manager may need more time or has issues."
  warn "You can re-run this script after waiting."
  exit 1
fi

# ── Step 4: Restart reconcile-kubeconfig pods ─────────────────────────────────
echo
info "═══ Step 4: Restarting reconcile-kubeconfig pods ═══"
for ns in "${STALE_NAMESPACES[@]}"; do
  kc get pods -n "$ns" --no-headers 2>/dev/null | grep 'konk-service-kubeconfig' | awk '{print $1}' | while read -r pod; do
    run_or_dry delete pod "$pod" -n "$ns" --grace-period=5 && info "  Restarted $ns/$pod"
  done
done

# ── Step 5: Wait for kubeconfig secrets to be updated ─────────────────────────
echo
info "═══ Step 5: Waiting for kubeconfig secrets to be updated (30s) ═══"
if ! $DRY_RUN; then
  sleep 30
fi

# ── Step 6: Restart stale kubectl-apiservice pods ─────────────────────────────
echo
info "═══ Step 6: Restarting stale kubectl-apiservice pods (0/1) ═══"
for ns in "${STALE_NAMESPACES[@]}"; do
  kc get pods -n "$ns" --no-headers 2>/dev/null | grep 'kubectl-api' | grep '0/1' | awk '{print $1}' | while read -r pod; do
    run_or_dry delete pod "$pod" -n "$ns" --grace-period=5 && info "  Restarted $ns/$pod"
  done
done

# ── Step 7: Final verification ────────────────────────────────────────────────
echo
info "═══ Step 7: Verification (waiting 45s for pods to start) ═══"
if ! $DRY_RUN; then
  sleep 45
fi

echo
ALL_OK=true
for ns in "${STALE_NAMESPACES[@]}"; do
  # Check kubeconfig secret CA
  kc_secret=$(kc get secret -n "$ns" --no-headers 2>/dev/null | grep 'konk-service-kubeconfig ' | head -1 | awk '{print $1}')
  if [[ -n "$kc_secret" ]]; then
    kc_ca=$(kc get secret "$kc_secret" -n "$ns" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | sed 's/sha256 Fingerprint=//')
    if [[ "$kc_ca" == "$CURRENT_CA_FP" ]]; then
      pass "$ns: kubeconfig CA matches ✓"
    else
      fail "$ns: kubeconfig CA still stale"
      ALL_OK=false
    fi
  fi

  # Check kubectl-apiservice pods
  still_failing=$(kc get pods -n "$ns" --no-headers 2>/dev/null | grep 'kubectl-api' | grep '0/1' | wc -l | tr -d ' ')
  total=$(kc get pods -n "$ns" --no-headers 2>/dev/null | grep 'kubectl-api' | wc -l | tr -d ' ')
  if [[ "$still_failing" -eq 0 && "$total" -gt 0 ]]; then
    pass "$ns: all kubectl-apiservice pods ready ($total/$total)"
  elif [[ "$still_failing" -gt 0 ]]; then
    warn "$ns: $still_failing/$total kubectl-apiservice pods still 0/1 (may need more time)"
  fi
done

echo
if $ALL_OK; then
  pass "═══ All x509 CA issues fixed ═══"
else
  warn "═══ Some issues remain — pods may need more startup time or have other problems ═══"
  warn "Re-run with no args to check again, or investigate manually."
fi