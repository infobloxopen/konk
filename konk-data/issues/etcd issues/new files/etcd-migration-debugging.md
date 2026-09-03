# etcd Upgrade — Migration Debugging Guide

Cluster tested: `us-dev-5` (box-dev)
Upgrade: `bitnami/etcd:3.4.14` → `cgr.dev/infoblox.com/etcd:3.7.1` with 3-replica HA

---

## Architecture — Value Chain

Config flows through 5 layers before reaching the StatefulSet:

```
DC repo (git)
  → Flux applies bulk HelmRelease values (vela-system)
    → bulk chart renders KonK CR spec
      → konk-operator reconciles KonK CR, creates/updates Etcd CR
        → etcd-controller (helm operator) reconciles Etcd CR
          → renders bulk-konk-etcd Helm release
            → manages etcd StatefulSet in aggregate namespace
```

The `Etcd` CR spec is passed directly as Helm values to the etcd chart.
So `spec.statefulset.replicaCount` in the Etcd CR = `.Values.statefulset.replicaCount` in the chart.

---

## Key Resources

| Resource | Namespace | Command |
|----------|-----------|---------|
| KonK CR | aggregate | `kubectl get konk bulk-konk -n aggregate` |
| Etcd CR | aggregate | `kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate` |
| konk-operator pod | konk | `kubectl get pods -n konk \| grep konk-operator` |
| etcd StatefulSet | aggregate | `kubectl get statefulset bulk-konk-etcd -n aggregate` |
| etcd Helm release | aggregate | `helm list -n aggregate \| grep etcd` |
| bulk Helm release | vela-system | `helm list -n vela-system \| grep bulk` |
| konk-operator HR | vela-system | `flux get helmrelease konk-operator -n vela-system` |

---

## Diagnostic Commands

### Check etcd pod status and images
```bash
kubectl get pods -n aggregate | grep etcd

# Check what image each pod is actually running
kubectl get pod bulk-konk-etcd-0 -n aggregate -o jsonpath='{.spec.containers[0].image}'

# Check StatefulSet desired spec vs running pods
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='replicas={.spec.replicas} ready={.status.readyReplicas} image={.spec.template.spec.containers[0].image}'
```

### Check Etcd CR health
```bash
# Quick status
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate

# Check for ReleaseFailed condition (main failure indicator)
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}'

# Check deployed vs failed reason
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='Deployed={.status.conditions[?(@.type=="Deployed")].reason} ReleaseFailed={.status.conditions[?(@.type=="ReleaseFailed")].status}'

# Full Etcd CR spec (desired state)
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate -o yaml | grep -A30 "^spec:"

# Check replicaCount in Etcd CR
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='replicaCount={.spec.statefulset.replicaCount}'
```

### Check Helm release state
```bash
# See full revision history and failed upgrades
helm history bulk-konk-etcd -n aggregate

# Current deployed values
helm get values bulk-konk-etcd -n aggregate

# Check bulk HR values (source of etcd config)
helm get values bulk -n vela-system | grep -A15 etcd
```

### Check operator logs
```bash
# Filter for bulk-konk-etcd reconciliation activity
kubectl logs -n konk -l app.kubernetes.io/name=konk-operator --tail=200 \
  | grep -E "bulk-konk-etcd|error|Error|immutable|Forbidden"

# Watch operator logs live
kubectl logs -n konk -l app.kubernetes.io/name=konk-operator -f \
  | grep -E "bulk-konk-etcd|error|Error"
```

### Check Flux HelmRelease status
```bash
flux get helmrelease bulk -n vela-system
flux get helmrelease konk-operator -n vela-system
```

### Check PVCs
```bash
kubectl get pvc -n aggregate
# old bitnami PVCs: data-bulk-konk-etcd-* (mount path /bitnami/etcd)
# new cgr PVCs:    data-v2-bulk-konk-etcd-* (mount path /var/lib/etcd)
```

### Check etcd cluster health (when pods are running)
```bash
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl member list \
  --endpoints=https://localhost:2379 \
  --cacert=/opt/bitnami/etcd/certs/client/ca.crt \
  --cert=/opt/bitnami/etcd/certs/client/tls.crt \
  --key=/opt/bitnami/etcd/certs/client/tls.key
```

---

## Issues Hit and Fixes

### Issue 1 — Operator rollback did not restart etcd pods

Rolling back `konk-operator` via helm did not restart etcd pods.

