# Konk Operator — Helm Annotation Loss: Root Cause & Permanent Fix

## Summary

On most konk-operator upgrades, 6+ KonkService CRs (and sometimes the main Konk CR like `bulk-konk`) fail to reconcile because their managed Kubernetes resources are missing Helm ownership annotations (`meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`). The operator logs show:

```
Deployment "...-konk-service-kubectl-apiservice" exists and cannot be imported
into the current release: invalid ownership metadata; missing key "meta.helm.sh/release-name"
```

This is a **structural deficiency** in the stock Helm operator-sdk, not a one-time data corruption event.

---

## Root Cause (Detailed)

### How the Operator Works

The konk-operator uses the **stock `helm-operator run`** binary from operator-sdk v1.42.0. It:

1. Watches three CRDs: `Konk`, `KonkService`, `Etcd`
2. Maps each CR to a Helm chart via `watches.yaml`
3. Stores Helm release state in Kubernetes **Secrets** (named `sh.helm.release.v1.<name>.v<N>`)
4. Injects **ownerReferences** on those release secrets, pointing to the CR

### The Failure Chain (Happens on Every Upgrade)

```
┌─────────────────────────────────────────────────────────────────┐
│  1. Operator pod upgrade → old pod terminates                   │
│                                                                 │
│  2. If mid-reconcile: release left in pending-install/upgrade   │
│     OR: CR UID changes → release secret gets GC'd              │
│                                                                 │
│  3. New operator starts → finds broken/missing release          │
│     - pending state → failure rollback DELETES release secret   │
│     - missing secret → stateNeedsInstall                        │
│                                                                 │
│  4. Operator calls helm Install (not Upgrade)                   │
│                                                                 │
│  5. Helm finds existing resources without ownership annotations │
│     → REFUSES to adopt → fails on FIRST bad resource → stops   │
│                                                                 │
│  6. Exponential backoff → CR stuck in InstallError              │
└─────────────────────────────────────────────────────────────────┘
```

### Why Release Secrets Get Lost

There are **three scenarios** that trigger this:

#### Scenario A: OwnerReference GC (Most Common)

The `DefaultSecretsStorageDriver` in helm-operator-plugins injects an `ownerReference` on each release secret pointing to the CR. If the CR's UID ever changes (e.g., CRD schema upgrade triggers delete+recreate, or manual re-apply), Kubernetes garbage-collects the release secrets because the ownerReference points to a non-existent UID.

#### Scenario B: Interrupted Reconcile + Failure Rollback

1. Operator pod dies mid-reconcile (during upgrade deployment rollout)
2. Release secret is in `status: pending-upgrade` or `pending-install`
3. New operator pod starts, sees the broken release
4. The `enableFailureRollbacks` logic **auto-uninstalls** the failed release
5. Release secret is deleted → next reconcile treats it as fresh install

#### Scenario C: maxReleaseHistory Pruning Race

With `maxReleaseHistory=10` (default), old release secrets are pruned. Under heavy reconcile load with concurrent reconciles (`maxConcurrentReconciles = runtime.NumCPU()`), a race condition can corrupt the release history chain.

### Why KonkService CRs Are More Affected Than Konk CRs

| Factor | Konk CR (bulk-konk) | KonkService CRs |
|--------|---------------------|-----------------|
| Count | 1 | 17 (one per aggregate API) |
| Resources per CR | ~30+ | ~3-5 |
| Reconcile time | Longer (more templates) | Shorter |
| Probability of interruption | Lower (1 CR) | Higher (17 CRs racing) |
| Observed failure rate | Occasional | 6/17 consistently |

The KonkService CRs that fail are the ones whose reconcile was in-flight when the old operator pod terminated. The ones that succeed either:
- Completed before the old pod died (annotations intact)
- Were created after the new operator started (fresh install succeeds — no pre-existing resources)

### Why the Operator Cannot Self-Heal

The stock `helm-operator run` binary has **no adoption logic**. The reconcile state machine is:

```go
// Simplified from helm-operator-plugins source
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) {
    rel, err := r.actionClient.Get(releaseName)
    if err == driver.ErrReleaseNotFound {
        // → doInstall() → helm install → FAILS if resources exist
    }
    // No intermediate "adopt orphaned resources" step exists
}
```

There is no pre-install hook, no resource scanning, no annotation repair — it's a hard fail.

