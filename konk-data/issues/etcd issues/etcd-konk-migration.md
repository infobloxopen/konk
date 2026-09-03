# Konk-Operator Image Comparison — etcd & konk Migration

**Date:** 2026-06-23
**Repo:** `github.com/infobloxopen/konk`
**Purpose:** Compare the konk-operator images involved in the etcd migration, so we know exactly what each one changes and which is safe to deploy where.

---

## TL;DR

| Image | Commit | Branch | etcd | konk | data-v2 (claimName) | Notes |
|-------|--------|--------|------|------|---------------------|-------|
| `v0.2.1-138-g8b64bf7-j170` | `8b64bf7` | main | **Bitnami** etcd (subchart v5.3.2) | old | ❌ | **Current prod baseline** — no etcd/konk upgrade |
| `v0.2.1-147-gaca7e33-j180` | `aca7e33` | main | **Upstream** `v3.6.8` | old | ❌ | etcd upgrade only |
| `v0.2.1-150-g97950c6-j15` | `97950c6` | release/upgrade-etcd | **Upstream** `v3.6.8` | old | ✅ **yes** | etcd upgrade **+ data-v2 param** |
| `v0.2.1-155-gd4614c2-j191` | `d4614c2` | main | **Upstream** `v3.6.9` | **new** | ❌ | konk upgrade **+** etcd upgrade |
| `v0.2.1-154-g1de007e-j20` | `1de007e` | release/upgrade-etcd | **Upstream** `v3.6.8` | old | ✅ **yes** | j15 lineage with STS recreate hook gating |
| `v0.2.1-155-g372db4e-j21` | `372db4e` | release/upgrade-etcd | **Upstream** `v3.6.8` | old | ✅ **yes** | j20 + one etcd hook fix (`#636`), no etcd version bump |
| `v0.2.1-164-gbd3f28a-j203` | `bd3f28a` | main | **Upstream** `v3.7.0` | new | ❌ | merge of `release/cve-remediations-july26` to main; etcd chart/image bumped |
| `v0.2.1-169-gbaac5f4` | `baac5f4` | release/cve-remediations-july26 | **Upstream** `v3.6.9` | **new** | ❌ | CVE remediations, Harbor promotion, post-upgrade hook, e2e test enhancements; no PVC migration support |

**Two independent change axes:**
- **etcd axis** — Bitnami subchart → upstream chart (j180), then patch bumps 3.6.8 → 3.6.9 (j191) → 3.7.0 (j203). Main is currently at **v3.7.0**.
- **konk axis** — konk-service Go fixes (HTTP/2 leak, kubeconfig file refs, apiservice truncation) landed only in j191.
- **migration axis** — the parameterized `persistence.claimName` (data-v2) feature landed **only** in j15/j20/j21 (`release/upgrade-etcd`).
- **hook-behavior axis** — j21 (`372db4e`) updates the etcd STS recreate hook behavior used in the j15/j20 migration lineage.
- **new-mainline axis** — j203 (`bd3f28a`) moves etcd to chart `1.1.0` / image `3.7.0` and does not carry the j15/j20 claimName + recreate-hook migration path.
- **CVE axis** — `release/cve-remediations-july26` (`baac5f4`) adds Harbor promotion, post-upgrade hook, and e2e test enhancements on top of upstream `v3.6.9`; no PVC migration support.

---

## Lineage

```
                          8b64bf7 (j170)  ── prod baseline: Bitnami etcd, old konk
                                │
                          (#572 replace Bitnami → upstream etcd v3.6.7)
                          (#583 bump v3.6.7 → v3.6.8)
                                │
                          aca7e33 (j180)  ── upstream etcd v3.6.8, old konk      ◄── merge-base
                               ╱ ╲
        (#631 claimName param)╱   ╲(release/konk-patch merged: #615/#619/#624/#625
                             ╱     ╲                          + etcd v3.6.8 → v3.6.9)
                            ╱       ╲
                  97950c6 (j15)    d4614c2 (j191)
              upstream etcd v3.6.8  upstream etcd v3.6.9
              + data-v2 claimName   + konk-service fixes
              (old konk)            (NO data-v2)
```

