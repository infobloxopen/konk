# Post-Upgrade Checks — etcd `claimName` Migration (Option B / PR #634)

> Run these **AFTER** the DC PR merges / the etcd chart upgrade completes. Compare
> against the baseline captured in [`pre-upgrade.md`](./pre-upgrade.md). The goal:
> confirm the pre-upgrade hook deleted the old STS and Helm recreated it fresh on
> `data-v2`, the cluster bootstrapped `new`, and the fail→rollback loop stopped.

## Setup

```bash
# Use current kubectl context by default; override with: export CTX=<cluster>
export CTX=${CTX:-$(kubectl config current-context)}
export NS=aggregate
export STS=bulk-konk-etcd
export TARGET_VCT=data-v2
export ETCD_TLS='--cacert=/etc/etcd/certs/client/ca.crt --cert=/etc/etcd/certs/client/server.crt --key=/etc/etcd/certs/client/server.key'
export ETCD_EP='--endpoints=https://localhost:2379'   # in-SAN; do NOT use --cluster/FQDN (TLS SAN mismatch)
```

## Success checklist

| # | Check | Command | Expect |
|---|-------|---------|--------|
| 1 | Operator image (post) | `kubectl --context $CTX get deploy -n vela-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \| grep -i konk` | New tag (e.g. `…-j16`) ✅ |
| 2 | **New STS VCT** | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='VCT={.spec.volumeClaimTemplates[0].metadata.name}{"\n"}'` | **`data-v2`** ✅ (was `data`) |
| 3 | **`ETCD_INITIAL_CLUSTER_STATE`** | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ETCD_INITIAL_CLUSTER_STATE")]}STATE={.value}{"\n"}{end}'` | **`new`** ✅ |
| 4 | STS created fresh | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='created={.metadata.creationTimestamp}{"\n"}'` | timestamp **after** the upgrade (proves recreate) ✅ |
| 5 | **New PVCs** | `kubectl --context $CTX get pvc -n $NS --no-headers \| grep $STS` | `data-v2-$STS-{0,1,2}` **Bound** (new, fresh) ✅ |
| 6 | **Old PVCs retained (backup)** | `kubectl --context $CTX get pvc -n $NS --no-headers \| grep "data-$STS-"` | `data-$STS-{0,1,2}` still **Bound** (untouched backup) ✅ |
| 7 | Pods Ready | `kubectl --context $CTX get pods -n $NS --no-headers \| grep $STS` | `3× 1/1 Running` ✅ |
| 8 | **etcd members** | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl member list -w table $ETCD_EP $ETCD_TLS` | 3 members `started`, **none learners**, leader elected ✅ |
| 9 | **etcd health** | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl endpoint health $ETCD_EP $ETCD_TLS` | `is healthy` (low-ms commit) ✅ |
| 10 | etcd version/db | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl endpoint status -w table $ETCD_EP $ETCD_TLS` | VERSION `3.6.8`, STORAGE `3.6.0`, leader present ✅ |
| 11 | **Keys reconstructed** | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null \| grep -c .` | Non-zero; KonkServices repopulate keys (≈ baseline count) ✅ |
| 12 | **Helm loop stopped** | `kubectl --context $CTX get secret -n $NS -l owner=helm,name=$STS --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}rev={.metadata.labels.version} {.metadata.labels.status}{"\n"}{end}' \| tail -6` | Latest rev = `deployed`, rev advanced by 1 (e.g. `72 → 73`), **no more `failed` churn** ✅ |
| 13 | **Konk CR** | `kubectl --context $CTX get konk bulk-konk -n $NS -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}{"\n"}'` | **`UpgradeSuccessful`** ✅ |
| 14 | Hook Job completed | `kubectl --context $CTX get job -n $NS \| grep recreate` | Job `Complete` (or already cleaned by hook-delete-policy) ✅ |
| 15 | Hook RBAC cleaned up | `kubectl --context $CTX get sa,role,rolebinding -n $NS \| grep recreate` | Empty — `before-hook-creation,hook-succeeded` cleaned them ✅ |
| 16 | KonkServices reconciled | `kubectl --context $CTX get konkservice -n $NS 2>/dev/null \| head` | Services present / reconciled ✅ |
| 17 | APIServices available | `kubectl --context $CTX get apiservice \| grep -iE 'aggregate\|konk' ` | Aggregated APIs `True` (Available) ✅ |

## Example confirmed result (sample run, manual STS-delete validation)

✅ **Confirmed — the mechanism works end-to-end.** Deleting the STS (exactly what
the PR #634 hook does) broke the immutable-VCT loop and completed the migration:

| Check | Result |
|-------|--------|
| New STS VCT | **`data-v2`** ✅ (was `data`) |
| `ETCD_INITIAL_CLUSTER_STATE` | **`new`** ✅ |
| New PVCs | `data-v2-bulk-konk-etcd-{0,1,2}` Bound ✅ |
| Old PVCs | `data-bulk-konk-etcd-{0,1,2}` retained as backup ✅ |
| Pods | 3× `1/1` Running ✅ |
| Cluster | 3 members `started`, none learners, leader elected ✅ |
| Health (localhost, in-SAN) | **healthy**, 8.47ms commit ✅ |
| etcd version | 3.6.8 (storage 3.6.0) ✅ |
| Keys | **196** — KonkServices reconstructed data ✅ |
| Helm rev | **72 → 73 `deployed`** — fail→rollback loop **stopped** ✅ |
| Konk CR | **`UpgradeSuccessful`** ✅ |

## Failure signs (investigate if seen)

- STS VCT still `data` → hook didn't fire. Check `recreateStatefulSet.enabled: true`
  reached the Etcd CR (`kubectl get etcd $STS -n $NS -o jsonpath='{.spec.recreateStatefulSet}'`),
  and that operator is the new `…-j16` build (#1).
- Helm rev still climbing with `failed` → still in the immutable-VCT loop (hook no-op or skipped).
- Pods `CrashLoopBackOff` with cluster-ID/`member already bootstrapped` errors →
  `initialClusterState` not `new`, or stale member data on the PVC.
- `data-v2-*` PVCs not created → `persistence.claimName` not `data-v2` in the live STS.

## One-shot verification snapshot

```bash
echo "=== $(date) POST-UPGRADE verify ($CTX/$NS) ===" \
 && kubectl --context $CTX get deploy -n vela-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' | grep -i konk \
 && echo "VCT:" && kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'; echo \
 && echo "STATE:" && kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ETCD_INITIAL_CLUSTER_STATE")]}{.value}{end}'; echo \
 && echo "pods:" && kubectl --context $CTX get pods -n $NS --no-headers | grep $STS \
 && echo "PVCs:" && kubectl --context $CTX get pvc -n $NS --no-headers | grep $STS \
 && echo "members:" && kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl member list -w table $ETCD_EP $ETCD_TLS \
 && echo "health:" && kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl endpoint health $ETCD_EP $ETCD_TLS \
 && echo "keys:" && kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . \
 && echo "helm:" && kubectl --context $CTX get secret -n $NS -l owner=helm,name=$STS --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}rev={.metadata.labels.version} {.metadata.labels.status}{"\n"}{end}' | tail -4 \
 && echo "Konk:" && kubectl --context $CTX get konk bulk-konk -n $NS -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}'; echo
```
