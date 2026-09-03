# bulk-konk etcd Automatic Restart Issue

**Date observed:** 2026-08-11 to 2026-08-12  
**Investigated by:** rsatal  
**Status:** Root cause confirmed — fixes pending

---

## Summary

`bulk-konk-etcd` pods are restarting automatically across multiple clusters. Clusters are affected by **different causes** depending on which konk branch their image was built from.

The `recreateStatefulSet.enabled` and `initialClusterState` flags are **new flags only added in the `release/upgrade-etcd` branch** of the konk repo. They only exist in the bulk chart bundled with images from that branch. Clusters running konk images from other branches (`main`, older releases) do not have the hook template at all — the values in DC repo are irrelevant for those clusters.

- **us-stg-1 and us-dev-5** run images from `release/upgrade-etcd` → have the `recreateStatefulSet` hook → affected by the flag being left `true`
- **us-dev-2, us-dev-4, gov-stg-2** run images from `main`/other branches → hook template does not exist → rolling is from a different cause (bulk chart spec changes triggering STS RollingUpdate or recreation)
- **eu-stg-1** runs an old image (pre-upgrade branch), single replica, separate issue

---

## Cluster Status Table

| Cluster | konk image / branch | etcd image | Bulk chart | Last upgraded | `recreateStatefulSet` flag applies? | `ETCD_INITIAL_CLUSTER_STATE` (live) | etcd pod ages (2026-08-12) | Status | Fix needed |
|---------|--------------------|-----------|-----------|--------------|------------------------------------|--------------------------------------|---------------------------|--------|------------|
| **us-stg-1** | `v0.2.1-158-gf8540d7-j26` / **release/upgrade-etcd** | `cgr.dev/…/etcd:3.7.0` | v2.5.0-75 | 2026-08-05 | **YES** — `true` ❌ + `new` ❌ | `new` ❌ | Rolling (etcd-0 live Aug 12) | **BROKEN** | **YES — PR #143226** |
| **us-dev-5** | `v0.2.1-158-gf8540d7-j26` / **release/upgrade-etcd** | `cgr.dev/…/etcd:3.7.1` | v2.5.0-92 | 2026-08-11 23:21 | **YES** — `true` ❌ + `new` ❌ | `new` ❌ | 26h / 7d6h / 5d16h | **BROKEN** | **YES — PR #143226** |
| **us-dev-2** | `v0.2.1-164-gbd3f28a` / main | `cgr.dev/…/etcd:3.7.0` | v2.5.0-90 | 2026-08-11 13:44 | No — hook not in chart | `existing` ✅ | 25h / 16h / 6h21m | Rolled on upgrade, now complete | No (different cause) |
| **us-dev-4** | `v0.2.1-164-gbd3f28a` / main | `cgr.dev/…/etcd:3.7.0` | v2.5.0-75 | 2026-07-15 | No — hook not in chart | `existing` ✅ | 6d14h / 6d3h / 6d17h | **STABLE** | No |
| **gov-stg-2** | (gov registry) / main | `cgr.dev/…/etcd:v3.7.0` | v2.5.0-92 | 2026-08-11 23:38 | No — hook not in chart | `existing` ✅ | 33m / 16h / 19m | Rolled on upgrade, now complete | No (different cause) |
| **eu-stg-1** | `v0.2.1-138-g8b64bf7-j170` / old | `bitnami/etcd:3.4.14` | v2.5.0-75 | 2026-07-29 | No — hook not in chart | n/a (1 replica) | 4d21h | Stable (single replica) | No (separate issue) |

### etcd version context

| etcd image | Branch | Clusters |
|-----------|--------|---------|
| `bitnami/etcd:3.4.14` | Pre-upgrade (old) | eu-stg-1 only — upgrade reverted Jun 24 |
| `cgr.dev/infoblox.com/etcd:3.7.0` | Post-upgrade (distroless) | us-dev-2, us-dev-4, us-stg-1, gov-stg-2 |
| `cgr.dev/infoblox.com/etcd:3.7.1` | Post-upgrade (distroless, newer) | us-dev-5 |

### konk image / branch context

