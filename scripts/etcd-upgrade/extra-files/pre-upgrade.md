# Pre-Upgrade Checks — etcd `claimName` Migration (Option B / PR #634)

> Capture this **baseline snapshot BEFORE** merging the DC PR / triggering the
> etcd chart upgrade. Save the output so you can diff it against
> [`post-upgrade.md`](./post-upgrade.md) afterward.

## Setup

```bash
export CTX=us-dev-5          # kube-context
export NS=aggregate          # namespace
export STS=bulk-konk-etcd    # etcd StatefulSet / helm release name
export TARGET_VCT=data-v2    # desired claimName after migration

# etcdctl TLS flags — cert path depends on the chart version:
#   j170 (Bitnami):  /opt/bitnami/etcd/certs/client/
#   j16  (upstream):  /etc/etcd/certs/client/
export ETCD_CERTS_DIR=/opt/bitnami/etcd/certs/client   # ← adjust per chart
export ETCD_TLS="--cacert=$ETCD_CERTS_DIR/ca.crt --cert=$ETCD_CERTS_DIR/server.crt --key=$ETCD_CERTS_DIR/server.key"
# NOTE: use the localhost endpoint for health/status — the per-pod FQDN is NOT in
# the server cert SAN (only `bulk-konk-etcd-headless` and `localhost` are), so
# `--cluster`/FQDN endpoints fail TLS verification (client-side artifact, not a fault).
export ETCD_EP='--endpoints=https://localhost:2379'
```

### Chart version differences (j170 vs j16)

| Aspect | j170 (pre-migration / Bitnami) | j16 (post-migration / upstream) |
|---|---|---|
| etcd image | `etcd:3.4.14-debian-10-r0` (Bitnami) | `gcr.io/etcd-development/etcd:v3.6.8` |
| Cert mount | `/opt/bitnami/etcd/certs/client/` | `/etc/etcd/certs/client/` |
| Data mount | `/bitnami/etcd` | `/var/run/etcd` |
| Shell in image | `sh` available | Distroless (no shell — call `etcdctl` directly) |
| Default claimName | `data` | `data` (configurable) |
| Default replicaCount | 1 | 1 |

## Baseline checklist

