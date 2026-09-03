#!/bin/bash
# fix-konk-annotations.sh — Fix missing or incorrect Helm ownership annotations on Konk and KonkService resources
#
# Usage:
#   ./fix-konk-annotations.sh [--apply] [--sweep] [--context <ctx>] [--namespace <ns>]
#
# Modes:
#   (default)   Dry-run — reports broken resources without modifying anything
#   --apply     Actually annotates resources and triggers reconciliation
#
# Options:
#   --context   kubectl context (default: current context)
#   --namespace Namespace for bulk-konk Konk CR (default: aggregate)
#   --sweep     Full API resource sweep for bulk-konk (slow on Teleport)
#
# Examples:
#   ./fix-konk-annotations.sh                              # dry-run, current context
#   ./fix-konk-annotations.sh --context us-dev-5           # dry-run on us-dev-5
#   ./fix-konk-annotations.sh --apply --context us-dev-5   # fix on us-dev-5
#   ./fix-konk-annotations.sh --apply --sweep              # fix + full sweep
#
# This script handles BOTH:
#   1. Konk CR (bulk-konk) — all resources in the aggregate namespace
#   2. KonkService CRs — all resources across all namespaces
#
# Safe to run multiple times — --overwrite ensures idempotency.

set -euo pipefail

# ─── Parse args ───────────────────────────────────────────────────────────────

APPLY=false
SWEEP=false
CONTEXT=""
NS="aggregate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --sweep) SWEEP=true; shift ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--apply] [--sweep] [--context <ctx>] [--namespace <ns>]"
      echo ""
      echo "  --apply      Fix annotations (default is dry-run)"
      echo "  --sweep      Full API sweep for bulk-konk resources (slow)"
      echo "  --context    kubectl context (default: current)"
      echo "  --namespace  Namespace for Konk CR (default: aggregate)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

KC="kubectl"
if [[ -n "$CONTEXT" ]]; then
  KC="kubectl --context $CONTEXT"
fi

RELEASE_NAME="bulk-konk"
RELEASE_NS="$NS"

MODE="DRY-RUN"
$APPLY && MODE="APPLY"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Konk & KonkService Annotation Fix                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Context:   ${CONTEXT:-$(kubectl config current-context)}"
echo "  Namespace: $NS (for Konk CR)"
echo "  Mode:      $MODE"
echo ""

# ─── Counters ─────────────────────────────────────────────────────────────────

konk_broken=()
konk_ok=()
konk_not_found=()
konk_fixed=()

ks_broken=()
ks_fixed=()

# ─── Helper: check/fix a single resource ─────────────────────────────────────

