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

1. Remove `etcd.initialClusterState: "new"` from bulk-values (so restarts use `existing`)
2. Set `recreateStatefulSet.enabled: false` (hook no longer needed)
3. Delete orphaned `data-bulk-konk-etcd-*` PVCs after soak (1 week)
4. Keep `persistence.claimName: data-v2` permanently (VCT is immutable anyway)

---

## References

- [prod-etcd-migration-options.md](prod-etcd-migration-options.md) — full option comparison (A/B/C/D/E/F)
- [etcd_approach_b_claimname.md](etcd_approach_b_claimname.md) — detailed execution logs (us-dev-4, us-dev-5)
- [etcd-konk-migration.md](etcd-konk-migration.md) — image lineage and chart internals