| # | Check | Command | Record / Expect |
|---|-------|---------|-----------------|
| 1 | Operator image (pre) | `kubectl --context $CTX get deploy -n konk -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \| grep -i operator` | Record the **old** operator tag (e.g. `…-j170`) |
| 1 | Operator image (pre) | `kubectl --context $CTX get deploy -n konk -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \| grep -i operator` | Record the **old** operator tag (e.g. `…-j170`) |
| 2 | Konk CR etcd spec | `kubectl --context $CTX get konk.konk.infoblox.com bulk-konk -n $NS -o jsonpath='{.spec.etcd}'; echo` | **Pre-migration (j170 baseline):** `replicaCount: 1`, no `claimName`/`initialClusterState` (defaults) |
| 3 | Etcd CR spec | `kubectl --context $CTX get etcd.konk.infoblox.com $STS -n $NS -o jsonpath='{.spec}'; echo` | Confirm `statefulset.replicaCount:1`; no `persistence.claimName` (= default `data`) |
| 4 | Hook enabled value | `kubectl --context $CTX get etcd.konk.infoblox.com $STS -n $NS -o jsonpath='{.spec.recreateStatefulSet.enabled}'; echo` | **blank** pre-merge (j170 doesn't know about the hook) |
| 5 | **Live STS VCT** | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='VCT={.spec.volumeClaimTemplates[0].metadata.name}{"\n"}'` | **`data`** — the baseline state the hook will migrate away from |
| 6 | Live STS state env | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ETCD_INITIAL_CLUSTER_STATE")]}STATE={.value}{"\n"}{end}'` | Empty or absent (Bitnami j170 doesn't inject this env for `replicaCount:1`) |
| 7 | Replicas Ready | `kubectl --context $CTX get sts $STS -n $NS -o jsonpath='ready={.status.readyReplicas}/{.status.replicas}{"\n"}'` | `1/1` |
| 8 | Helm rev stable | `kubectl --context $CTX get secret -n $NS -l owner=helm,name=$STS --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}rev={.metadata.labels.version} status={.metadata.labels.status} {.metadata.creationTimestamp}{"\n"}{end}' \| tail -6` | Record the **highest rev N** — should be `deployed` with **no fail→rollback loop** |
| 9 | PVCs | `kubectl --context $CTX get pvc -n $NS --no-headers \| grep $STS` | Single `data-$STS-0` Bound (fresh, from the reset) |
| 10 | Pods | `kubectl --context $CTX get pods -n $NS --no-headers \| grep $STS` | `1` pod Running `1/1` |
| 11 | etcd members | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl member list -w table $ETCD_EP $ETCD_TLS` | 1 member `started`, IS LEADER = true |
| 12 | etcd health | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl endpoint health $ETCD_EP $ETCD_TLS` | `is healthy` |
| 13 | etcd status (version/db) | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl endpoint status -w table $ETCD_EP $ETCD_TLS` | Record VERSION (`3.4.14`), **DB SIZE**, leader=true |
| 14 | **Baseline key count** | `kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null \| grep -c .` | Record N keys (≈195 from KonkService repopulation) |
| 15 | Konk CR status | `kubectl --context $CTX get konk bulk-konk -n $NS -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}{"\n"}'` | **`UpgradeSuccessful`** (clean baseline, no loop) |
| 16 | No stale hook resources | `kubectl --context $CTX get job,sa,role,rolebinding -n $NS \| grep -i recreate` | Should be empty before upgrade |
| 17 | No orphan PVCs | `kubectl --context $CTX get pvc -n $NS --no-headers \| grep $STS` | Only `data-$STS-0`; no `data-v2-*` leftovers |

## Preconditions that MUST be true before merging

- [ ] **#5 live VCT = `data`** — if it is already `data-v2`, the migration is done and
      the hook will be a **no-op** (it only fires when live VCT ≠ `TARGET_VCT`).
- [ ] **#8 helm rev is stable `deployed`** — no active fail→rollback loop.
- [ ] **#17 no orphan PVCs** — only `data-$STS-0` should exist.
- [ ] PR #134745 carries:
  - konk-operator bump to **j16** (`v0.2.1-151-gfd9ed6b-j16`)
  - `bulk-values.yaml` with:
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

## Reset to `data` to (re-)test the migration

> Needed when the live STS is **already `data-v2`** (e.g. us-dev-5 after the manual
> validation) but you want to exercise the real j16 hook from a clean pre-migration
> state. The hook only fires when live VCT ≠ `data-v2`, so you must put the live STS
> back on VCT=`data` first.

> ⚠️ **The VCT name is immutable in BOTH directions.** A simple value flip
> `data-v2 → data` will **not** move the live STS back — it hits the same
> immutable-rename loop in reverse. You must **delete the STS** while the desired
> spec says `claimName: data`, so the operator recreates it fresh.

### Steps

1. **Revert to the pre-migration chart** (j170) via a DC PR that:
   - Sets `konk-operator-version.txt` = `v0.2.1-138-g8b64bf7-j170`
   - Removes the `konk.custom.etcd` block from `bulk-values.yaml`
     (defaults: `claimName: data`, `replicaCount: 1`, no hook)
   - Example: [DC PR #134748](https://github.com/Infoblox-CTO/deployment-configurations/pull/134748)

2. **Wait for the DC PR to deploy** — the Konk/Etcd CR will revert, but the STS
   remains stuck (immutable VCT). Confirm:
   ```bash
   kubectl --context $CTX get etcd.konk.infoblox.com $STS -n $NS -o jsonpath='replicaCount={.spec.statefulset.replicaCount} claimName={.spec.persistence.claimName}{"\n"}'
   # Expect: replicaCount=1 claimName=  (blank = default "data")
   kubectl --context $CTX get sts $STS -n $NS -o jsonpath='VCT={.spec.volumeClaimTemplates[0].metadata.name}{"\n"}'
   # Expect: VCT=data-v2  (stuck — immutable)
   ```

3. **Delete the live STS** so the operator recreates it per the reverted chart:
   ```bash
   kubectl --context $CTX delete sts $STS -n $NS --wait=true
   ```

4. **Delete ALL stale etcd PVCs** (both `data-*` and `data-v2-*`).
   The old `data-*` PVCs contain 3-member cluster metadata; a fresh `replicaCount:1`
   bootstrap on them would fail quorum. Delete everything and let the STS create
   a fresh empty `data-0`:
   ```bash
   kubectl --context $CTX get pvc -n $NS --no-headers | grep $STS   # confirm targets
   kubectl --context $CTX delete pvc -n $NS \
     data-$STS-0 data-$STS-1 data-$STS-2 \
     data-v2-$STS-0 data-v2-$STS-1 data-v2-$STS-2 \
     --ignore-not-found
   ```
   > ⚠️ On a **dev cluster** this is safe — KonkServices repopulate all keys.
   > On **stage/prod** preserve `data-*` PVCs and use `replicaCount:3` instead.

5. **Nudge the operator** if the STS hasn't reappeared within ~30s (the operator
   may be processing other CRs). Annotate the Etcd CR to trigger a reconcile:
   ```bash
   kubectl --context $CTX annotate etcd.konk.infoblox.com $STS -n $NS \
     konk.infoblox.com/reconcile-nudge="$(date +%s)" --overwrite
   ```

6. **Verify clean baseline** (VCT=`data`, 1 pod Ready, fresh PVC, keys repopulated):
   ```bash
   kubectl --context $CTX get sts $STS -n $NS -o jsonpath='VCT={.spec.volumeClaimTemplates[0].metadata.name} ready={.status.readyReplicas}/{.spec.replicas}{"\n"}'
   kubectl --context $CTX get pvc -n $NS --no-headers | grep $STS
   kubectl --context $CTX get pods -n $NS --no-headers | grep $STS
   kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c .
   kubectl --context $CTX get konk bulk-konk -n $NS -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}{"\n"}'
   ```
   Expect: VCT=`data`, `1/1`, single fresh PVC, ≈195 keys, `UpgradeSuccessful`.

7. **Re-apply the migration target** — merge PR #134745 (j16 + `claimName: data-v2`
   + `recreateStatefulSet.enabled: true` + `replicaCount: 3` + `initialClusterState: new`).
   The j16 hook now sees live VCT=`data` ≠ `data-v2` and performs the real migration.
   Proceed to [`post-upgrade.md`](./post-upgrade.md).