---

## The Fix: Annotation Sweep Script

Since modifying the operator requires building a custom binary (Hybrid Helm operator), the practical fix is a **pre-upgrade annotation sweep** that runs before or immediately after the operator upgrade.

### Option 1: Manual Fix (Current Approach)

Run after detecting reconcile failures:

```bash
#!/bin/bash
# fix-konk-annotations.sh — Sweep all resources missing Helm ownership annotations
# Usage: ./fix-konk-annotations.sh <kubectl-context> <namespace> <release-name>

CTX="${1:?Usage: $0 <context> <namespace> <release-name>}"
NS="${2:?}"
RELEASE="${3:?}"

echo "Fixing Helm annotations for release=$RELEASE in ns=$NS on context=$CTX"

# Sweep all namespaced API resources
kubectl --context "$CTX" api-resources --verbs=list --namespaced -o name 2>/dev/null | \
  grep -v '^events\|^endpoints\|^pods\|^replicasets' | \
  while read -r kind; do
    kubectl --context "$CTX" get "$kind" -n "$NS" --no-headers 2>/dev/null | \
      grep "$RELEASE" | awk '{print $1}' | while read -r name; do
        ann=$(kubectl --context "$CTX" get "$kind" "$name" -n "$NS" \
          -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
        if [[ -z "$ann" ]]; then
          kubectl --context "$CTX" annotate "$kind" "$name" -n "$NS" \
            meta.helm.sh/release-name="$RELEASE" \
            meta.helm.sh/release-namespace="$NS" \
            --overwrite 2>/dev/null && echo "FIXED: $kind/$name"
        fi
      done
  done

# Sweep cluster-scoped resources
for kind in clusterrole clusterrolebinding clusterissuer.cert-manager.io; do
  kubectl --context "$CTX" get "$kind" --no-headers 2>/dev/null | \
    grep "$RELEASE" | awk '{print $1}' | while read -r name; do
      ann=$(kubectl --context "$CTX" get "$kind" "$name" \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
      if [[ -z "$ann" ]]; then
        kubectl --context "$CTX" annotate "$kind" "$name" \
          meta.helm.sh/release-name="$RELEASE" \
          meta.helm.sh/release-namespace="$NS" \
          --overwrite 2>/dev/null && echo "FIXED: $kind/$name (cluster-scoped)"
      fi
    done
done

echo "Done. Trigger reconcile:"
echo "  kubectl --context $CTX annotate konk $RELEASE -n $NS konk.infoblox.com/reconcile-trigger=\"\$(date +%s)\" --overwrite"
```

#### For KonkService CRs (different release naming):

```bash
#!/bin/bash
# fix-konkservice-annotations.sh — Fix all failing KonkService CRs
# Usage: ./fix-konkservice-annotations.sh <kubectl-context>

CTX="${1:?Usage: $0 <context>}"

# Get all KonkService CRs across all namespaces
kubectl --context "$CTX" get konkservice --all-namespaces --no-headers 2>/dev/null | \
  while read -r ns name rest; do
    # The Helm release name = KonkService CR name, namespace = CR namespace
    deploy="${name}-konk-service-kubectl-apiservice"
    
    # Check if the deployment is missing annotations
    ann=$(kubectl --context "$CTX" get deploy "$deploy" -n "$ns" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    
    if [[ -z "$ann" ]]; then
      echo "FIXING: $ns/$name (deploy=$deploy)"
      
      # Annotate deployment
      kubectl --context "$CTX" annotate deploy "$deploy" -n "$ns" \
        meta.helm.sh/release-name="$name" \
        meta.helm.sh/release-namespace="$ns" \
        --overwrite 2>/dev/null
      
      # Annotate service if exists
      kubectl --context "$CTX" annotate svc "$deploy" -n "$ns" \
        meta.helm.sh/release-name="$name" \
        meta.helm.sh/release-namespace="$ns" \
        --overwrite 2>/dev/null
      
      # Annotate configmaps
      kubectl --context "$CTX" get cm -n "$ns" --no-headers 2>/dev/null | \
        grep "$name" | awk '{print $1}' | while read -r cm; do
          kubectl --context "$CTX" annotate cm "$cm" -n "$ns" \
            meta.helm.sh/release-name="$name" \
            meta.helm.sh/release-namespace="$ns" \
            --overwrite 2>/dev/null && echo "  FIXED: cm/$cm"
        done
      
      # Trigger reconcile
      kubectl --context "$CTX" annotate konkservice "$name" -n "$ns" \
        konk.infoblox.com/reconcile-trigger="$(date +%s)" --overwrite 2>/dev/null
      
      echo "  Triggered reconcile for $ns/$name"
    fi
  done
```

