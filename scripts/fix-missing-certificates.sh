#!/usr/bin/env bash
# fix-missing-certificates.sh — Detect and fix missing cert-manager Certificate CRs
#
# PROBLEM:
#   Certificate CRs have been deleted from the cluster (e.g. CRD reinstall,
#   cert-manager upgrade, or accidental cleanup) while the kubeconfig-cert secrets
#   remain. Without the Certificate CR, cert-manager has no instruction to renew
#   the secret. The cert inside the secret expires (12hr TTL) and is never replaced.
#
# HOW IT MANIFESTS:
#   - bulk-konk apiserver logs: "certificate has expired or is not yet valid"
#   - Multiple distinct expired cert serial numbers (each from a different namespace)
#   - Certs expired at different dates (each was the last cert issued before the
#     Certificate CR disappeared)
#   - Pods are new (restarted recently) but still present expired certs because
#     the SECRET ITSELF contains the expired cert — pods read from the secret volume
#     correctly, the problem is the secret was never renewed.
#
# THIS IS NOT A POD MEMORY CACHING ISSUE:
#   Pods mount the kubeconfig-cert secret as a volume. Kubelet syncs the volume
#   contents when the secret changes (~60s). But since cert-manager never updates
#   the secret (no Certificate CR exists), the volume always has the expired cert.
#
# RELATED: fix-x509-issues.sh (different issue — CA mismatch after etcd re-bootstrap)
#
# This script:
#   1. Detects kubeconfig-cert secrets that have cert-manager annotations but no
#      corresponding Certificate CR
#   2. Extracts Certificate manifests from the Helm release secrets
#   3. Applies them to restore cert-manager auto-renewal
#
# Usage:
#   ./fix-missing-certificates.sh                    # dry run using current context
#   ./fix-missing-certificates.sh --context gov-stg-2 # dry run with explicit context
#   ./fix-missing-certificates.sh --apply            # actually recreate Certificate CRs
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CTX=""
APPLY=false
AGGREGATE_NS="aggregate"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) APPLY=false; shift ;;
    -h|--help)
      echo "Usage: $0 [--context <ctx>] [--apply]"
      echo ""
      echo "  Detects missing cert-manager Certificate CRs for konk-service"
      echo "  kubeconfig-cert secrets and recreates them from Helm release data."
      echo ""
      echo "  Default mode is dry run. Pass --apply to recreate Certificate CRs."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Resolve context
if [[ -n "$CTX" ]]; then
  # Try matching partial context name
  FULL_CTX=$(kubectl config get-contexts -o name 2>/dev/null | grep "$CTX" | head -1)
  if [[ -z "$FULL_CTX" ]]; then
    fail "No context matching '$CTX'"
    exit 1
  fi
  KC="kubectl --context=$FULL_CTX"
else
  FULL_CTX=$(kubectl config current-context)
  KC="kubectl"
fi

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD} Fix Missing Certificate CRs${NC}"
echo -e "${BOLD}================================================================${NC}"
echo "  Cluster:  $FULL_CTX"
echo "  Mode:     $(if $APPLY; then echo -e "${RED}APPLY${NC}"; else echo -e "${GREEN}DRY RUN${NC}"; fi)"
echo "  Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# ── Step 1: Discover KonkService namespaces ───────────────────────────────────
header "1. Discovering KonkService namespaces"

KONKSERVICE_NAMESPACES=()
while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  [[ -n "$ns" ]] && KONKSERVICE_NAMESPACES+=("$ns")
done < <($KC get konkservice -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)