The merge-base of **j15** and **j191** is **j180 (`aca7e33`)**. They are siblings:
- **j15** = j180 + one commit (`#631`, data-v2 claimName param). No konk changes.
- **j191** = j180 + the `release/konk-patch` konk-service commits + etcd patch bump to 3.6.9. No data-v2 param.

---

## Detailed comparison

### `v0.2.1-138-g8b64bf7-j170` — prod baseline

| Aspect | Value |
|--------|-------|
| etcd chart | **Bitnami** etcd subchart, chart `version: 5.3.2`, `appVersion: 3.4.14` (deployed tag overridden to bitnamilegacy/etcd 3.5.x) |
| etcd image | `docker.io/bitnami/etcd` |
| PVC mount path | **`/bitnami/etcd`** |
| `ETCD_DATA_DIR` | **`/bitnami/etcd/data`** → data lives under `data/member/` on the PVC volume root |
| VCT name | fixed `data` (no parameter) |
| `initialClusterState` logic | present (Bitnami template), value-or-IsInstall-or-existing |
| konk | original konk-service / kube-apiserver |

This is what runs on prod today. No etcd or konk upgrade.

### `v0.2.1-147-gaca7e33-j180` — etcd upgrade only

| Aspect | Value | Δ vs j170 |
|--------|-------|-----------|
| etcd chart | **Upstream** custom chart, `version: 1.0.0`, `appVersion: 3.5.17` | ✅ chart replaced |
| etcd image | `gcr.io/etcd-development/etcd:v3.6.8` | ✅ Bitnami → upstream |
| PVC mount path | **`/var/lib/etcd`** | ✅ **changed** |
| `ETCD_DATA_DIR` | **`/var/lib/etcd`** → expects `member/` at PVC root | ✅ **changed** |
| VCT name | fixed `data` (no parameter) | — |
| `initialClusterState` logic | `value || .Release.IsInstall ? "new" : "existing"` | — |
| konk | unchanged from j170 | — |

This is the minimal etcd-only upgrade. No `data-v2` param, no konk changes.

### `v0.2.1-150-g97950c6-j15` — etcd upgrade + data-v2

| Aspect | Value | Δ vs j180 |
|--------|-------|-----------|
| etcd chart | Upstream, `version: 1.0.0`, `appVersion: 3.5.17` | — |
| etcd image | `gcr.io/etcd-development/etcd:v3.6.8` | — |
| PVC mount path | `/var/lib/etcd` | — |
| `ETCD_DATA_DIR` | `/var/lib/etcd` | — |
| **VCT name** | **parameterized: `{{ .Values.persistence.claimName \| default "data" }}`** | ✅ **#631** |
| `persistence.claimName` value | default `data`, settable to `data-v2` | ✅ **new** |
| `initialClusterState` logic | same block; **set to `"new"` via DC values** | (values, not code) |
| konk | unchanged from j180 (old konk) | — |

**Only image that supports Option B (`claimName: data-v2`).** Branched off j180; carries no konk-service changes.

### `v0.2.1-155-gd4614c2-j191` — konk upgrade + etcd upgrade

| Aspect | Value | Δ vs j180 |
|--------|-------|-----------|
| etcd chart | Upstream, `version: 1.0.0`, `appVersion: 3.6.9` | — |
| etcd image | `gcr.io/etcd-development/etcd:**v3.6.9**` | ✅ patch bump 3.6.8 → 3.6.9 |
| PVC mount path | `/var/lib/etcd` | — |
| `ETCD_DATA_DIR` | `/var/lib/etcd` | — |
| VCT name | fixed `data` (**no claimName param**) | ❌ does NOT have #631 |
| `initialClusterState` logic | same block | — |
| **konk-service** | **4 commits from `release/konk-patch`** | ✅ **new** |

konk-service commits unique to j191 (not in j15):

| PR | Commit | Change |
|----|--------|--------|
| #625 | `d4614c2` | close HTTP/2 transport to prevent memory accumulation |
| #624 | `d45a403` | use file refs in kubeconfig instead of embedded cert data |
| #619 | `f64afd9` | merge `release/konk-patch` to master |
| #615 | `bb306e9` | truncate apiservice konk services |

**Does NOT support `data-v2`** — it branched before #631.

### `v0.2.1-154-g1de007e-j20` vs `v0.2.1-155-g372db4e-j21` — same etcd version, one hook fix