**Why:** The operator pod restarts but etcd StatefulSet only changes if reconciliation detects a spec diff AND can apply it. Blocked by:
- `recreateStatefulSet: false` prevents StatefulSet deletion/recreation
- Helm upgrade was failing on immutable fields (see Issue 3)

**Diagnose:**
```bash
# Confirm etcd pod images haven't changed
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

### Issue 2 — Flux kept re-applying HA values after manual rollback

Manual `helm rollback bulk` was overwritten by Flux repeatedly.

**Observed pattern:**
```
Rev 46: Rollback to 41       ← manual rollback
Rev 47: Upgrade complete     ← Flux re-applied HA values from git
Rev 48: Rollback to 46       ← manual rollback again
Rev 49: Upgrade complete     ← Flux re-applied again
```

**Fix — always suspend Flux before manual helm operations:**
```bash
flux suspend helmrelease bulk -n vela-system
flux suspend helmrelease konk-operator -n vela-system

# ... do manual operations ...

flux resume helmrelease bulk -n vela-system
flux resume helmrelease konk-operator -n vela-system
```

---

### Issue 3 — Helm upgrade loop: immutable StatefulSet fields

**Symptom:** `ReleaseFailed=True` with error:
```
upgrade failed: cannot patch "bulk-konk-etcd" with kind StatefulSet:
StatefulSet.apps "bulk-konk-etcd" is invalid: spec: Forbidden: updates
to statefulset spec for fields other than 'replicas', 'ordinals',
'template', 'updateStrategy', 'revisionHistoryLimit',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

**Why:** The etcd chart change modified `selector` labels or `volumeClaimTemplates` (immutable Kubernetes fields). Helm can't patch them. Helm auto-rolls back but the loop repeats on every reconciliation.

**Diagnose:**
```bash
# See the failed revision
helm history bulk-konk-etcd -n aggregate | grep failed

# See the ReleaseFailed message
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="ReleaseFailed")].message}'
```

**Manual recovery (when operator is stuck):**
```bash
# Option A: Delete StatefulSet only (operator retries upgrade fresh)
kubectl delete statefulset bulk-konk-etcd -n aggregate
# Watch helm history — next reconciliation should show "Upgrade complete"
helm history bulk-konk-etcd -n aggregate

# Option B: Full reset (use when helm release itself is corrupt)
helm uninstall bulk-konk-etcd -n aggregate
kubectl delete etcds.konk.infoblox.com bulk-konk-etcd -n aggregate
# konk-operator recreates the Etcd CR → fresh helm install
kubectl get pods -n aggregate -w
```

**Permanent fix — add to upgrade values:**
```yaml
konk:
  custom:
    etcd:
      recreateStatefulSet:
        enabled: true   # operator auto-deletes StatefulSet when immutable fields change
```

---

### Issue 4 — Mixed pod state / CrashLoopBackOff after partial upgrade

etcd-0 ran old bitnami image, etcd-1/2 crashed with:
```
exec /scripts/setup.sh: no such file or directory
```

**Why:** StatefulSet rolling update goes highest-ordinal first (etcd-2 → etcd-1 → etcd-0). New pods got the new spec (cgr.dev image) which has no `/scripts/setup.sh` (bitnami-specific). Rollout stalled.

**Diagnose:**
```bash
kubectl logs bulk-konk-etcd-1 -n aggregate --previous
kubectl describe pod bulk-konk-etcd-1 -n aggregate | grep Image:
```

**Fix:** Delete StatefulSet and let operator reinstall fresh.

---

### Issue 5 — Stale ReleaseFailed on Etcd CR after reinstall

Even after clean reinstall, health check showed `ReleaseFailed=True`.

**Why:** Flux re-applied HA values before Etcd CR was fully recreated. New upgrade attempt hit the same immutable field error, stamping `ReleaseFailed` on the fresh CR.

**Fix:** Suspend Flux (Issue 2) before doing the reinstall.

---

### Issue 6 — Silent replicaCount regression in CVE fix (PR #572)

**Symptom:** Prod (`us-com-1`) was running 3 etcd pods. After deploying the CVE fix branch, etcd ran as 1 replica despite config saying 3.

