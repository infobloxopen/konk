# Helm Revision Number Increases — bulk-konk-etcd

**Date:** 2026-06-25
**Clusters affected:** us-dev-4, us-dev-5
**Status:** Resolved (PR #135031)

---

## Symptom

After deploying PR #135020 (konk-operator etcd migration with Option B), Helm revision numbers for `bulk-konk-etcd` and `bulk-konk` kept climbing:

| Cluster | Release | Before | After | Stabilized at |
|---------|---------|--------|-------|---------------|
| us-dev-4 | bulk-konk-etcd | 107 | 114 | 114 |
| us-dev-4 | bulk-konk | 11 | 18 | 18 |
| us-dev-5 | bulk-konk-etcd | ~107 | 113 | 113 |

Revisions increased by ~7 over several hours, then stopped after PR #135031 merged.

---

## Root Cause

`recreateStatefulSet.enabled: true` was left in `bulk-values.yaml` after the initial migration succeeded.

This value gates a pre-upgrade hook in the etcd chart that deletes the StatefulSet (with `--cascade=orphan`) so Helm can recreate it with immutable field changes (VCT name). The hook fires on **every** `helm upgrade` — including no-op reconciles by the operator.

**Chain of events:**
1. Operator reconciles Etcd CR (periodic, every few minutes)
2. Detects spec matches → runs `helm upgrade` (since values haven't changed, this is effectively a no-op)
3. But `recreateStatefulSet.enabled: true` → pre-upgrade hook fires → deletes STS with `--cascade=orphan`
4. Helm recreates STS with identical spec → STS re-adopts existing pods
5. Revision bumps by 1
6. Repeat on next reconcile

The `bulk-konk` (Konk chart) revision also increased because the Konk CR's `spec.etcd.*` values flow through it, and the same reconcile pattern applies.

---

## Actual Impact

**Operationally harmless:**
- etcd pods were **NOT** restarted (orphan cascade keeps pods running)
- No etcd downtime, no quorum loss
- No effect on bulk aggregate APIs
- `maxHistory=1` on the operator means only 1 release secret exists at a time (no storage bloat)

**Cosmetically noisy:**
- Revision numbers increment unnecessarily
- Operator doing pointless work (delete STS → recreate identical STS)

**Pod restarts observed were unrelated** — staggered uptimes (13h, 8h, 7h49m) were from normal Karpenter node rotation on dev clusters, not from the hook.

---

## Fix

PR #135031 reverted the one-shot migration values:

```yaml
# Before (causing churn)
recreateStatefulSet:
  enabled: true
etcd:
  initialClusterState: "new"

# After (stable)
recreateStatefulSet:
  enabled: false
etcd:
  initialClusterState: "existing"
```

Once Flux propagated the new values, the operator's next reconcile produced no diff → no `helm upgrade` → revisions stabilized.

---

## Comparison: Normal Behavior

On **us-com-1** (prod), the same operator image (j170) has maintained:
- `bulk-konk`: revision **1** since 2023-09-28
- `bulk-konk-etcd`: revision **2** since 2023-09-28

The Helm operator does NOT bump revisions on every reconcile. It only runs `helm upgrade` when the rendered values/spec differ from the deployed release. The churn on dev was specifically caused by the `recreateStatefulSet` hook being a stateful side-effect (STS deletion) that triggers on every upgrade regardless of whether the manifest changed.

---

## Lesson for Prod Migration

When deploying Option B to prod:
1. Deploy with `recreateStatefulSet.enabled: true` + `initialClusterState: "new"` (one-shot migration)
2. **Immediately follow up** with a revert PR setting both back (`false` / `"existing"`)
3. Do NOT leave the one-shot values in place — they cause harmless but confusing revision churn

The revert PR should be prepared in advance and merged as soon as migration is confirmed healthy (etcd 3/3 Running, member list shows 3 members, bulk-konk 1/1).

---

## What Would Happen If It Continued

- **Revision numbers** would keep climbing indefinitely (no hard limit)
- **No functional impact** on etcd or bulk services (pods not restarted)
- **New releases** (e.g., a legitimate operator version bump) would still work normally — the operator sees a spec change and runs `helm upgrade` as usual. High revision numbers don't block anything.
- **Only risk:** if the hook implementation changed to NOT use `--cascade=orphan`, then pods would be deleted on every cycle → repeated etcd restarts → ~30-60s API disruption per cycle




us-dev-4

 helm list -n aggregate
NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	11      	2026-06-24 13:48:41.366728013 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	107     	2026-06-24 13:48:24.878169659 +0000 UTC	deployed	etcd-1.0.0	3.5.17 

 helm list -n aggregate                        
NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	18      	2026-06-24 15:49:49.918480694 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	114     	2026-06-24 15:49:50.994997891 +0000 UTC	deployed	etcd-1.0.0	3.5.17   

NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	2       	2026-06-25 11:55:26.982475574 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	121     	2026-06-25 11:55:26.743536807 +0000 UTC	deployed	etcd-1.0.0	3.5.17  


us-dev-5                   

NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	2       	2026-06-23 14:32:57.571484903 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	113     	2026-06-23 14:32:58.521373002 +0000 UTC	deployed	etcd-1.0.0	3.5.17    

NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	3       	2026-06-25 07:39:59.733479678 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	114     	2026-06-25 07:40:00.67241172 +0000 UTC 	deployed	etcd-1.0.0	3.5.17 



us-stg-1

bulk-konk     	aggregate	7       	2026-06-19 06:48:36.664432633 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	3       	2026-06-19 07:56:37.863130848 +0000 UTC	deployed	etcd-5.3.2	3.4.14   

NAME          	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART     	APP VERSION
bulk-konk     	aggregate	11      	2026-06-25 16:08:35.218965724 +0000 UTC	deployed	konk-0.1.0	v1.25.8    
bulk-konk-etcd	aggregate	4       	2026-06-25 16:08:36.175823229 +0000 UTC	deployed	etcd-1.0.0	3.5.17