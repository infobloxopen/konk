# etcd Rollback Debugging — us-stg-1 (j20 → j170)

Cluster: `us-stg-1` (com-stage)
Date: 2026-08-05
Rollback: konk-operator `v0.2.1-154-g1de007e-j20` → `v0.2.1-138-g8b64bf7-j170`
etcd: `gcr.io/etcd-development/etcd:v3.6.8` + `data-v2` PVCs → `docker.io/bitnami/etcd:3.4.14-debian-10-r0` + `data` PVCs

> **Naming note:** this rollback is *gcr.io → bitnami*, not *cgr.dev → bitnami*.
> us-stg-1 was on j20 (`1de007e`), which predates `e13f6ed`/`9deaa9d` (the
> `cgr.dev/infoblox.com/etcd:3.7.0/3.7.1` commits). Only us-dev-5 reached cgr.dev.
> See [Doc corrections](#doc-corrections-to-etcd-migration-debuggingmd).

---

## TL;DR

The rollback PR merged cleanly and Flux went green, but **etcd never rolled back**.
Eight distinct problems stacked on top of each other. All are now resolved — #7 is a
chart-level bug in j170 that cannot be fixed in place, so the final solution routes
around it entirely rather than fixing it.

| # | Issue | Status |
|---|-------|--------|
| 1 | Rollback was a silent no-op — Flux green, etcd untouched | Solved |
| 2 | Helm ownership metadata blocked all reconciliation | Solved |
| 3 | Immutable `volumeClaimTemplates`; j170 has no recreate hook | Solved |
| 4 | Hybrid STS: bitnami chart + upstream image → `exec setup.sh: no such file` | Solved |
| 5 | RollingUpdate deadlock — only highest ordinal updated | Solved |
| 6 | Restored data is a 1-member cluster; config wants 3 | Solved |
| 7 | Chart cannot grow a cluster — `member add` is dead code | Won't fix in j170 — bypassed |
| 8 | Manual scaling reverted by operator in ~60s | Solved — patch the CR, not the STS |

**Final state: rollback complete.** A healthy **3-member** etcd cluster on the prod
bitnami image with `data` PVCs, under konk-operator j170. Achieved by wiping the etcd
data and bootstrapping a fresh cluster — see
[the solution that worked](#solution-that-worked--wipe-and-bootstrap).

> **Precondition:** this cluster held no application data, so discarding etcd
> contents was acceptable. If the data must survive, use
> [Option A](#option-a-alternative--snapshot-restore-a-3-member-cluster) instead —
> same end state, considerably more work.

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| 2026-06-25 16:01 | PR #134685 merged — upgrade to j20, `claimName: data-v2`, `initialClusterState: new`, `recreateStatefulSet: true`, `replicaCount: 1` → `3` |
| 2026-06-25 16:05 | ConfigMap `bulk-konk-etcd-scripts` created (chart `etcd-5.3.2`, **no** helm ownership annotations) |
| 2026-06-25 16:08 | etcd helm release rev 4 — last etcd activity for 6 weeks |
| 2026-08-05 09:35 | PR #141184 merged — revert to j170 |
| 2026-08-05 09:38:43 | Etcd CR stamped `Irreconcilable` / `ReconcileError` |
| 2026-08-05 ~09:55 | ConfigMap annotated; StatefulSet deleted |
| 2026-08-05 09:57:13 | helm rev 31 — chart `etcd-5.3.2`, appVersion `3.4.14` (correct chart, wrong image) |
| 2026-08-05 10:08:57 | `spec.image` removed from Etcd CR → helm rev 32 (correct image) |
| 2026-08-05 10:14:50 | `etcd-0` restarted member `132d3f2b2031a7d7`, became leader at term 10 |
| 2026-08-05 10:31 | Snapshot taken — revision 5432, 219 keys, hash `20901b1e`, 1.6 MB |
| 2026-08-05 ~10:35 | Manual `scale --replicas=1` reverted to 3 by operator within 60s |
| 2026-08-05 11:13 | Proved the `is_disastrous_failure` health probe can never succeed (Issue 7) |
| 2026-08-05 11:25:50 | `initialClusterState: "new"` patched onto Etcd CR → helm rev 33 |
| 2026-08-05 ~11:27 | All three `data` PVCs and pods deleted |
| 2026-08-05 ~11:29 | Fresh 3-member cluster formed — 3/3 Ready in ~80s, 0 restarts |

---

## Version / commit reference

| Label | konk version | etcd chart | etcd image |
|-------|--------------|------------|------------|
| j170 (prod, rollback target) | `v0.2.1-138-g8b64bf7` | `etcd-5.3.2` / app `3.4.14` | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` |
| j20 (rolled back from) | `v0.2.1-154-g1de007e` | — | `gcr.io/etcd-development/etcd:v3.6.8` |
| j25 (forward branch) | `v0.2.1-158-gf8540d7` | — | `cgr.dev/infoblox.com/etcd:3.7.1` |

Relevant konk commits, oldest → newest:

```
518eac5  Konk-operator version upgrade (#565)
7c13757  PTCI-3293: replace bitnamilegacy/etcd with gcr.io/etcd-development/etcd:v3.6.7 (#572)
aca7e33  cve-fix: bump etcd image tag v3.6.7 -> v3.6.8 (#583)
895772e  feat(etcd): parameterize volumeClaimTemplate name for migration (#631)
fd9ed6b  feat(etcd): declarative StatefulSet recreate hook for claimName/PVC migration (#634)
1de007e  fix: add meta.helm.sh ownership annotations to chart templates (#635)   ← j20
372db4e  fix(etcd): always recreate STS when hook enabled (#636)
e13f6ed  Use cgr.dev/infoblox.com/etcd:3.7.0 image
9deaa9d  Fix CVE: bump etcd image from 3.7.0 to 3.7.1
f8540d7  fix(etcd): restore statefulset.replicaCount in chart templates          ← j25
```

**Critical:** `8b64bf7` (j170) is an ancestor of all of the above. Every etcd fix
listed exists **only in the newer versions**. Rolling back to j170 discards them.

```bash
cd <konk-repo>
git merge-base --is-ancestor 1de007e 8b64bf7 && echo "in j170" || echo "j170 LACKS it"
# → j170 LACKS it
```

---

## Where `setup.sh` comes from

Not in any image — `git grep setup.sh` outside `helm-charts/` returns nothing.

```
konk repo: helm-charts/etcd/templates/scripts-configmap.yaml   ← source of truth
      │ rendered by the etcd chart when konk-operator installs
      │ the bulk-konk-etcd helm release
      ▼
ConfigMap bulk-konk-etcd-scripts  (ns: aggregate)
      │ mounted per-key via subPath by helm-charts/etcd/templates/statefulset.yaml
      ▼
/scripts/setup.sh  in each etcd pod  ← also the container's command
```

It runs in the **etcd pods**, not the operator pod. It is Helm-templated: the
literal `if [[ 3 -eq 1 ]]` in the deployed script is `replicaCount` substituted at
render time. To change the logic you must change the chart and cut a new operator
version — editing the live ConfigMap is reverted on the next helm reconcile.

```bash
# read the deployed script
kubectl get configmap bulk-konk-etcd-scripts -n aggregate \
  -o jsonpath='{.data.setup\.sh}'
```

---

## Ownership chain (needed to reason about who reverts what)

```
Flux HR konk-operator (vela-system) ──► konk-operator Deployment (ns konk)
Flux HR bulk          (vela-system) ──► helm release bulk ──► KonK CR (ns aggregate)
konk-operator POD ──► Etcd CR ──► helm release bulk-konk-etcd ──► StatefulSet
```

Verified:

```bash
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{.metadata.ownerReferences}'
# → [{"kind":"Etcd","name":"bulk-konk-etcd","controller":true}]
```

**There is no Flux HelmRelease for `bulk-konk-etcd`.** `flux suspend helmrelease
bulk-konk-etcd` fails with "not found". Only `bulk` and `konk-operator` are Flux HRs.

```bash
kubectl get helmrelease.helm.toolkit.fluxcd.io -A | grep -iE "bulk|konk"
```

---

## Issue 1 — Rollback merged, Flux green, etcd untouched

### Symptom

Everything reported success, but the data plane was still on the upgrade:

```
DC config (origin/master):  v0.2.1-138-g8b64bf7-j170        ✓
konk-operator pod:          konk:v0.2.1-138-g8b64bf7-j170   ✓
Flux HR bulk / konk-operator: READY=True, not suspended     ✓
KonK CR etcd values:        reverted                        ✓

etcd STS image:             gcr.io/etcd-development/etcd:v3.6.8   ✗
STS volumeClaimTemplates:   data-v2                               ✗
helm release bulk-konk-etcd: revision 4, updated Jun 25 16:08     ✗
```

Zero etcd helm activity in the 6 weeks since the original upgrade.

### Root cause

The Etcd CR carried an `Irreconcilable` condition stamped 3 minutes after the PR
merged. Reconciliation was aborting before helm could compute a diff.

### Diagnostic — and a blind spot in the old runbook

The verification in `etcd-migration-debugging.md` checks only `Deployed` and
`ReleaseFailed`. Both were misleading here:

```
Deployed=UpgradeSuccessful   ← stale, from 2025-07-10
ReleaseFailed=               ← condition absent entirely
```

**Always check all conditions, not a hand-picked two:**

```bash
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .status.conditions[*]}{.type}={.reason} {end}{"\n"}'

# full message for any failing condition
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="Irreconcilable")].message}'
```

Cross-check that helm actually did something — a stale `UPDATED` timestamp is the
strongest signal a "successful" rollback did nothing:

```bash
helm history bulk-konk-etcd -n aggregate
```

---

## Issue 2 — Helm ownership metadata blocks all reconciliation

### Symptom

```
failed to get candidate release: Unable to continue with update: ConfigMap
"bulk-konk-etcd-scripts" in namespace "aggregate" exists and cannot be imported
into the current release: invalid ownership metadata; annotation validation error:
missing key "meta.helm.sh/release-name": must be set to "bulk-konk-etcd";
annotation validation error: missing key "meta.helm.sh/release-namespace":
must be set to "aggregate"
```

### Root cause

The ConfigMap was created 2026-06-25T16:05:23Z carrying `helm.sh/chart: etcd-5.3.2`
and the `app.kubernetes.io/managed-by: Helm` label, but **no `meta.helm.sh/*`
annotations**. Helm therefore refused to adopt it.

The fix for exactly this is konk commit `1de007e` — *"fix: add meta.helm.sh
ownership annotations to chart templates (#635)"* — which is **in j20 and j25 but
not in j170**.

> **The rollback target predates the fix for the problem the rollback creates.**
> This is the general trap: rolling *backwards* past a compatibility fix
> re-introduces the incompatibility, and the old code has no way to resolve it.

### Fix

Sweep first — helm reports only the **first** conflicting resource, so fixing one
can surface the next:

```bash
kubectl get configmap,secret,service,statefulset,serviceaccount,poddisruptionbudget \
  -n aggregate -l app.kubernetes.io/instance=bulk-konk-etcd -o json \
| jq -r '["KIND","NAME","REL-NAME","REL-NS","MANAGED-BY","CHART"], (.items[] | [.kind, .metadata.name,
    (.metadata.annotations["meta.helm.sh/release-name"]      // "MISSING"),
    (.metadata.annotations["meta.helm.sh/release-namespace"] // "MISSING"),
    (.metadata.labels["app.kubernetes.io/managed-by"]        // "NO-LABEL"),
    (.metadata.labels["helm.sh/chart"]                       // "-")]) | @tsv' | column -t
```

Result — the mismatched `CHART` value is the tell:

```
KIND         NAME                     REL-NAME        REL-NS     MANAGED-BY  CHART
ConfigMap    bulk-konk-etcd-scripts   MISSING         MISSING    Helm        etcd-5.3.2   ← orphan
Service      bulk-konk-etcd           bulk-konk-etcd  aggregate  Helm        etcd-1.0.0   ✓
Service      bulk-konk-etcd-headless  bulk-konk-etcd  aggregate  Helm        etcd-1.0.0   ✓
StatefulSet  bulk-konk-etcd           bulk-konk-etcd  aggregate  Helm        etcd-1.0.0   ✓
```

Apply:

```bash
kubectl annotate configmap bulk-konk-etcd-scripts -n aggregate \
  meta.helm.sh/release-name=bulk-konk-etcd \
  meta.helm.sh/release-namespace=aggregate \
  --overwrite

# if any resource shows NO-LABEL, it also needs:
# kubectl label <kind>/<name> -n aggregate app.kubernetes.io/managed-by=Helm --overwrite

kubectl rollout restart deployment konk-operator -n konk   # force immediate reconcile
```

Verify — `Irreconcilable` gone and a **new** helm revision:

```bash
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .status.conditions[*]}{.type}={.reason} {end}{"\n"}'
helm history bulk-konk-etcd -n aggregate
```

### False positives to ignore in the sweep

| Resource | Why it shows MISSING but is fine |
|----------|--------------------------------|
| `Endpoints/bulk-konk-etcd`, `-headless` | Auto-generated by the kube endpoints controller from the Services (inherit labels, not annotations). Helm never templates Endpoints → cannot conflict. |
| `Secret/bulk-konk-etcd-ca`, `-cert` | Owned by release **`bulk-konk`**, created by the kubeadm init script. The Etcd CR uses `auth.client.existingSecret`, so the etcd chart consumes but never renders them. |

---

## Issue 3 — Immutable `volumeClaimTemplates`, and j170 has no recreate hook

### Symptom

```
upgrade failed: cannot patch "bulk-konk-etcd" with kind StatefulSet:
StatefulSet.apps "bulk-konk-etcd" is invalid: spec: Forbidden: updates to
statefulset spec for fields other than 'replicas', 'ordinals', 'template',
'updateStrategy', 'revisionHistoryLimit',
'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden
```

### Root cause

The rollback reverts `claimName` from `data-v2` back to `data`, which changes
`volumeClaimTemplates` — an immutable StatefulSet field.

Worse: PR #141184 also reverted `recreateStatefulSet.enabled: true`, and **j170
predates the recreate hook entirely** (`fd9ed6b` #634, `372db4e` #636). So there is
no auto-recreate capability on this version at any value of that flag.

### Fix — manual delete

```bash
kubectl delete statefulset bulk-konk-etcd -n aggregate
# operator recreates it fresh on the next reconcile
helm history bulk-konk-etcd -n aggregate   # expect a new "Upgrade complete"
```

PVCs are safe — retention policy is `Retain/Retain`:

```bash
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'
# → {"whenDeleted":"Retain","whenScaled":"Retain"}
```

---

## Issue 4 — Hybrid StatefulSet: right chart, wrong image

### Symptom

All pods `CrashLoopBackOff` with a maximally misleading error:

```
exec /scripts/setup.sh: no such file or directory
```

The script **is** mounted correctly. `setup.sh` begins `#!/bin/bash`, and the
upstream `gcr.io/etcd-development/etcd` image is minimal with **no `/bin/bash`**.
The ENOENT is on the *interpreter*, not the script.

### Root cause

The StatefulSet was a hybrid of both versions — j170's bitnami chart with j20's image:

```
cmd:    ["/scripts/setup.sh"]                                    ← bitnami chart
mounts: data:/bitnami/etcd, certs:/opt/bitnami/etcd/certs/client/ ← bitnami chart
image:  gcr.io/etcd-development/etcd:v3.6.8                       ← upstream, from j20
```

The Etcd CR still carried a stale `spec.image`, frozen at **generation 17**:

```json
{"pullPolicy":"IfNotPresent","registry":"gcr.io","repository":"etcd-development/etcd","tag":"v3.6.8"}
```

The Etcd CR spec is passed **straight through as helm values**, so it overrode the
chart default. And j170's operator has **no code that sets the etcd image anywhere**
— the only hit in `8b64bf7` is `config/samples/konk_v1alpha1_etcd.yaml`:

```bash
git grep -n -iE "etcd-development|bitnami/etcd" 8b64bf7 -- ':!helm-charts/etcd/**'
```

Nothing in j170 owns that field, so nothing cleared it.

> **Why `claimName` cleared but `image` didn't:** `claimName` and
> `initialClusterState` come from `bulk-values.yaml`, so reverting the DC file
> removed them. `image` is not DC-driven — it was written by the newer operator and
> j170 has no logic to remove it. **Rolling back the operator does not clean fields
> the newer operator wrote.**

### Diagnostic method: compare against a healthy cluster on the same version

`eu-stg-1` also runs j170. This is the fastest way to isolate a single bad field:

```bash
kubectl --context eu-stg-1 get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}claim={range .spec.volumeClaimTemplates[*]}{.metadata.name} {end}{"\n"}'
kubectl --context eu-stg-1 get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.image}{"\n"}'
```

```
eu-stg-1:  image=docker.io/bitnami/etcd:3.4.14-debian-10-r0   claim=data   spec.image=(empty)
us-stg-1:  image=gcr.io/etcd-development/etcd:v3.6.8          claim=data   spec.image={gcr.io...}
```

`spec.image` was the only delta. This also disproved a suspected
`bitnamilegacy` pull failure — the 3.4.14 tag still pulls fine (via the Harbor
proxy as `harbor.services.sdp.infoblox.com/infobloxcto/etcd:3.4.14-debian-10-r0`).

### Fix

```bash
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type=json -p '[{"op":"remove","path":"/spec/image"}]'
```

Bumps the CR generation → reconcile → chart default applies. Image is a **mutable**
template field, so no StatefulSet delete is needed.

```bash
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
# → docker.io/bitnami/etcd:3.4.14-debian-10-r0
```

### Also stale on the CR

`spec.replicaCount: 3` at top level, a leftover of the `7c13757` regression
(see `etcd-migration-debugging.md` Issue 6). Harmless on j170 — chart `etcd-5.3.2`
predates that change and reads `statefulset.replicaCount`, and both were 3.

---

## Issue 5 — RollingUpdate deadlock

### Symptom

After the image fix, only the highest ordinal picked up the new revision:

```
etcd-0: harbor.../etcd:v3.6.8               rev 68948bf6b9  ← OLD, bash error
etcd-1: harbor.../etcd:v3.6.8               rev 68948bf6b9  ← OLD, bash error
etcd-2: harbor.../etcd:3.4.14-debian-10-r0  rev 6dfd86857c  ← NEW
```

`etcd-2` was working correctly but could not become Ready:

```
==> Detected data from previous deployments...
etcdmain: the server is already initialized as member before, starting as etcd member...
could not get cluster response from ...etcd-0...:2380: connection refused
could not get cluster response from ...etcd-1...:2380: connection refused
cannot fetch cluster info from peer urls
```

### Root cause

Chicken-and-egg: `ETCD_INITIAL_CLUSTER_STATE=existing` means a rejoining member
must reach a live peer. Both peers were still on the broken old image.
`RollingUpdate` will not advance to lower ordinals until `etcd-2` is Ready, and
`etcd-2` cannot be Ready without a peer.

### Fix

`podManagementPolicy` is `Parallel`, so all pods can be replaced at once:

```bash
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='podMgmt={.spec.podManagementPolicy}{"\n"}'
# → Parallel

kubectl delete pod bulk-konk-etcd-0 bulk-konk-etcd-1 bulk-konk-etcd-2 -n aggregate
```

Safe: StatefulSet PVCs are never deleted with pods, and all three members were
already down, so no availability was lost.

**Result:** `etcd-0` restored the real cluster and became leader.

```
etcdserver: restarting member 132d3f2b2031a7d7 in cluster e9e217a51a7c2cee at commit index 7404
raft: 132d3f2b2031a7d7 became leader at term 10
mvcc: restore compact to 5430
embed: ready to serve client requests
```

---

## Issue 6 — Restored data is a 1-member cluster; config wants 3

### Symptom

`etcd-0` healthy and leading. `etcd-1`/`etcd-2` crashloop with:

```
error validating peerURLs {ClusterID:e9e217a51a7c2cee Members:[&{ID:132d3f2b2031a7d7
  ... Name:bulk-konk-etcd-0 ...}] RemovedMemberIDs:[]}: member count is unequal
```

### Root cause

`etcd-0`'s `data` PVC contains a **single-member** cluster:

```
raft: 132d3f2b2031a7d7 switched to configuration voters=(1381830115128879063)   ← one voter
embed: initial cluster =                                                        ← empty
```

`ETCD_INITIAL_CLUSTER` lists three peers; the live cluster reports one → mismatch.

Git shows why — and that **PR #141184's revert was incomplete**:

```bash
cd <dc-repo>
git log --oneline -L '/^konk:/,/^storage:/:envs/com-stage/us-stg-1/bulk-values.yaml'
```

```
13fba2233b5 (original)   # Run konk-etcd in non-HA (single pod) mode so that
                         # there are no quorum issues on startup
                           replicaCount: 1

59c428f5fcd #134685      - # Run konk-etcd in non-HA...   ← comment deleted
                         -   replicaCount: 1
                         +   replicaCount: 3

01660eaf3bc #141184      - claimName: data-v2             ← reverted
            (rollback)   - initialClusterState: "new"     ← reverted
                         - recreateStatefulSet: true      ← reverted
                           replicaCount: 3                ← LEFT AT 3
```

The `data` PVCs date from when us-stg-1 ran non-HA, so they hold a 1-member cluster.
The rollback left `replicaCount: 3`, so the chart demands three members the restored
data does not contain.

### Note on the prod baseline

`replicaCount: 3` **is** prod-consistent — `prd-1`/`us-com-1` set no override and
inherit the konk chart default:

```bash
git show 8b64bf7:helm-charts/konk/values.yaml | grep -n -A2 "statefulset:"
# helm-charts/konk/values.yaml:83:    replicaCount: 3    (under etcd.statefulset)
```

`eu-stg-1` explicitly overriding to `1` is the outlier. Note the etcd **sub**chart
default is `1` (`helm-charts/etcd/values.yaml:79`) — the konk chart is what makes it 3.

### Resolution — three choices

**A. Snapshot-restore a fresh 3-member cluster** — prod-matching *and* preserves the
data. Most work. See
[Option A](#option-a-alternative--snapshot-restore-a-3-member-cluster).

**B. Set `replicaCount: 1`** in `envs/com-stage/us-stg-1/bulk-values.yaml`,
restoring the original comment. `etcd-0` already serves the data; the other two pods
disappear. Requires a DC PR — an in-cluster patch drifts back. Not prod-matching.

**C. Wipe and bootstrap a fresh 3-member cluster** — prod-matching, simplest by far,
but **discards all etcd contents**. ← **this is what was done**, see
[the solution that worked](#solution-that-worked--wipe-and-bootstrap).

---

## Issue 7 — The chart cannot grow a cluster (`member add` is dead code)

This is the blocker. **Any** plan that relies on the chart adding a member to a
live cluster will fail, including "scale to 1, then 2, then 3".

### The logic

```bash
if [[ 3 -eq 1 ]]; then                       # templated replicaCount
    echo "==> Single node cluster detected!!"
elif is_disastrous_failure; then
    echo "==> Cluster not responding!!"
    echo "==> Disaster recovery is disabled, ..."
elif should_add_new_member; then
    echo "==> Adding new member to existing cluster..."
    etcdctl $AUTH_OPTIONS member add "$HOSTNAME" --peer-urls="http://...:2380" | grep "^ETCD_" > new_member_envs
    source new_member_envs                   # overrides ETCD_INITIAL_CLUSTER correctly
else
    echo "==> Updating member in existing cluster..."
    etcdctl $AUTH_OPTIONS member update "$(cat member_id)"
fi
exec etcd
```

```bash
is_disastrous_failure() {
    local -r min_endpoints=$(((3 + 1)/2))    # = 2
    for e in "${endpoints_array[@]}"; do
        if [[ "$e" != "$ETCD_ADVERTISE_CLIENT_URLS" ]] && (... etcdctl endpoint health --endpoints="$e"); then
            active_endpoints=$((active_endpoints + 1))
        fi
    done
    if [[ $active_endpoints -lt $min_endpoints ]]; then true; else false; fi
}
```

`ETCDCTL_ENDPOINTS` uses the **peer port 2380**.

### Proof: the health probe can never succeed

Run against a healthy, leading `etcd-0`:

```bash
kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c '
A=" --cert /opt/bitnami/etcd/certs/client/server.crt --key /opt/bitnami/etcd/certs/client/server.key --cacert /opt/bitnami/etcd/certs/client/ca.crt"
ETCDCTL_API=3 etcdctl $A endpoint health --endpoints=bulk-konk-etcd-0.bulk-konk-etcd-headless.aggregate.svc.cluster.local:2380'
```

```
tls: first record does not look like a TLS handshake
...:2380 is unhealthy: failed to commit proposal: context deadline exceeded
```

Port 2380 speaks plain HTTP raft (`ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380`);
`etcdctl` speaks TLS gRPC. So `active_endpoints` is **always 0** — not because peers
are down, but by construction.

Port 2379 fails too, for a different reason — the server cert lacks the per-pod FQDN:

```
x509: certificate is valid for bulk-konk-etcd-headless, bulk-konk-init-..., localhost,
      not bulk-konk-etcd-0.bulk-konk-etcd-headless.aggregate.svc.cluster.local
```

### Consequences

Since `min_endpoints ≥ 1` for any `replicaCount ≥ 2`, and `active_endpoints` is
always 0, `is_disastrous_failure` returns **true unconditionally**. The
`should_add_new_member` / `member add` branch is **unreachable**.

Corollaries:

- Emptying a PVC does not help — the guard is hit before the member-add branch.
- Lowering `replicaCount` to 2 does not help — the numerator is always 0.
- `kubectl scale` does not help — the `3` in the script and `ETCD_INITIAL_CLUSTER`
  are rendered from the **chart value**, not `spec.replicas`. Scaling changes how
  many pods run; it re-renders nothing.
- Empirically confirmed: every `etcd-1`/`etcd-2` boot printed
  `==> Cluster not responding!!` while `etcd-0` was healthy and leading.

The original DC comment — *"non-HA (single pod) mode so that there are no quorum
issues on startup"* — is documenting this bug.

**Two genuine chart bugs to file:** `is_disastrous_failure` probing 2380 with
`etcdctl`, and missing per-pod FQDN SANs. If j170 is prod's version, prod's
3-member cluster has no working self-heal either — a replaced member there hits
the same wall.

---

## Issue 8 — Manual scaling reverted by the operator in ~60s

### Symptom

```bash
kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=1
```

```
57s  SuccessfulDelete  delete Pod bulk-konk-etcd-1   ← the scale
0s   SuccessfulCreate  create Pod bulk-konk-etcd-1   ← operator put it back
```

`spec.replicas` was back to 3 within a minute.

### What does and does not stop it

| Action | Effect |
|--------|--------|
| `flux suspend hr konk-operator` | Stops Flux re-applying the Deployment. **Does not stop the operator pod reconciling.** Only makes a scale-to-0 stick. |
| `flux suspend hr bulk` | Stops KonK CR re-apply. Optional, harmless. |
| `flux suspend hr bulk-konk-etcd` | **Fails — not a Flux HR.** |
| `kubectl scale deploy konk-operator --replicas=0` | This is what actually stops reconciliation. |

Flux `driftDetection` is unset (disabled) on both HRs, so Flux will **not** revert
`kubectl annotate` / `rollout restart` / in-cluster mutations:

```bash
kubectl get helmrelease bulk -n vela-system \
  -o jsonpath='{.spec.driftDetection.mode}'   # → empty = disabled
```

> **When suspension matters:** not for one-shot metadata patches (Issue 2) — git
> and cluster already agreed, so Flux had nothing to re-apply. It *is* required for
> multi-step surgery where pods must stay down.

### Better answer: don't scale at all

The freeze below is only needed when pods must stay *down*. For everything else,
patch the **Etcd CR** and let the reconcile carry the change down to the
StatefulSet — the operator then works for you instead of against you.

| Layer | Durability of a manual change |
|-------|-------------------------------|
| StatefulSet (`kubectl scale`, spec edits) | Reverted in ~60s by the helm-operator |
| Etcd CR (`kubectl patch etcds...`) | **Holds** — `spec.image` removal survived 70+ min untouched |
| KonK CR | Rewritten by Flux HR `bulk` every 5m |
| `bulk-values.yaml` (DC repo) | Permanent |

The konk-operator does **not** rewrite the Etcd CR spec on a timer. This is what made
[the wipe-and-bootstrap fix](#solution-that-worked--wipe-and-bootstrap) possible with
no freeze at all.

### Working freeze sequence

```bash
flux suspend helmrelease konk-operator -n vela-system
flux suspend helmrelease bulk -n vela-system              # optional
kubectl scale deploy konk-operator -n konk --replicas=0   # stops reconciliation
kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=0   # now holds
```

The third step is still needed — with the operator dead, core Kubernetes' STS
controller still maintains 3 pods, and PVCs stay attached while pods exist.

Blast radius of stopping the operator on us-stg-1 is small — one `KonK` CR, one
`Etcd` CR, zero `KonkService`s:

```bash
kubectl get konk,etcds.konk.infoblox.com,konkservices -A
```

Unfreeze:

```bash
kubectl scale deploy konk-operator -n konk --replicas=1
flux resume helmrelease konk-operator -n vela-system
flux resume helmrelease bulk -n vela-system
```

---

## Solution that worked — wipe and bootstrap

**Applicable when the etcd contents are expendable.** us-stg-1 held no application
data, only `bulk-konk`'s own Kubernetes state (219 keys), so this was acceptable.

Like Option A, this sidesteps Issue 7 by never asking a pod to *join* an existing
cluster — all three bootstrap together from empty. Unlike Option A it needs no
snapshot, no helper pods, and **no freeze**: total elapsed time ~4 minutes.

### The one thing that makes or breaks it: `initialClusterState`

Three empty data dirs told to join a cluster that does not exist will all fail. The
bootstrap requires `new`, and the chart will **not** give you that by default:

```bash
# helm-charts/etcd/values.yaml:192
initialClusterState: ""
```

```gotemplate
{{/* helm-charts/etcd/templates/statefulset.yaml:142 */}}
- name: ETCD_INITIAL_CLUSTER_STATE
{{- if not (empty .Values.etcd.initialClusterState) }}
  value: {{ .Values.etcd.initialClusterState | quote }}
{{- else if .Release.IsInstall }}
  value: "new"
```

The release already exists, so every reconcile is an **upgrade**, not an install —
the `.Release.IsInstall` branch is never taken and it renders `existing`. You must
set it explicitly.

> This is also why PR #134685 (the original Jun 25 upgrade) set
> `initialClusterState: "new"` — it was bootstrapping the fresh `data-v2` cluster.
> The rollback removed it, correctly, and that is why bare PVC deletion is not enough.

### Why patching the Etcd CR works when `kubectl scale` does not (Issue 8)

`kubectl scale` on the StatefulSet is reverted in ~60s, but **Etcd CR spec patches
stick**. Evidence: the `spec.image` removal from Issue 4 survived ~70 minutes
untouched. The konk-operator does not rewrite the Etcd CR spec on a timer — only the
inner helm-operator reconciles CR → release → StatefulSet. So patch the CR and let
the reconcile carry your change down, rather than fighting it at the STS layer.

### Step 1 — switch to bootstrap mode

```bash
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate --type=merge \
  -p '{"spec":{"etcd":{"initialClusterState":"new"}}}'
```

**Confirm it reached the StatefulSet before deleting anything:**

```bash
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate -o jsonpath='{.spec.etcd}{"\n"}'
# → {"initialClusterState":"new"}

kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep INITIAL_CLUSTER_STATE
# → ETCD_INITIAL_CLUSTER_STATE=new     ← must say "new"

helm history bulk-konk-etcd -n aggregate | tail -1
# → 33  deployed  etcd-5.3.2  3.4.14  Upgrade complete
```

### Step 2 — wipe the PVCs and pods

```bash
kubectl delete pvc data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 \
  -n aggregate --wait=false
kubectl delete pod bulk-konk-etcd-0 bulk-konk-etcd-1 bulk-konk-etcd-2 -n aggregate
```

`--wait=false` matters: the PVCs cannot delete while pods hold them
(`kubernetes.io/pvc-protection`), so mark them for deletion first, then release them
by deleting the pods.

`podManagementPolicy: Parallel` brings all three back simultaneously on fresh
volumes. Each hits the top branch of `setup.sh` —
`==> There is no data at all. Initializing a new member of the cluster...` — which
never touches the broken `member add` path.

> **Expected hiccup that did not occur:** the STS can recreate a pod while its PVC is
> still `Terminating`, leaving it `Pending` with
> `persistentvolumeclaim ... is being deleted`. It usually self-resolves; if one
> sticks, delete that pod once more. In this run all three came up clean.

### Step 3 — verify

Ready in ~80 seconds, zero restarts:

```bash
kubectl get pods -n aggregate | grep etcd
```

```
bulk-konk-etcd-0   1/1   Running   0   2m51s
bulk-konk-etcd-1   1/1   Running   0   3m2s
bulk-konk-etcd-2   1/1   Running   0   2m57s
```

Leader and sync state — **per pod via `localhost`**, never `--cluster` (see the
warning below):

```bash
C="--cacert=/opt/bitnami/etcd/certs/client/ca.crt \
   --cert=/opt/bitnami/etcd/certs/client/server.crt \
   --key=/opt/bitnami/etcd/certs/client/server.key"

kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  "ETCDCTL_API=3 etcdctl member list -w table --endpoints=https://localhost:2379 $C"

for i in 0 1 2; do
  kubectl exec -n aggregate bulk-konk-etcd-$i -c etcd -- sh -c \
    "ETCDCTL_API=3 etcdctl endpoint status -w json --endpoints=https://localhost:2379 $C" \
  | jq -r --arg p "etcd-$i" '.[0].Status |
      "\($p): member=\(.header.member_id) IS_LEADER=\(.header.member_id == .leader) term=\(.raftTerm) index=\(.raftIndex)"'
done
```

```
etcd-0: member=9245973311162752139   IS_LEADER=false  term=11  index=285
etcd-1: member=15982733113733458825  IS_LEADER=false  term=11  index=285
etcd-2: member=14347249957239136383  IS_LEADER=true   term=11  index=285
```

Exactly one leader, identical term and index across all three.

**Prove quorum with a real write** — a member list alone does not show that raft can
commit:

```bash
kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  "ETCDCTL_API=3 etcdctl put /rollback-check ok --endpoints=https://localhost:2379 $C"
for i in 1 2; do
  kubectl exec -n aggregate bulk-konk-etcd-$i -c etcd -- sh -c \
    "ETCDCTL_API=3 etcdctl get /rollback-check --endpoints=https://localhost:2379 $C"
done
kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  "ETCDCTL_API=3 etcdctl del /rollback-check --endpoints=https://localhost:2379 $C"
```

Written on `etcd-0`, read back linearizably from both peers → quorum confirmed.

> **`--cluster` will always fail on this chart — this is not a cluster fault.**
> `etcdctl endpoint status --cluster` resolves each member's per-pod client URL,
> which is absent from the server cert SANs (`bulk-konk-etcd-headless`,
> `bulk-konk-init-*`, `localhost` only):
> ```
> x509: certificate is valid for bulk-konk-etcd-headless, bulk-konk-init-..., localhost,
>       not bulk-konk-etcd-2.bulk-konk-etcd-headless.aggregate.svc.cluster.local
> ```
> Same defect that makes `is_disastrous_failure` permanently true (Issue 7). Always
> query each pod on `localhost` instead.

### Step 4 — remove the bootstrap override

Do this once 3/3 are healthy. If `new` is left in place, a pod that later loses its
PVC will bootstrap its **own** cluster instead of rejoining — a split-brain risk.

```bash
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type=json -p '[{"op":"remove","path":"/spec/etcd/initialClusterState"}]'
```

Triggers one rolling restart, safe now that membership (3) matches replicas (3).
Harmless to the running cluster: etcd only reads `initial-cluster-state` at bootstrap
and ignores it once a data dir exists.

**No DC change is required.** `us-stg-1` at j170 with `replicaCount: 3` and no
`claimName` / `initialClusterState` overrides is exactly the prod shape; the chart
default correctly resolves to `existing` on upgrades.

---

## Option A (alternative) — snapshot-restore a 3-member cluster

> **Not used on us-stg-1** — the data was expendable, so
> [wipe-and-bootstrap](#solution-that-worked--wipe-and-bootstrap) was chosen instead.
> Use this when the etcd contents must survive.

Rather than *grow* the cluster, build a new one whose starting data is a snapshot.
No pod ever has to *join*, so the broken join logic is never exercised.

### Why it works

`etcdctl snapshot restore` is a purely **offline, local file** operation — it never
contacts a running etcd. It writes a fresh data dir containing (a) the snapshot's
key/value data and (b) a newly-written raft/membership state describing whatever
cluster you declare on the command line.

Run it three times with the **same** `--initial-cluster` and
`--initial-cluster-token`, differing only in `--name` and
`--initial-advertise-peer-urls`. Result: three data dirs with identical data,
identical cluster ID, and a shared view that this is a 3-member cluster.

| | `member add` (grow) | restore (rebuild) |
|---|---|---|
| Membership goes | 1 → 2 voters **while only 1 is live** | 3 voters from first boot, all booting together |
| Quorum vs. live | 2 required, 1 live → **stalls** | 2 required, met once any 2 are up |
| If a new member never starts | Cannot `member remove` (needs quorum) → `--force-new-cluster` | Nothing was serving; retry the restore |

`initialClusterState: existing` validates cleanly because all three peers report
the same 3 members, matching the 3-entry `ETCD_INITIAL_CLUSTER`. Contrast with the
Issue 6 failure (3 configured vs 1 reported). `podManagementPolicy: Parallel` means
all three start together; an early starter fails validation, crashes, and retries
until they overlap — self-correcting.

> Conventionally a restored cluster is started with `--initial-cluster-state=new`.
> `existing` is expected to work here because membership is pre-baked in all three
> dirs. **Fallback if they churn without forming:** set
> `initialClusterState: "new"` in DC — which is what PR #134685 used.

This is not zero-downtime: etcd is stopped and rebuilt (~10–15 min, during which the
KonK-hosted kube-apiserver has no etcd). What it avoids is any *unrecoverable* state.

### Phase 1 — snapshot, then freeze

Take the snapshot **before** stopping `etcd-0`:

```bash
flux suspend helmrelease konk-operator -n vela-system
flux suspend helmrelease bulk -n vela-system
kubectl scale deploy konk-operator -n konk --replicas=0

kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c '
  ETCDCTL_API=3 etcdctl snapshot save /tmp/snap.db \
    --endpoints=https://localhost:2379 \
    --cacert=/opt/bitnami/etcd/certs/client/ca.crt \
    --cert=/opt/bitnami/etcd/certs/client/server.crt \
    --key=/opt/bitnami/etcd/certs/client/server.key'

kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  'ETCDCTL_API=3 etcdctl snapshot status /tmp/snap.db -w table'

kubectl cp -c etcd aggregate/bulk-konk-etcd-0:/tmp/snap.db ./snap-$(date +%Y%m%d-%H%M).db

kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=0
```

> `--endpoints=https://localhost:2379` — `localhost` **is** in the cert SANs; the
> per-pod FQDN is not. Always use localhost from inside the pod.

### Phase 2 — restore into all three PVCs

One helper pod per PVC (RWO, so one at a time), same image and
`runAsUser`/`fsGroup: 1001` as the etcd pods, mounting `data-bulk-konk-etcd-$i` at
`/bitnami/etcd`, command `sleep 3600`. Then per member:

```bash
i=0   # repeat for 1 and 2
PEERS="bulk-konk-etcd-0=http://bulk-konk-etcd-0.bulk-konk-etcd-headless.aggregate.svc.cluster.local:2380,\
bulk-konk-etcd-1=http://bulk-konk-etcd-1.bulk-konk-etcd-headless.aggregate.svc.cluster.local:2380,\
bulk-konk-etcd-2=http://bulk-konk-etcd-2.bulk-konk-etcd-headless.aggregate.svc.cluster.local:2380"

kubectl cp ./snap-*.db aggregate/etcd-restore-$i:/tmp/snap.db

kubectl exec -n aggregate etcd-restore-$i -- sh -c "
  rm -rf /bitnami/etcd/data
  ETCDCTL_API=3 etcdctl snapshot restore /tmp/snap.db \
    --name bulk-konk-etcd-$i \
    --initial-cluster $PEERS \
    --initial-cluster-token etcd-cluster-k8s \
    --initial-advertise-peer-urls http://bulk-konk-etcd-$i.bulk-konk-etcd-headless.aggregate.svc.cluster.local:2380 \
    --data-dir /bitnami/etcd/data
  chmod -R 700 /bitnami/etcd/data"
```

**Must match the live env exactly** or the members will not form a cluster:

| Flag | Value | Source |
|------|-------|--------|
| `--initial-cluster-token` | `etcd-cluster-k8s` | `ETCD_INITIAL_CLUSTER_TOKEN` |
| peer URL scheme | `http` (not https) | `ETCD_INITIAL_ADVERTISE_PEER_URLS` |
| `--data-dir` | `/bitnami/etcd/data` | `ETCD_DATA_DIR` |

Read them back from a pod to confirm:

```bash
kubectl get statefulset bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E "ETCD_INITIAL|ETCD_DATA_DIR"
```

### Phase 3 — unfreeze

```bash
kubectl delete pod etcd-restore-0 etcd-restore-1 etcd-restore-2 -n aggregate
kubectl scale deploy konk-operator -n konk --replicas=1
flux resume helmrelease konk-operator -n vela-system
flux resume helmrelease bulk -n vela-system
```

The operator restores `replicas: 3` and pods start on the restored dirs. No DC
change needed.

### Phase 4 — verify

```bash
kubectl get pods -n aggregate | grep etcd

C="--cacert=/opt/bitnami/etcd/certs/client/ca.crt \
   --cert=/opt/bitnami/etcd/certs/client/server.crt \
   --key=/opt/bitnami/etcd/certs/client/server.key"

kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  "ETCDCTL_API=3 etcdctl member list -w table --endpoints=https://localhost:2379 $C"
kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c \
  "ETCDCTL_API=3 etcdctl endpoint status -w table --endpoints=https://localhost:2379 $C"
```

Expect 3 members `started`, one leader, revision ≥ the snapshot's.

### What changes

- **Preserved:** all keys and revision history from the snapshot.
- **Changes:** new cluster ID and new member IDs. Nothing external depends on them.
- **Side effect:** the chart's `member_id` bookkeeping files won't exist
  (`store_member_id` only runs on the "no data at all" branch). Benign — a future
  single-pod replacement takes the `member add` path rather than `member update`.

---

## Final verified state (us-stg-1, 2026-08-05)

**Rollback complete.**

```
konk-operator:  infoblox/konk:v0.2.1-138-g8b64bf7-j170     ✓ prod version
etcd STS:       docker.io/bitnami/etcd:3.4.14-debian-10-r0 ✓ prod image
etcd version:   3.4.14                                     ✓
claimName:      data                                       ✓ rolled back
replicas:       3/3 Ready, 0 restarts                      ✓ prod-matching
Etcd CR:        Initialized, Deployed=UpgradeSuccessful; no Irreconcilable

bulk-konk-etcd-0   1/1  Running   member 9245973311162752139
bulk-konk-etcd-1   1/1  Running   member 15982733113733458825
bulk-konk-etcd-2   1/1  Running   member 14347249957239136383   ← LEADER

all members: term 11, raft index 285, one leader, quorum write verified
bulk-konk apiserver: 1/1 Running, no further restarts
```

The pre-rollback cluster (ID `e9e217a51a7c2cee`, single member
`132d3f2b2031a7d7`) is gone; this is a new cluster with new member IDs. Nothing
external depended on them.

Snapshot of the discarded data retained: revision **5432**, **219 keys**, hash
`20901b1e`, 1.6 MB.

### PVC inventory

```
data-bulk-konk-etcd-0      re-provisioned 11:27  pvc-631f9678  ← LIVE
data-bulk-konk-etcd-1      re-provisioned 11:27  pvc-a84c050c  ← LIVE
data-bulk-konk-etcd-2      re-provisioned 11:27  pvc-7296fed1  ← LIVE
data-v2-bulk-konk-etcd-0   40d   ← Jun 26 – Aug 5 data, ORPHANED
data-v2-bulk-konk-etcd-1   40d   ← ORPHANED
data-v2-bulk-konk-etcd-2   40d   ← ORPHANED
```

The three original `data-*` volumes (pre-Jun-25) were deleted. The three `data-v2-*`
volumes are now referenced by nothing — 24Gi reclaimable whenever wanted.

---

## Open items

1. **Remove the bootstrap override** — the Etcd CR still carries
   `initialClusterState: "new"`. See
   [Step 4](#step-4--remove-the-bootstrap-override). Leaving it set is a split-brain
   risk if a pod later loses its PVC.
2. **Delete the orphaned `data-v2-*` PVCs** — 3 × 8Gi, referenced by nothing.
3. **File the two chart bugs** from Issue 7 (2380 health probe, cert SANs). These
   also mean prod's 3-member cluster has no working self-heal for a replaced member.
4. **Forward branch not merged** — `konk-operator-us-stg-1-v0.2.1-158-gf8540d7-j25`
   has local commit `071a0ab76e5` (j25 + `data-v2` + `initialClusterState: existing`
   + `recreateStatefulSet: false`), unpushed. Note rolling *forward* to j25 clears
   Issue 2 on its own, since j25 contains `1de007e`.

**No DC change is needed.** `envs/com-stage/us-stg-1/bulk-values.yaml` at j170 with
`replicaCount: 3` and no `claimName` / `initialClusterState` overrides is already the
correct prod-matching shape.

Resolved and closed: Issue 6 (1-member vs 3) and the ~6 weeks of Jun 26 – Aug 5 data
— discarded deliberately, as the cluster held no application data.

---

## Doc corrections to etcd-migration-debugging.md

That runbook was written against **us-dev-5**. Several parts do not transfer to the
us-stg-1 rollback.

| Item there | Correction |
|------------|------------|
| Issue 7 table: "Bitnami (j170 prod)" → "CGR (new)" `cgr.dev/infoblox.com/etcd:3.7.1` | Correct for us-dev-5. us-stg-1's hop was `gcr.io/etcd-development/etcd:v3.6.8` → `bitnami/etcd:3.4.14`; it was on j20 (`1de007e`), which predates `e13f6ed`/`9deaa9d`. |
| Step-5 verification checks only `Deployed` and `ReleaseFailed` | Blind spot. Both looked healthy while reconciliation was dead. Add `Irreconcilable`, or print all conditions. See [Issue 1](#issue-1--rollback-merged-flux-green-etcd-untouched). |
| "Validated Working Upgrade Values" mandate `recreateStatefulSet.enabled: true` | Meaningless on j170 — it predates the recreate hook (`fd9ed6b` #634, `372db4e` #636) entirely. Any STS recreate on j170 must be manual. |
| Issue 1 cause: "`recreateStatefulSet: false` prevents deletion" + "helm upgrade failing on immutable fields" | Same symptom, different root cause here. Reconciliation aborted on helm **ownership metadata** before any diff was computed. See [Issue 2](#issue-2--helm-ownership-metadata-blocks-all-reconciliation). |
| Issue 4 cause: new pods got a spec whose image "has no `/scripts/setup.sh`" | The script is mounted fine. ENOENT is on the **interpreter** (`#!/bin/bash`, absent from the minimal upstream image). And the fix was removing a stale `spec.image` from the Etcd CR, not deleting the STS. See [Issue 4](#issue-4--hybrid-statefulset-right-chart-wrong-image). |
| Issue 6: "konk chart default has always been `etcd.statefulset.replicaCount: 3` (since PR #135)" | **Confirmed** for j170 — `helm-charts/konk/values.yaml:83`. Note the etcd *subchart* default is `1`; the konk chart is what makes it 3. |
| `etcdctl member list` example uses `--cert=.../tls.crt --key=.../tls.key` | Wrong filenames for this cluster. The Etcd CR sets `certFilename: server.crt` / `certKeyFilename: server.key`. Use `server.crt` / `server.key`, and address `https://localhost:2379` — `localhost` is in the cert SANs, the per-pod FQDN is not (see [Issue 7](#issue-7--the-chart-cannot-grow-a-cluster-member-add-is-dead-code)). |

Correct command:

```bash
kubectl exec -n aggregate bulk-konk-etcd-0 -c etcd -- sh -c '
  ETCDCTL_API=3 etcdctl member list -w table \
    --endpoints=https://localhost:2379 \
    --cacert=/opt/bitnami/etcd/certs/client/ca.crt \
    --cert=/opt/bitnami/etcd/certs/client/server.crt \
    --key=/opt/bitnami/etcd/certs/client/server.key'
```

---

## Lessons

1. **Rolling back an operator does not roll back the data plane.** Verify the
   StatefulSet image, `volumeClaimTemplates`, and the helm release `UPDATED`
   timestamp — never just Flux `READY=True`.
2. **Check every CR condition.** `Deployed=UpgradeSuccessful` was 13 months stale
   and `ReleaseFailed` was absent while reconciliation was dead. The real signal was
   `Irreconcilable`, which the old runbook never checked.
3. **Rolling back past a compatibility fix re-introduces the incompatibility** —
   and the old code has no way to resolve it (Issue 2, `1de007e`).
4. **A rollback only reverts fields something still owns.** DC-driven values
   (`claimName`) cleared; operator-written values (`spec.image`) did not.
5. **Compare against a healthy cluster on the same version.** `eu-stg-1` isolated
   Issue 4 to a single field in one command.
6. **Read the deployed script, not the chart source.** The templated
   `if [[ 3 -eq 1 ]]` and the 2380 health probe are only visible in the rendered
   ConfigMap.
7. **`exec <script>: no such file or directory` usually means the interpreter is
   missing**, not the script.
8. **Revert PRs need review for completeness.** #141184 reverted three of four
   values; the one it missed (`replicaCount`) caused Issues 6 and 7.
9. **Rebuild beats repair when the data is expendable.** Four commands and ~4 minutes
   versus a snapshot-restore with helper pods and a freeze window. Establish whether
   the data actually matters *before* designing the recovery — it collapses the
   problem.
10. **Patch the layer that owns the field.** `kubectl scale` on the StatefulSet was
    reverted in 60s; an Etcd CR patch held for 70+ minutes. Work down the ownership
    chain (CR → helm release → STS), never against it.
11. **`.Release.IsInstall` is false forever after the first install.** Chart defaults
    gated on it — like `initialClusterState` → `"new"` — silently stop applying, so a
    "fresh bootstrap" on an existing release renders `existing` and fails. Read the
    rendered env, not the chart's documented default.
12. **A member list does not prove quorum.** Three `started` members only shows
    membership. Write a key and read it back from the other members.