| konk image | Branch | `recreateStatefulSet` hook in chart? |
|-----------|--------|--------------------------------------|
| `v0.2.1-138-g8b64bf7-j170` | old release | No |
| `v0.2.1-158-gf8540d7-j26` | **release/upgrade-etcd** | **YES** |
| `v0.2.1-164-gbd3f28a` | main | No |

---

## Root Cause

### The `recreateStatefulSet` hook — only in `release/upgrade-etcd`

The `recreateStatefulSet.enabled` flag and its `pre-upgrade` Helm hook were introduced exclusively in the **`release/upgrade-etcd`** branch of the konk repo as part of the etcd 3.4 → 3.7 migration. The hook runs:

```bash
kubectl delete statefulset bulk-konk-etcd --wait=true
```

This deletes **all 3 etcd members simultaneously**, then lets the StatefulSet controller recreate them in ascending order (etcd-0 → etcd-1 → etcd-2), waiting for each to be Ready before creating the next. This was designed as a one-time migration operation. The flag was never set back to `false` in DC after the migration completed.

**This hook only exists in clusters running konk images from `release/upgrade-etcd`** (`v0.2.1-158-gf8540d7-j26`). Clusters on `main` or other branches do not have this hook — the `recreateStatefulSet.enabled` value in their DC `bulk-values.yaml` is irrelevant.

### Flag: `initialClusterState: "new"`

Also only in `release/upgrade-etcd`. When etcd members restart after STS deletion, `"new"` tells each member to bootstrap a fresh cluster instead of rejoining peers. This causes prolonged quorum failure — members compete as cluster founders rather than syncing. The correct post-migration value is `"existing"`.

### Why the hook fires automatically on us-stg-1 and us-dev-5

The bulk Helm release is upgraded whenever a new chart version is promoted (via Flux HelmRelease). The konk-operator also reconciles managed Konk CRs; when the operator pod restarts (node eviction, pod eviction, rolling update), it re-reconciles all CRs and can trigger a bulk Helm upgrade. Any such upgrade with `recreateStatefulSet.enabled: true` in the incoming values fires the hook.

### Why us-dev-2 and gov-stg-2 also rolled (different cause)

These clusters run konk images from `main` — **no `recreateStatefulSet` hook exists in their charts**. Their etcd pods rolled because the bulk chart was upgraded to a new version (v2.5.0-90 and v2.5.0-92 respectively on Aug 11) that changed the etcd StatefulSet spec (new image, resources, or config). Kubernetes applied this as either a normal RollingUpdate or STS recreation due to an immutable field change. Both clusters recovered cleanly with `ETCD_INITIAL_CLUSTER_STATE=existing` (correct default). This is a one-time event per chart upgrade, not a recurring issue.

---

## Evidence Per Cluster

### us-stg-1 — CRITICAL (explicit dangerous flags)

```yaml
# envs/com-stage/us-stg-1/bulk-values.yaml
konk:
  custom:
    etcd:
      etcd:
        initialClusterState: "new"      # ← should be "existing"
      recreateStatefulSet:
        enabled: true                    # ← should be false
```

- Bulk chart v2.5.0-75, last upgraded 2026-08-05T12:02:07Z (v16)
- konk-operator pod restarted ~2026-08-11 21:00 UTC → triggered reconciliation → fired hook
- etcd rolling pattern (etcd-1 → etcd-2 → etcd-0 over 17h) from hook + `"new"` prolonging recovery
- All KonkService namespaces (tagging-v2, ngp-cp, redirect, ddi, hostapp, atcapi…) experienced simultaneous probe flapping
- Simultaneous recovery at 14:27:16–14:27:20 UTC Aug 11 across all three namespaces (within 4s) — confirms shared cause

### us-dev-5 — CRITICAL (explicit dangerous flags)

```yaml
# envs/box-dev/us-dev-5/bulk-values.yaml
konk:
  custom:
    etcd:
      recreateStatefulSet:
        enabled: true                    # ← should be false
      etcd:
        initialClusterState: "new"      # ← should be "existing"
```

- Bulk chart v2.5.0-92, last upgraded 2026-08-11T23:21:04Z
- etcd-0 (26h) restarted before that upgrade; etcd-1 (7d6h) and etcd-2 (5d16h) are older

