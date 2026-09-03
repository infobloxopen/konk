# Helm Ownership Annotation Issue — bulk-konk Reconcile Failure

## Problem

The konk-operator fails to reconcile the `bulk-konk` Konk CR with errors like:

```
Unable to continue with install: ServiceAccount "bulk-konk" in namespace "aggregate"
exists and cannot be imported into the current release: invalid ownership metadata;
annotation validation error: missing key "meta.helm.sh/release-name": must be set to "bulk-konk";
annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "aggregate"
```

The operator reports `InstallError` on the Konk CR, and bulk-konk pods stay on the old version while konk-service pods (managed by independent KonkService CRs) upgrade normally.

## Root Cause

Helm 3 requires resources it manages to have ownership annotations:
- `meta.helm.sh/release-name`
- `meta.helm.sh/release-namespace`

When a Helm release secret is lost (e.g. operator restart during install, manual secret deletion, or storage backend corruption), Helm loses track of the release. On the next reconcile it attempts a fresh `install` but finds existing resources without ownership annotations — and refuses to adopt them.

The operator processes resources **sequentially** — it fails on the first unannotated resource and stops. Each fix-and-retry reveals the next unannotated resource (whack-a-mole pattern).

## Impact

- `bulk-konk` (apiserver) and `bulk-konk-init` (provision) pods stuck on old version
- `konk-service` pods (KonkService CRs) are unaffected — they reconcile independently
- No functional impact if the running version is stable — the Kubernetes API contract between components is version-stable

## Detection

The e2e test script catches this in **Section 3 (Image version consistency)**:
```
── 3. Image version consistency ──
  [INFO] konk-operator          : v0.2.1-155-gd4614c2
  [WARN] bulk-konk (apiserver)  : v0.2.1-175-g1d5d187 — expected v0.2.1-155-gd4614c2 (reconcile failing)
  [WARN] bulk-konk (provision)  : v0.2.1-175-g1d5d187 — expected v0.2.1-155-gd4614c2 (reconcile failing)
```

Also visible in **Section 11 (konk-operator log health)** as reconcile errors.

## Fix

### Step 1: Annotate all bulk-konk resources

The resources span multiple types: ServiceAccount, Deployments, Services, Secrets, ConfigMaps, Certificates, Issuers, ClusterRoles, ClusterRoleBindings, StatefulSets, Etcd CRs, Space CRs, PVCs, etc.

#### Namespaced resources (aggregate namespace)

```bash
# Standard K8s resources
for res in \
  serviceaccount/bulk-konk \
  service/bulk-konk service/bulk-konk-etcd service/bulk-konk-etcd-headless \
  deployment.apps/bulk-konk deployment.apps/bulk-konk-init \
  statefulset.apps/bulk-konk-etcd \
  configmap/bulk-konk-scripts \
  secret/bulk-konk-apiserver-cert secret/bulk-konk-ca secret/bulk-konk-etcd-ca \
  secret/bulk-konk-etcd-cert secret/bulk-konk-imagepullsecret secret/bulk-konk-kubeconfig \
  secret/bulk-konk-ingress-client secret/bulk-konk-proxy-client \
  secret/bulk-konk-requestheader-self-signed; do
  kubectl annotate "$res" -n aggregate \
    meta.helm.sh/release-name=bulk-konk \
    meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null
done

# cert-manager resources
for cert in bulk-konk-ingress-client bulk-konk-requestheader-proxy-client bulk-konk-requestheader-self-signed; do
  kubectl annotate certificates.cert-manager.io "$cert" -n aggregate \
    meta.helm.sh/release-name=bulk-konk \
    meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null
done

for issuer in bulk-konk-requestheader bulk-konk-requestheader-self-signed; do
  kubectl annotate issuer.cert-manager.io "$issuer" -n aggregate \
    meta.helm.sh/release-name=bulk-konk \
    meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null
done

# Custom CRDs
kubectl annotate etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  meta.helm.sh/release-name=bulk-konk \
  meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null

kubectl annotate spaces.spacecontroller.infoblox-cto.github.com bulk-konk-imagepullsecret -n aggregate \
  meta.helm.sh/release-name=bulk-konk \
  meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null
```

#### Cluster-scoped resources

```bash
kubectl annotate clusterrole bulk-konk-certs-role \
  meta.helm.sh/release-name=bulk-konk \
  meta.helm.sh/release-namespace=aggregate --overwrite

kubectl annotate clusterrolebinding bulk-konk-certs-rb \
  meta.helm.sh/release-name=bulk-konk \
  meta.helm.sh/release-namespace=aggregate --overwrite

kubectl annotate clusterissuer.cert-manager.io bulk-konk-kubeadm-ca \
  meta.helm.sh/release-name=bulk-konk \
  meta.helm.sh/release-namespace=aggregate --overwrite
```

### Step 2: Trigger reconcile

The operator uses exponential backoff after failures. Force an immediate retry:

```bash
kubectl annotate konk bulk-konk -n aggregate \
  konk.infoblox.com/reconcile-trigger="$(date +%s)" --overwrite
```

### Step 3: Verify

```bash
# Check operator logs for success
kubectl logs deployment/konk-operator -n konk --since=1m 2>&1 | grep '"name":"bulk-konk"' | grep -v etcd

# Should show: "Installed release" / "Reconciled release" (not "Release failed")

# Check pods are rolling
kubectl get pods -n aggregate --no-headers | grep bulk-konk

# Verify images match operator
kubectl get deploy bulk-konk bulk-konk-init -n aggregate \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
```

### Nuclear option: sweep ALL resources

If you keep hitting new resources one by one, sweep all namespaced API resources:

```bash
kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | while read -r kind; do
  kubectl get "$kind" -n aggregate --no-headers 2>/dev/null | grep bulk-konk | awk '{print $1}' | while read -r name; do
    ann=$(kubectl get "$kind" "$name" -n aggregate -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    if [[ -z "$ann" ]]; then
      kubectl annotate "$kind" "$name" -n aggregate \
        meta.helm.sh/release-name=bulk-konk \
        meta.helm.sh/release-namespace=aggregate --overwrite 2>/dev/null && echo "FIXED: $kind/$name"
    fi
  done
done
```

**Note:** This is slow through Teleport (~3-5 min). Skip `events` and `endpoints` kinds if you want to speed it up — those are recreated automatically.

## Timeline (us-dev-5, 2026-06-12)

| Time | Event |
|------|-------|
| 2026-05-20 | Helm release metadata lost; Konk CR enters InstallError |
| 2026-06-12 10:10 | Detected via e2e test Section 3 |
| 2026-06-12 10:10–10:35 | Iterative annotation of ~25 resources (SA, ClusterRole, Certificates, Etcd CR, Space CR, etc.) |
| 2026-06-12 10:37 | Reconcile succeeds — "Installed release" + "Reconciled release" |
| 2026-06-12 10:37 | bulk-konk pods rolling to v0.2.1-155-gd4614c2 |

## Prevention

- The konk chart should set `helm.sh/resource-policy: keep` annotations on cert-manager Certificates and CA secrets, but NOT on the ServiceAccount or other chart-managed resources that can be safely recreated.
- Consider adding a pre-reconcile hook in the operator that checks for orphaned resources and auto-annotates them (feature request).



Example - https://grafana-csp.us-stg-1.na.stage.test.infoblox.com/goto/pYPlLzfvg?orgId=1