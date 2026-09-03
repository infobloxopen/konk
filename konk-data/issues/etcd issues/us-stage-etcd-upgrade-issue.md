# Konk Operator Stage Upgrade Issue — us-stg-1

**Date:** 2026-06-15  
**Cluster:** us-stg-1  
**Namespace:** aggregate  
**PR:** https://github.com/Infoblox-CTO/deployment-configurations/pull/132999

## Change

Upgraded konk-operator from `v0.2.1-138-g8b64bf7-j170` to `v0.2.1-155-gd4614c2-j191` on us-stg-1, adding:
- Harbor image overrides for konk-operator and relatedImages
- New version in `konk-operator-version.txt`

## Symptoms

After the PR merged, `bulk-konk` and `bulk-konk-etcd` pods went into CrashLoopBackOff:

```
bulk-konk-6b799fbb8c-t6gnz        0/1     CrashLoopBackOff   5d11h
bulk-konk-7c577d9775-2v8mt        0/1     CrashLoopBackOff   16m
bulk-konk-etcd-0                   0/1     CrashLoopBackOff
bulk-konk-etcd-1                   0/1     CrashLoopBackOff
bulk-konk-etcd-2                   0/1     CrashLoopBackOff
```

etcd error:
```
"bootstrap failed","error":"cannot fetch cluster info from peer urls: could not retrieve cluster information from the given URLs"
```

bulk-konk (kube-apiserver) error:
```
"transport: authentication handshake failed" / "context deadline exceeded"
```

## Pre-existing Failure (before upgrade)

The old bulk-konk pod (`6b799fbb8c-t6gnz`, 5d11h old, 19+ restarts) was **already crashing before the upgrade**:

- **June 12 12:36 UTC (Friday)** — e2e-konk-test.sh ran and PASSED (all pods healthy)
- **June 13-14** — Large-scale node rotation: **37 new nodes** created (Karpenter drift/expiry)
- The node rotation evicted old bitnami etcd pods, causing EBS Multi-Attach errors
- Once etcd lost quorum, bulk-konk (kube-apiserver) started crash-looping
- **June 15 05:07** — konk-operator upgrade landed on an already-broken deployment

Evidence:
- Oldest surviving nodes in the cluster are from June 8-9
- 37 nodes created June 13-14, 56 more on June 15
- Events show `Multi-Attach error for volume "pvc-a5e20429..."` (same old etcd-0 PVC)
- Helm release v8 (old operator) was deployed March 15, untouched until June 15

## Root Cause (upgrade failure)

### What changed in the chart

The konk-operator upgrade (v0.2.1-138 → v0.2.1-155) made a **breaking etcd infrastructure change**:

| | Before (v0.2.1-138) | After (v0.2.1-155) |
|---|---|---|
| **etcd image** | `bitnamilegacy/etcd` (3.5.x) | `gcr.io/etcd-development/etcd:v3.6.9` |
| **Chart** | Bitnami etcd subchart | Custom in-house `helm-charts/etcd/` |
| **StatefulSet template** | Bitnami-generated (with sidecars, scripts) | Minimal upstream-style (single container) |
| **Data format** | bitnami 3.5.x WAL/snap | upstream etcd 3.6.x WAL/snap |
| **PRs** | — | #548 (bitnamilegacy pull), #572 (replace with upstream), #583 (3.6.7→3.6.8), #619 (merge to master) |

### How the failure happens (step by step)

1. **DC PR merges** → Flux/KubeVela updates the konk-operator HelmRelease
2. **konk-operator pod restarts** with new image (v0.2.1-155) and new bundled charts
3. **Operator reconciles the Konk CR** (`bulk-konk`) → runs Helm upgrade on the konk chart
4. **Konk chart creates a new Etcd CR** with the new chart structure (upstream etcd template)
5. **Operator reconciles the Etcd CR** (`bulk-konk-etcd`) → runs Helm upgrade on the etcd chart
6. **Helm replaces the entire StatefulSet** because the template changed completely (different containers, env vars, probes, volumes). This is NOT a rolling update — it's a delete + create.
7. **Old bitnami etcd pods are terminated** — the old cluster is gone
8. **New StatefulSet is created** but reuses the old PVCs (PVC names match: `data-bulk-konk-etcd-{0,1,2}`)
9. **New etcd 3.6.9 pods start** and find old bitnami data in the PVCs:
   - `member/snap/db` has bitnami 3.5.x schema
   - `member/wal/` has bitnami WAL entries
   - etcd 3.6.9 detects `member/` directory → logs `"server has already been initialized"`
10. **Helm chart sets `ETCD_INITIAL_CLUSTER_STATE=existing`** because it's a Helm upgrade (`Release.IsInstall = false`), not a fresh install
11. **With `existing` state, etcd tries to contact peers** via their peer URLs to fetch cluster membership info
12. **All 3 pods do this simultaneously** — none can respond because none has successfully started yet
13. **Each pod fails immediately**: `"bootstrap failed: cannot fetch cluster info from peer urls"`
14. **All pods enter CrashLoopBackOff** → bulk-konk (kube-apiserver) cannot connect to etcd → also crashes