**Why:** The CVE fix (commit `7c13757`) rewrote the etcd chart and changed the StatefulSet template:
```diff
- replicas: {{ .Values.statefulset.replicaCount }}
+ replicas: {{ .Values.replicaCount }}
```
The konk chart default has always been `etcd.statefulset.replicaCount: 3` (since PR #135). After the regression, the template read `.Values.replicaCount` (default 1), silently ignoring the configured value.

Additionally, the konk chart `values.yaml` was changed from:
```yaml
etcd:
  statefulset:
    replicaCount: 3
```
to:
```yaml
etcd:
  replicaCount: 3   # wrong key — never read by the template
```

**Fix (commit `c4dbb7b` on `release/upgrade-etcd`):**
1. Restored etcd chart template to use `.Values.statefulset.replicaCount` in all three call sites
2. Restored konk chart `values.yaml` default to `etcd.statefulset.replicaCount: 3`

**Result:** 3 replicas is the default — no explicit DC config override needed.

---

### Issue 7 — claimName change causes immutable volumeClaimTemplates

**Why `claimName: data-v2` is required:**

| | Bitnami (j170 prod) | CGR (new) |
|---|---|---|
| Image | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` | `cgr.dev/infoblox.com/etcd:3.7.1` |
| PVC mount path | `/bitnami/etcd` | `/var/lib/etcd` |
| ETCD_DATA_DIR | `/bitnami/etcd/data` | `/var/lib/etcd` |
| member/ on PVC | `data/member/` | `member/` |

Reusing old bitnami PVCs with the new image causes a path mismatch — etcd looks for `member/` but finds `data/member/`. A new claim name (`data-v2`) is required to use fresh PVCs with the correct directory structure.

**However**, changing `volumeClaimTemplates` is an immutable StatefulSet field. This is why `recreateStatefulSet: true` is mandatory when changing `claimName`.

---

### Issue 8 — initialClusterState: existing works with data-v2 PVCs

The `data-v2` PVCs were previously populated by the gcr.io etcd v3.6.8 HA cluster. When upgrading to cgr.dev etcd v3.7.1:

- `initialClusterState: existing` correctly instructs etcd to restore from existing PVC data
- etcd automatically upgrades storage from v3.6 → v3.7 format on first start
- Confirmed in logs: `updated cluster version from 3.6 to 3.7`

`initialClusterState: new` would fail if the `data-v2` PVCs already contain etcd data (etcd refuses to start with existing data directory in `new` mode).

---

## Validated Working Upgrade Values

```yaml
konk:
  custom:
    etcd:
      recreateStatefulSet:
        enabled: true            # REQUIRED: handles immutable StatefulSet fields
      persistence:
        claimName: data-v2       # REQUIRED: avoids bitnami path clash on PVCs
      etcd:
        initialClusterState: existing   # restores from data-v2 PVCs
      statefulset:
        replicaCount: 3
```

**Do NOT need to set replicaCount in DC values** — the chart default is 3 (after fix in `c4dbb7b`).

---

## Correct Full Upgrade Process

```bash
# 1. Suspend both HelmReleases to prevent Flux interference
flux suspend helmrelease konk-operator -n vela-system
flux suspend helmrelease bulk -n vela-system

# 2. Resume both together (atomic apply of new operator + new values)
flux resume helmrelease bulk -n vela-system
flux resume helmrelease konk-operator -n vela-system

# 3. Monitor the upgrade
kubectl get pods -n aggregate -w

# 4. If stuck in ReleaseFailed loop (immutable fields) and recreateStatefulSet is false:
kubectl delete statefulset bulk-konk-etcd -n aggregate
# Then watch operator reconcile — next helm revision should be "Upgrade complete"
helm history bulk-konk-etcd -n aggregate

# 5. Verify cluster health
kubectl get pods -n aggregate | grep etcd
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='Deployed={.status.conditions[?(@.type=="Deployed")].reason} ReleaseFailed={.status.conditions[?(@.type=="ReleaseFailed")].status}'
```

---

## Final Confirmed State (us-dev-5, 2026-08-04)

```
bulk-konk-etcd-0   1/1   Running   cgr.dev/infoblox.com/etcd:3.7.1
bulk-konk-etcd-1   1/1   Running   cgr.dev/infoblox.com/etcd:3.7.1
bulk-konk-etcd-2   1/1   Running   cgr.dev/infoblox.com/etcd:3.7.1

Helm release: etcd-1.1.2  revision 241  STATUS: deployed
Etcd CR: Deployed=UpgradeSuccessful, ReleaseFailed=False
Cluster: leader elected, version upgraded 3.6 → 3.7
```
