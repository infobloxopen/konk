# Approach B — Parameterized `claimName` (etcd PVC Migration)

**Date:** 2026-06-22 (started), 2026-06-23 (us-dev-5 tested + validated)
**Reference:** [prod-etcd-migration-options.md](prod-etcd-migration-options.md) — Option B
**Operator version:** `v0.2.1-151-gfd9ed6b-j16` (includes pre-upgrade hook from [PR #634](https://github.com/infobloxopen/konk/pull/634))
**Previous operator (no hook):** `v0.2.1-150-g97950c6-j15`

---

## Summary

Instead of deleting PVCs (Option A), we parameterize the `volumeClaimTemplate` name in the etcd chart. Setting `persistence.claimName: data-v2` provisions **brand-new empty PVCs** while leaving old ones untouched as a backup.

This is the **recommended prod migration path** — declarative, zero PVC deletion, instant rollback via the orphaned `data-*` PVCs.

---

## Chart Changes (konk repo)

### 1. Parameterized VCT name (branch: `release/upgrade-etcd`)

Parameterized in `helm-charts/etcd/templates/statefulset.yaml` (3 locations):

```yaml
# Before (hardcoded)
name: data

# After
name: {{ .Values.persistence.claimName | default "data" }}
```

### 2. Pre-upgrade recreate-StatefulSet hook ([PR #634](https://github.com/infobloxopen/konk/pull/634))

Branch: `rsatal/etcd-recreate-sts-hook` (merged into `release/upgrade-etcd`)
Operator tag: `v0.2.1-151-gfd9ed6b-j16`

**Problem:** VCT name is immutable in Kubernetes. A helm upgrade that changes `claimName: data → data-v2` fails with an immutable-field error, causing a fail→rollback loop.

**Solution:** A value-gated Helm pre-upgrade hook that:
1. Uses `lookup` to read the live STS's current VCT name
2. Compares against the target `persistence.claimName`
3. If different → renders a Job that `kubectl delete sts --wait` → allows Helm to CREATE a fresh STS
4. If same → renders nothing (idempotent no-op)

**Resources rendered (when active):**
| Resource | Name | Hook Weight |
|---|---|---|
| ServiceAccount | `bulk-konk-etcd-recreate-hook` | -5 |
| Role | `bulk-konk-etcd-recreate-hook` | -5 |
| RoleBinding | `bulk-konk-etcd-recreate-hook` | -4 |
| Job | `bulk-konk-etcd-recreate-sts` | 0 |

All have `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded` (self-cleaning).

**Gate:**
```yaml
{{- if and .Values.recreateStatefulSet.enabled .Values.persistence.enabled }}
  # + lookup sees live VCT ≠ target
{{- end }}
```

**Values:**
```yaml
recreateStatefulSet:
  enabled: false  # must be explicitly enabled
  image:
    repository: registry.k8s.io/kubectl
    tag: "v1.31.4"
```

---

## DC Repo Changes

### Value flow path

```
DC bulk-values.yaml
  → konk.custom.etcd.persistence.claimName
    → bulk chart templates Konk CR → spec.etcd.persistence.claimName
      → konk chart {{ toYaml .Values.etcd }} → Etcd CR spec.persistence.claimName
        → etcd chart .Values.persistence.claimName → StatefulSet VCT name
```

### Values added to `bulk-values.yaml`

```yaml
konk:
  custom:
    etcd:
      persistence:
        claimName: data-v2
      statefulset:
        replicaCount: 3
      etcd:
        initialClusterState: "new"
      recreateStatefulSet:
        enabled: true
```

### Version change to `konk-operator-version.txt`

```
v0.2.1-138-g8b64bf7-j170 → v0.2.1-151-gfd9ed6b-j16
```

---

## Cluster Executions

| Cluster | PR | Status | Issues | Notes |
|---------|-----|--------|--------|-------|
| us-dev-4 | [#134529](https://github.com/Infoblox-CTO/deployment-configurations/pull/134529) | ✅ Done | HelmRelease blocked + annotation fix needed | Manual (j15, no hook) |
| us-dev-5 | [#134745](https://github.com/Infoblox-CTO/deployment-configurations/pull/134745) | ✅ Done | Intermediate CrashLoop (self-healed) | **Automated via hook (j16)** |

---

## us-dev-4 — Execution (2026-06-22)

### Context

us-dev-4 was on `j170` (`v0.2.1-138-g8b64bf7-j170`). The Konk CR had been in `InstallError` for **451 days** due to missing Helm ownership annotations on bulk-konk resources.

### Blockers Encountered

1. **`bulk` HelmRelease blocked by `authz` dependency** — the `authz` HelmRelease was not ready, preventing the `bulk` chart from updating. This means the Konk CR values (`persistence.claimName: data-v2`, etc.) were NOT propagated automatically via the normal DC→Flux→bulk→Konk path.

2. **Konk CR in `InstallError` (451 days)** — the konk-operator couldn't reconcile the Konk CR because bulk-konk resources (ServiceAccounts, Deployments, StatefulSets, Services, Secrets, Certificates, ClusterRoles, ClusterRoleBindings, CRDs) were missing `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` annotations. Without these annotations, Helm refuses to adopt pre-existing resources during an install/upgrade.

### Manual Steps Performed

**Step 1: Manually patched the Konk CR** with migration values (since HelmRelease was blocked):

```bash
kubectl --context us-dev-4 patch konk bulk-konk -n aggregate --type='merge' -p='{
  "spec": {
    "etcd": {
      "persistence": {
        "claimName": "data-v2"
      },
      "statefulset": {
        "replicaCount": 3
      },
      "etcd": {
        "initialClusterState": "new"
      }
    }
  }
}'
```

**Step 2: Applied Helm ownership annotations** to all bulk-konk resources:

```bash
# Pattern: annotate each resource type that the Konk Helm release manages
for kind in serviceaccount service deployment statefulset secret; do
  for resource in $(kubectl --context us-dev-4 get $kind -n aggregate --no-headers | grep bulk-konk | awk '{print $1}'); do
    kubectl --context us-dev-4 annotate $kind/$resource -n aggregate \
      meta.helm.sh/release-name=bulk-konk \
      meta.helm.sh/release-namespace=aggregate --overwrite
  done
done

# Also: Certificates, Issuers, ClusterRoles, ClusterRoleBindings, CRDs
# (same pattern, different resource types — some are cluster-scoped)
```

**Step 3: Triggered reconcile** on Konk CR and Etcd CR.

### Result: ✅ SUCCESS

| Check | Status | Details |
|-------|--------|---------|
| Konk CR status | ✅ | `InstallSuccessful` |
| Etcd CR status | ✅ | `InstallSuccessful` |
| etcd pods | ✅ | 3/3 Running (1/1 ready) |
| etcd image | ✅ | `harbor.services.sdp.infoblox.com/infobloxcto/etcd:v3.6.8` (upstream) |
| New PVCs (`data-v2-*`) | ✅ | `data-v2-bulk-konk-etcd-{0,1,2}` all Bound (fresh gp3) |
| Old PVCs (`data-*`) | ✅ | `data-bulk-konk-etcd-{0,1,2}` untouched (backup) |
| etcd cluster | ✅ | 3 members, all `started`, leader elected |
| DB size | ✅ | 283 kB |
| Total keys | ✅ | 177 keys reconstructed |
| APIServices | ✅ | `bootstrap.bulk.infoblox.com`, `onprem.bulk.infoblox.com`, `tagging.bulk.infoblox.com` registered |
| KonkServices | ✅ | hostapp, bootstrap-app, ntp, tagging — all present |

### Key Observations

- Data fully reconstructed by KonkService reconcile loops (~30-60s after apiserver ready)
- `initialClusterState: "new"` + `replicaCount: 3` successfully bootstrapped a 3-member cluster from scratch
- Old PVCs (`data-*`) never touched — instant rollback available
- The `InstallError` → `InstallSuccessful` transition confirms the annotation fix is the key prerequisite
- **Prod readiness:** Validates the exact prod migration path. Only additional step is the Helm annotation fix if Konk CR is in `InstallError` there too.

---

## us-dev-5 — Execution (2026-06-23)

### Context

us-dev-5 was reset to a clean j170 baseline before this test:
- konk-operator: `v0.2.1-138-g8b64bf7-j170` (Bitnami etcd chart `etcd-5.3.2`)
- etcd: `3.4.14` (Bitnami), single-node (`replicaCount: 1`), fresh bootstrap on `data-bulk-konk-etcd-0`
- Konk CR: `UpgradeSuccessful`, helm rev 108 `deployed` — **no fail→rollback loop**
- No orphan PVCs

This test validates the **real upgrade path** (helm upgrade rev 108 → 113, NOT a fresh install) with the PR #634 pre-upgrade hook.

### PR

- **DC PR:** [#134745](https://github.com/Infoblox-CTO/deployment-configurations/pull/134745)
- **Branch:** `rsatal/konk-operator-us-dev-5-j16`
- **Changes:**
  - `envs/box-dev/us-dev-5/konk-operator-version.txt`: `v0.2.1-138-g8b64bf7-j170` → `v0.2.1-151-gfd9ed6b-j16`
  - `envs/box-dev/us-dev-5/bulk-values.yaml`: added full `konk.custom.etcd` block:
    ```yaml
    konk:
      custom:
        etcd:
          persistence:
            claimName: data-v2
          statefulset:
            replicaCount: 3
          etcd:
            initialClusterState: "new"
          recreateStatefulSet:
            enabled: true
    ```

### Pre-Deploy Baseline (captured)

| Check | Value |
|-------|-------|
| Operator | `infoblox/konk:v0.2.1-138-g8b64bf7-j170` |
| Chart | `etcd-5.3.2` (Bitnami) |
| etcd version | `3.4.14` |
| STS VCT | `data` |
| replicaCount | `1` |
| `ETCD_INITIAL_CLUSTER_STATE` | not set (absent) |
| Helm rev | `108 deployed` |
| PVCs | single `data-bulk-konk-etcd-0` (fresh) |
| Pods | `1/1` Running |
| Keys | 197 |
| Konk CR | `UpgradeSuccessful` |

### Upgrade Timeline

```
T+0s:    DC PR merged → FluxCD reconciles → konk-operator bumped to j16
T+~30s:  j16 operator reconciles Konk CR → updates Etcd CR with new spec
         Helm upgrade triggered (rev 108 → ...)
         Intermediate attempts (revs 109-112): operator reconciled multiple
         times before hook completed → etcd pods CrashLoopBackOff
         (tried to scale 1→3 on old data-0 PVC with "new" cluster state = member conflict)
T+~21s:  Hook Job (bulk-konk-etcd-recreate-sts-f89kq) COMPLETED
         → kubectl delete sts bulk-konk-etcd --wait=true
         → old crashing pods Terminated
T+~24s:  Helm applies final manifest (rev 113) → fresh STS with VCT=data-v2
         → Kubernetes provisions data-v2-bulk-konk-etcd-{0,1,2} PVCs
T+~36s:  3 etcd pods ContainerCreating (pulling etcd:v3.6.8 image)
T+~60s:  3 pods Running, cluster bootstrapping "new"
T+~90s:  3/3 Ready, cluster healthy, 196 keys repopulated
```

### Intermediate CrashLoop (expected, self-healed)

Between the operator receiving the new spec and the hook Job completing, intermediate revisions attempted the upgrade:
- Created `data-bulk-konk-etcd-1` and `data-bulk-konk-etcd-2` PVCs (scaling 1→3 on old VCT `data`)
- Pods on old `data-0` PVC with `initialClusterState: new` conflicted with existing single-member metadata → Error/CrashLoopBackOff
- **Self-healed:** Hook Job completed → STS deleted → fresh recreation on `data-v2` PVCs

### Result: ✅ SUCCESS (hook-driven, automated)

| Check | Status | Details |
|-------|--------|--------|
| Operator image | ✅ | `infoblox/konk:v0.2.1-151-gfd9ed6b-j16` |
| STS VCT | ✅ | **`data-v2`** (was `data`) |
| `ETCD_INITIAL_CLUSTER_STATE` | ✅ | `new` |
| STS created timestamp | ✅ | `2026-06-23T14:33:23Z` (fresh, after upgrade) |
| New PVCs | ✅ | `data-v2-bulk-konk-etcd-{0,1,2}` Bound |
| Old PVCs (backup) | ✅ | `data-bulk-konk-etcd-{0,1,2}` retained (orphan, cleanable) |
| Pods | ✅ | 3× `1/1` Running, **3/3 Ready** |
| etcd image | ✅ | `harbor…/infobloxcto/etcd:v3.6.8` |
| etcd members | ✅ | 3 members `started`, none learners, leader elected |
| etcd health | ✅ | healthy (6.98ms commit) |
| etcd version | ✅ | 3.6.8 (storage 3.6.0) |
| Keys | ✅ | **196** — KonkServices repopulated |
| Helm rev | ✅ | **108 → 113 `deployed`** — no fail→rollback loop |
| Konk CR | ✅ | **`UpgradeSuccessful`** |
| Hook Job | ✅ | Completed, resources cleaned by `hook-succeeded` policy |
| Hook resources | ✅ | (none) — self-cleaned |

### Key Observations

1. **Hook works on a real upgrade path** — this was helm rev 108→113 (upgrade), NOT a fresh install. The hook's `lookup` correctly detected VCT=`data` ≠ target `data-v2` and rendered the delete Job.
2. **Intermediate CrashLoop is cosmetic** — operator reconciled multiple times before hook completed (~21s). The crashed pods were killed once the hook deleted the STS. End result is clean.
3. **Rev jump 108→113** — 5 intermediate revisions from rapid operator reconcile cycles. Only rev 113 (with the hook) succeeded. `helm history` only shows 113 due to `maxHistory` pruning.
4. **Total time to healthy: ~90s** — from PR merge to 3/3 Ready.
5. **No manual intervention required** — fully automated via the hook. Compare with us-dev-4 which needed manual CR patching + annotation fixes.
6. **196 keys in ~60s** — KonkService reconcile loops reconstruct all data quickly.
7. **Orphan PVCs created:** `data-bulk-konk-etcd-{0,1,2}` — data-0 has old j170 single-node data, data-1/2 are empty artifacts from intermediate failed revs. All can be cleaned up after soak.

---

## Differences: us-dev-4 vs us-dev-5

| Aspect | us-dev-4 | us-dev-5 |
|--------|----------|----------|
| Starting operator | j170 | j170 |
| Target operator | j15 (no hook) | **j16 (with hook)** |
| Starting etcd | Bitnami 3.4.14 | Bitnami 3.4.14 (fresh single-node) |
| Helm operation | **Install** (CR recreated) | **Upgrade** (rev 108→113) |
| Konk CR state before | `InstallError` (451 days) | `UpgradeSuccessful` (clean) |
| HelmRelease blocker | Yes (`authz` dependency) | No |
| Manual intervention | Yes (patch CR + annotations) | **None — fully automated** |
| Hook used? | No (j15 doesn't have it) | **Yes — PR #634 hook** |
| Intermediate crashes? | No (fresh install = no VCT conflict) | Yes (self-healed in ~21s) |
| Time to healthy | ~5 min (manual steps) | **~90s (automated)** |

---

## Rollback Strategy

If something goes wrong after deploying:

1. **Revert DC PR** — remove `persistence.claimName: data-v2` values and revert `konk-operator-version.txt` back to j170
2. **StatefulSet won't update** — VCT name is immutable in K8s, so the STS change is rejected
3. **Force:** Delete the new StatefulSet → old operator recreates it with `name: data` → old PVCs rebind → old Bitnami etcd data restored
4. **Or:** Simply leave `data-v2-*` PVCs and roll back only the operator version (old operator can't template `claimName` so it renders `data` and STS update fails — etcd continues running on `data-v2-*` unaffected)

---

## Post-Migration Cleanup (after soak)

After verifying the cluster is healthy and stable (recommended: 1 week soak):

1. **Remove `initialClusterState: "new"`** from `bulk-values.yaml` — subsequent reconciles should use chart default (`existing` for upgrades)
2. **Delete old orphaned PVCs** (`data-bulk-konk-etcd-{0,1,2}`) to free EBS storage
3. **Keep `persistence.claimName: data-v2` permanently** — do NOT revert (VCT is immutable anyway)

---

## Lessons Learned

### From us-dev-4 (manual, j15, no hook)

1. **Annotation fix is prerequisite** — if Konk CR is in `InstallError`, the operator can't reconcile regardless of values changes. Fix annotations first.
2. **HelmRelease dependencies can block** — if `bulk` HelmRelease depends on `authz` (or other charts) and they're not ready, values won't propagate. May need manual CR patching as workaround.
3. **The approach itself works perfectly** — once the operator can reconcile, `claimName: data-v2` provisions fresh PVCs, etcd bootstraps cleanly, and data reconstructs from KonkService reconcile loops.
4. **177 keys in ~30-60s** — reconstruction is fast; konk etcd is small (just CRDs/RBAC/APIServices).

### From us-dev-5 (automated, j16, with hook)

5. **Hook solves the upgrade path** — us-dev-4 "worked" because it was a fresh install (no existing STS). On a real upgrade (us-dev-5 rev 108→113), the VCT immutability blocks Helm. The hook declaratively solves this.
6. **Intermediate CrashLoop is expected and harmless** — the operator reconciles multiple times before the hook Job completes (~21s). Crashed pods are killed once the STS is deleted. This is cosmetic noise, not a failure.
7. **VCT immutability is bidirectional** — reverting from `data-v2` back to `data` also requires STS deletion. Rollback = revert values + delete STS + clean PVCs.
8. **j170 operator is slow to reconcile after STS delete** — may need an annotation nudge on the Etcd CR to trigger recreation.
9. **For the revert/reset on dev:** must delete ALL PVCs (old 3-member metadata on `data-*` prevents a single-node quorum). On stage/prod with `replicaCount:3`, the old `data-*` PVCs are safe to reuse.
10. **`recreateStatefulSet.enabled: true` is required in values** — the hook is opt-in. Without it, the migration falls back to the old fail→rollback loop.
