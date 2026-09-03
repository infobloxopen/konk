# Pre-Upgrade Baseline — us-dev-5 (2026-06-23)

> Captured BEFORE merging DC PR #134745 (j16 + `claimName: data-v2` migration).
> This documents the clean j170 baseline state that the upgrade will modify.

## Expected pre-upgrade state

| # | Check | Expected value |
|---|-------|----------------|
| 1 | konk-operator chart | `v0.2.1-138-g8b64bf7-j170` |
| 2 | konk-operator image | `infoblox/konk:v0.2.1-138-g8b64bf7-j170` |
| 3 | etcd chart | `etcd-5.3.2` (Bitnami) |
| 4 | etcd image | `etcd:3.4.14-debian-10-r0` |
| 5 | STS VCT | `data` |
| 6 | STS replicaCount | `1` |
| 7 | STS `ETCD_INITIAL_CLUSTER_STATE` env | not set (absent for single-node Bitnami) |
| 8 | Helm release rev | `108` status=`deployed` |
| 9 | PVCs | single `data-bulk-konk-etcd-0` Bound (fresh) |
| 10 | Pods | `bulk-konk-etcd-0` 1/1 Running |
| 11 | etcd version | `3.4.14` |
| 12 | etcd members | 1 member `started`, IS LEADER = true |
| 13 | etcd health | `is healthy` (≈5ms commit) |
| 14 | Key count | ≈197 (KonkServices repopulated) |
| 15 | Konk CR status | `UpgradeSuccessful` |
| 16 | `recreateStatefulSet.enabled` | blank (not set — j170 doesn't know about hook) |
| 17 | Hook resources (Job/SA/Role/RB) | none |
| 18 | Orphan `data-v2-*` PVCs | none |

## Actual captured state

```
Date: Tue Jun 23 19:59:24 IST 2026

1. Operator image:    infoblox/konk:v0.2.1-138-g8b64bf7-j170     ✅
2. Konk CR spec.etcd: {"resources":{"limits":{"memory":"4Gi"}},"statefulset":{"replicaCount":1}}  ✅
3. Etcd CR spec:      statefulset.replicaCount=1, persistence=(default)  ✅
4. Hook value:        recreateStatefulSet.enabled=(blank)          ✅
5. Live STS:          VCT=data ready=1/1                           ✅
6. STATE env:         (not set)                                    ✅
7. Helm rev:          108 deployed 2026-06-23T14:05:26Z            ✅
8. PVCs:              data-bulk-konk-etcd-0  Bound  8Gi  gp3  24m  ✅
9. Pods:              bulk-konk-etcd-0  1/1  Running  0  22m       ✅
10. etcd health:      https://localhost:2379 is healthy (5.26ms)   ✅
11. etcd members:     1 member (132d3f2b2031a7d7) started, leader  ✅
12. etcd status:      v3.4.14, DB=598kB, leader=true, RAFT=3/284  ✅
13. Key count:        197                                          ✅
14. Konk CR:          UpgradeSuccessful                            ✅
15. Hook resources:   (none)                                       ✅
16. Orphan PVCs:      (none)                                       ✅
```

## All preconditions met ✅

- [x] Live VCT = `data` (hook will detect mismatch vs target `data-v2`)
- [x] Helm rev stable `deployed` — no fail→rollback loop
- [x] No orphan `data-v2-*` PVCs (fresh migration target)
- [x] No stale hook resources
- [x] Konk CR = `UpgradeSuccessful`
- [x] etcd healthy, 1 member, leader, 197 keys

## What PR #134745 will change

| Before (j170) | After (j16) |
|---|---|
| konk-operator `v0.2.1-138-g8b64bf7-j170` | `v0.2.1-151-gfd9ed6b-j16` |
| etcd chart `etcd-5.3.2` (Bitnami 3.4.14) | `etcd-1.0.0` (upstream 3.6.8) |
| VCT `data` | `data-v2` |
| replicaCount `1` | `3` |
| `ETCD_INITIAL_CLUSTER_STATE` absent | `new` |
| `recreateStatefulSet.enabled` absent | `true` |
| Cert path `/opt/bitnami/etcd/certs/client/` | `/etc/etcd/certs/client/` |

## Expected upgrade sequence

1. DC PR merges → FluxCD reconciles → HelmRelease updates konk-operator to j16
2. j16 operator reconciles Konk CR → updates Etcd CR with new spec
3. Etcd CR change triggers helm upgrade on `bulk-konk-etcd` (rev 108 → 109)
4. **Pre-upgrade hook fires**: `lookup` sees STS VCT=`data` ≠ target `data-v2` → renders Job
5. Hook Job: `kubectl delete sts bulk-konk-etcd --wait=true` → STS gone
6. Helm applies new STS manifest with VCT=`data-v2`, replicaCount=3
7. Kubernetes auto-provisions fresh `data-v2-bulk-konk-etcd-{0,1,2}` PVCs
8. 3 etcd pods bootstrap `new` on fresh empty PVCs → healthy 3-member cluster
9. Old `data-bulk-konk-etcd-0` PVC retained (orphaned backup — clean up later)

## Post-upgrade verification

→ See [`post-upgrade.md`](./post-upgrade.md) for the full 17-point success checklist.