### us-dev-2 — chart default fired on upgrade

- No `recreateStatefulSet` or `initialClusterState` in `envs/box-dev/us-dev-2/bulk-values.yaml`
- Chart default `true` fired when bulk chart upgraded to v2.5.0-90 at 2026-08-11 13:44 UTC
- STS deleted → recreated in ascending order (etcd-0 at ~13:54 UTC, etcd-1 ~9h later, etcd-2 ~9h after that)
- `initialClusterState` chart default is `existing` → cluster eventually recovered
- Rolling now complete (`currentRevision == updateRevision`, 3/3 Ready)
- Next bulk chart upgrade will re-trigger the hook

### gov-stg-2 — chart default fired on upgrade

- No `recreateStatefulSet` in `envs/gov-box-stage/gov-stg-2/bulk-values.yaml`
- Chart default `true` fired when bulk chart upgraded to v2.5.0-92 at 2026-08-11 23:38 UTC
- `ETCD_INITIAL_CLUSTER_STATE=existing` (chart default) → recovered
- RollingUpdate complete (`currentRevision == updateRevision`, 3/3 Ready)
- Pod creation timeline: etcd-1 at 23:06 UTC Aug 11, etcd-0 at 14:51 UTC Aug 12, etcd-2 at 15:05 UTC Aug 12
- Next bulk chart upgrade will re-trigger the hook

### us-dev-2 — different cause, no hook in chart

- konk image: `v0.2.1-164-gbd3f28a` (main branch) — **no `recreateStatefulSet` hook in chart**
- Bulk chart upgraded to v2.5.0-90 at 2026-08-11 13:44 UTC — new chart version changed STS spec
- etcd pods rolled in creation order (etcd-0: 25h, etcd-1: 16h, etcd-2: 6h21m) with ~9h gaps — consistent with STS recreation due to immutable field change in new chart version
- `ETCD_INITIAL_CLUSTER_STATE=existing` → recovered cleanly, now stable (3/3 Ready, `currentRevision == updateRevision`)
- Not a persistent issue — only happens when bulk chart version changes

### gov-stg-2 — different cause, no hook in chart

- konk image: gov registry / main branch — **no `recreateStatefulSet` hook in chart**
- Bulk chart upgraded to v2.5.0-92 at 2026-08-11 23:38 UTC
- etcd-1 created at 23:06 UTC Aug 11 (during upgrade), etcd-0 and etcd-2 created Aug 12
- `ETCD_INITIAL_CLUSTER_STATE=existing` → recovered cleanly (3/3 Ready, `currentRevision == updateRevision`)
- Same one-time chart-upgrade mechanism as us-dev-2

### us-dev-4 — stable, main branch

```yaml
# envs/box-dev/us-dev-4/bulk-values.yaml
konk:
  custom:
    etcd:
      etcd:
        initialClusterState: "existing"  # set but irrelevant — hook not in main branch chart
      recreateStatefulSet:
        enabled: false                    # set but irrelevant — hook not in main branch chart
```

- konk image: `v0.2.1-164-gbd3f28a` (main branch) — no `recreateStatefulSet` hook
- Bulk chart v2.5.0-75, last upgraded 2026-07-15 (Helm v2)
- konk-operator upgraded to `v0.2.1-164-gbd3f28a-j203` on Jul 15 — stable at 6d+
- The explicit `false`/`existing` flags in DC values have no effect since the hook template doesn't exist in this chart

### eu-stg-1 — different issue, not the flag

- **etcd image: `bitnami/etcd:3.4.14`** — OLD version, pre-migration
- Etcd upgrade was done and then **reverted on 2026-06-24**
- Single replica (no HA)
- No `recreateStatefulSet` or `initialClusterState` flags in values
- Bulk chart v2.5.0-75, last upgraded 2026-07-29
- etcd-0 pod started 2026-08-07 23:40 IST (= 18:10 UTC) — 4d21h ago at time of observation
- konk-operator (`v0.2.1-138-g8b64bf7-j170`) started 2026-08-05 14:03 UTC; operator reconciliation ~2 days later triggered a bulk RollingUpdate
- The 4d21h restart is from normal operator reconciliation, not the recreateStatefulSet hook
- Single replica means no quorum concern