if [[ ${#KONKSERVICE_NAMESPACES[@]} -eq 0 ]]; then
  fail "No KonkService namespaces found"
  exit 1
fi
info "Found ${#KONKSERVICE_NAMESPACES[@]} namespace(s): ${KONKSERVICE_NAMESPACES[*]}"

# ── Step 2: Check for missing Certificate CRs ────────────────────────────────
header "2. Checking for missing Certificate CRs"

MISSING_CERTS=()
EXPIRED_SECRETS=()
EXPIRING_SOON_SECRETS=()
VALID_SECRETS=()
NOW_EPOCH=$(date +%s)

for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  # Find kubeconfig-cert secrets with cert-manager annotations
  secrets=$($KC -n "$ns" get secrets -o json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for item in data.get('items',[]):
    name=item['metadata']['name']
    ann=item.get('metadata',{}).get('annotations',{}) or {}
    if 'cert-manager.io/certificate-name' in ann and 'kubeconfig-cert' in name:
        cert_name=ann['cert-manager.io/certificate-name']
        print(f'{name}|{cert_name}')
" 2>/dev/null || true)

  for entry in $secrets; do
    secret_name=$(echo "$entry" | cut -d'|' -f1)
    cert_name=$(echo "$entry" | cut -d'|' -f2)

    # Check if Certificate CR exists
    if ! $KC -n "$ns" get certificate "$cert_name" &>/dev/null; then
      MISSING_CERTS+=("$ns/$cert_name")

      # Check cert expiry
      expiry_str=$($KC -n "$ns" get secret "$secret_name" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [[ -n "$expiry_str" ]]; then
        expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_str" +%s 2>/dev/null || date -d "$expiry_str" +%s 2>/dev/null || echo "0")
        remaining=$(( expiry_epoch - NOW_EPOCH ))
        hours_remaining=$(( remaining / 3600 ))

        if [[ $remaining -le 0 ]]; then
          EXPIRED_SECRETS+=("$ns/$secret_name (EXPIRED $(( -remaining / 3600 ))hrs ago)")
          fail "$ns/$secret_name: Certificate CR '$cert_name' MISSING — cert EXPIRED $(( -remaining / 3600 ))hrs ago"
        elif [[ $remaining -le 21600 ]]; then  # 6 hours
          EXPIRING_SOON_SECRETS+=("$ns/$secret_name (expires in ${hours_remaining}hrs)")
          warn "$ns/$secret_name: Certificate CR '$cert_name' MISSING — cert expires in ${hours_remaining}hrs"
        else
          VALID_SECRETS+=("$ns/$secret_name (valid ${hours_remaining}hrs)")
          warn "$ns/$secret_name: Certificate CR '$cert_name' MISSING — cert valid ${hours_remaining}hrs (but won't renew!)"
        fi
      else
        MISSING_CERTS+=("$ns/$cert_name")
        fail "$ns/$secret_name: Certificate CR '$cert_name' MISSING — cannot read cert"
      fi
    fi
  done
done

echo ""
info "Summary: ${#MISSING_CERTS[@]} missing Certificate CR(s)"
[[ ${#EXPIRED_SECRETS[@]} -gt 0 ]] && fail "  Expired: ${#EXPIRED_SECRETS[@]}"
[[ ${#EXPIRING_SOON_SECRETS[@]} -gt 0 ]] && warn "  Expiring soon (<6hrs): ${#EXPIRING_SOON_SECRETS[@]}"
[[ ${#VALID_SECRETS[@]} -gt 0 ]] && info "  Valid (but won't renew): ${#VALID_SECRETS[@]}"

if [[ ${#MISSING_CERTS[@]} -eq 0 ]]; then
  pass "All kubeconfig-cert secrets have corresponding Certificate CRs"
  exit 0
fi

# ── Step 3: Extract Certificate manifests from Helm releases ──────────────────
header "3. Extracting Certificate manifests from Helm releases"

CERT_MANIFESTS_DIR=$(mktemp -d)
EXTRACTED_COUNT=0

for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  # Find Helm release secrets for this namespace
  helm_secrets=$($KC -n "$ns" get secrets -l owner=helm --sort-by='.metadata.creationTimestamp' --no-headers 2>/dev/null | awk '{print $1}' | tail -5)

  for hs in $helm_secrets; do
    # Decode Helm release and extract Certificate manifests
    $KC -n "$ns" get secret "$hs" -o jsonpath='{.data.release}' 2>/dev/null | base64 -d | base64 -d 2>/dev/null | gunzip 2>/dev/null | python3 -c "
import json,sys,re
try:
    data=json.load(sys.stdin)
    manifest=data.get('manifest','')
    # Split by --- and find Certificate resources
    docs=manifest.split('---')
    for doc in docs:
        if 'kind: Certificate' in doc and 'kubeconfig' in doc:
            # Remove Helm ownership annotations that would conflict
            # Keep the manifest as-is for kubectl apply
            print('---')
            print(doc.strip())
except:
    pass
" 2>/dev/null > "${CERT_MANIFESTS_DIR}/${ns}-certs.yaml" || true

    # Check if we got anything
    if [[ -s "${CERT_MANIFESTS_DIR}/${ns}-certs.yaml" ]]; then
      count=$(grep -c "kind: Certificate" "${CERT_MANIFESTS_DIR}/${ns}-certs.yaml" 2>/dev/null || echo "0")
      if [[ "$count" -gt 0 ]]; then
        info "$ns: extracted $count Certificate manifest(s) from Helm release '$hs'"
        EXTRACTED_COUNT=$((EXTRACTED_COUNT + count))
        break  # Use the first (latest) release that has certs
      fi
    fi
  done
done

echo ""
if [[ $EXTRACTED_COUNT -eq 0 ]]; then
  fail "Could not extract any Certificate manifests from Helm releases"
  echo ""
  warn "Alternative: manually trigger operator reconcile by deleting Helm release secrets:"
  for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
    helm_secret=$($KC -n "$ns" get secrets -l owner=helm --sort-by='.metadata.creationTimestamp' --no-headers 2>/dev/null | awk '{print $1}' | tail -1)
    [[ -n "$helm_secret" ]] && echo "  kubectl -n $ns delete secret $helm_secret"
  done
  rm -rf "$CERT_MANIFESTS_DIR"
  exit 1
fi

info "Total: $EXTRACTED_COUNT Certificate manifest(s) extracted"

# ── Step 4: Apply or display manifests ────────────────────────────────────────
header "4. $(if $APPLY; then echo 'Applying'; else echo 'Would apply'; fi) Certificate CRs"

APPLIED=0
FAILED=0

for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
  manifest_file="${CERT_MANIFESTS_DIR}/${ns}-certs.yaml"
  [[ ! -s "$manifest_file" ]] && continue

  if $APPLY; then
    if $KC apply -f "$manifest_file" 2>&1; then
      count=$(grep -c "kind: Certificate" "$manifest_file" 2>/dev/null || echo "0")
      APPLIED=$((APPLIED + count))
      pass "$ns: applied $count Certificate CR(s)"
    else
      FAILED=$((FAILED + 1))
      fail "$ns: failed to apply Certificate CRs"
    fi
  else
    info "$ns: would apply:"
    grep -E "name:|namespace:|secretName:|issuerRef:" "$manifest_file" 2>/dev/null | sed 's/^/    /'
  fi
done

echo ""
if $APPLY; then
  if [[ $FAILED -eq 0 ]]; then
    pass "Applied $APPLIED Certificate CR(s) — cert-manager will now auto-renew"
  else
    warn "Applied some but $FAILED namespace(s) failed"
  fi

  # ── Step 5: Verify renewal ────────────────────────────────────────────────
  header "5. Verifying cert-manager picks up the new Certificate CRs"
  info "Waiting 15s for cert-manager to process..."
  sleep 15

  renewed=0
  for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
    certs=$($KC -n "$ns" get certificate --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$($KC -n "$ns" get certificate -o json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
count=0
for item in data.get('items',[]):
    for cond in item.get('status',{}).get('conditions',[]):
        if cond.get('type')=='Ready' and cond.get('status')=='True':
            count+=1
print(count)
" 2>/dev/null || echo "0")
    if [[ "$ready" -gt 0 ]]; then
      pass "$ns: $ready/$certs Certificate(s) Ready"
      renewed=$((renewed + ready))
    elif [[ "$certs" -gt 0 ]]; then
      warn "$ns: $certs Certificate(s) created but not yet Ready (cert-manager processing)"
    fi
  done

  echo ""
  if [[ $renewed -gt 0 ]]; then
    pass "cert-manager is renewing certificates ($renewed Ready so far)"
  else
    warn "No certificates Ready yet — check cert-manager logs:"
    echo "  kubectl -n cert-manager logs deploy/cert-manager --since=2m | grep -i error"
  fi

  # ── Step 6: Restart all deployments that mount kubeconfig secrets ───────────
  header "6. Restarting deployments with stale kubeconfig certs"
  info "Go HTTP clients cache TLS certs in memory — volume sync alone is not enough"

  RESTARTED_DEPLOYS=0
  for ns in "${KONKSERVICE_NAMESPACES[@]}"; do
    # Find all deployments in this namespace that mount a konk-service-kubeconfig secret
    deploys=$($KC -n "$ns" get deploy -o json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
seen=set()
for item in data.get('items',[]):
    name=item['metadata']['name']
    for vol in item['spec']['template']['spec'].get('volumes',[]):
        secret_name=(vol.get('secret') or {}).get('secretName','')
        if 'konk-service-kubeconfig' in secret_name and name not in seen:
            seen.add(name)
            print(name)
        for src in (vol.get('projected') or {}).get('sources',[]):
            secret_name=((src.get('secret') or {}).get('name',''))
            if 'konk-service-kubeconfig' in secret_name and name not in seen:
                seen.add(name)
                print(name)
" 2>/dev/null || true)

    for deploy in $deploys; do
      $KC -n "$ns" rollout restart "deploy/$deploy" &>/dev/null \
        && info "  Restarted $ns/$deploy" \
        || warn "  Failed to restart $ns/$deploy"
      RESTARTED_DEPLOYS=$((RESTARTED_DEPLOYS + 1))
    done
  done

  # Also restart the bulk deployment in aggregate (connects via bulk-konk-kubeconfig)
  if $KC -n "$AGGREGATE_NS" get deploy/bulk &>/dev/null; then
    $KC -n "$AGGREGATE_NS" rollout restart deploy/bulk &>/dev/null \
      && info "  Restarted $AGGREGATE_NS/bulk" \
      || warn "  Failed to restart $AGGREGATE_NS/bulk"
    RESTARTED_DEPLOYS=$((RESTARTED_DEPLOYS + 1))
  fi

  if [[ $RESTARTED_DEPLOYS -gt 0 ]]; then
    pass "Restarted $RESTARTED_DEPLOYS deployment(s)"
    info "Waiting 30s for pods to start with renewed certs..."
    sleep 30
  else
    info "No deployments found to restart"
  fi

else
  echo -e "${YELLOW}DRY RUN — no changes made. Run with --apply to recreate Certificate CRs.${NC}"
  echo ""
  echo "Generated manifests saved to: $CERT_MANIFESTS_DIR"
  echo "To review: cat ${CERT_MANIFESTS_DIR}/*.yaml"
fi

# ── Step 7: Check for expired certs causing active apiserver rejections ───────
header "7. Checking bulk-konk apiserver for active cert rejection errors"

errors=$($KC -n "$AGGREGATE_NS" logs deploy/bulk-konk --since=1m 2>/dev/null | grep -c "certificate has expired" || echo "0")
if [[ "$errors" -gt 0 ]]; then
  warn "bulk-konk apiserver: $errors 'certificate has expired' rejection(s) in last 1 min"
  if $APPLY; then
    info "These may clear in the next 30-60s as old pods terminate"
    info "If errors persist, check for other pods connecting to bulk-konk:"
    echo "  kubectl get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]? | .secret?.secretName? // \"\" | test(\"konk-service-kubeconfig|bulk-konk\")) | [.metadata.namespace, .metadata.name, .metadata.creationTimestamp] | @tsv'"
  else
    info "These will persist until Certificate CRs are recreated (run with --apply)"
  fi
else
  pass "No active 'certificate has expired' errors in bulk-konk apiserver"
fi

# Cleanup temp dir only if applied (keep for review in dry-run)
if $APPLY; then
  rm -rf "$CERT_MANIFESTS_DIR"
fi

echo ""
echo -e "${BOLD}Done.${NC}"
