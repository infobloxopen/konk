# etcd Migration Rollback — Procedure and Issues Hit

**Cluster:** us-stg-1 (`com-stage`)
**Direction:** `v0.2.1-158-gf8540d7-j26` → `v0.2.1-138-g8b64bf7-j170` (release line → prod baseline)
**PR:** [#148167](https://github.com/Infoblox-CTO/deployment-configurations/pull/148167)
**Executed:** 2026-09-01, 13:31–13:50 UTC (~19 minutes)
**Outcome:** succeeded, but only after **three** interventions that the PR did not anticipate

Companion documents: [etcd-3.4.14-to-3.7.1-migration-changes.md](etcd-3.4.14-to-3.7.1-migration-changes.md)
(what the upgrade changes), [phase-1-deployment-checklist.md](phase-1-deployment-checklist.md)
(the **forward** runbook), [us-dev-2-downgrade_to_prd1.md](us-dev-2-downgrade_to_prd1.md)
(the earlier us-dev-2 downgrade).

---

## The headline

**Rollback is not the forward migration in reverse.** The forward path self-heals:
the chart carries a pre-upgrade hook that deletes and recreates the StatefulSet
when `persistence.claimName` changes. The rollback target chart (`8b64bf7`) has
**neither** `persistence.claimName` **nor** the recreate hook — both landed after it
(konk #631 / #634 / #636). So on the way back, every structural change is manual.

A rollback needs three things the PR diff does not express:

1. A manual StatefulSet delete (the immutable `volumeClaimTemplate` wall)
2. A Kyverno opt-in label before any PVC can be deleted on com-stage
3. A decision about the **old PVCs' contents**, which determines whether etcd
   bootstraps clean or recovers a stale cluster it cannot form quorum in

---

## Starting state

Captured immediately before the rollout:

| | |
|---|---|
| konk-operator | `infoblox/konk:v0.2.1-158-gf8540d7-j26` |
| StatefulSet | `replicas=3 ready=3`, vct `data-v2`, `cgr.dev/infoblox.com/etcd:3.7.1`, created 2026-08-05T12:02:18Z |
| `ETCD_DATA_DIR` | `/var/lib/etcd` |
| `ETCD_INITIAL_CLUSTER_STATE` | `existing` (emitted — replicaCount 3 > 1) |
| PVCs | `data-*` ×3 **and** `data-v2-*` ×3, all Bound |
| Keys / KonkServices | 211 / 17 |
| Helm release | `bulk-konk-etcd` rev **4**, `deployed` |
| PDB / PodMonitor | none |

Both PVC sets were created on 2026-08-05 — `data-*` at **11:28**, `data-v2-*` at
**12:02–12:03**. That 34-minute gap turned out to matter a great deal (Issue 3).

---

## What the PR changed

```yaml
# envs/com-stage/us-stg-1/konk-operator-version.txt
-v0.2.1-158-gf8540d7-j26
+v0.2.1-138-g8b64bf7-j170

# envs/com-stage/us-stg-1/bulk-values.yaml
 konk:
+  # Run konk-etcd in non-HA (single pod) mode so that there are no quorum issues on startup
   custom:
     etcd:
-      persistence:
-        claimName: data-v2
       statefulset:
-        replicaCount: 3
-      etcd:
-        initialClusterState: "existing"
-      recreateStatefulSet:
-        enabled: false
+        replicaCount: 1
       resources:
         limits:
           memory: 4Gi
```

`konk-operator-values.yaml` was **not** touched. Unlike us-dev-2 — whose equivalent
downgrade ([#147782](https://github.com/Infoblox-CTO/deployment-configurations/pull/147782))
had to strip `image.repository` and a `relatedImages` block — us-stg-1 carries no
`relatedImages` or `image.repository` at cluster, lifecycle **or** global level, so
there was nothing to remove.

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 13:31 | Baseline captured |
| ~13:34 | Wave 1 lands — konk-operator flips to `j170` |
| 13:35:05 | `Release failed ... upgrade failed; rollback required` |
| 13:36:20 | Same. Helm rev 4 → 8 |
| 13:37:54 | Same. Rev → 12. StatefulSet still completely untouched |
| 13:41:01 | **Intervention 1** — `delete sts bulk-konk-etcd`. STS recreated: vct `data`, `bitnami/etcd:3.4.14`, `replicas=1` |
| 13:41:11 | etcd: `restarting member 80504bbd3e991c8b in cluster 8dde300e0f060d87 at commit index 310` ← **not a bootstrap** |
| 13:41:44 | Election term 36, pod `0/1` |
| 13:43:15 | Election term 96, still `0/1`, no restarts, no ERROR lines |
| ~13:46 | **Intervention 2** — PVC delete blocked by Kyverno; label applied |
| 13:47:23 | **Intervention 3** — `data-*` ×3 deleted, STS deleted. No etcd pods |
| 13:47:52 | Etcd CR: `ReleaseFailed` **cleared**, `Deployed=True` |
| 13:48:48 | Operator recreates STS; fresh PVC `pvc-96c22ae2` |
| 13:49:02 | etcd: `starting member 132d3f2b2031a7d7 in cluster e9e217a51a7c2cee`, `became leader at term 2` |
| 13:50:17 | Pod `1/1 Running` |
| 13:50:41 | Validated |

---

## Issue 1 — Helm upgrade loop on the immutable `volumeClaimTemplate`

**Symptom.** Operator reconciles every ~75s; each attempt fails and rolls back.
Helm revisions climb (4 → 8 → 12 in six minutes), each landing `deployed` because
the *rollback* succeeds. Nothing on the cluster changes; all three etcd pods stay
`1/1 Running` with zero restarts.

```
13:35:05 error helm.controller "Release failed" release=bulk-konk-etcd
         error="upgrade failed; rollback required"
```

The Etcd CR carries **both** conditions simultaneously:

```
Deployed=True      reason=UpgradeSuccessful      (from the successful rollback)
ReleaseFailed=True reason=UpgradeError           (from the failed upgrade)
```

**Cause.** Live STS has `volumeClaimTemplates[0].metadata.name: data-v2`. The
`8b64bf7` chart hardcodes `data` and exposes no `persistence.claimName`. That field
is immutable, so the API server rejects the patch. The `8b64bf7` chart also has no
recreate hook, so nothing repairs it — the loop is infinite.

**Fix.**

```bash
kubectl -n aggregate delete sts bulk-konk-etcd
```

Plain delete, **not** `--cascade=orphan`. The rollback also goes `replicas: 3 → 1`;
orphaning would leave `bulk-konk-etcd-1` and `-2` running unmanaged. (The
`--cascade=orphan` guidance in the forward checklist applies to the forward path,
where keeping pods alive across the STS swap is the point.)

Safe to delete — verified first:

```bash
kubectl -n aggregate get sts bulk-konk-etcd \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'
  # {"whenDeleted":"Retain","whenScaled":"Retain"}
kubectl -n aggregate get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences}{"\n"}{end}'
  # no ownerReferences on any PVC
```

**Diagnostic gap.** The underlying `Forbidden: updates to statefulset spec for
fields other than 'replicas'...` never surfaced. The CR condition and the operator
log both say only `upgrade failed; rollback required`, and no `Forbidden` event was
recorded in the namespace. `helm history bulk-konk-etcd -n aggregate` is the only
place the real reason is visible.

---

## Issue 2 — Kyverno blocks PVC deletion on com-stage

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
resource PersistentVolumeClaim/aggregate/data-bulk-konk-etcd-0 was blocked
due to the following policies

block-user-actions:
  This operation is not allowed. Request made by user: rsatal
  To perform this operation, set label k8s.infoblox.com/allow-user-action: enabled
```

Applies to PVCs on com-stage; the StatefulSet delete was **not** blocked. Not
present on box-dev, so this does not show up when rehearsing on us-dev-2.

**Fix.**

```bash
kubectl -n aggregate label pvc \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 \
  k8s.infoblox.com/allow-user-action=enabled
```

Label **only** the PVCs being removed. Leaving `data-v2-*` unlabelled keeps the
guard in place on the volumes still holding the migrated cluster — a useful
accident-prevention property, not an obstacle.

---

## Issue 3 — Stale 3-member data → permanent election loop (the real trap)

**Symptom.** After the STS was recreated on vct `data`, the pod came up and stayed
`0/1 Running` indefinitely. **Zero restarts. No `CrashLoopBackOff`. Nothing logged
at ERROR level.** `kubectl logs | grep -i error` returns nothing.

```
13:41:11 etcdserver: restarting member 80504bbd3e991c8b in cluster 8dde300e0f060d87 at commit index 310
13:41:11 etcdserver/membership: set the initial cluster version to 3.0
...
rafthttp: health check for peer ddce131637f4ab89 ... lookup bulk-konk-etcd-1 ... no such host
rafthttp: health check for peer c71babd234fa207f ... lookup bulk-konk-etcd-2 ... no such host
raft: 80504bbd3e991c8b is starting a new election at term 95
raft: 80504bbd3e991c8b became candidate at term 96
etcdserver: publish error: etcdserver: request timed out
```

**Cause.** The `data-*` PVCs were **not** empty and were **not** written by the
cgr.dev chart. They contained a bitnami-layout data directory at
`/bitnami/etcd/data` describing a **3-member** cluster (`8dde300e0f060d87`, members
`80504bbd3e991c8b` + `ddce131637f4ab89` + `c71babd234fa207f`). etcd 3.4.14 found it
and *recovered* rather than bootstrapping.

At `replicaCount: 1` only member 0 exists. Winning an election needs 2 of 3 votes
and it can only ever cast its own, so it campaigns forever — term climbed 36 → 96
in 90 seconds. Raft logs elections at `INFO` and unreachable peers at `WARN`, so
this is **silent**: a hung pod that looks idle rather than broken.

This is exactly the failure konk [#683](https://github.com/infobloxopen/konk/pull/683)
describes — *"scaled 3 → 1 on upgrade and left etcd-0 with stale 3-node cluster data
that failed health checks"* — and it is recorded in
[etcd-upgrade-issues.md](../issues/etcd%20issues/etcd-upgrade-issues.md) §6.

**Fix.** Give etcd an empty data directory.

```bash
kubectl -n aggregate label pvc data-bulk-konk-etcd-{0,1,2} \
  k8s.infoblox.com/allow-user-action=enabled
kubectl -n aggregate delete pvc data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 --wait=false
kubectl -n aggregate delete sts bulk-konk-etcd
```

**Order matters.** Delete the PVCs *first*, then the STS. Deleting the STS first
gives the operator a ~75s window to recreate it and re-bind the stale volume before
you can remove it. `data-bulk-konk-etcd-0` will sit in `Terminating` — the
`pvc-protection` finalizer holds it while the pod mounts it — and completes once the
STS delete removes the pod.

Delete **all three**, not just `-0`. They all carry the same 3-member cluster, so
`-1` and `-2` would reintroduce this exact failure on any later move back to
`replicaCount: 3`.

**Data-preserving alternative (not used):** `etcd --force-new-cluster` rewrites
membership down to a single member while keeping the keyspace. The `8b64bf7` chart
does not expose the flag, so it needs a hand-patched StatefulSet. Not worth it for
data being deliberately discarded — but it is the right tool if the recovered data
matters.

---

## Verification

**Success looks like `starting member`, not `restarting member`:**

```
13:49:02 etcdserver: starting member 132d3f2b2031a7d7 in cluster e9e217a51a7c2cee
13:49:02 raft: 132d3f2b2031a7d7 became leader at term 2
13:49:02 etcdserver: published {Name:bulk-konk-etcd-0 ...} to cluster e9e217a51a7c2cee
13:49:02 etcdserver/membership: set the initial cluster version to 3.4
```

Note `setting up the **initial** cluster version to 3.4` (fresh bootstrap) versus
the earlier `set the initial cluster version to 3.0` (recovery of the old dir).

| | Before | After |
|---|---|---|
| konk-operator | `v0.2.1-158-gf8540d7-j26` | `v0.2.1-138-g8b64bf7-j170` |
| etcd image | `cgr.dev/infoblox.com/etcd:3.7.1` | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` |
| StatefulSet | `replicas=3 ready=3`, vct `data-v2` | `replicas=1 ready=1`, vct `data` |
| `ETCD_DATA_DIR` | `/var/lib/etcd` | `/bitnami/etcd/data` |
| `ETCD_INITIAL_CLUSTER*` | emitted | **absent** (gated on `replicaCount > 1`) |
| Etcd CR | `Deployed=True` + `ReleaseFailed=True` | `Initialized=True Deployed=True` |
| Cluster ID | `8dde300e0f060d87` (stale) | `e9e217a51a7c2cee` (new) |
| PV | `pvc-631f9678` | `pvc-96c22ae2` |
| Keys / KonkServices | 211 / 17 | 211 / 16 |

> ⚠️ **The key count returning to 211 is not evidence of data preservation.** The
> volume was genuinely empty; the konk apiserver rewrote the same
> `/registry/apiregistration.k8s.io/...` entries within ~90 seconds. See
> [Part 5.4](etcd-3.4.14-to-3.7.1-migration-changes.md) of the migration doc. Judge
> repopulation by KonkService count and `/registry` readability instead.

Client cert paths differ between charts — `etcdctl` needs the right one:

| Chart | Path |
|---|---|
| `8b64bf7` (bitnami) | `/opt/bitnami/etcd/certs/client/` |
| release line (cgr.dev) | `/etc/etcd/certs/client/` |

`post-upgrade.sh` will **not** validate a rolled-back cluster. Its defaults expect
the forward end state (`TARGET_VCT=data-v2`, cgr.dev image, `j25`–`j35`, cgr cert
paths) and will report failures that are in fact correct outcomes.

**Open item:** KonkServices read 16 after the rollback versus 17 before. Recheck and
identify the missing one if it persists.

---

## Should we have deleted the StatefulSet and PVCs together up front?

Asked after the fact: would going straight to "delete STS + PVCs" at 13:41 have been
better than deleting the STS, hitting the election loop, and then deleting the PVCs?

**Cost of what we did:** roughly 7 minutes of a hung (`0/1`) etcd and one extra STS
delete, on a stage cluster, during a window where the data was being discarded
anyway. Small.

**The stepwise approach was still the right default,** for a reason that is not
about this outcome: deleting the StatefulSet is reversible, deleting a PVC is not.
When you do not know what is on a volume, doing the reversible thing first and
observing is correct. Had those PVCs held genuine pre-migration production data,
deleting them up front would have destroyed the only copy — and on a prod cluster
that is the difference between a rehearsal and an incident. The sequence converted
an unknown into an observed fact at a cost of a few minutes.

**But the real error was earlier, and it was an avoidable one.** The prediction that
those volumes would present as empty rested on inferring *which chart wrote them*
from *when the PVC object was created*. Those are different facts. A PVC created at
11:28 on 2026-08-05 tells you nothing about the layout of the bytes inside it. The
information was cheaply obtainable and simply was not gathered.

**The improvement is not "delete more up front" — it is "look inside the volume
first."** Neither blanket deletion nor delete-and-hope; a 30-second read-only check
that makes the decision obvious:

```bash
kubectl -n aggregate run pvc-inspect --rm -it --restart=Never \
  --image=busybox --overrides='{
    "spec":{"containers":[{"name":"x","image":"busybox","command":["ls","-la","/mnt","/mnt/data"],
    "volumeMounts":[{"name":"v","mountPath":"/mnt"}]}],
    "volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"data-bulk-konk-etcd-0"}}]}}'
```

Interpretation:

| Volume layout | Written by | `8b64bf7` chart (reads `<root>/data`) sees | Action |
|---|---|---|---|
| `<root>/member/` | cgr.dev chart | nothing → clean bootstrap | reuse is safe |
| `<root>/data/member/` | bitnami chart | **recovers that cluster** | delete the PVC first, unless the membership matches the target `replicaCount` |
| empty / `lost+found` only | fresh | nothing → clean bootstrap | reuse is safe |

Run it against `data-bulk-konk-etcd-0` **before** the first StatefulSet delete and
the whole of Issue 3 collapses into a decision made in advance rather than a
symptom diagnosed from raft logs.

### The membership/replicaCount coupling matters more than it looks

The election loop was **not** caused by recovery as such. It was caused by
recovering *3-member* data into a *1-replica* StatefulSet. The same recovery into
`replicaCount: 3` would have formed quorum and come up healthy — preserving the
data.

That has a direct consequence for prod. `prd-1`, `us-com-1` and `eu-com-1` set no
konk override at any level and inherit the chart default
`etcd.statefulset.replicaCount: 3`. A rollback there would recover 3-member data
into a 3-replica StatefulSet — which should work, and should be **data-preserving**,
unlike what happened here. The destructive outcome on us-stg-1 came from the
`replicaCount: 1` in the PR, not from the rollback direction itself.

Whether `replicaCount: 1` is even correct for us-stg-1 is a separate open question:
it matches us-stg-1's own history and eu-stg-1, but **not** us-com-1, which runs 3.
The PR title claims parity with "the us-com-1 prod baseline"; on replica count that
is inaccurate.

---

## Checklist for the next rollback

1. **Inspect the old PVC's layout** (above). Decide reuse-vs-delete *before* touching anything.
2. Record `etcdctl endpoint status` + key count. Note that key count is an audit record, not a recovery path — a 3.7 snapshot cannot be restored into 3.4.
3. Confirm `persistentVolumeClaimRetentionPolicy` is `Retain` and PVCs carry no `ownerReferences`.
4. Merge the DC PR. Expect the Helm upgrade loop (Issue 1) — it is harmless; workload keeps serving.
5. Confirm the loop via climbing Helm revisions + `ReleaseFailed=True` on the Etcd CR.
6. If deleting PVCs: label for Kyverno **first**, delete PVCs, **then** delete the STS.
7. If not deleting PVCs: confirm the recovered membership matches the target `replicaCount`, or you will hit Issue 3.
8. Verify `starting member` + a **new** cluster ID + `became leader`. `restarting member` means the volume was not replaced.
9. Do not use `post-upgrade.sh` — its defaults assert the forward end state.
