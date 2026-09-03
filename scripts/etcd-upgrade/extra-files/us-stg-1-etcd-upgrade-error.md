# us-stg-1 etcd PVC Migration — ETCD_NAME Env Var Bug

**Cluster:** us-stg-1  
**Namespace:** aggregate  
**Date:** 2025-06-25  
**PR:** #134685 (DC repo)  
**Operator version:** `v0.2.1-154-g1de007e-j20`  
**Pre-upgrade etcd:** 3.4.14 (Bitnami), 1 replica, VCT=`data`  
**Post-upgrade etcd:** 3.6.8 (upstream), 3 replicas, VCT=`data-v2`  

---

## Issue: ETCD_NAME Dual value/valueFrom

### Symptom

After PR #134685 merged and the operator reconciled, the `bulk-konk-etcd` StatefulSet was updated but pods failed to create with:

```
Invalid value: "": may not be specified when `value` is not empty
```

The STS existed with `replicas=3` but 0 pods were running.

### Root Cause

**NOT a chart code bug.** The j20 etcd chart template only has `valueFrom` for `ETCD_NAME` — no `value`. The diff between j16 and j20 is only Helm ownership annotations (`meta.helm.sh/release-name`); the env var template is identical in both.

The dual value/valueFrom is a **Kubernetes strategic merge patch artifact** during the Bitnami→upstream chart transition.

**Old Bitnami chart** (live on cluster before migration):
```yaml
- name: MY_POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: ETCD_NAME
  value: "$(MY_POD_NAME)"        # K8s variable substitution
```

**New upstream chart** (desired state):
```yaml
- name: ETCD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name   # Direct fieldRef, no intermediate env var
```

The Helm operator SDK (operator-sdk v1.42.0) uses `action.Upgrade` which applies a **three-way strategic merge patch** to existing resources. For the `env` array, the merge key is `name`. When merging the `ETCD_NAME` entry, the patch **adds** `valueFrom` from the new chart but **fails to remove** `value` from the old Bitnami state, producing:

```yaml
- name: ETCD_NAME
  value: "$(MY_POD_NAME)"         # ← stale, from old Bitnami STS
  valueFrom:                      # ← new, from upstream chart
    fieldRef:
      fieldPath: metadata.name
```

Kubernetes rejects this at pod creation — a container env var must have either `value` or `valueFrom`, not both.

The env var was at **index 4** in the container's env array.

### Why us-dev-5 Didn't Hit This

Both us-dev-5 and us-stg-1 run the same operator (j20, `v0.2.1-154-g1de007e-j20`) and the same etcd chart. The chart code is identical. The difference is in **runtime behavior**:

The `recreateStatefulSet` pre-upgrade hook is designed to prevent exactly this issue — it deletes the old STS before Helm tries to patch it, forcing a fresh CREATE (no merge). On us-dev-5, the hook fired before the strategic merge occurred, so the STS was created clean. On us-stg-1, the operator's reconcile loop patched the STS before the hook could fire, resulting in the merged env vars.

This is a **timing/race condition** in the operator-sdk Helm operator's reconcile vs upgrade paths, not a chart or code bug.

### Diagnosis Commands

Identify the problem — dump all env vars on the STS to find the conflicting entry:

```bash
kubectl --context us-stg-1 get sts bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\t"}{.value}{"\t"}{.valueFrom}{"\n"}{end}'
```

Confirm the index of `ETCD_NAME` (index 4):

```bash
kubectl --context us-stg-1 get sts bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.template.spec.containers[0].env[4]}'
```

### Fix Applied

Manual JSON patch to remove the conflicting `valueFrom` field from `ETCD_NAME` (env index 4), keeping `value`:

```bash
kubectl --context us-stg-1 patch sts bulk-konk-etcd -n aggregate \
  --type=json \
  -p '[{"op": "remove", "path": "/spec/template/spec/containers/0/env/4/valueFrom"}]'
```

After the patch, pods started creating immediately.

### Self-Correcting Behavior

The bug only appeared on the **initial** STS (before the `recreateStatefulSet` hook ran). Once pods were able to start:

1. The `recreateStatefulSet` pre-upgrade hook job (`bulk-konk-etcd-recreate-sts`) fired
2. The hook deleted the old STS
3. Helm recreated the STS with VCT=`data-v2`
4. The **recreated** STS had a clean `ETCD_NAME` — only `valueFrom`:

```yaml
env:
  - name: ETCD_NAME
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.name
```

The hook forces a fresh CREATE (no strategic merge), so the new STS gets the chart's clean env spec. The chart code was always correct — the issue was only in the merge path.