### Option 2: Pre-Upgrade Hook (Recommended Long-Term)

Add a Kubernetes Job as a Helm pre-upgrade hook in the konk-operator chart that sweeps all managed resources before the operator reconciles:

```yaml
# In the operator's Helm chart: templates/pre-upgrade-annotation-fix.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: konk-annotation-fix
  namespace: {{ .Release.Namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded,hook-failed
spec:
  template:
    spec:
      serviceAccountName: konk-operator  # needs RBAC to annotate
      containers:
      - name: fix
        image: bitnami/kubectl:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          # Sweep all KonkService deployments
          kubectl get konkservice --all-namespaces --no-headers | while read ns name rest; do
            deploy="${name}-konk-service-kubectl-apiservice"
            ann=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
            if [[ -z "$ann" ]]; then
              kubectl annotate deploy "$deploy" -n "$ns" \
                meta.helm.sh/release-name="$name" \
                meta.helm.sh/release-namespace="$ns" --overwrite
            fi
          done
      restartPolicy: Never
  backoffLimit: 1
```

### Option 3: Operator Code Fix (Best Long-Term)

Switch to a **Hybrid Helm operator** with a custom `main.go` that:

1. Calls `DisableStorageOwnerRefInjection(true)` — prevents release secret GC
2. Adds a pre-reconcile step that sweeps existing resources and adds ownership annotations before calling Install
3. Handles the `pending-*` → recovery path without deleting the release

This requires forking the operator initialization from the default `helm-operator run`.

---

## Detection

### How to tell if this issue is active

```bash
# Check KonkService CR conditions — healthy ones show "ReleasedCondition: True"
kubectl --context $CTX get konkservice --all-namespaces \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,MSG:.status.conditions[0].message'

# Check for InstallError/UpgradeError in operator logs
kubectl --context $CTX logs deploy/konk-operator -n konk --since=5m 2>&1 | \
  grep -E '"level":"error"' | grep -oP '"name":"[^"]+"' | sort -u
```

### Healthy vs Unhealthy output

```
# Healthy:
NS        NAME                                STATUS              MSG
atcapi    atcapi-apiservice                   ReleaseFetched      ...

# Unhealthy (annotation issue):
NS        NAME                                STATUS              MSG
ddi       dns-data-importexport-apiservice    <none>              <none>
```

---

## Timeline / Affected Clusters

| Cluster | Date | CRs Affected | Resolution |
|---------|------|--------------|------------|
| us-dev-5 | 2026-06-12 | bulk-konk + 6 KonkServices | Manual annotation sweep |
| us-dev-5 | 2026-06-16 | 6 KonkServices (same set) | Manual annotation sweep |
| us-dev-2 | 2026-06-18 | 4 KonkServices | Manual annotation sweep |

The pattern repeats on **every operator upgrade** because the structural issue (ownerRef on release secrets + no adoption logic) is never addressed.

---

## Why It Appears as "6 out of 17"

The 6 failing KonkServices are consistently the ones with:
- Longer-running workloads (larger deployments, more sidecars)
- Higher reconcile times that overlap with the operator pod termination window
- Resources created by an older operator version that never had annotations set correctly in the first place (pre-existing issue exposed by the upgrade)

The 11 working KonkServices either:
1. Had their resources freshly created by the current operator (no pre-existing conflict)
2. Completed reconcile before the old pod terminated (annotations were already correct)
3. Were reconciled successfully by the new operator on first try (release secret survived)

---

## Recommendations

| Priority | Action | Owner | Effort |
|----------|--------|-------|--------|
| P1 (Now) | Add annotation sweep script to upgrade runbook | SRE | 1 day |
| P2 (Next sprint) | Add pre-upgrade hook Job to operator chart | Konk team | 2-3 days |
| P3 (Backlog) | Switch to Hybrid Helm operator with adoption logic | Konk team | 1-2 weeks |
| P3 (Backlog) | Disable ownerRef injection on release secrets | Konk team | 1 week |
