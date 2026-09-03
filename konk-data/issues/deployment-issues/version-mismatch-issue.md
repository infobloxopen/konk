# bulk-konk Image Version Mismatch — us-dev-4

**Date:** 2026-07-07  
**Cluster:** us-dev-4  
**Namespace:** aggregate  
**Status:** Resolved

## Symptom

The konk-operator was running `v0.2.1-185-gea83580` but bulk-konk pods (apiserver + provision) were stuck on `v0.2.1-155-gd4614c2`. The operator was failing to reconcile the `bulk-konk` Helm release.

```
[INFO] konk-operator          : v0.2.1-185-gea83580
[WARN] bulk-konk (apiserver)  : v0.2.1-155-gd4614c2 — expected v0.2.1-185-gea83580
[WARN] bulk-konk (provision)  : v0.2.1-155-gd4614c2 — expected v0.2.1-185-gea83580
```

## Root Cause

The `bulk-konk` Helm release had **no release history** — no `sh.helm.release.v1.bulk-konk.*` secret existed. The operator was attempting a fresh `helm install`, but all existing resources on the cluster were missing the required Helm ownership annotations:

- `meta.helm.sh/release-name`
- `meta.helm.sh/release-namespace`

Helm refuses to adopt resources without these annotations, erroring:

```
failed to install release: Unable to continue with install: <Resource> exists and
cannot be imported into the current release: invalid ownership metadata; annotation
validation error: missing key "meta.helm.sh/release-name": must be set to "bulk-konk"
```

**Why the release history was lost:** The previous operator version managed these resources before PR #637 added `meta.helm.sh` annotations to chart templates. When the Helm release secret was lost (possibly during the Konk v1→v2 migration or a failed previous reconcile that never completed), the operator couldn't re-install because existing resources had no ownership metadata.

## Operator Error Log

```json
{"level":"error","logger":"helm.controller","msg":"Release failed",
 "namespace":"aggregate","name":"bulk-konk",
 "error":"failed to install release: Unable to continue with install:
  ClusterRole \"bulk-konk-certs-role\" in namespace \"\" exists and cannot be
  imported into the current release: invalid ownership metadata..."}
```

## Fix Applied

Manually annotated all 15 orphaned resources with Helm ownership metadata:

```bash
CTX="teleport.services.sdp.infoblox.com-us-dev-4"

# Namespace-scoped (aggregate)
for resource in "sa/bulk-konk" "deploy/bulk-konk" "deploy/bulk-konk-init" "svc/bulk-konk"; do
  kubectl --context "$CTX" -n aggregate annotate "$resource" \
    meta.helm.sh/release-name=bulk-konk \
    meta.helm.sh/release-namespace=aggregate --overwrite
done

# Cluster-scoped
kubectl --context "$CTX" annotate clusterrole/bulk-konk-certs-role \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
kubectl --context "$CTX" annotate clusterrolebinding/bulk-konk-certs-rb \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
kubectl --context "$CTX" annotate clusterissuer bulk-konk-kubeadm-ca \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite

# cert-manager resources
for cert in bulk-konk-ingress-client bulk-konk-requestheader-proxy-client bulk-konk-requestheader-self-signed; do
  kubectl --context "$CTX" -n aggregate annotate "certificates.cert-manager.io/$cert" \
    meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
done
for issuer in bulk-konk-requestheader bulk-konk-requestheader-self-signed; do
  kubectl --context "$CTX" -n aggregate annotate "issuers.cert-manager.io/$issuer" \
    meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
done

# Secrets
kubectl --context "$CTX" -n aggregate annotate secret/bulk-konk-imagepullsecret \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite

# CRD resources
kubectl --context "$CTX" -n aggregate annotate etcds.konk.infoblox.com bulk-konk-etcd \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
kubectl --context "$CTX" -n aggregate annotate spaces.spacecontroller.infoblox-cto.github.com bulk-konk-imagepullsecret \
  meta.helm.sh/release-name=bulk-konk meta.helm.sh/release-namespace=aggregate --overwrite
```

After patching, forced a reconcile:

```bash
kubectl --context "$CTX" -n aggregate patch konk bulk-konk --type=merge \
  -p '{"metadata":{"annotations":{"konk.infoblox.com/force-reconcile":"'$(date +%s)'"}}}'
```

## Result

- Operator successfully reconciled → created `sh.helm.release.v1.bulk-konk.v1` (status: `deployed`)
- New pods rolled out with `v0.2.1-185-gea83580`
- All konk-service namespaces unaffected (already had correct version)

## Complete List of Orphaned Resources

| # | Kind | Name | Scope |
|---|------|------|-------|
| 1 | ServiceAccount | bulk-konk | namespace |
| 2 | Deployment | bulk-konk | namespace |
| 3 | Deployment | bulk-konk-init | namespace |
| 4 | Service | bulk-konk | namespace |
| 5 | ClusterRole | bulk-konk-certs-role | cluster |
| 6 | ClusterRoleBinding | bulk-konk-certs-rb | cluster |
| 7 | ClusterIssuer | bulk-konk-kubeadm-ca | cluster |
| 8 | Certificate | bulk-konk-ingress-client | namespace |
| 9 | Certificate | bulk-konk-requestheader-proxy-client | namespace |
| 10 | Certificate | bulk-konk-requestheader-self-signed | namespace |
| 11 | Issuer | bulk-konk-requestheader | namespace |
| 12 | Issuer | bulk-konk-requestheader-self-signed | namespace |
| 13 | Secret | bulk-konk-imagepullsecret | namespace |
| 14 | Etcd (CRD) | bulk-konk-etcd | namespace |
| 15 | Space (CRD) | bulk-konk-imagepullsecret | namespace |

## Prevention

The `fix-helm-orphans` pre-install hook exists in `helm-charts/konk-service/` but **not** in `helm-charts/konk/`. Adding an equivalent hook to the konk chart would prevent this from recurring for the bulk-konk release. The hook would need to cover all resource types listed above, including cluster-scoped resources and CRDs.

## Related

- PR #637: Added `meta.helm.sh` ownership annotations to chart templates
- Commit `ea83580`: `fix-helm-orphans` pre-install hook (konk-service chart only)
- This is NOT caused by the pre/post upgrade hooks — those only run in konk-service chart (KonkService CRs), not the konk chart (Konk CRs)