Resolved commits:
- `j20` = `1de007e7335ec1aa9fdb031465676531669e7270`
- `j21` = `372db4e2b70ddf5b77352bbbbc0edbb69da7a3b6`

Commit delta (`j20...j21`) is exactly one commit:
- `372db4e` — `fix(etcd): always recreate STS when hook enabled to prevent strategic merge issues (#636)`

What changed:
- Only `helm-charts/etcd/templates/recreate-statefulset-hook.yaml` was modified.
- Hook gating was broadened from "only when live claimName differs from target" to "whenever a live claimName exists" when the recreate hook is enabled.
- Doc text was updated to explain strategic-merge patch conflict avoidance.

What did not change:
- etcd chart metadata remained the same: `version: 1.0.0`, `appVersion: 3.5.17`.
- etcd image values remained the same: `repository: etcd-development/etcd`, `tag: v3.6.8`.
- No konk-service code changes in this j20 → j21 delta.

### `v0.2.1-164-gbd3f28a-j203` — mainline merge with newer etcd baseline

Resolved commit:
- `j203` = `bd3f28a868ee437121ebcc2801cfc9589413ef3b` (merge to `main`, PR `#658`)

etcd state at this image:
- etcd chart metadata: `version: 1.1.0`, `appVersion: 3.7.0`.
- etcd image values: `repository: infoblox.com/etcd`, `tag: 3.7.0`.

Migration-related differences vs j15/j20/j21 lineage:
- `volumeClaimTemplates[].metadata.name` is fixed back to `data` (no `persistence.claimName` parameter).
- The `recreate-statefulset-hook.yaml` template used in j20/j21 migration flow is not present.
- This image includes a broader merge set (CVE remediations + chart/runtime updates), not just an etcd migration-hook change.

---

## etcd chart `ETCD_INITIAL_CLUSTER_STATE` logic (all upstream images)

`helm-charts/etcd/templates/statefulset.yaml`:

```yaml
- name: ETCD_INITIAL_CLUSTER_STATE
  {{- if .Values.etcd.initialClusterState }}
  value: {{ .Values.etcd.initialClusterState | quote }}   # explicit value wins
  {{- else if .Release.IsInstall }}
  value: "new"                                             # fresh Helm install
  {{- else }}
  value: "existing"                                        # Helm upgrade
  {{- end }}
```

This block is **identical** in j180, j15, and j191. "ETCD_INITIAL_CLUSTER_STATE = new" is therefore **not** a property of any specific image — it is a **DC values setting** (`konk.custom.etcd.initialClusterState: "new"`) that overrides the default on every upstream chart.

---

## etcd data-path diff (Bitnami vs upstream)

**Mount paths differ, so the old Bitnami data is invisible to the new etcd.**

| | Bitnami (old, ≤ j170) | Upstream (new, j180 / j15 / j191) |
|---|---|---|
| PVC `data` mounted at | **`/bitnami/etcd`** | **`/var/lib/etcd`** |
| `ETCD_DATA_DIR` | **`/bitnami/etcd/data`** | **`/var/lib/etcd`** |
| `member/` location **on the PVC volume root** | **`data/member/`** | **`member/`** |

### What this looks like on the raw PVC volume

The PVC (`data-bulk-konk-etcd-N`) is the **same EBS volume** before and after the upgrade. Only the path the container mounts/reads changes:

```
Bitnami (mount = /bitnami/etcd, data-dir = /bitnami/etcd/data)
  PVC volume root/
  ├── data/            ◄── ETCD_DATA_DIR
  │   ├── member/
  │   │   ├── snap/db  (bbolt KV store)
  │   │   └── wal/     (write-ahead log)
  └── lost+found/

Upstream (mount = /var/lib/etcd, data-dir = /var/lib/etcd)
  PVC volume root/     ◄── ETCD_DATA_DIR is now the volume root
  ├── data/            ◄── old Bitnami data, NOW IGNORED (etcd doesn't look inside)
  │   └── member/...   (orphaned)
  ├── lost+found/
  └── member/          ◄── upstream etcd writes a FRESH member/ here on bootstrap
```

Upstream etcd looks for `member/` at the **volume root** (`/var/lib/etcd/member/`). Bitnami's `member/` is one level down inside `data/`. So the upstream etcd sees only `data/` + `lost+found/` at the root, finds **no `member/`**, treats the data dir as **empty**, and bootstraps fresh. The Bitnami data is never read, never migrated, never deleted — it just sits orphaned under `data/`.

