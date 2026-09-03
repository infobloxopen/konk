# Konk etcd Upgrade — Final Approach

**Date:** 2026-07-29
**Operator image:** `v0.2.1-155-g372db4e-j21` (branch: `release/upgrade-etcd`)
**PR:** [#668](https://github.com/infobloxopen/konk/pull/668)
**Clusters:** us-stg-1, eu-stg-1, us-com-1, eu-com-1

---

## Problem

Prod runs `docker.io/bitnami/etcd:3.4.14` (operator `j170`). Upgrading to upstream etcd fails because:

1. **Data-path mismatch** — Bitnami mounts PVC at `/bitnami/etcd` (data dir: `/bitnami/etcd/data`). Upstream mounts at `/var/lib/etcd`. Same PVC, different paths → upstream etcd sees an empty data dir at its mount point.

2. **`ETCD_INITIAL_CLUSTER_STATE` defaults to `existing` on upgrade** — the chart renders `existing` for any `helm upgrade` (revision N → N+1). With no visible member data at the new mount path, all 3 pods try to join a cluster that doesn't exist → CrashLoopBackOff.

3. **VCT name is immutable** — changing `volumeClaimTemplates[].metadata.name` from `data` → `data-v2` on an existing StatefulSet is rejected by the Kubernetes API → operator loops in a failed-upgrade/rollback cycle forever.

**Both conditions must be fixed simultaneously:** fresh PVCs (or fresh install) + `initialClusterState: "new"`.

---

## Approach: Option B — Declarative `claimName: data-v2`

Use the parameterized `persistence.claimName` to provision **brand-new empty PVCs** (`data-v2-bulk-konk-etcd-{0,1,2}`) while old PVCs remain untouched as backup.

### What the operator image (`j21`) provides

| Feature | Details |
|---------|---------|
| Parameterized VCT name | `{{ .Values.persistence.claimName \| default "data" }}` |
| Pre-upgrade recreate hook | Deletes the existing STS so Helm can CREATE a fresh one with the new VCT name (solves immutability) |
| Hook gating | Fires whenever `recreateStatefulSet.enabled=true` and a live STS exists — prevents strategic merge conflicts |
| Helm ownership annotations | Baked into all chart templates — prevents "cannot be imported" errors |

### DC values required

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

### Why `initialClusterState: "new"` is needed

The chart defaults to `existing` on any `helm upgrade`. Even though the new PVCs are empty (no stale Bitnami data), etcd still needs to know it should **bootstrap a new cluster** rather than try to rejoin an existing one:

| Value | Behavior on empty PVC |
|-------|----------------------|
| `existing` | Pods wait to join a cluster that doesn't exist → timeout → crash |
| `new` | Pods elect a leader and form a fresh cluster ✅ |

After the cluster is stable, `initialClusterState` should be removed from values so subsequent reconciles use the chart default (`existing` for upgrades = correct for a running cluster).

---

## What this avoids

| Issue | How it's avoided |
|-------|-----------------|
| **Manual PVC deletion** on prod | Not needed — fresh `data-v2-*` PVCs are provisioned automatically |
| **Kyverno bypass labels** for PVC deletion | Not needed — no PVCs are deleted |
| **Helm annotation fix** (`meta.helm.sh` ownership) | Baked into j21 chart templates — no manual annotation of cluster resources |
| **Helm release secret deletion** (to force `.Release.IsInstall`) | Not needed — the recreate hook handles the immutable VCT problem directly |
| **Manual `etcdctl member` surgery** | Not needed — clean bootstrap with 3 fresh members |
| **Operator fail→rollback loop** (immutable VCT) | Solved by the recreate hook deleting the STS before Helm applies the new spec |

---

## What happens during the upgrade

1. Operator reconciles new Etcd CR spec
2. Recreate hook fires → deletes existing StatefulSet (pods terminate)
3. Helm creates fresh StatefulSet with VCT `data-v2`
4. Kubernetes provisions empty `data-v2-bulk-konk-etcd-{0,1,2}` PVCs
5. etcd pods start with `ETCD_INITIAL_CLUSTER_STATE=new` → bootstrap fresh cluster
6. KonkService reconcile loops re-register APIServices/CRDs (~30-60s)
7. Old `data-bulk-konk-etcd-*` PVCs remain as backup (can be cleaned up after soak)

**Downtime:** ~60-90s (etcd unavailable → bulk aggregate APIs down until KonkService reconstructs)

---

## Post-migration cleanup

This is **not optional housekeeping** — both migration flags become latent hazards if
left enabled. Do this as soon as the cluster is verified stable.

```yaml
konk:
  custom:
    etcd:
      persistence:
        claimName: data-v2        # keep forever — VCT name is immutable
      statefulset:
        replicaCount: 3           # keep — intended HA topology
      etcd:
        initialClusterState: "existing"   # was "new"
      recreateStatefulSet:
        enabled: false                    # was true
```

### 1. `recreateStatefulSet.enabled: true` → `false`

The hook is gated on `recreateStatefulSet.enabled` **and a live STS existing** — not on
whether the claim name actually changed. While it stays `true` it fires on the **next**
`helm upgrade` of `bulk-konk-etcd`: any konk-operator bump, konk chart change, or edit
to the `konk:` block in `bulk-values.yaml`.

The hook runs `kubectl delete statefulset bulk-konk-etcd --wait=true`, so **all 3
members go down simultaneously** — quorum loss, konk apiserver down, aggregate APIs
unavailable until the STS is recreated and KonkService re-registers APIServices/CRDs.
That is the same ~60–90s outage budgeted for the migration itself, and it must not be
spent accidentally on an unrelated version bump.

It is *dormant*, not *active*: the helm-operator only upgrades when desired ≠ deployed,
so a stable cluster never fires it. us-dev-5 sat at helm revision 255 unchanged for 22h
with the flag still `true`. The risk is entirely about the next change.

### 2. `initialClusterState: "new"` → `"existing"`

`new` was correct during migration because the `data-v2` PVCs were empty. Once the
cluster is formed and data dirs are populated it is wrong-but-dormant — etcd only reads
the flag when its data dir is empty.

The danger is the **combination** with (1): if the STS is recreated *and* any member
comes up with an empty data dir (lost or re-provisioned PVC, node/EBS failure, replica
scale-up, future claimName change), that member bootstraps its own single-member
cluster instead of joining the survivors → **split brain**, recoverable only via
`etcdctl member` surgery or a restore.

Removing the key also works (chart default is `existing` on upgrade), but **prefer
setting it explicitly** — it documents intent and survives a chart-default change.

### 3. Remaining

- Delete orphaned `data-bulk-konk-etcd-*` PVCs after soak (~1 week) — separate change
- Keep `persistence.claimName: data-v2` permanently. Dropping it renders the chart
  default `data` → immutable-field rejection → operator back in the failed-upgrade loop

### Applying the flip is safe (no second outage)

Helm renders `pre-upgrade` hooks from the **incoming** values, so with
`recreateStatefulSet.enabled: false` the hook template renders nothing and the delete
Job never runs. The only live change is `ETCD_INITIAL_CLUSTER_STATE` on the pod
template → ordinary StatefulSet rolling update, one pod at a time in ordinal order,
each waiting for Ready. Quorum preserved, **zero downtime**.

### Verify before flipping

```bash
kubectl -n aggregate get konk bulk-konk -o jsonpath='{.status.conditions}'   # UpgradeSuccessful
kubectl -n aggregate get sts bulk-konk-etcd \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name} {.status.readyReplicas}'  # data-v2 3
helm history bulk-konk-etcd -n aggregate | tail -3        # revision stable, status deployed
kubectl -n konk logs deploy/konk-operator --since=4h | grep -c "Upgraded release"   # expect 0
```

### Status

| Cluster | Migrated | Post-upgrade flip |
|---------|----------|-------------------|
| us-dev-4 | done | done — pinned `recreateStatefulSet.enabled: false` |
| us-dev-5 | 2026-08-04 17:51 UTC | DC PR [#143226](https://github.com/Infoblox-CTO/deployment-configurations/pull/143226) |
| us-stg-1 | 2026-08-05 12:02 UTC | DC PR [#143226](https://github.com/Infoblox-CTO/deployment-configurations/pull/143226) |
| eu-stg-1 | not started — still Bitnami `etcd-5.3.2` / `3.4.14` | n/a |

---

## References

- [prod-etcd-migration-options.md](prod-etcd-migration-options.md) — full option comparison (A/B/C/D/E/F)
- [etcd_approach_b_claimname.md](etcd_approach_b_claimname.md) — detailed execution logs (us-dev-4, us-dev-5)
- [etcd-konk-migration.md](etcd-konk-migration.md) — image lineage and chart internals