### Why `initial-cluster-state=existing` fails

The `ETCD_INITIAL_CLUSTER_STATE` env var tells etcd how to bootstrap:

| Value | Behavior |
|-------|----------|
| `new` | Form a **brand new cluster** — all members start fresh, elect a leader, no pre-existing membership expected |
| `existing` | **Join an existing cluster** — expects to find peers that already know about this member; fails immediately if peers aren't running or don't recognize it |

The Helm chart defaults to `existing` on upgrades (assumes etcd is already running and just restarting). But since the **entire etcd implementation changed** (bitnami → upstream), there IS no existing cluster to join — the old bitnami StatefulSet was deleted and replaced. Setting `new` tells all 3 pods to bootstrap from scratch.

After the cluster is healthy, the value doesn't matter — etcd only uses it during initial bootstrap. Subsequent pod restarts use the data in the PVC (WAL/snapshots) to rejoin, ignoring `initial-cluster-state`.

### Why PVC deletion is required

Even with `initial-cluster-state=new`, etcd 3.6.9 **ignores the flag** when it finds existing member data:
- Pod starts → detects `/var/lib/etcd/member/` directory → logs `"server has already been initialized"`
- Regardless of `ETCD_INITIAL_CLUSTER_STATE`, it tries to resume from existing data
- The old bitnami 3.5.x data is incompatible → crash

Both fixes are required: `initialClusterState: "new"` (for fresh PVC bootstrap) AND PVC deletion (to remove incompatible data).

### Why PVC deletion is safe

The etcd PVCs store `/var/lib/etcd`:
- `member/snap/db` — bbolt database with all key-value data (CRDs, custom resources, leases)
- `member/wal/` — write-ahead logs
- `lost+found/` — ext4 filesystem artifact (irrelevant)

For **bulk-konk**, this etcd backs the konk kube-apiserver. Deleting the PVCs is safe because:

1. **konk etcd is NOT the application database** — it only stores Kubernetes API objects (CRDs, CRs, RBAC, leases) for the konk kube-apiserver. The actual bulk application data lives in **PostgreSQL** (managed by `bulk-dbapi`).
2. **CRDs are re-registered automatically** — the `konk-service` pods run `reconcile-apiservice` on startup, which re-creates all APIService and CRD registrations.
3. **Custom Resources are re-synced by controllers** — the bulk operator watches its own database (PostgreSQL) as the source of truth and reconciles the konk API objects. Any CRs deleted from etcd are recreated by the controller loop.
4. **Certs and kubeconfig are regenerated** — the `bulk-konk-init` (provision) pod detects a fresh etcd and re-runs `kubeadm init`, regenerating all PKI material and kubeconfig secrets.
5. **No user-facing data loss** — end users interact with the bulk REST API (backed by PostgreSQL), not directly with the konk kube-apiserver.
6. **Proven safe** — this was already performed on **us-dev-2** and **us-stg-1** with zero data loss or service impact (beyond the brief etcd restart window).

## Resolution (us-stg-1)

1. Scaled down etcd StatefulSet to 0
2. Labeled PVCs with `k8s.infoblox.com/allow-user-action=enabled` (Kyverno policy bypass)
3. Deleted all 3 etcd PVCs
4. Patched the Etcd CR to override cluster state:
   ```bash
   kubectl patch etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
     --type='merge' -p='{"spec":{"etcd":{"initialClusterState":"new"}}}'
   ```
5. Operator reconciled: set `ETCD_INITIAL_CLUSTER_STATE=new` on StatefulSet, scaled back to 3
6. etcd cluster bootstrapped fresh, became healthy (1/1 Running)
7. Deleted stale bulk-konk pods to reset CrashLoopBackOff timers
8. bulk-konk (kube-apiserver) connected to new etcd and went 1/1 Running

## Deployment Strategy for Other Clusters

### Pre-merge (no downtime, safe):
```bash
# Patch the Etcd CR — old operator ignores this field, current system unaffected
kubectl patch etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type='merge' -p='{"spec":{"etcd":{"initialClusterState":"new"}}}'
```

### Merge the DC PR (operator upgrades, old etcd StatefulSet gets replaced)

### Immediately after operator reconciles (~2-3 min post-merge):
```bash
# Old StatefulSet is already replaced — old etcd is gone
# New etcd pods are crashing because of stale PVCs with bitnami data

# Label PVCs for Kyverno bypass
kubectl label pvc -n aggregate \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 \
  k8s.infoblox.com/allow-user-action=enabled

# Delete stale PVCs
kubectl delete pvc -n aggregate \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2

# Pods auto-restart with fresh PVCs → bootstrap with "new" → healthy in ~60s
# If bulk-konk is still CrashLoopBackOff after etcd is healthy, delete the pod:
kubectl delete pod -n aggregate -l app.kubernetes.io/instance=bulk-konk,app.kubernetes.io/component=apiserver
```

**Expected downtime:** ~2-3 minutes (from operator reconciliation until new etcd bootstraps after PVC deletion).

## Lessons / Action Items

