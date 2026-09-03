# KonkService ImagePullBackOff — us-dev-5

**Date:** 2026-06-24  
**Cluster:** us-dev-5  
**Operator version:** `v0.2.1-151-gfd9ed6b-j16`

## Symptom

15 konk-service deployments across namespaces (ddi, atcapi, hostapp, ntp, ngp-cp, redirect) had 1/2 containers in `ImagePullBackOff`:

```
Failed to pull image "ghcr.io/infobloxopen/konk-service:v1.25.8": not found
```

## Root Cause

The `j16` operator version is a **downgrade** from a newer version that had `RELATED_IMAGE_KIND` / `RELATED_IMAGE_KIND_REPO` env var mappings in `watches.yaml`. The failure chain:

1. Previous (newer) operator deployed konk-service pods with image `ghcr.io/infobloxopen/konk-service:<tag>` via `RELATED_IMAGE_KIND_REPO` override
2. Downgrade to `j16` — this version's `watches.yaml` does **not** map `kind.image.repository` or `kind.image.tag` for KonkService CRs
3. The `j16` operator pod has **no `RELATED_IMAGE_*` env vars** at all (confirmed via `kubectl get pod -o jsonpath`)
4. Operator reconciled successfully (logs show "Reconciled release") but Helm's 3-way merge did **not** update the existing deployments — they retained the old image reference
5. The old image (`ghcr.io/infobloxopen/konk-service:v1.25.8`) doesn't exist — `v1.25.8` is the Kubernetes version from `.Chart.AppVersion`, not a konk image tag

### Why the operator didn't fix it

- The helm-operator does **not** perform live drift detection on managed resources
- It only compares desired chart output vs stored Helm release secret
- Since the release secret was re-created fresh (via Install after annotation loss), the operator considers it "up to date"
- The actual deployment spec diverges from what the chart would render, but the operator doesn't check

### Key evidence

| Check | Result |
|-------|--------|
| Operator env vars | Only `AUTH_URL`, `CERT_MANAGER_NAMESPACE`, `SPACE`, `VAULT_PATH` — no `RELATED_IMAGE_*` |
| `watches.yaml` at `fd9ed6b` | KonkService overrides: `authURL`, `space.enabled`, `vaultCommon.imagepullsecret.path` only |
| Chart defaults at `fd9ed6b` | `kind.image.repository: kindest/node`, `kind.image.tag: v1.25.8` |
| `.status.deployedRelease.manifest` | Shows `kindest/node:v1.25.8` (chart default) |
| Actual deployment | Shows `ghcr.io/infobloxopen/konk-service:v1.25.8` (stale from previous operator) |
| us-dev-2 (working) | Uses `v0.2.1-155-gd4614c2-j191` with `relatedImages` values → `harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-155-gd4614c2` |

## Fix Applied

Manually patched all 15 affected deployments to use the working image from us-dev-2:

```bash
kubectl --context us-dev-5 get deploy --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.name}={.image}{","}{end}{"\n"}{end}' \
  | grep "ghcr.io/infobloxopen/konk-service:v1.25.8" \
  | while IFS=$'\t' read -r ns name containers; do
      echo "$containers" | tr ',' '\n' | grep "ghcr.io/infobloxopen/konk-service:v1.25.8" \
        | while IFS='=' read -r cname cimage; do
            kubectl --context us-dev-5 set image "deploy/$name" -n "$ns" \
              "$cname=harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-155-gd4614c2"
          done
    done
```

**Target image:** `harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-155-gd4614c2`

### Affected deployments

| Namespace | Deployment | Container |
|-----------|-----------|-----------|
| atcapi | atcapi-apiservice-konk-service-kubeconfig | kubeconfig |
| atcapi | atcapi-apiservice-v2-konk-service-kubeconfig | kubeconfig |
| ddi | dns-config-importexport-apiservice-konk-service-kubeconfig | kubeconfig |
| ddi | dns-config-importexport-apiservice-v2-k-kubectl-apiservice-test | apiservice-test |
| ddi | dns-config-importexport-apiservice-v2-konk-service-kubeconfig | kubeconfig |
| ddi | dns-data-importexport-apiservice-v2-konk-service-kubeconfig | kubeconfig |
| ddi | ipam-importexport-apiservice-konk-service-kubeconfig | kubeconfig |
| ddi | ipam-importexport-apiservice-konk-service-kubectl-apiservice | apiservice |
| ddi | ipam-importexport-apiservice-v3-konk-service-kubeconfig | kubeconfig |
| ddi | keys-importexport-apiservice-konk-service-kubeconfig | kubeconfig |
| ddi | keys-importexport-apiservice-konk-service-kubectl-apiservice | apiservice |
| hostapp | hostapp-aggregate-api-infra-konk-service-kubeconfig | kubeconfig |
| hostapp | hostapp-aggregate-api-infra-konk-service-kubectl-apiservice | apiservice |
| ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-service-kubeconfig | kubeconfig |
| redirect | redirect-apiservice-konk-service-kubeconfig | kubeconfig |

## Caveats

- The operator does not do drift detection, so these patches persist
- If the operator ever re-installs a KonkService (e.g., after release secret loss/annotation issue), it will render `kindest/node:v1.25.8` from the j16 chart defaults — which is the wrong binary
- **Proper fix**: upgrade us-dev-5 to `v0.2.1-155-gd4614c2-j191` (like us-dev-2) with matching `relatedImages` values in the DC repo

## Related

- [Annotation issue fix](annotation/annotation-issue-fix.md) — Helm annotation loss causing reconcile failures