---

## Impact of etcd Disruption

When the etcd STS is deleted or quorum is lost, the konk apiserver becomes unavailable. All KonkService pods in every namespace route their `kubectl api-resources` health check through the bulk-konk kubeconfig. When this call fails:

- Health loop writes `1` to `/tmp/healthy`
- Readiness probe fails across **all** KonkServices simultaneously
- Affects: tagging-v2, ngp-cp, redirect, ddi, hostapp, atcapi, and every other namespace with a KonkService

---

## Fixes Required

### PR #143226 — deployment-configurations (covers us-stg-1 + us-dev-5)

**URL:** https://github.com/Infoblox-CTO/deployment-configurations/pull/143226  
**Status:** Open, approved by vdhunde-infoblox, labeled `Stage Change` + `DO NOT MERGE`  
**Action:** Remove `DO NOT MERGE` label and merge.

Changes:
- `envs/com-stage/us-stg-1/bulk-values.yaml`: `initialClusterState: new → existing`, `recreateStatefulSet.enabled: true → false`
- `envs/box-dev/us-dev-5/bulk-values.yaml`: same

**Why merging is safe:** The hook fires based on the *incoming* values in the Helm upgrade. With `enabled: false`, the pre-upgrade hook template renders empty — no deletion occurs.

Only us-stg-1 and us-dev-5 need DC changes — they are the only clusters running `release/upgrade-etcd` images that have the hook template.

---

## Fix Summary

| Cluster | Branch | Hook exists? | Fix needed | Action |
|---------|--------|-------------|------------|--------|
| **us-stg-1** | release/upgrade-etcd | **YES** | `recreateStatefulSet: false` + `initialClusterState: existing` | **Merge PR #143226** |
| **us-dev-5** | release/upgrade-etcd | **YES** | `recreateStatefulSet: false` + `initialClusterState: existing` | **Merge PR #143226** |
| us-dev-2 | main | No | None — rolling was one-time chart upgrade | Monitor |
| us-dev-4 | main | No | None — stable | — |
| gov-stg-2 | main | No | None — rolling was one-time chart upgrade | Monitor |
| eu-stg-1 | old release | No | None — separate issue | — |

---

## Related

- [tagging-v2-issue.md](tagging-v2-issue.md) — 467 readiness probe failures traced back to this etcd restart on us-stg-1
- DC PR #143226 — the primary fix for us-stg-1 and us-dev-5
- konk script: `scripts/e2e-konk-test.sh` Section 6 — probe flapping detection added to catch this pattern


## etcd pod restarts history---Do not delete it - 12/aug
kgpo --context=us-dev-5  -n aggregate  | grep etcd
bulk-konk-etcd-0                               1/1     Running     0          26h
bulk-konk-etcd-1                               1/1     Running     0          7d6h
bulk-konk-etcd-2                               1/1     Running     0          5d16h
                                                                                                  
kgpo --context=us-dev-2  -n aggregate  | grep etcd
bulk-konk-etcd-0                               1/1     Running     0          25h
bulk-konk-etcd-1                               1/1     Running     0          16h
bulk-konk-etcd-2                               1/1     Running     0          6h21m

kgpo --context=us-dev-4  -n aggregate  | grep etcd
bulk-konk-etcd-0                               1/1     Running    0          6d14h
bulk-konk-etcd-1                               1/1     Running    0          6d3h
bulk-konk-etcd-2                               1/1     Running    0          6d17h

kgpo --context=us-stg-1  -n aggregate  | grep etcd
bulk-konk-etcd-0                               1/1     Running     0          31m
bulk-konk-etcd-1                               1/1     Running     0          17h
bulk-konk-etcd-2                               1/1     Running     0          15h

kgpo --context=eu-stg-1  -n aggregate  | grep etcd
bulk-konk-etcd-0                              1/1     Running     0               4d21h

 create a table where it should specify the values in the main branch and values in the etcd feature branch separately  | grep etcd                                               
bulk-konk-etcd-0                              2/2     Running   0          33m
bulk-konk-etcd-1                              2/2     Running   0          16h
bulk-konk-etcd-2                              2/2     Running   0          19m
