#!/bin/bash
# fix-konk-service-imagepull-us-dev-4.sh
# Fixes ImagePullBackOff on konk-service deployments caused by stale image reference
# (ghcr.io/infobloxopen/konk-service:v1.25.8 does not exist)
#
# The operator on us-dev-4 is v0.2.1-151-gfd9ed6b-j16. Its chart defaults:
#   kind.image: kindest/node:v1.25.8     (correct for 'kind' container)
#   konk-service image: should be konk-service binary (for apiservice/apiservice-test containers)
#
# This script ONLY fixes containers using ghcr.io/infobloxopen/konk-service:v1.25.8
# (which doesn't exist). It does NOT touch kindest/node:v1.25.8 (that's correct).
#
# Usage:
#   ./fix-konk-service-imagepull-us-dev-4.sh          # dry-run
#   ./fix-konk-service-imagepull-us-dev-4.sh --apply  # apply fix
#   ./fix-konk-service-imagepull-us-dev-4.sh --revert # revert kind containers back to kindest/node

set -euo pipefail

CONTEXT="teleport.services.sdp.infoblox.com-us-dev-4"
BROKEN_IMAGE="ghcr.io/infobloxopen/konk-service:v1.25.8"
TARGET_IMAGE="harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-151-gfd9ed6b"

# For reverting kind containers that were incorrectly patched
WRONG_KIND_IMAGE="harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-155-gd4614c2"
CORRECT_KIND_IMAGE="kindest/node:v1.25.8"

APPLY=false
REVERT=false
[[ "${1:-}" == "--apply" ]] && APPLY=true
[[ "${1:-}" == "--revert" ]] && REVERT=true

KC="kubectl --context $CONTEXT"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Fix KonkService ImagePullBackOff — us-dev-4             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Context:      $CONTEXT"

if $REVERT; then
  echo "  Mode:         REVERT (kind containers → kindest/node:v1.25.8)"
  echo ""

  # Revert 'kind' containers back to kindest/node:v1.25.8
  while IFS=$'\t' read -r ns name containers; do
    [[ -z "$ns" ]] && continue
    echo "$containers" | tr ',' '\n' | grep "$WRONG_KIND_IMAGE" | while IFS='=' read -r cname cimage; do
      [[ -z "$cname" ]] && continue
      # Only revert the 'kind' container, not apiservice/apiservice-test
      if [[ "$cname" == "kind" || "$cname" == "provision" ]]; then
        echo "  [REVERT] $ns/$name container=$cname → $CORRECT_KIND_IMAGE"
        $KC set image "deploy/$name" -n "$ns" "$cname=$CORRECT_KIND_IMAGE"
      fi
    done
  done < <($KC get deploy --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.name}={.image}{","}{end}{"\n"}{end}' \
    | grep "$WRONG_KIND_IMAGE")

  echo ""
  echo "  ✅ Reverted kind containers back to kindest/node:v1.25.8"
  exit 0
fi

echo "  Broken image: $BROKEN_IMAGE"
echo "  Target image: $TARGET_IMAGE"
echo "  Mode:         $($APPLY && echo "APPLY" || echo "DRY-RUN")"
echo ""

# Fix ghcr.io/infobloxopen/konk-service:v1.25.8 (only apiservice/apiservice-test containers)
while IFS=$'\t' read -r ns name containers; do
  [[ -z "$ns" ]] && continue
  echo "$containers" | tr ',' '\n' | grep "$BROKEN_IMAGE" | while IFS='=' read -r cname cimage; do
    [[ -z "$cname" ]] && continue
    echo "  [FIX] $ns/$name container=$cname"
    echo "        $BROKEN_IMAGE → $TARGET_IMAGE"
    if $APPLY; then
      $KC set image "deploy/$name" -n "$ns" "$cname=$TARGET_IMAGE"
    fi
  done
done < <($KC get deploy --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.name}={.image}{","}{end}{"\n"}{end}' \
  | grep "$BROKEN_IMAGE")

echo ""
if $APPLY; then
  echo "  ✅ Patches applied. Pods will restart automatically."
else
  echo "  ℹ️  Dry-run complete. Re-run with --apply to fix."
fi