check_and_fix() {
  local resource="$1"
  local ns_flag="$2"
  local release="$3"
  local release_ns="$4"
  local section="$5"  # "konk" or "ks"

  if ! $KC get $resource $ns_flag -o name &>/dev/null; then
    [[ "$section" == "konk" ]] && konk_not_found+=("$resource")
    return
  fi

  local current
  current=$($KC get $resource $ns_flag -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)

  if [[ "$current" == "$release" ]]; then
    [[ "$section" == "konk" ]] && konk_ok+=("$resource")
    return
  fi

  # Missing or wrong annotation
  if [[ "$section" == "konk" ]]; then
    konk_broken+=("$resource")
  else
    ks_broken+=("$ns_flag $resource")
  fi

  if $APPLY; then
    if $KC annotate $resource $ns_flag \
      meta.helm.sh/release-name="$release" \
      meta.helm.sh/release-namespace="$release_ns" --overwrite &>/dev/null; then
      if [[ "$section" == "konk" ]]; then
        konk_fixed+=("$resource")
      else
        ks_fixed+=("$ns_flag $resource")
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Konk CR (bulk-konk)
# ═══════════════════════════════════════════════════════════════════════════════

echo "── Phase 1: Konk CR (bulk-konk) in $NS ──"
echo ""

# Standard K8s resources owned by bulk-konk release
# NOTE: etcd resources (service/bulk-konk-etcd*, statefulset/bulk-konk-etcd)
# belong to the separate bulk-konk-etcd Helm release — do NOT check them here.
for res in \
  serviceaccount/bulk-konk \
  service/bulk-konk \
  deployment.apps/bulk-konk \
  deployment.apps/bulk-konk-init \
  configmap/bulk-konk-scripts; do
  check_and_fix "$res" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"
done

# Etcd resources — owned by the bulk-konk-etcd Helm release
ETCD_RELEASE="bulk-konk-etcd"
for res in \
  service/bulk-konk-etcd \
  service/bulk-konk-etcd-headless \
  statefulset.apps/bulk-konk-etcd; do
  check_and_fix "$res" "-n $NS" "$ETCD_RELEASE" "$RELEASE_NS" "konk"
done
# NOTE: secret/bulk-konk-etcd-ca and secret/bulk-konk-etcd-cert are generated
# by cert-manager/provision and are NOT part of any Helm release manifest.
# Do not check them — they legitimately have no Helm ownership annotation.

# Secrets owned by bulk-konk release
for secret in \
  bulk-konk-apiserver-cert \
  bulk-konk-ca \
  bulk-konk-imagepullsecret \
  bulk-konk-kubeconfig \
  bulk-konk-ingress-client \
  bulk-konk-proxy-client \
  bulk-konk-requestheader-self-signed; do
  check_and_fix "secret/$secret" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"
done

# cert-manager Certificates
for cert in \
  bulk-konk-ingress-client \
  bulk-konk-requestheader-proxy-client \
  bulk-konk-requestheader-self-signed; do
  check_and_fix "certificate.cert-manager.io/$cert" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"
done

# cert-manager Issuers
for issuer in \
  bulk-konk-requestheader \
  bulk-konk-requestheader-self-signed; do
  check_and_fix "issuer.cert-manager.io/$issuer" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"
done

# Custom CRDs (namespaced)
check_and_fix "etcd.konk.infoblox.com/bulk-konk-etcd" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"
check_and_fix "space.spacecontroller.infoblox-cto.github.com/bulk-konk-imagepullsecret" "-n $NS" "$RELEASE_NAME" "$RELEASE_NS" "konk"

# Cluster-scoped resources
check_and_fix "clusterrole/bulk-konk-certs-role" "" "$RELEASE_NAME" "$RELEASE_NS" "konk"
check_and_fix "clusterrolebinding/bulk-konk-certs-rb" "" "$RELEASE_NAME" "$RELEASE_NS" "konk"
check_and_fix "clusterissuer.cert-manager.io/bulk-konk-kubeadm-ca" "" "$RELEASE_NAME" "$RELEASE_NS" "konk"

# Optional full sweep
if [[ "$SWEEP" == "true" ]]; then
  echo "  Running full API sweep for bulk-konk resources..."
  sweep_count=0

  while IFS= read -r kind; do
    [[ "$kind" == "events" || "$kind" == "events.events.k8s.io" || "$kind" == "endpoints" ]] && continue
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      ann=$($KC get "$kind" "$name" -n "$NS" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
      if [[ -z "$ann" ]]; then
        konk_broken+=("$kind/$name (sweep)")
        if $APPLY; then
          if $KC annotate "$kind" "$name" -n "$NS" \
            meta.helm.sh/release-name="$RELEASE_NAME" \
            meta.helm.sh/release-namespace="$RELEASE_NS" --overwrite &>/dev/null; then
            konk_fixed+=("$kind/$name (sweep)")
            ((sweep_count++))
          fi
        fi
      fi
    done < <($KC get "$kind" -n "$NS" --no-headers 2>/dev/null | grep bulk-konk | awk '{print $1}')
  done < <($KC api-resources --verbs=list --namespaced -o name 2>/dev/null)

  # Cluster-scoped sweep
  while IFS= read -r kind; do
    [[ "$kind" == "events" || "$kind" == "events.events.k8s.io" ]] && continue
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      ann=$($KC get "$kind" "$name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
      if [[ -z "$ann" ]]; then
        konk_broken+=("$kind/$name (cluster-sweep)")
        if $APPLY; then
          if $KC annotate "$kind" "$name" \
            meta.helm.sh/release-name="$RELEASE_NAME" \
            meta.helm.sh/release-namespace="$RELEASE_NS" --overwrite &>/dev/null; then
            konk_fixed+=("$kind/$name (cluster-sweep)")
            ((sweep_count++))
          fi
        fi
      fi
    done < <($KC get "$kind" --no-headers 2>/dev/null | grep bulk-konk | awk '{print $1}')
  done < <($KC api-resources --verbs=list --namespaced=false -o name 2>/dev/null)

  echo "  Sweep found $sweep_count additional resources"
fi

if [[ ${#konk_broken[@]} -eq 0 ]]; then
  echo "  [PASS] All bulk-konk resources have correct annotations"
else
  echo "  [FAIL] ${#konk_broken[@]} resource(s) with missing or incorrect annotations"
  for r in "${konk_broken[@]}"; do
    echo "    [BROKEN] $r"
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: KonkService CRs (all namespaces)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "── Phase 2: KonkService CRs (all namespaces) ──"
echo ""

ks_total=0
ks_pass=0

# Resource types to check for each KonkService release
# These are all the types that the konk-service Helm chart creates
KS_RESOURCE_TYPES=(
  "deploy"
  "svc"
  "sa"
  "cm"
  "secret"
  "role"
  "rolebinding"
  "certificate.cert-manager.io"
  "issuer.cert-manager.io"
  "space.spacecontroller.infoblox-cto.github.com"
)

# Helper: check and fix all resources of a given type for a KonkService
fix_ks_resources() {
  local kind="$1"
  local ks_ns="$2"
  local ks_name="$3"
  local found_issue=false

  while IFS= read -r res_name; do
    [[ -z "$res_name" ]] && continue

    local ann
    ann=$($KC get "$kind" "$res_name" -n "$ks_ns" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)

    if [[ -z "$ann" || "$ann" != "$ks_name" ]]; then
      found_issue=true
      ks_broken+=("$ks_ns/$kind/$res_name (KonkService: $ks_name)")

      if $APPLY; then
        $KC annotate "$kind" "$res_name" -n "$ks_ns" \
          meta.helm.sh/release-name="$ks_name" \
          meta.helm.sh/release-namespace="$ks_ns" \
          --overwrite &>/dev/null && ks_fixed+=("$ks_ns/$kind/$res_name") || true
      fi
    fi
  done < <($KC get "$kind" -n "$ks_ns" --no-headers 2>/dev/null | awk '{print $1}' | grep -E "(^|/)${ks_name}(-|$)" || true)

  [[ "$found_issue" == "true" ]] && return 1 || return 0
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ks_ns=$(echo "$line" | awk '{print $1}')
  ks_name=$(echo "$line" | awk '{print $2}')
  ks_total=$((ks_total + 1))

  # Check all resource types for this KonkService
  found_broken=false
  for kind in "${KS_RESOURCE_TYPES[@]}"; do
    if ! fix_ks_resources "$kind" "$ks_ns" "$ks_name"; then
      found_broken=true
    fi
  done

  # Also check cluster-scoped resources (ClusterRole, ClusterRoleBinding)
  for cluster_kind in clusterrole clusterrolebinding; do
    while IFS= read -r res_name; do
      [[ -z "$res_name" ]] && continue
      local_ann=$($KC get "$cluster_kind" "$res_name" \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)
      if [[ -z "$local_ann" || "$local_ann" != "$ks_name" ]]; then
        found_broken=true
        ks_broken+=("$cluster_kind/$res_name (KonkService: $ks_name)")
        if $APPLY; then
          $KC annotate "$cluster_kind" "$res_name" \
            meta.helm.sh/release-name="$ks_name" \
            meta.helm.sh/release-namespace="$ks_ns" \
            --overwrite &>/dev/null && ks_fixed+=("$cluster_kind/$res_name") || true
        fi
      fi
    done < <($KC get "$cluster_kind" --no-headers 2>/dev/null | awk '{print $1}' | grep -E "(^|/)${ks_name}(-|$)" || true)
  done

  if [[ "$found_broken" == "false" ]]; then
    ks_pass=$((ks_pass + 1))
  fi
done < <($KC get konkservice --all-namespaces --no-headers 2>/dev/null)

if [[ ${#ks_broken[@]} -eq 0 ]]; then
  echo "  [PASS] All $ks_total KonkService CRs have correct annotations"
else
  echo "  [FAIL] ${#ks_broken[@]} KonkService resource(s) with missing or incorrect annotations"
  for r in "${ks_broken[@]}"; do
    echo "    [BROKEN] $r"
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Trigger reconciliation (only in --apply mode)
# ═══════════════════════════════════════════════════════════════════════════════

if $APPLY && [[ ${#konk_fixed[@]} -gt 0 || ${#ks_fixed[@]} -gt 0 ]]; then
  echo ""
  echo "── Phase 3: Triggering reconciliation ──"
  echo ""

  # Trigger Konk CR reconcile
  if [[ ${#konk_fixed[@]} -gt 0 ]]; then
    $KC annotate konk bulk-konk -n "$NS" \
      konk.infoblox.com/reconcile-trigger="$(date +%s)" --overwrite &>/dev/null
    echo "  Triggered reconcile for Konk CR: bulk-konk"
  fi

  # Trigger KonkService reconciles
  if [[ ${#ks_fixed[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ks_ns=$(echo "$line" | awk '{print $1}')
      ks_name=$(echo "$line" | awk '{print $2}')
      $KC annotate konkservice "$ks_name" -n "$ks_ns" \
        konk.infoblox.com/reconcile-trigger="$(date +%s)" --overwrite &>/dev/null && \
        echo "  Triggered reconcile for KonkService: $ks_ns/$ks_name" || true
    done < <($KC get konkservice --all-namespaces --no-headers 2>/dev/null)
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                        SUMMARY                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Konk CR summary
echo "┌─ Konk CR (bulk-konk) ─────────────────────────────────────────"
echo "│  OK:        ${#konk_ok[@]} resource(s)"
echo "│  Broken:    ${#konk_broken[@]} resource(s)"
echo "│  Not found: ${#konk_not_found[@]} resource(s)"
if $APPLY; then
  echo "│  Fixed:     ${#konk_fixed[@]} resource(s)"
fi
echo "└───────────────────────────────────────────────────────────────"

echo ""

# KonkService summary
echo "┌─ KonkService CRs ─────────────────────────────────────────────"
echo "│  Total CRs:      $ks_total"
echo "│  Healthy:        $ks_pass"
echo "│  Broken resources: ${#ks_broken[@]}"
if $APPLY; then
  echo "│  Fixed:          ${#ks_fixed[@]} resource(s)"
fi
echo "└───────────────────────────────────────────────────────────────"

echo ""

# Overall status
total_broken=$(( ${#konk_broken[@]} + ${#ks_broken[@]} ))
total_fixed=$(( ${#konk_fixed[@]} + ${#ks_fixed[@]} ))

if [[ $total_broken -eq 0 ]]; then
  echo "  ✅ ALL HEALTHY — no annotation issues found"
elif $APPLY; then
  if [[ $total_fixed -eq $total_broken ]]; then
    echo "  ✅ ALL FIXED — $total_fixed resource(s) annotated, reconcile triggered"
  else
    echo "  ⚠️  PARTIALLY FIXED — $total_fixed/$total_broken resource(s) annotated"
    echo "     Re-run to catch remaining issues"
  fi
else
  echo "  ❌ $total_broken RESOURCE(S) NEED FIXING"
  echo ""
  echo "  Run with --apply to fix:"
  echo "    $0 --apply${CONTEXT:+ --context $CONTEXT}"
fi

echo ""