### Source (`helm-charts/etcd/templates/statefulset.yaml`)

| | Bitnami chart (`8b64bf7`) | Upstream chart (`aca7e33`+) |
|---|---|---|
| `ETCD_DATA_DIR` env | `value: /bitnami/etcd/data` | `value: {{ .Values.etcd.dataDir }}` → `/var/lib/etcd` |
| volumeMount | `name: data` → `mountPath: /bitnami/etcd` | `name: data` → `mountPath: {{ .Values.etcd.dataDir }}` → `/var/lib/etcd` |

---

## Why this matters for migration

### The mount-path change makes the upgrade non-destructive (but bootstrap-sensitive)

Bitnami wrote data to `/bitnami/etcd/data` (→ `data/member/` on the PVC). The upstream chart reads `/var/lib/etcd` (→ `member/` at the PVC root). On the **same reused PVC**, the upstream etcd never sees the old Bitnami `member/` (it's hidden in the `data/` subdir) → it starts with an effectively **empty data dir**.

Consequence: the only thing that decides crash vs. clean start is `ETCD_INITIAL_CLUSTER_STATE`:
- **`new`** → fresh bootstrap succeeds (no crash), regardless of leftover Bitnami data.
- **`existing`** (default on a Helm *upgrade* of the etcd release) → all 3 pods try to join a non-existent cluster → *"cannot fetch cluster info from peer urls"* → CrashLoopBackOff (this is what hit us-stg-1 / eu-stg-1).

The new etcd needs `ETCD_INITIAL_CLUSTER_STATE=new` **at first bootstrap** (when there is no upstream `member/` yet). It can get `new` from **either**:
1. **A fresh Helm install** of the `bulk-konk-etcd` release — revision 1 → `.Release.IsInstall=true` → chart auto-renders `new`. **OR**
2. **An explicit value** `etcd.initialClusterState: "new"` — forces `new` on any revision (install or upgrade).

> ✅ **Propagation works (corrected).** Earlier notes claimed the Etcd CR overrides don't reach the etcd chart. That was wrong. Verified on us-dev-5 (j15): the rendered `bulk-konk-etcd` Helm **values** carry both `etcd.initialClusterState: new` **and** `persistence.claimName: data-v2`, and the rendered manifest uses VCT `data-v2`. CR → release → manifest propagation is intact. The actual blocker is a different one — an **immutable StatefulSet field**, see the failure-mode box below.

### How the `bulk-konk-etcd` release is created (all versions)

The standalone `bulk-konk-etcd` release is **not** a subchart of `bulk-konk`. It is produced by a CR → operator → helm chain that is **identical in j170, j180, j15, and j191**:

1. The **konk chart** (the `bulk-konk` release) renders an `Etcd` CR named `{{ .Release.Name }}-etcd` = `bulk-konk-etcd`, via `helm-charts/konk/templates/etcd.yaml`, gated on `.Values.etcd.operator`.
2. The **operator watches `Etcd` CRs** — the `kind: Etcd → chart: helm-charts/etcd` entry is already present in **j170's** `watches.yaml`.
3. The operator reconciles that CR with `helm install/upgrade` → creates the native `bulk-konk-etcd` Helm release.

So `bulk-konk-etcd` exists as a **separate native Helm release on every version**. The ONLY thing that differs between versions is the *flavor* of the `helm-charts/etcd` chart it deploys:

| Version | etcd chart rendered | Evidence in `helm-charts/etcd` tree | Mount |
|---------|--------------------|-------------------------------------|-------|
| j170 (`8b64bf7`) | **Bitnami wrapper** → `etcd-5.3.2` | `Chart.lock` + vendored `charts/` dep | `/bitnami/etcd` |
| j180 (`aca7e33`) | upstream rewrite → `etcd-1.0.0` | own `templates/`, no `Chart.lock`/`charts/` | `/var/lib/etcd` |

**Confirmed live on us-com-1 (prod, j170):**
```
NAME           NAMESPACE REVISION CHART       APP VERSION
bulk-konk      aggregate 1        konk-0.1.0  v1.25.8
bulk-konk-etcd aggregate 2        etcd-5.3.2  3.4.14     ← separate Bitnami release
```

#### Why `bulk-konk` is rev 1 but `bulk-konk-etcd` is rev 2

Each release has an **independent** revision counter (= install + upgrade count for that release):
- `bulk-konk` **rev 1** — installed once and never needed a follow-up `helm upgrade`.
- `bulk-konk-etcd` **rev 2** — installed (rev 1), then **one immediate follow-up upgrade** ~3 s later (06:29:24 → 06:29:27). Normal helm-operator behavior: on the first reconcile after install a value *materializes* that wasn't present at install time (cert secret `…-etcd-cert`, an image ref, or a status-driven field) → rendered manifest differs → one `helm upgrade` to converge → rev 2. Stable for ~7 months since.

> 🔁 **Reconcile-behavior difference — and the real cause of the rev churn:** the **j170** operator only bumps a revision on a real change (us-com-1 sat at rev 1/2 for ~7 months). On **us-dev-5 (j15)** the revision climbed to **44+ in a single day** (now 62 and counting) — **not** because of benign re-applies, but because the operator is stuck in a **failing upgrade → rollback loop** (see the failure-mode box below). Revision number on the newer operator is therefore meaningless as a change count.

> 🛑 **Failure mode: immutable VCT rename loop (`data` → `data-v2`).** On us-dev-5 the Etcd CR requests `persistence.claimName: data-v2`, which renders correctly into the etcd chart manifest. But the **live StatefulSet already has VCT `data`**, and `volumeClaimTemplates[].metadata.name` is **immutable**. So every reconcile (~1–2 min) does:
> ```
> helm upgrade → patch StatefulSet VCT data → data-v2
>   → API rejects: "updates to statefulset spec for fields other than
>      'replicas','ordinals','template','updateStrategy',
>      'persistentVolumeClaimRetentionPolicy','minReadySeconds' are forbidden"
>   → upgrade FAILS → operator ROLLS BACK to the last `data` revision
>   → next reconcile retries → fails again → ∞
> ```
> Live helm history confirms it: `rev 61 failed ("... StatefulSet ... Forbidden")`, `rev 62 deployed ("Rollback to 60")`. Each failed upgrade + rollback = **two** new revisions, which is why the counter races.
>
> **Pods stay `1/1 Running`** only because the rollback keeps the working `data` spec — so the cluster *looks* healthy while the desired `data-v2` migration **never actually applies**.
>
> **Remediation:** a VCT name change cannot be done in place. To move to `data-v2` you must recreate the StatefulSet:
> ```bash
> # orphan-delete the STS so pods/PVCs survive, then let the operator recreate it with data-v2
> kubectl --context us-dev-5 delete sts bulk-konk-etcd -n aggregate --cascade=orphan
> # (or fully uninstall the bulk-konk-etcd release, then redeploy)
> ```

### ⭐ The decisive factor: is `bulk-konk-etcd` a fresh INSTALL or an in-place UPGRADE?

Because `bulk-konk-etcd` **already exists on every j170 cluster** (rev ≥ 2 on us-com-1, rev 3 on reverted us-stg-1), migrating j170 → upstream is, by default, an **in-place `helm upgrade`** of that existing release (revision N → N+1) → renders **`existing`** → crash.

A migration only gets the safe auto-`new` if the `bulk-konk-etcd` release is **brand new** (revision 1). That happens **only if the old release was uninstalled first.**

This is exactly the us-dev-5 vs. stage difference:

| Cluster | `bulk-konk-etcd` release at migration | Render | Result |
|---------|---------------------------------------|--------|--------|
| **us-dev-5** | **uninstalled + reinstalled** → `first_deployed` = today (rev 1 = install), chart `etcd-1.0.0` | auto **`new`** | ✅ clean bootstrap |
| **us-stg-1 / eu-stg-1** | **upgraded in place** → release history kept (rev N→N+1) | **`existing`** | ❌ CrashLoopBackOff |
| **us-com-1** (prod, still j170) | release exists at **rev 2** (Bitnami) → next deploy = rev 3 **upgrade** unless uninstalled | **`existing`** | ⚠️ would crash on naive migration |

Verified live state:
- `us-dev-5`: `bulk-konk-etcd` rev 44, chart `etcd-1.0.0` (upstream), `first_deployed` 2026-06-23 07:21 (**install today**)
- `us-stg-1` (after revert): `bulk-konk-etcd` rev 3, chart `etcd-5.3.2` (**Bitnami**), created 2026-06-19 — **release still exists**
- `us-com-1` (prod, j170): `bulk-konk-etcd` rev 2, chart `etcd-5.3.2` (**Bitnami**), installed 2025-11-10 — **release exists, untouched for ~7 months**

➡️ **A re-migration of us-stg-1 right now would be an UPGRADE (rev 3 → 4) → `existing` → crash.** Likewise **us-com-1 would be rev 2 → 3 (UPGRADE) → crash.** Neither is a fresh install.

### Required pre-migration step (to force a fresh install)

Before deploying the upstream operator on any cluster whose `bulk-konk-etcd` release already exists (i.e. every cluster currently on j170, and any reverted cluster), **uninstall the existing release first**:

```bash
CTX=teleport.services.sdp.infoblox.com-<cluster>   # e.g. -us-stg-1
NS=aggregate

# Confirm the release exists and its revision/chart
helm --kube-context $CTX list -n $NS | grep bulk-konk-etcd

# Uninstall it so the next deploy is a clean install (revision 1 → auto "new").
# PVCs survive (volumeClaimTemplate PVCs are NOT deleted by helm uninstall);
# the orphaned Bitnami data stays under data/ and is ignored at /var/lib/etcd.
helm --kube-context $CTX uninstall bulk-konk-etcd -n $NS
# OR, if helm CLI scope is a problem, delete the release-history secrets directly:
# kubectl --context $CTX delete secret -n $NS -l owner=helm,name=bulk-konk-etcd

# Verify no release history remains (must return nothing)
kubectl --context $CTX get secret -n $NS -l owner=helm,name=bulk-konk-etcd
```

Then deploy the upstream operator → the operator does `helm install bulk-konk-etcd` (revision 1) → `.Release.IsInstall=true` → `new` → clean bootstrap on the reused PVCs.

> ⚠️ Uninstalling removes the **running** etcd release — do this inside the migration window, not casually.

**Consequences summary:**
- **Fresh install** (release uninstalled first, or never existed) → auto-`new` → safe.
- **In-place upgrade** (release left in place) → `existing` → crash. The explicit `initialClusterState: new` value *does* reach the chart, but on an in-place upgrade the etcd pods are resuming on existing data so the flag is moot — the crash on stage came from the upgrade rendering `existing` against data that isn't visible at the new mount path.
- **Separately**, if the CR sets `persistence.claimName: data-v2` against a StatefulSet already created with VCT `data`, the upgrade fails on the immutable-VCT rename and loops forever (see failure-mode box) — recreate the STS with `--cascade=orphan` to converge.

PVC deletion is NOT required for bootstrap — the Bitnami data is invisible at the new mount path; the only requirement is `new` at first bootstrap (achieved via the fresh install above).

### Which image to deploy

| Goal | Use | Why |
|------|-----|-----|
| Clean PVC migration (Option B, fresh `data-v2` volumes) | **j15** | Only image with the `persistence.claimName` param (#631). Values propagate fine, **but** renaming the VCT on an existing STS fails (immutable) — orphan-delete the STS so it's recreated with `data-v2` |
| etcd upgrade reusing existing `data` PVCs | j180 / j15 / j191 | Works when the etcd release is a **fresh install** (auto `new`); for re-attempts, delete the `bulk-konk-etcd` release first |
| konk-service fixes (HTTP/2 leak, kubeconfig file refs, apiservice truncation) | **j191** | Only image with the konk-service patches — but **no `data-v2` support** |
| Both konk fixes **and** data-v2 | _none yet_ | #631 (data-v2) and `release/konk-patch` (konk fixes) are on divergent branches; needs a merge of both |

### Gap

**No single image has both the konk-service fixes (j191) and the `data-v2` migration param (j15).** They live on divergent branches off j180. If prod needs both, `#631` must be merged into the `release/konk-patch` lineage (or vice versa) and a new image cut.

---

## Post-migration: reverting the migration-only flags

Two of the four DC values are **switches for the migration itself**, not steady-state
config. They must be flipped back once the cluster is up on `data-v2`, otherwise they
sit as latent hazards.

| Value | Keep after migration? | Why |
|-------|----------------------|-----|
| `persistence.claimName: data-v2` | ✅ **keep forever** | VCT name is immutable. Dropping it renders the chart default `data` → immutable-field rejection → operator back in the failed-upgrade/rollback loop |
| `statefulset.replicaCount: 3` | ✅ keep | Intended HA topology, not a migration artifact |
| `recreateStatefulSet.enabled` | ❌ **flip to `false`** | See below |
| `etcd.initialClusterState` | ❌ **flip to `existing`** | See below |

### `recreateStatefulSet.enabled: true` → `false`

The hook template (`recreate-statefulset-hook.yaml`) is gated on
`recreateStatefulSet.enabled` **and a live STS existing** — *not* on whether the claim
name actually changed. So while it stays `true` it fires on the **next** `helm upgrade`
of `bulk-konk-etcd`, triggered by any konk-operator bump, konk chart change, or edit to
the `konk:` block in `bulk-values.yaml`.

It runs `kubectl delete statefulset bulk-konk-etcd --wait=true`, so **all 3 members go
down at once** — instant quorum loss, konk apiserver down, aggregate APIs unavailable
until the STS is recreated and KonkService re-registers APIServices/CRDs. That is the
same ~60–90s outage we accept deliberately during migration; it must not happen
accidentally on an unrelated version bump.

Note this is *dormant*, not *active*: the helm-operator only upgrades when desired ≠
deployed, so a stable cluster never fires the hook. That's why us-dev-5 sat at helm
revision 255 unchanged for 22h with the flag still `true`. The risk is entirely about
the next change.

### `initialClusterState: "new"` → `"existing"`

`new` = bootstrap a brand-new cluster. `existing` = join the cluster described by
`ETCD_INITIAL_CLUSTER`. `new` was correct during migration because the `data-v2` PVCs
were empty (see [ETCD_INITIAL_CLUSTER_STATE logic](#etcd-chart-etcd_initial_cluster_state-logic-all-upstream-images)).

Post-migration it is wrong-but-dormant — etcd only reads the flag when its data dir is
empty. The danger is the **combination** with the hook above: if the STS is recreated
*and* any member comes up with an empty data dir (lost/re-provisioned PVC, node or EBS
failure, replica scale-up, future claimName change), that member bootstraps its own
single-member cluster instead of joining the survivors → **split brain**, recoverable
only via `etcdctl member` surgery or a restore.

Either removing the key (chart default is `existing` on upgrade) or setting it
explicitly to `"existing"` works. **Prefer explicit** — it documents intent and
survives a chart-default change.

### Applying the flip is safe

Helm renders `pre-upgrade` hooks from the **incoming** values, so with
`recreateStatefulSet.enabled: false` the hook template renders nothing and the delete
Job never runs. The only live change is `ETCD_INITIAL_CLUSTER_STATE` on the pod
template → ordinary STS rolling update, one pod at a time in ordinal order, each
waiting for Ready. Quorum preserved, zero downtime.

### Status

| Cluster | Migrated | Post-upgrade flip |
|---------|----------|-------------------|
| us-dev-4 | done | done — `recreateStatefulSet.enabled: false` pinned in `envs/box-dev/us-dev-4/bulk-values.yaml` |
| us-dev-5 | 2026-08-04 17:51 UTC | DC PR [#143226](https://github.com/Infoblox-CTO/deployment-configurations/pull/143226) |
| us-stg-1 | 2026-08-05 12:02 UTC | DC PR [#143226](https://github.com/Infoblox-CTO/deployment-configurations/pull/143226) |
| eu-stg-1 | not started — still on Bitnami `etcd-5.3.2` / `3.4.14` | n/a |

Old `data-bulk-konk-etcd-*` PVCs are retained on both migrated clusters as a rollback
safety net; cleanup is a separate change after a ~1 week soak.

---

## Source of truth

- etcd chart: `helm-charts/etcd/{Chart.yaml,values.yaml,templates/statefulset.yaml}`
- konk-service: `cmd/konk-service/`, `helm-charts/konk-service/`
- Commits: `8b64bf7` (j170), `aca7e33` (j180), `97950c6` (j15), `1de007e` (j20), `372db4e` (j21), `d4614c2` (j191)
- Merge-base of j15 & j191: `aca7e33` (j180)
