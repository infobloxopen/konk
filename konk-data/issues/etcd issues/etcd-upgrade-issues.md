# etcd Upgrade Issues — konk-operator HA Upgrade

## Upgrade Goal

Upgrade the konk etcd from single-node `bitnami/etcd:3.4.14` to a 3-replica cluster using `cgr.dev/infoblox.com/etcd:3.7.1` via a new etcd chart version. Changes were delivered via:
- `konk-operator` HelmRelease — new operator version bundling the new etcd chart (`etcd-5.3.2`)
- `bulk` HelmRelease values — originally added explicit HA overrides (later found to be unnecessary; see Issue #6)

The upgrade was tested on `us-dev-5` (box-dev) before promoting to `us-com-1` (com-prod).

---

## Architecture Context

The etcd lifecycle in konk is a layered chain:

```
Flux HelmRelease (bulk)
  → bulk Helm chart renders KonK CR
    → konk-operator reconciles KonK CR, creates Etcd CR
      → etcd-controller (helm operator) reconciles Etcd CR
        → renders bulk-konk-etcd Helm release
          → manages etcd StatefulSet in aggregate namespace
```

Key CRDs involved:
- `konks.konk.infoblox.com` — the top-level KonK instance (e.g. `bulk-konk`)
- `etcds.konk.infoblox.com` — the etcd sub-resource (e.g. `bulk-konk-etcd`)

The `Etcd` CR's spec is used directly as Helm values when the etcd-controller renders the etcd chart. So `spec.statefulset.replicaCount` in the Etcd CR maps to `.Values.statefulset.replicaCount` in the chart.

---

## Issues Encountered

### 1. Operator rollback did not restart etcd pods

**What happened:** Rolling back `konk-operator` to the prod version (`v0.2.1-138-g8b64bf7-j170`) via `helm rollback konk-operator 16 -n vela-system` did not trigger any etcd pod restarts.

**Why:** Rolling back the operator only restarts the operator pod itself. The managed resources (etcd StatefulSet, pods) only change if the operator's reconciliation loop detects a spec diff in the Etcd CR and successfully applies it. Two factors blocked this:
1. `recreateStatefulSet: false` was set in the KonK CR — this flag explicitly prevents the operator from deleting and recreating the StatefulSet even when it reconciles.
2. The Helm upgrade was failing on immutable StatefulSet fields (see Issue #3), so reconciliation never succeeded.

**Diagnosis commands:**
```bash
# Check what image etcd pods are actually running
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Check if operator is reconciling successfully
kubectl logs -n konk -l app.kubernetes.io/name=konk-operator --tail=100 \
  | grep -E "bulk-konk-etcd|error|Error"

# Check Etcd CR status
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}'
```

---

### 2. `bulk` HelmRelease re-applied HA values after manual rollback

**What happened:** Manually rolling back the `bulk` Helm release (`helm rollback bulk 41 -n vela-system`) was repeatedly overwritten. Within minutes, Flux reconciled and re-applied the HA etcd values from git, putting the cluster back into a broken state.

**Why:** The `bulk` HelmRelease was managed by Flux with a short reconciliation interval. Flux continuously compares the cluster state to git and re-applies any drift. Rolling back the Helm release manually creates drift — so Flux immediately re-applies the git state on top.

**Observed pattern from helm history:**
```
Rev 46: Rollback to 41       ← manual rollback
Rev 47: Upgrade complete     ← Flux immediately re-applied HA values
Rev 48: Rollback to 46       ← manual rollback attempt again
Rev 49: Upgrade complete     ← Flux re-applied HA values again
```

**Fix:** Always suspend Flux before manual helm operations:
```bash
flux suspend helmrelease bulk -n vela-system
helm rollback bulk 41 -n vela-system
# ... do the fix ...
flux resume helmrelease bulk -n vela-system
```

---

### 3. Helm upgrade loop — immutable StatefulSet fields

**What happened:** After the HA upgrade deployed a new etcd chart, any attempt to roll back caused an infinite reconciliation failure loop in the operator logs:
```
upgrade failed: cannot patch "bulk-konk-etcd" with kind StatefulSet:
StatefulSet.apps "bulk-konk-etcd" is invalid: spec: Forbidden: updates
to statefulset spec for fields other than 'replicas', 'ordinals',
'template', 'updateStrategy', 'revisionHistoryLimit',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

**Why:** The old etcd chart (`etcd-1.0.0` using `gcr.io/etcd-development/etcd:v3.6.8`) and the new chart (`etcd-5.3.2` using `cgr.dev/infoblox.com/etcd:3.7.1`) have different StatefulSet `selector` labels. Kubernetes treats selector labels as immutable after creation — they cannot be changed via a patch. Helm's upgrade mechanism uses `kubectl patch` under the hood, which Kubernetes rejects.

When the upgrade fails, Helm auto-rolls back by restoring the previous release's manifests — but the Kubernetes StatefulSet object is already stuck with the partially-applied spec. The next reconciliation loop hits the same error, creating an infinite loop:

```
Operator detects diff → helm upgrade → K8s rejects immutable field patch
  → helm auto-rollback → Etcd CR stamped ReleaseFailed → repeat
```

**Diagnosis:**
```bash
# See the failed revision and error in helm history
helm history bulk-konk-etcd -n aggregate

# See the ReleaseFailed condition
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}'
```

**Fix (manual recovery):**
```bash
# 1. Remove the stuck helm release (leaves PVCs intact)
helm uninstall bulk-konk-etcd -n aggregate

# 2. Delete the Etcd CR so the operator recreates it fresh (no stale ReleaseFailed status)
kubectl delete etcds.konk.infoblox.com bulk-konk-etcd -n aggregate

# 3. Watch the operator reinstall from scratch
kubectl get pods -n aggregate -w
```

**Long-term fix:** Set `recreateStatefulSet: true` in the upgrade values. The konk etcd-controller then handles this automatically — it detects the immutable field conflict, deletes the StatefulSet, and lets Helm recreate it. No manual intervention needed:
```yaml
konk:
  custom:
    etcd:
      recreateStatefulSet:
        enabled: true
```

---

### 4. Mixed pod state after partial upgrade

**What happened:** After repeated Helm upgrade/rollback cycles, the StatefulSet spec was updated to `cgr.dev/infoblox.com/etcd:3.7.1` but etcd-0 was still running the old bitnami image from before the spec change. etcd-1 and etcd-2 (newly created pods) crashed immediately with:
```
exec /scripts/setup.sh: no such file or directory
```

**Why:** StatefulSet rolling updates apply from the highest ordinal downward (etcd-2 → etcd-1 → etcd-0). etcd-0 was already Running and not yet updated. etcd-1 and etcd-2 were brand new pods created with the current spec (`cgr.dev/infoblox.com/etcd:3.7.1`). The `cgr.dev` image does not have `/scripts/setup.sh` — that script is specific to the Bitnami etcd image. The rollout stalled with etcd-1/2 in `CrashLoopBackOff`, blocking etcd-0's update.

**Diagnosis:**
```bash
kubectl logs bulk-konk-etcd-1 -n aggregate --previous
kubectl describe pod bulk-konk-etcd-1 -n aggregate | grep Image:
```

---

### 5. Stale `ReleaseFailed` condition on Etcd CR after reinstall

**What happened:** After a clean `helm uninstall` + Etcd CR delete, the health check still reported `ReleaseFailed=True reason=UpgradeError` on the newly created Etcd CR.

**Why:** Because the `bulk` HelmRelease was not suspended (Issue #2), Flux re-applied the HA values before the Etcd CR was fully settled. The etcd-controller picked up the new Etcd CR, attempted an upgrade of the freshly installed release with the HA chart values, hit the immutable field error again, and stamped `ReleaseFailed` on the new CR.

The operator then entered exponential backoff — so even after the situation was logically fixed, the condition persisted until the next retry cycle.

**Fix:** Always suspend `bulk` before uninstalling etcd (see Issue #2). Once suspended, the reinstall proceeds cleanly and the Etcd CR gets `Deployed=True reason=UpgradeSuccessful` without a `ReleaseFailed`.

---

### 6. Silent replica count regression in CVE fix — etcd always ran as 1 replica

**What happened:** During investigation, it was found that `us-com-1` (prod) was already running 3 etcd pods without any explicit `replicaCount` in the DC values files. However, after deploying the CVE fix branch, etcd ran as 1 replica despite the config saying 3. This caused confusion about whether the 3-replica decision was intentional.

Architecture context — the full layered chain from Flux → bulk chart → KonK CR → Etcd CR → StatefulSet, so it's clear why changes propagate slowly and where things break

**Root cause:** The CVE fix (PR #572, commit `7c13757`) replaced the entire Bitnami etcd chart with a custom chart. In doing so, it silently regressed the StatefulSet template from:
```yaml


# old (correct)
replicas: {{ .Values.statefulset.replicaCount }}
```
to:
```yaml
# regression introduced by PR #572
replicas: {{ .Values.replicaCount }}
```

The konk chart's default (since PR #135) has always been:
```yaml
# helm-charts/konk/values.yaml
etcd:
  statefulset:
    replicaCount: 3
```

This passes through to the Etcd CR as `spec.statefulset.replicaCount: 3`, which maps to `.Values.statefulset.replicaCount` in the etcd chart. After the regression, the chart read `.Values.replicaCount` instead (default `1`), so the StatefulSet always rendered with 1 replica — silently ignoring the configured 3.

Additionally, the CVE fix also moved the konk chart default from `etcd.statefulset.replicaCount: 3` to `etcd.replicaCount: 3` (wrong key), compounding the problem.

**Fix (commit `c4dbb7b` on `release/upgrade-etcd`):** Two changes were needed:

1. Restore the etcd chart StatefulSet template and helpers to use `.Values.statefulset.replicaCount` in all call sites:
   - `helm-charts/etcd/templates/statefulset.yaml` — `replicas:` field and HA conditional
   - `helm-charts/etcd/templates/_helpers.tpl` — `etcd.initialCluster` and `etcd.endpoints` helpers

2. Fix the konk chart `values.yaml` default key:
   ```yaml
   # helm-charts/konk/values.yaml
   etcd:
     statefulset:
       replicaCount: 3   # correct key — matches what the etcd chart reads
   ```

**Value chain (verified correct after fix):**
```
konk/values.yaml
  etcd.statefulset.replicaCount: 3
    ↓ toYaml into Etcd CR spec
  spec.statefulset.replicaCount: 3
    ↓ etcd-controller uses Etcd CR spec as helm values
  .Values.statefulset.replicaCount = 3
    ↓ etcd chart statefulset.yaml
  replicas: 3
```

**Impact:** With both fixes, 3 replicas is the default again with no explicit DC config required — identical to prod j170 behavior.

---

## Correct Upgrade Process

1. **Suspend both HelmReleases** to prevent Flux from interfering:
   ```bash
   flux suspend helmrelease konk-operator -n vela-system
   flux suspend helmrelease bulk -n vela-system
   ```

2. **Ensure `recreateStatefulSet: true`** is set in the bulk values so the operator can handle immutable field changes automatically:
   ```yaml
   konk:
     custom:
       etcd:
         recreateStatefulSet:
           enabled: true
   ```

3. **Resume both HelmReleases together** so Flux applies the new operator and new bulk values atomically:
   ```bash
   flux resume helmrelease bulk -n vela-system
   flux resume helmrelease konk-operator -n vela-system
   ```

4. **Monitor the upgrade:**
   ```bash
   # Watch pod rollout
   kubectl get pods -n aggregate -w

   # Check operator reconciliation
   kubectl logs -n konk -l app.kubernetes.io/name=konk-operator --tail=50 \
     | grep -E "bulk-konk-etcd|error|Error"

   # Verify no ReleaseFailed condition
   kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
     -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].status}'
   ```

5. **Verify etcd cluster health** once all 3 pods are Running:
   ```bash
   kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl member list \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key
   ```

---

## Key Learnings

| Lesson | Detail |
|--------|--------|
| Always suspend Flux before manual helm ops | Flux will overwrite any manual rollback within its reconciliation interval |
| `recreateStatefulSet: true` is required for chart changes that touch immutable fields | Without it, the operator loops forever on immutable field errors |
| Operator rollback ≠ managed resource rollback | Rolling back the operator only restarts the operator pod; etcd pods only change if reconciliation succeeds |
| Check the full value chain when debugging replica count | The Etcd CR spec → chart values mapping means a wrong key silently produces the wrong replica count |
| Suspend both HRs and resume together | Upgrading operator and bulk values in lockstep avoids partial state where one is ahead of the other |