- **This will happen on every cluster** where konk-operator is upgraded from v0.2.1-138 (or any pre-#572 version) to v0.2.1-155+
- The Etcd CR patch (`initialClusterState: "new"`) must be applied on each cluster during the upgrade, OR the etcd chart needs a migration path
- Consider adding an initContainer to the etcd StatefulSet that detects incompatible data and cleans the data dir
- The `lost+found` directory on fresh EBS PVCs causes etcd 3.6.9 to log "found invalid file under data directory" warnings (cosmetic but confusing)
- After recovery, the `initialClusterState: "new"` override on the Etcd CR can be left in place (only used during bootstrap) or removed

## Affected Pods (Final State — Healthy)

```
bulk-konk-7c577d9775-r48d7        1/1     Running   0
bulk-konk-etcd-0                   1/1     Running   0
bulk-konk-etcd-1                   1/1     Running   0
bulk-konk-etcd-2                   1/1     Running   0
bulk-konk-init-66575f5b55-r4npk   1/1     Running   0
```

---

## Appendix: Etcd Bootstrap Issue (standalone reference)

### Problem Statement

When upgrading konk-operator from any version using `bitnamilegacy/etcd` (≤ v0.2.1-138) to a version using upstream `gcr.io/etcd-development/etcd` (≥ v0.2.1-155), the etcd cluster **cannot bootstrap** and enters CrashLoopBackOff.

### Why it fails

The upgrade changes the etcd Helm chart entirely (bitnami subchart → custom upstream chart). This causes:

1. **StatefulSet is replaced** (not rolling-updated) because the pod template changed completely
2. **Old etcd pods are terminated** — the old bitnami cluster ceases to exist
3. **New etcd 3.6.9 pods start** but find old bitnami data in the PVCs (`/var/lib/etcd/member/`)
4. **etcd detects existing data** → ignores `ETCD_INITIAL_CLUSTER_STATE` → tries to resume from old data → fails (incompatible format)
5. **Even if data is empty**, the chart sets `ETCD_INITIAL_CLUSTER_STATE=existing` (Helm upgrade, not install) → etcd tries to join a non-existent cluster → fails

### Two things must be fixed

| Fix | What it does | Why it's needed |
|-----|-------------|-----------------|
| Patch Etcd CR: `initialClusterState: "new"` | Overrides the chart default to form a new cluster | Without this, etcd tries to join a non-existent "existing" cluster |
| Delete etcd PVCs | Removes old bitnami data from the volume | Without this, etcd sees old `member/` dir, ignores `new` flag, and tries to resume from incompatible data |

### Why PVC deletion is safe for bulk-konk

```
┌─────────────────────────────────────────────────────────┐
│                    User / Application                     │
│                         ↕                                │
│              Bulk REST API (bulk pods)                    │
│                         ↕                                │
│         PostgreSQL (via bulk-dbapi) ← SOURCE OF TRUTH    │
│                         ↕                                │
│        Bulk Operator (controller loops)                  │
│                         ↕                                │
│      Konk kube-apiserver (bulk-konk) ← stateless API     │
│                         ↕                                │
│          etcd (bulk-konk-etcd) ← CAN BE WIPED            │
└─────────────────────────────────────────────────────────┘
```

- **Application data** lives in PostgreSQL, NOT in etcd
- **etcd only stores** Kubernetes API objects: CRDs, custom resources, RBAC, leases, events
- **CRDs** are re-registered by `konk-service` pods on startup
- **Custom Resources** are re-synced by the bulk operator from its database
- **Certs/kubeconfig** are regenerated by `bulk-konk-init` (provision pod)
- **No user-facing data loss** — users interact with the bulk REST API, not the konk apiserver directly

### Fix commands (copy-paste ready)

```bash
# Set your context and namespace
CONTEXT="teleport.services.sdp.infoblox.com-us-stg-1"  # change per cluster
NS="aggregate"

# 1. Pre-patch (safe, no impact on running system — do BEFORE merging DC PR)
kubectl --context $CONTEXT patch etcd.konk.infoblox.com bulk-konk-etcd -n $NS \
  --type='merge' -p='{"spec":{"etcd":{"initialClusterState":"new"}}}'

# 2. Merge the DC PR (operator upgrades, etcd StatefulSet gets replaced)
# ... wait ~2-3 min for operator reconciliation ...

# 3. Delete stale PVCs (immediately after operator reconciles)
kubectl --context $CONTEXT label pvc -n $NS \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 \
  k8s.infoblox.com/allow-user-action=enabled

kubectl --context $CONTEXT delete pvc -n $NS \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2

# 4. Wait ~60-90s for etcd to bootstrap, then verify
kubectl --context $CONTEXT get pods -n $NS -l app.kubernetes.io/instance=bulk-konk-etcd

# 5. If bulk-konk is still CrashLoopBackOff, delete to reset backoff timer
kubectl --context $CONTEXT delete pod -n $NS \
  -l app.kubernetes.io/instance=bulk-konk,app.kubernetes.io/component=apiserver
```

### Expected downtime

~2-3 minutes from operator reconciliation (old etcd destroyed) until new etcd bootstraps after PVC deletion. bulk-konk consumers (tagging, etc.) will get errors during this window.