### Validated result (us-dev-5, 2026-06-23)

| Step | Outcome |
|---|---|
| Revert PR (#134748) deployed | Konk/Etcd CR reverted to `replicaCount:1`, no claimName ✅ |
| STS stuck | VCT still `data-v2` (immutable in both directions) — expected ✅ |
| Manual STS delete | `statefulset.apps "bulk-konk-etcd" deleted` ✅ |
| All 6 PVCs deleted | `data-*` + `data-v2-*` removed ✅ |
| Nudge annotation | Triggered operator reconcile immediately ✅ |
| New STS | VCT=`data`, `replicaCount:1`, fresh PVC (`data-bulk-konk-etcd-0`) ✅ |
| etcd health | 1 member, leader, healthy (5.3ms commit), v3.4.14 (Bitnami) ✅ |
| Keys | 195 — KonkServices repopulated ✅ |
| Konk CR | `UpgradeSuccessful` ✅ |
| Helm rev | 108 `deployed` — stable, no loop ✅ |

## Rollback (migration went wrong — return to `data`)

> Same mechanism as the reset above. Rollback = revert chart + STS delete +
> PVC cleanup → fresh `data` baseline.

1. **Revert** the DC PR (set konk-operator back to j170, remove the `konk.custom.etcd` block).
2. Wait for deploy → Konk/Etcd CR reverts. STS remains stuck on `data-v2`.
3. **Delete the STS** (immutable VCT can't revert in-place):
   ```bash
   kubectl --context $CTX delete sts $STS -n $NS --wait=true
   ```
4. **Delete stale PVCs** — on dev, delete ALL (`data-*` + `data-v2-*`) for a clean
   bootstrap. On stage/prod with `replicaCount:3`, keep the original `data-*` PVCs
   (they hold real data with matching 3-member metadata):
   ```bash
   # Dev (fresh start):
   kubectl --context $CTX delete pvc -n $NS \
     data-$STS-0 data-$STS-1 data-$STS-2 \
     data-v2-$STS-0 data-v2-$STS-1 data-v2-$STS-2 --ignore-not-found
   # Stage/Prod (preserve data-*):
   kubectl --context $CTX delete pvc -n $NS \
     data-v2-$STS-0 data-v2-$STS-1 data-v2-$STS-2 --ignore-not-found
   ```
5. **Nudge** the Etcd CR if STS doesn't reappear:
   ```bash
   kubectl --context $CTX annotate etcd.konk.infoblox.com $STS -n $NS \
     konk.infoblox.com/reconcile-nudge="$(date +%s)" --overwrite
   ```
6. **Verify** clean baseline (VCT=`data`, Ready, healthy, keys repopulated, `UpgradeSuccessful`).

## One-shot baseline snapshot

```bash
echo "=== $(date) PRE-UPGRADE baseline ($CTX/$NS) ===" \
 && echo "operator:" && kubectl --context $CTX get deploy -n konk -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' | grep -i operator \
 && echo "Konk etcd spec:" && kubectl --context $CTX get konk.konk.infoblox.com bulk-konk -n $NS -o jsonpath='{.spec.etcd}'; echo \
 && echo "VCT:" && kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'; echo \
 && echo "STATE:" && kubectl --context $CTX get sts $STS -n $NS -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="ETCD_INITIAL_CLUSTER_STATE")]}{.value}{end}'; echo \
 && echo "helm revs:" && kubectl --context $CTX get secret -n $NS -l owner=helm,name=$STS --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}rev={.metadata.labels.version} {.metadata.labels.status}{"\n"}{end}' | tail -6 \
 && echo "PVCs:" && kubectl --context $CTX get pvc -n $NS --no-headers | grep $STS \
 && echo "pods:" && kubectl --context $CTX get pods -n $NS --no-headers | grep $STS \
 && echo "keys:" && kubectl --context $CTX exec -n $NS $STS-0 -- etcdctl get "" --prefix --keys-only $ETCD_EP $ETCD_TLS 2>/dev/null | grep -c . \
 && echo "Konk CR:" && kubectl --context $CTX get konk bulk-konk -n $NS -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}'; echo
```




Manual update - Make sure there are no ownership annotations issues in konk services