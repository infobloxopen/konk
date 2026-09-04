# etcd Migration Rollback — Procedure and Issues Hit

Two rollbacks of the 3.4.14 → 3.7.1 migration have been executed, both on `com-stage`.
They failed in **different** ways, and the second one's outcome was the opposite of
the first's — so read the one that matches your situation rather than generalising
from either.

| | [Rollback 1 — us-stg-1](#rollback-1--us-stg-1-2026-09-01) | [Rollback 2 — eu-stg-1](#rollback-2--eu-stg-1-2026-09-04) |
|---|---|---|
| Direction | `j26` → `j170` | `j33` → `j170` |
| PR | [#148167](https://github.com/Infoblox-CTO/deployment-configurations/pull/148167) | [#150632](https://github.com/Infoblox-CTO/deployment-configurations/pull/150632) (revert of [#149507](https://github.com/Infoblox-CTO/deployment-configurations/pull/149507)) |
| Executed | 2026-09-01, 13:31–13:50 UTC | 2026-09-04, 12:17–12:35 UTC |
| Replicas | 3 → **1** (a scale-down) | 3 → **1** (back to its own baseline) |
| Old PVC contents | 3-member bitnami data | **1-member** bitnami data |
| Data outcome | **discarded** (deliberately) | **preserved** |
| Success signal | `starting member` | **`restarting member`** |
| Blocking issues | 3 (immutable vct, Kyverno PVC, stale membership) | 1, and a **new one** (Helm ownership orphan) |

**The single most important cross-cutting fact:** the interventions a rollback needs
depend on whether the recovered membership matches the target `replicaCount`. Get that
right and the rollback is data-preserving and nearly hands-off; get it wrong and you
are deleting volumes.

Companion documents: [etcd-3.4.14-to-3.7.1-migration-changes.md](etcd-3.4.14-to-3.7.1-migration-changes.md)
(what the upgrade changes), [phase-1-deployment-checklist.md](phase-1-deployment-checklist.md)
(the **forward** runbook), [us-dev-2-downgrade_to_prd1.md](us-dev-2-downgrade_to_prd1.md)
(the earlier us-dev-2 downgrade).

Automation: [`scripts/etcd-upgrade/rollback-recreate-sts.sh`](../../scripts/etcd-upgrade/rollback-recreate-sts.sh)
— written for Rollback 2:

| Mode | What it does | Mutates? |
|---|---|---|
| `inspect` | mounts each old PVC read-only as uid 1001 and prints the layout | no |
| `baseline` | captures operator / Etcd CR / STS / PVC / Helm state | no |
| `preflight` | renders the target chart against the live Etcd CR and audits Helm ownership on every object (Issue 4) | no |
| `watch` | runs `preflight`, refuses to arm if it fails, then gates and performs the one StatefulSet delete; after the delete, watches the operator log and **fails loudly on a hard block** rather than waiting out the clock | one `delete sts` |
| `verify` | asserts the end state and reports the etcd startup mode | no |

---

# Rollback 1 — us-stg-1 (2026-09-01)

**Cluster:** us-stg-1 (`com-stage`)
**Direction:** `v0.2.1-158-gf8540d7-j26` → `v0.2.1-138-g8b64bf7-j170` (release line → prod baseline)
**PR:** [#148167](https://github.com/Infoblox-CTO/deployment-configurations/pull/148167)
**Executed:** 2026-09-01, 13:31–13:50 UTC (~19 minutes)
**Outcome:** succeeded, but only after **three** interventions that the PR did not anticipate

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

---

# Rollback 2 — eu-stg-1 (2026-09-04)

**Cluster:** eu-stg-1 (`com-stage`)
**Direction:** `v0.2.1-162-gbeea16d-j33` → `v0.2.1-138-g8b64bf7-j170`
**PR:** [#150632](https://github.com/Infoblox-CTO/deployment-configurations/pull/150632) — a straight
revert of [#149507](https://github.com/Infoblox-CTO/deployment-configurations/pull/149507) (merged 2026-09-02 13:22 UTC)
**Executed:** 2026-09-04, 12:17–12:35 UTC (~18 minutes, **8.5 of them a hard etcd outage**)
**Outcome:** succeeded and was **data-preserving**. None of Issues 1–3 required intervention.
A **new** issue (Issue 4) did, and mishandling its timing caused the outage.

## The headline

**All three of us-stg-1's issues were designed out in advance, and a fourth appeared.**

Issues 2 and 3 did not arise at all, because this rollback returned eu-stg-1 to *its own*
pre-migration state rather than scaling it down: the recovered membership (1) matched
the target `replicaCount` (1), so no PVC needed deleting, so no Kyverno label was needed.
Issue 1 (the immutable `volumeClaimTemplate`) was still structurally unavoidable but was
automated away.

What actually blocked the rollback was a **Helm ownership orphan** — a ConfigMap left
behind by the forward migration. It fails *earlier* in the Helm lifecycle than Issue 1
and therefore presents with a completely different diagnostic signature.

---

## Starting state

| | |
|---|---|
| konk-operator | `infoblox/konk:v0.2.1-162-gbeea16d-j33` |
| StatefulSet | `replicas=3 ready=3`, vct `data-v2`, `cgr.dev/infoblox.com/etcd:3.7.1` |
| `ETCD_DATA_DIR` | `/var/lib/etcd` (PVC mounted **at** the data dir) |
| `ETCD_INITIAL_CLUSTER_STATE` | `new` (emitted — replicaCount 3 > 1) |
| etcd | 3 members, all `started`, raft term 2, index 67658, db **586 kB** |
| PVCs | `data-*` ×3 **and** `data-v2-*` ×3, all Bound |
| Keys / KonkServices | 213 / 16 |
| Helm release | `bulk-konk-etcd` rev **7**, `deployed`, chart `etcd-1.2.0` |
| Etcd CR | `Initialized=True Deployed=True` — clean, no `ReleaseFailed` |
| PDB / PodMonitor | present (`minAvailable: 2`) |

PVC ages are worth noting: `data-bulk-konk-etcd-0` dates to **2023-09-27** (gp2), `-1`/`-2`
to 2026-06-18 (gp3), and the `data-v2-*` set to 2026-09-02. The `-1`/`-2` volumes are
leftovers from an earlier 3-replica attempt and are **inert** at `replicaCount: 1`.

## What the PR changed

A revert, so: `konk-operator-version.txt` back to `j170`; `bulk-values.yaml` stripped of
`persistence.claimName`, `etcd.initialClusterState`, `recreateStatefulSet`, `metrics` and
`dashboards`, with `statefulset.replicaCount` 3 → 1; and
`envs/com-stage/eu-stg-1/konk-operator-values.yaml` **deleted** (it carried operator
`metrics`/`podMonitor` plus `podAnnotations: null`).

Nothing needed stripping by hand. Unlike us-dev-2, eu-stg-1 carries no `relatedImages`
or `image.repository` at any level, and the etcd image is not set in DC at all — see
[Why the image flips by itself](#why-the-image-flips-by-itself).

---

## Pre-flight: the work that made this rollback different

This is the part worth copying. Every one of these was done **before** the merge, and
each one removed an issue that had to be diagnosed live on us-stg-1.

**1. Inspect the old volume** — step 1 of the us-stg-1 checklist, actually followed:

```
data-bulk-konk-etcd-0
  data/                    Aug 30 08:50    <- bitnami layout
  data/member/snap/db      Sep  2 13:30    5,423,104 bytes
  data/member/wal          Sep  2 13:30
  member/                  Sep  2 13:31    123.5 MB   <- cgr layout, INERT
  lost+found, member_removal.log
  du: data=432.6M  member=123.5M
```

The target chart mounts the claim at `/bitnami/etcd` with `ETCD_DATA_DIR=/bitnami/etcd/data`,
so it reads `<root>/data/member` — present, and cleanly closed at 13:30, the moment of the
forward cutover. The `member/` directory at the root is the *release-line* layout
(`/var/lib/etcd` mounted at the data dir) written by a cgr bootstrap that briefly ran
against this volume during the forward migration. The rollback chart never looks there,
so it is harmless — but it is a footgun for any future forward migration that reuses
`data`.

> Run the inspector as **uid 1001**. The directories are `drwxrws--- 1001:1001`, so a
> `runAsUser: 65534` pod can list the root and nothing else — it looks empty when it is not.

**2. Confirm membership matches the target `replicaCount`.** DC git shows the parent of
the forward merge pinned exactly `v0.2.1-138-g8b64bf7-j170` with `replicaCount: 1`, so
the revert restores the *exact* prior state. eu-stg-1 was serving from this volume as a
single member up to 13:30 — therefore recovering it into `replicaCount: 1` forms quorum
immediately. **This is why Issue 3 could not occur here.**

**3. Diff every immutable StatefulSet field**, not just the vct name:

| Field | `beea16d` (live) | `8b64bf7` (target) | |
|---|---|---|---|
| `volumeClaimTemplates[0].metadata.name` | `data-v2` | `data` (hardcoded) | ✗ differs |
| `selector.matchLabels` | `{name: etcd, instance: bulk-konk-etcd}` | same | ✓ |
| `serviceName` | `bulk-konk-etcd-headless` | same | ✓ |
| `podManagementPolicy` | `Parallel` | `Parallel` (default) | ✓ |

Only the vct name differs, so **one plain delete is necessary and sufficient** — no other
field forces a recreate, and no field survives to break the new object.

**4. Establish that Kyverno does not block the StatefulSet delete.** Verified with
server-side dry-runs, which run the full admission chain and persist nothing:

```bash
kubectl -n aggregate delete statefulset bulk-konk-etcd --dry-run=server
# statefulset.apps "bulk-konk-etcd" deleted from aggregate namespace (server dry run)

kubectl -n aggregate delete pvc data-bulk-konk-etcd-1 --dry-run=server
# Error from server: admission webhook "validate.kyverno.svc-ignore" denied the request
```

`block-user-actions` matches `Namespace, CustomResourceDefinition, PersistentVolumeClaim,
PersistentVolume, StorageClass, DatabaseClaim, Ingress, cert-manager.io/*/*,
*.crossplane.io/*/*` — **`StatefulSet` is not in the list**, and no
`block-user-actions-fluxcd-objects` rule covers it either. The user (`rsatal`, groups
`teleport-group:k8s-admin`, `system:authenticated`) is *not* in the exemption list, so the
policy does apply — it simply does not cover StatefulSets. Issue 2's label is a **PVC-only**
requirement.

**5. Automate the delete, gated on the desired state.** See
[the wave-ordering trap](#the-wave-ordering-trap) for why the gating matters more than the
delete.

---

## The wave-ordering trap

`apps.yaml` declares `bulk` as **depending on** `konk-operator`:

```yaml
bulk:
  dependencies:
    - name: authz
    - name: konk-operator
```

So the operator image flips **first** and the bulk values land **second**. In that gap the
Etcd CR still reads `replicaCount: 3` / `claimName: data-v2`, and the operator is already
running the rollback chart.

**Delete the StatefulSet in that window and the operator recreates it as three bitnami
pods on `data-{0,1,2}`** — three volumes holding unrelated etcd state, each recovering its
own cluster ID. On us-stg-1 this was pure luck: the values happened to have landed by
13:41, so the recreate came up at `replicas=1`.

The fix is to gate the delete on the *end state*, not on the first failure:

```
operator pods ALL on the target tag
  AND Etcd CR .spec.statefulset.replicaCount == target
  AND Etcd CR .spec.persistence.claimName unset
  AND live vct != target
→ then, and only then, delete
```

Check operator **pods**, not the Deployment spec: a Deployment mid-rollout still has an old
ReplicaSet pod actively reconciling, and that pod will recreate the StatefulSet from the
old chart seconds after the delete.

---

## Issue 4 — Helm ownership orphan blocks the release before it reaches the StatefulSet

**Symptom.** The operator loops every ~35s, but the signature is *not* Issue 1's:

| | Issue 1 (immutable vct) | Issue 4 (ownership orphan) |
|---|---|---|
| Helm revisions | **climb** (4 → 8 → 12) | **frozen** at 7 |
| Etcd CR condition | `ReleaseFailed=True` | `Irreconcilable=True reason=ReconcileError` |
| Where it fails | applying the StatefulSet | computing the candidate release |

```
2026-09-04T12:21:31Z error Failed to sync release
  failed to get candidate release: Unable to continue with update:
  ConfigMap "bulk-konk-etcd-scripts" in namespace "aggregate" exists and cannot be
  imported into the current release: invalid ownership metadata;
  annotation validation error: missing key "meta.helm.sh/release-name":
    must be set to "bulk-konk-etcd";
  annotation validation error: missing key "meta.helm.sh/release-namespace":
    must be set to "aggregate"
```

**Cause.** The rollback chart has a `scripts-configmap.yaml` template
(`setup.sh`, `prestop-hook.sh`, `probes.sh`); the release-line chart does not. The object
was left on the cluster:

```
ConfigMap bulk-konk-etcd-scripts   created 2026-09-02T13:30:40Z
  labels:      app.kubernetes.io/managed-by=Helm   helm.sh/chart=etcd-5.3.2
  annotations: <none>
```

Created **34 seconds before** the forward migration's new StatefulSet, by the outgoing
bitnami chart's last reconcile. Because it never made it into a tracked release manifest,
the release-line chart never pruned it. Now the rollback chart wants to create it, finds
it already there, and Helm refuses to adopt an object lacking ownership metadata. Note the
`helm.sh/chart=etcd-5.3.2` label — that is the bitnami chart version, and it matches what
`helm template` renders for the target, confirming the provenance.

**Fix.** Adopt it. The `app.kubernetes.io/managed-by=Helm` label is already correct, so
only the two annotations are missing:

```bash
kubectl -n aggregate annotate configmap bulk-konk-etcd-scripts \
  meta.helm.sh/release-name=bulk-konk-etcd \
  meta.helm.sh/release-namespace=aggregate
```

Adopt rather than `delete cm`: it is reversible (drop the annotations to undo), nothing
mounts it while the release-line StatefulSet is live, and Helm overwrites the content on
adoption anyway. Not blocked by Kyverno — the only ConfigMap rule is scoped to
`names: [cluster-config-map]` in `namespaces: [vela-system]`.

**⚠️ Order matters, and getting it wrong is what caused the outage.** This must be fixed
**before** the StatefulSet is deleted. In this run it was not: the gates opened at 12:25:12,
the automation deleted the StatefulSet at 12:25:15 as designed, and Helm — still blocked —
could not recreate it. etcd was down from 12:25:15 until 12:33:41, **8.5 minutes**.
**Treat Issue 4 as a blocking prerequisite, not a parallel task.**

It was closer than that sounds. The delete handed off to a 600s wait-for-recreate, i.e. a
12:35:15 deadline; the ConfigMap was annotated at ~12:32 and Helm created the StatefulSet
at 12:33:25 — **~110 seconds of margin**. Had the fix landed three minutes later the
automation would have given up with `StatefulSet not recreated with vct=data within 600s`
and etcd would have stayed down until someone noticed.

The root cause of the near-miss is that *"no StatefulSet yet"* has two causes that look
identical from outside: reconcile latency (waiting is correct) and a hard-blocked release
(waiting is useless). **While etcd is down, watch the operator log, not the clock.**
`rollback-recreate-sts.sh` now does this: after the delete it polls the operator log for a
sync error on this release and, once one appears, prints the full message, classifies it
(ownership orphan / immutable field / unknown), re-runs the ownership audit to name the
offending object, and exits non-zero — within about one reconcile interval instead of ten
minutes. Tunable via `RECREATE_TIMEOUT` and `BLOCK_GRACE`.

Note the operator's error must be parsed out of its JSON `.error` field, not grepped: the
message embeds escaped quotes (`ConfigMap \"bulk-konk-etcd-scripts\"`) that a
`sed 's/.*"error":"\([^"]*\)".*/\1/'` pattern truncates at the first one.

**Not universal.** us-stg-1 did not have this orphan. It is history-dependent, so it must
be *checked for*, not assumed.

### Pre-check: render the target chart and audit ownership

Thirty seconds, before the merge. Render the chart the operator is about to run, against
the live Etcd CR's own values — the CR spec *is* the values file the operator uses — and
audit every object it wants.

**Automated:**

```bash
./rollback-recreate-sts.sh preflight        # exit 0 = clean, 1 = blockers, 2 = setup error
```

It extracts the chart at `TARGET_REF` (default `8b64bf7`) from `KONK_REPO`, renders it
against the live CR, and for each rendered object reports `ownership OK` / `absent ->
Helm CREATEs it` / `BLOCKER` with the exact `label`/`annotate` commands to fix it.
`watch` runs this first and **refuses to arm** if it fails (override with
`SKIP_PREFLIGHT=true`). Override the chart source with `CHART_DIR=` or `TARGET_REF=`.

**By hand:**

```bash
git archive 8b64bf7 helm-charts/etcd | tar -x -C /tmp/t
kubectl -n aggregate get etcds.konk.infoblox.com bulk-konk-etcd -o yaml \
  | awk '/^spec:/{f=1;next} /^status:/{f=0} f' | sed 's/^  //' > /tmp/vals.yaml
helm template bulk-konk-etcd /tmp/t/helm-charts/etcd -n aggregate -f /tmp/vals.yaml \
  | grep -E '^(kind|  name):' | paste - -
```

Then for each object check `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`
and `app.kubernetes.io/managed-by=Helm`.

On eu-stg-1 the target renders exactly four objects:

| Object | State |
|---|---|
| `ConfigMap/bulk-konk-etcd-scripts` | **ORPHAN** — the blocker |
| `Service/bulk-konk-etcd` | ownership correct |
| `Service/bulk-konk-etcd-headless` | ownership correct |
| `StatefulSet/bulk-konk-etcd` | to be created — no adoption needed |

PVCs show as unannotated in any such scan and that is **normal** — StatefulSet PVCs are
created by the statefulset controller and are never part of a Helm manifest. Do not
"fix" them.

> **Do not use `fix-konk-annotations.sh` for this.** Its explicit lists cover
> `configmap/bulk-konk-scripts` (a different object) and, for the etcd release, only the
> two Services and the StatefulSet — `configmap/bulk-konk-etcd-scripts` is in neither.
> Worse, `--sweep` annotates everything matching `bulk-konk` with
> `release-name=bulk-konk`, which is the **wrong release** for this ConfigMap (Helm would
> then fail on a "must equal `bulk-konk-etcd`" mismatch) and would stamp all six
> `data-*`/`data-v2-*` PVCs as owned by `bulk-konk`, inviting a future upgrade to prune
> the pre-migration data.

---

## Why the image flips by itself

Worth recording because it looks like something you must do by hand, and is not.

Both charts ship **inside the operator image**, so the operator version controls both:

```
DC bulk app ──> Konk CR (spec.etcd)
                   │  konk-operator reconciles ──> konk chart ──> release bulk-konk
                   └──────────────────────────────> Etcd CR
                                                      │  konk-operator reconciles
                                                      └─> etcd chart ──> release bulk-konk-etcd
```

The konk chart's `values.yaml` sets `etcd.image` — `cgr.dev/infoblox.com/etcd:3.7.1` at
`beea16d`, and **commented out** at `8b64bf7`. So on rollback Helm removes `image` from the
Etcd CR spec entirely and the etcd chart's own default
(`docker.io/bitnami/etcd:3.4.14-debian-10-r0`) applies. Same mechanism retires the PDB
(`pdb.enabled: false` in the target) and the PodMonitor (no template).

> Latent landmine: `8b64bf7`'s `pdb.yaml` renders `policy/v1beta1`, removed in k8s 1.25.
> It is safe only because `pdb.enabled` defaults to `false`. Anyone enabling it on that
> chart gets an unrenderable release.

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 12:17:00 | Baseline captured; delete automation armed and correctly gating (all 3 gates closed) |
| 12:20:37 | **Wave 1** — all konk-operator pods on `j170`. **Gate 1 opens; gates 2 and 3 still closed — the wave-ordering gap** |
| 12:20:45 | `bulk-konk` release upgraded to rev 6 (`konk-0.1.0`) |
| 12:21:31 | First etcd sync failure — **Issue 4**, `invalid ownership metadata` |
| 12:21–12:30 | Loops every ~35s. Helm rev **frozen at 7**. `ReleaseFailed` never set; `Irreconcilable=True` |
| 12:25:12 | **Wave 2** — Etcd CR → `replicaCount: 1`, `claimName` unset, `image` unset. All 3 gates open |
| 12:25:15 | Automation preflights (3 checks pass) and deletes the StatefulSet. **etcd down** — Helm still blocked, cannot recreate |
| 12:30:15 | Last blocked reconcile |
| ~12:32 | **Intervention** — ConfigMap annotated |
| 12:33:25 | Helm rev **8**, chart `etcd-5.3.2`, `Upgrade complete`. StatefulSet created: vct `data`, `replicas=1` |
| 12:33:40 | `restarting member 132d3f2b2031a7d7 in cluster e9e217a51a7c2cee at commit index 15293903` |
| 12:33:41 | `became candidate at term 70` → `became leader at term 70` → `ready to serve client requests` |
| 12:34:39 | `rollout status` complete; automation prints verification |
| 12:35 | `1/1 Running`, 0 restarts. All APIServices `Available` |

---

## Verification — the criteria are **inverted** from us-stg-1

This rollback was meant to *recover* data, so:

```
restarting member <id> in cluster <id>    <- data preserved (WANTED)
starting member   <id> in cluster <id>    <- volume was empty, data GONE
```

That is the exact opposite of us-stg-1, where the volumes were deliberately discarded and
`starting member` was the success signal. **Reusing us-stg-1's criteria here would report a
correct outcome as a failure.**

What the log showed:

```
12:33:40 etcdserver/membership: set the cluster version to 3.4 from store
12:33:40 mvcc: restore compact to 14984019
12:33:40 etcdserver: restarting member 132d3f2b2031a7d7 in cluster e9e217a51a7c2cee at commit index 15293903
12:33:41 etcdserver: 132d3f2b2031a7d7 as single-node; fast-forwarding 9 ticks (election ticks 10)
raft     132d3f2b2031a7d7 became candidate at term 70
raft     132d3f2b2031a7d7 became leader at term 70
12:33:41 embed: ready to serve client requests
```

`as single-node` and a **single** election won on the first attempt are the positive proof
that recovered membership matches `replicaCount`. Contrast Issue 3, where the term climbed
36 → 96 in 90 seconds.

| | Before | After |
|---|---|---|
| konk-operator | `v0.2.1-162-gbeea16d-j33` | `v0.2.1-138-g8b64bf7-j170` |
| etcd image | `cgr.dev/infoblox.com/etcd:3.7.1` | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` |
| StatefulSet | `replicas=3 ready=3`, vct `data-v2` | `replicas=1 ready=1`, vct `data`, 0 restarts |
| `ETCD_DATA_DIR` | `/var/lib/etcd` | `/bitnami/etcd/data` |
| Helm release | rev 7, `etcd-1.2.0` | rev 8, `etcd-5.3.2`, `Upgrade complete` |
| etcd | 3 members, term 2, index 67658 | 1 member `started`, term 70, index 15293906 |
| **DB size** | **586 kB** | **5.4 MB** |
| Keys / KonkServices | 213 / 16 | 212 / 16 |
| Etcd CR | `Initialized`/`Deployed` | `Initialized`/`Deployed`, `Irreconcilable` cleared |
| PDB / PodMonitor | present | removed (chart defaults) |
| PVCs | 6 Bound | 6 Bound (all retained) |

**The DB size is the load-bearing evidence, not the key count.** 5.4 MB matches
`data/member/snap/db` (5,423,104 bytes) byte-for-byte from the pre-flight inspection.
Together with `restore compact to 14984019` and index 15293906 — against the 3.7.1
cluster's index 67658 — this is conclusive: the pre-migration keyspace, not a rebuild.
The ~46h of 3.7.1 writes are gone, but they were all `/registry/*` entries the konk
apiserver rewrites, and KonkServices live in the host cluster, so there is no
user-visible loss.

Client cert paths and **filenames** both differ between the charts:

| Chart | Path | Files |
|---|---|---|
| `8b64bf7` (bitnami) | `/opt/bitnami/etcd/certs/client/` | `ca.crt`, `server.crt`, `server.key` |
| release line (cgr) | `/etc/etcd/certs/client/` | `ca.crt`, `server.crt`, `server.key` |

The filenames come from the Etcd CR's `auth.client.certFilename: server.crt` — **not**
`tls.crt`. Also note the cgr image is distroless: `kubectl exec ... -- sh -c` fails with
`"sh": executable file not found`; invoke `etcdctl` directly. And `endpoint status --cluster`
fails TLS verification because the server cert's SANs are `bulk-konk-etcd-headless` and
`localhost` only — use `--endpoints=https://127.0.0.1:2379` without `--cluster`.

---

## Notes and open items

- **`data-bulk-konk-etcd-{1,2}` are inert but dangerous.** They hold stale state from an
  earlier 3-replica attempt. At `replicaCount: 1` they are never mounted, but scaling
  eu-stg-1 to 3 later would recover three unrelated clusters — Issue 3, exactly.
- **The stray `member/` directory on `data-bulk-konk-etcd-0`** (123.5 MB, cgr layout) is
  ignored by the rollback chart, but a future forward migration reusing claim `data` would
  find and recover it. Clean it up or use a fresh claim name.
- **`data-v2-*` ×3 are retained** and still hold the 3.7.1 keyspace. Keep them until the
  rollback is accepted; note a 3.7 snapshot cannot be restored into 3.4.
- **Do not run `post-upgrade.sh`** — its defaults assert the forward end state
  (`TARGET_VCT=data-v2`, cgr image, cgr cert paths).
- **The us-stg-1 "16 vs 17 KonkServices" open item is probably a counting artifact.**
  `kubectl get konkservices -A --no-headers 2>&1 | wc -l` picks up an extra line from
  stderr. eu-stg-1 read 16 consistently before and after. Re-check how that count was
  taken before hunting a missing service.

---

# Checklist for the next rollback

Ordered. Steps 1–6 are **before** the merge.

1. **Inspect the old PVC's layout** — as **uid 1001**, or the volume looks empty when it
   is not. `rollback-recreate-sts.sh inspect`. Decide reuse-vs-delete now, not later.
2. **Confirm the recovered membership matches the target `replicaCount`.** This single
   fact determines whether the rollback is data-preserving (eu-stg-1) or destructive
   (us-stg-1). Check DC git for the pre-migration `replicaCount`, and confirm the cluster
   was healthy at that count on that volume.
3. **Audit Helm ownership on every object the target chart renders** —
   `rollback-recreate-sts.sh preflight`. **Fix any orphan now** (Issue 4) — it is a
   blocking prerequisite, not a parallel task. Ignore PVCs. Do not use
   `fix-konk-annotations.sh --sweep`.
4. **Diff all immutable StatefulSet fields**, not just the vct name: `selector.matchLabels`,
   `serviceName`, `podManagementPolicy`, `volumeClaimTemplates[0].metadata.name`.
5. **Confirm `persistentVolumeClaimRetentionPolicy` is `Retain/Retain`** and PVCs carry no
   `ownerReferences`.
6. Record `etcdctl endpoint status` + **DB size** + key count. DB size is the evidence that
   survives; key count is only an audit record.
7. **Arm the gated delete first** (`rollback-recreate-sts.sh watch` — it re-runs step 3
   and refuses to arm if anything is unowned), **then** merge the DC PR.
8. **Expect the operator to loop.** Distinguish the two failure modes:
   climbing Helm revisions + `ReleaseFailed=True` is Issue 1 (harmless, workload serving);
   **frozen** Helm revision + `Irreconcilable=True` is Issue 4 (blocking — fix before the
   StatefulSet is deleted).
9. **Delete the StatefulSet only once the end state has settled** — operator pods all on
   the target tag *and* the Etcd CR at the target `replicaCount` with `claimName` unset.
   Deleting during the wave-ordering gap recreates it at the wrong replica count on the
   wrong volumes. Plain delete; **not** `--cascade=orphan` when scaling down.
10. **If deleting PVCs:** label for Kyverno **first**, delete PVCs, **then** the STS. The
    StatefulSet delete itself needs no label — verify with `--dry-run=server` rather than
    assuming either way.
11. **Verify against the right criteria for your case.** Recovering data → `restarting
    member`, same cluster ID, `as single-node` (or matching peer count), one election.
    Discarding data → `starting member`, a **new** cluster ID. Check DB size against the
    inspected `snap/db`.
12. **Confirm the blast radius cleared:** all APIServices `Available`, konk apiserver logs
    clean, KonkService count unchanged.
13. **Do not use `post-upgrade.sh`** — its defaults assert the forward end state.