---

## Migration Result

### Post-Upgrade Verification

| Check | Result |
|-------|--------|
| VCT | `data-v2` ✅ |
| ETCD_NAME env | Clean — only `valueFrom` ✅ |
| Pods | 3/3 Running (0 restarts) ✅ |
| Members | 3 `started`, no learners ✅ |
| Health | healthy, 7.8ms commit ✅ |
| etcd version | 3.6.8 (storage 3.6.0) ✅ |
| DB size | 115 kB ✅ |
| Keys | 164 (KonkServices populating) ✅ |
| Helm rev | 4 `deployed` ✅ |
| Konk CR | `UpgradeSuccessful` ✅ |
| New PVCs | `data-v2-bulk-konk-etcd-{0,1,2}` Bound ✅ |
| Old PVCs | `data-bulk-konk-etcd-{0,1,2}` retained ✅ |

### PVC State

```
data-bulk-konk-etcd-0      Bound   8Gi   gp3   (old, retained)
data-bulk-konk-etcd-1      Bound   8Gi   gp3   (old, retained)
data-bulk-konk-etcd-2      Bound   8Gi   gp3   (old, retained)
data-v2-bulk-konk-etcd-0   Bound   8Gi   gp3   (new, active)
data-v2-bulk-konk-etcd-1   Bound   8Gi   gp3   (new, active)
data-v2-bulk-konk-etcd-2   Bound   8Gi   gp3   (new, active)
```

### Pending Follow-Up

- [ ] Run full post-upgrade validation (post-upgrade.sh)
- [ ] Check for x509 CA mismatch (same issue as us-dev-5 expected)
- [ ] Check for Helm annotation issues on KonkService Deployments
- [ ] ~File chart bug~ — NOT a chart bug; strategic merge patch artifact from Bitnami→upstream transition
- [ ] Clean up old `data-bulk-konk-etcd-*` PVCs after validation period

---

## Workarounds for Future Clusters

### Workaround A: Pre-Patch STS Before Merging DC PR (Operational)

Before merging the DC migration PR, patch the live STS to align env vars with the
new chart. This eliminates the strategic merge conflict before it happens.

```bash
CTX=<cluster>; NS=aggregate

# 1. Find the ETCD_NAME index (look for the line number)
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | grep -n ETCD_NAME
# Output: "5:ETCD_NAME" → index = line_number - 1 = 4

# 2. Pre-patch: replace value with valueFrom (adjust index from step 1)
IDX=4
kubectl --context $CTX patch sts bulk-konk-etcd -n $NS --type=json -p "[
  {\"op\": \"remove\", \"path\": \"/spec/template/spec/containers/0/env/${IDX}/value\"},
  {\"op\": \"add\",    \"path\": \"/spec/template/spec/containers/0/env/${IDX}/valueFrom\",
   \"value\": {\"fieldRef\": {\"fieldPath\": \"metadata.name\"}}}
]"

# 3. Verify — should show only valueFrom, no value
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ETCD_NAME")]}' \
  | python3 -m json.tool

# 4. NOW merge the DC PR — strategic merge sees matching env vars, no conflict
```

**Use for:** Clusters that still have old Bitnami STS (e.g., us-dev-4 before PR #135020 merge).

### Workaround B: Chart Fix — Always Recreate STS When Hook Enabled (Long-Term)

Widen the `recreateStatefulSet` hook condition to always delete and recreate the STS
when `recreateStatefulSet.enabled=true`, regardless of whether VCT changed. This
forces a fresh CREATE (no strategic merge path at all).

**Change in** `helm-charts/etcd/templates/recreate-statefulset-hook.yaml`:
```diff
- {{- if and $currentClaim (ne $currentClaim $target) }}
+ {{- if $currentClaim }}
```

This is safe because `recreateStatefulSet.enabled` is manually set for migration and
removed after. The hook only fires during Helm upgrades (not periodic reconciles).

**PR:** konk repo — `fix/recreate-sts-always-when-enabled`

### Workaround C: Manual Patch After the Fact (Reactive)

If the dual value/valueFrom issue is already present (pods failing to create):

```bash
CTX=<cluster>; NS=aggregate; IDX=4
kubectl --context $CTX patch sts bulk-konk-etcd -n $NS --type=json \
  -p "[{\"op\": \"remove\", \"path\": \"/spec/template/spec/containers/0/env/${IDX}/valueFrom\"}]"
```

The hook will eventually fire and recreate the STS with clean env vars. This is what
was done on us-stg-1.
