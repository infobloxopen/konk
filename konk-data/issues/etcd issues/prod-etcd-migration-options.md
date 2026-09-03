# Konk etcd Prod Upgrade — Migration Options

**Date:** 2026-06-18 (updated 2026-06-19)
**Context:** Upgrading konk-operator that swaps etcd from Bitnami (3.5.x) to upstream (3.6.x). On dev/stage this required deleting etcd PVCs because the new etcd finds incompatible Bitnami data in the reused PVC, logs `"server has already been initialized"`, and crash-loops. This doc compares options to migrate prod safely.

---

## Background: Why a simple upgrade fails

### The image swap is the root cause

The upgrade swaps the etcd container image:

| | Old | New |
|---|---|---|
| **etcd image** | `bitnamilegacy/etcd` (3.5.x) | `gcr.io/etcd-development/etcd:v3.6.9` |
| **Data dir** | `/bitnami/etcd/data` | `/var/lib/etcd` (per `--data-dir`) |
| **Entrypoint** | Bitnami wrapper scripts (`/opt/bitnami/scripts/etcd/`) that bootstrap, snapshot-restore, and manage membership before launching etcd | None — runs the raw etcd binary directly |
| **Shell/tooling** | Has shell + `tar` (non-distroless) | **Distroless** — no shell, `tar`, `ls`, `cat` |

This swap breaks an in-place upgrade for **two independent reasons:**

**1. Data-directory layout mismatch → "already initialized."**
When the StatefulSet is replaced and the **same PVC is reused**, the new upstream etcd points `--data-dir` at the reused volume and finds a pre-existing `member/` directory (Bitnami-era data). etcd interprets *any* existing member data as "I am already a bootstrapped member," logs `server has already been initialized` / `member has already been bootstrapped`, **ignores `ETCD_INITIAL_CLUSTER_STATE`**, and tries to rejoin its old cluster — whose member IDs / cluster ID no longer exist. No quorum → crash-loop.

**2. Bitnami's wrapper did the bootstrapping; upstream doesn't.**
The Bitnami image is more than etcd — its entrypoint generated `ETCD_INITIAL_CLUSTER`, handled member registration, snapshot restore, and stale-member cleanup. The upstream image is **just the etcd binary**, so all that orchestration must now come from the chart's env vars. On a fresh install the chart's logic works (`IsInstall` → `new`); on an upgrade over existing Bitnami data the chart computes `existing` **and** the volume has foreign member data — the two collide.

### The chart's cluster-state logic

The custom etcd chart ([helm-charts/etcd/templates/statefulset.yaml](https://github.com/infobloxopen/konk/blob/e8ba134702dd46bd7c63cb32122bec6557607a8a/helm-charts/etcd/templates/statefulset.yaml#L94)) sets cluster bootstrap state as:

```yaml
{{- if gt (int .Values.replicaCount) 1 }}       # ← ONLY for multi-replica
- name: ETCD_INITIAL_CLUSTER
  value: {{ include "etcd.initialCluster" . | quote }}
- name: ETCD_INITIAL_CLUSTER_TOKEN
  value: {{ .Values.etcd.initialClusterToken | quote }}
- name: ETCD_INITIAL_CLUSTER_STATE
  {{- if .Values.etcd.initialClusterState }}
  value: {{ .Values.etcd.initialClusterState | quote }}
  {{- else if .Release.IsInstall }}
  value: "new"
  {{- else }}
  value: "existing"     # ← upgrades default to "existing"
  {{- end }}
{{- end }}
```

> **Key detail:** This entire block (including `ETCD_INITIAL_CLUSTER_STATE`) is **only rendered when `replicaCount > 1`**. For single-replica deployments, none of these env vars are set — etcd uses its own defaults. Bulk-konk uses **3 replicas**, so the block applies.

The `volumeClaimTemplate` name is hardcoded to `data`, so the StatefulSet **reuses the existing PVCs** on upgrade:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data        # ← hardcoded, no parameterization
```

**Failure chain on upgrade:**
1. Helm replaces the StatefulSet (`bitnamilegacy/etcd:3.5.x` → `gcr.io/etcd-development/etcd:v3.6.9` — full template replace, not rolling)
2. New upstream etcd pods start, reuse old PVCs (`data-bulk-konk-etcd-{0,1,2}`)
3. etcd opens `--data-dir`, finds old Bitnami `member/` data → `server has already been initialized` (ignores `initialClusterState`)
4. Chart computed `ETCD_INITIAL_CLUSTER_STATE=existing` (it's an upgrade) → pods try to rejoin a cluster whose members/IDs no longer exist
5. No quorum → all 3 etcd pods CrashLoopBackOff
6. bulk-konk (kube-apiserver) loses its etcd backend → also crashes

**Both fixes are needed:** a data dir etcd recognizes as **empty** (clean/delete PVC, or fresh `data-v2` volume — clears reason #1) **AND** `initialClusterState: "new"` (tells etcd to bootstrap — clears reason #2). Prod needs the clean data dir **without** destroying the old PVCs.

---

## Key fact that makes all options safe

**konk etcd is NOT the application database.** It only stores Kubernetes API objects (CRDs, CRs, RBAC, leases) for the konk kube-apiserver. The real bulk application data lives in **PostgreSQL** (`bulk-dbapi`). On a fresh etcd:
- `konk-service` re-runs `reconcile-apiservice` → re-registers APIServices/CRDs
- bulk operator reconciles CRs back from PostgreSQL (source of truth)
- `bulk-konk-init` re-runs `kubeadm init` → regenerates PKI/kubeconfig

So an empty etcd start causes a brief reconcile window, **not** user-facing data loss. The backups below are insurance, not a hard requirement.

---

## Option A — Manual snapshot + PVC deletion + fresh bootstrap (RECOMMENDED)

The simplest, proven approach: take a backup, delete the old PVCs, and let etcd bootstrap from scratch on fresh volumes. This is the same playbook that worked on dev/stage, with an off-cluster backup taken first for safety.

**Prerequisites:**
- Prod etcd is **non-distroless** → `etcdctl snapshot save` + `kubectl cp` both work
- etcd cluster is healthy (can take a logical snapshot)

**Steps:**

```bash
# 1. Take etcd snapshot (saved onto the PVC)
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl snapshot save /var/lib/etcd/backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key

# 2. Copy snapshot off-cluster (works on prod — has tar)
kubectl cp aggregate/bulk-konk-etcd-0:/var/lib/etcd/backup.db ./prod-etcd-backup.db

# 3. (Optional but recommended) EBS-snapshot the volumes as belt-and-suspenders
aws ec2 create-snapshot --volume-id <vol-id> --description "konk-etcd pre-upgrade prod $(date +%F)"

# 4. Scale StatefulSet to 0 (releases PVCs)
kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=0

# 5. Retain PVs so EBS volumes survive PVC deletion (on-cluster backup)
for i in 0 1 2; do
  PV=$(kubectl get pvc data-bulk-konk-etcd-$i -n aggregate -o jsonpath='{.spec.volumeName}')
  echo "PVC $i → PV: $PV"
  kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done

# 6. Delete the PVCs (PVs + EBS data survive due to Retain; Kyverno bypass label required)
for i in 0 1 2; do
  kubectl label pvc data-bulk-konk-etcd-$i -n aggregate \
    k8s.infoblox.com/allow-user-action=enabled --overwrite
  kubectl delete pvc data-bulk-konk-etcd-$i -n aggregate
done

# 7. Patch the Etcd CR's initialClusterState to "new" so etcd bootstraps fresh
kubectl patch etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type='merge' -p='{"spec":{"etcd":{"initialClusterState":"new"}}}'

# 8. Scale back up — fresh PVCs auto-provisioned, etcd bootstraps clean
kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=3

# 9. Verify
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key

# 10. Post-migration: revert initialClusterState so normal restarts use "existing"
kubectl patch etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type='merge' -p='{"spec":{"etcd":{"initialClusterState":""}}}'
```

### Why is `initialClusterState: "new"` still needed with empty PVCs?

Deleting PVCs removes the **blocker** (stale Bitnami `member/` data). But the chart still computes `ETCD_INITIAL_CLUSTER_STATE=existing` because it's a `helm upgrade`, not an install. Without the override:

| Flag | Meaning | On an empty volume |
|---|---|---|
| `existing` | "A cluster already exists, I'm joining it" | All 3 pods wait for a cluster that doesn't exist → none bootstrap → all timeout/crash |
| `new` | "We are bootstrapping a brand-new cluster" | All 3 pods elect a leader and form a fresh cluster ✅ |

You need **both**: empty PVCs (clears reason #1) + `initialClusterState: "new"` (clears reason #2).

### Workaround: setting `initialClusterState: "new"` without a chart/CR change

If you don't want to (or can't) set `spec.etcd.initialClusterState: "new"` via the Etcd CR or values file, there are two cluster-level workarounds:

#### Workaround 1: Delete the Helm release secret (RECOMMENDED)

Delete the Helm release history secret so the operator's next reconcile treats it as a **fresh install** instead of an upgrade. The chart template already has:

```yaml
# helm-charts/etcd/templates/statefulset.yaml lines 94-101
- name: ETCD_INITIAL_CLUSTER_STATE
  {{- if .Values.etcd.initialClusterState }}
  value: {{ .Values.etcd.initialClusterState | quote }}
  {{- else if .Release.IsInstall }}
  value: "new"           # ← this path is taken on install
  {{- else }}
  value: "existing"      # ← this path is taken on upgrade
  {{- end }}
```

By removing the release secret, `.Release.IsInstall` becomes `true` → template renders `"new"` automatically.

```bash
# After scaling STS to 0 and deleting PVCs:

# Find and delete the Helm release secret(s)
kubectl get secret -n aggregate -l owner=helm,name=bulk-konk-etcd
# e.g.: sh.helm.release.v1.bulk-konk-etcd.v3

kubectl delete secret -n aggregate -l owner=helm,name=bulk-konk-etcd

# Trigger operator reconcile (it will do a fresh install)
kubectl annotate etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  konk.infoblox.com/reconcile-trigger="$(date +%s)" --overwrite

# The operator sees no existing release → runs helm install → ETCD_INITIAL_CLUSTER_STATE="new"
# Scale up happens automatically as part of the install
```

**Pros:**
- No CR or values change needed — purely cluster-level operation
- The chart's own logic handles the `new` vs `existing` decision
- Operator doesn't fight you — it's doing its normal reconciliation
- Etcd CR status shows `InstallSuccessful` (cosmetic difference only)

**Cons:**
- Helm release history (revision numbers, rollback capability) is lost
- The Etcd CR may briefly show `ReleaseFailed` during the transition

#### Workaround 2: Patch the StatefulSet env var directly (fragile, not recommended)

Directly patch `ETCD_INITIAL_CLUSTER_STATE` on the StatefulSet after PVC deletion, then scale up before the operator overwrites it.

```bash
# After scaling STS to 0 and deleting PVCs:

# Find the env var index for ETCD_INITIAL_CLUSTER_STATE
kubectl get sts bulk-konk-etcd -n aggregate \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | grep -n INITIAL_CLUSTER_STATE
# e.g.: 1:ETCD_INITIAL_CLUSTER_STATE → index 0

# Patch (adjust index as needed)
kubectl patch sts bulk-konk-etcd -n aggregate --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"new"}]'

# Scale up immediately (before operator reconciles and overwrites)
kubectl scale sts bulk-konk-etcd -n aggregate --replicas=3
```

**Why this works despite being fragile:** etcd only reads `--initial-cluster-state` on **first boot with empty data dir**. Once it bootstraps and writes member data, the flag is ignored on subsequent restarts. So even if the operator later reverts it to `"existing"`, etcd is already bootstrapped.

**Cons:**
- Index-based JSON patches are error-prone (wrong index = corrupt different env var)
- Race condition with operator reconciliation
- Operator will overwrite on next reconcile (but etcd already bootstrapped, so harmless)

#### Summary: which workaround to use

| Approach | Reliability | Complexity | Operator-friendly |
|----------|------------|------------|-------------------|
| CR patch (`spec.etcd.initialClusterState: "new"`) | ✅ Best | Low | Yes |
| Workaround 1: Delete Helm release secret | ✅ Good | Low | Yes |
| Workaround 2: Patch STS env var | ⚠️ Fragile | Medium | No (race) |

**Recommendation:** Use Workaround 1 (delete Helm release secret) if you cannot modify the CR. It's clean, the operator cooperates, and no manual revert is needed afterward (subsequent reconciles will be upgrades and compute `"existing"` correctly).

**Pros:**
- ✅ Simple, proven (worked on us-dev-2, us-stg-1)
- ✅ No chart code change needed
- ✅ Keeps the canonical `data-*` PVC name going forward
- ✅ Off-cluster backup provides restore path if anything goes wrong

**Cons:**
- ⚠️ Old PVCs are deleted but **PVs + EBS volumes are retained** on-cluster (can rebind if needed)
- ❌ Requires Kyverno bypass label for PVC deletion
- ⚠️ Manual steps on prod (but straightforward and sequential)
- ⚠️ Brief downtime window while etcd re-bootstraps and konk reconciles from PostgreSQL

---

## Option B — Chart `claimName` change (declarative, zero deletion)

Parameterize the volumeClaimTemplate name so the upgrade provisions **brand-new empty PVCs** while leaving the old ones untouched.

**Chart change:**
```yaml
volumeClaimTemplates:
  - metadata:
      name: {{ .Values.persistence.claimName | default "data" }}
```

**Per-cluster values:**
```yaml
persistence:
  claimName: data-v2
etcd:
  initialClusterState: "new"
```

**What happens:**
- New StatefulSet provisions empty `data-v2-bulk-konk-etcd-{0,1,2}` (fresh EBS volumes)
- Old `data-bulk-konk-etcd-{0,1,2}` PVCs/volumes are **never touched** → instant backup + rollback
- etcd bootstraps clean; konk re-registers from PostgreSQL

**Pros:**
- ✅ Zero PVC/PV deletion, zero live volume surgery
- ✅ Declarative — runs through the normal Flux/Helm upgrade
- ✅ No manual `etcdctl member` commands (the thing that broke eu-stg)
- ✅ Rollback = revert values to `claimName: data` + `initialClusterState: ""`

**Cons / Notes:**
- ⚠️ Prod runs on `data-v2-*` **permanently** going forward. This is fine — the name is only an identifier; there is no functional cost to running on `data-v2-*` forever.
- ⚠️ One-way per migration: a *future* incompatible etcd change would need `data-v3-*`, etc. (rare).
- ⚠️ Requires a chart code change + release (one-time).
- ⚠️ Old PVCs linger consuming EBS until manually cleaned up (intended — they're the backup).

### Q: "Will prod always run on data-v2-*?"
**Yes.** After migration prod uses `data-v2-bulk-konk-etcd-*` as its permanent data PVCs. The old `data-*` PVCs become orphaned backups you can delete once the new cluster is verified healthy. The name change is permanent and harmless.

### Q: "Can we revert claimName back to `data` in a later deployment?"
**No — treat `data-v2` as permanent.** Two things can happen:

| Action | Outcome |
|---|---|
| Revert `claimName` → `data`, normal `helm upgrade` | **Blocked.** `volumeClaimTemplates` is an immutable StatefulSet field. Kubernetes rejects with `Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', and 'updateStrategy' are forbidden`. No change applied. |
| Revert + force STS recreation (`--force` / manual `kubectl delete sts`) | **Silent rollback.** The new StatefulSet rebinds the old `data-*` PVCs, which still hold the **original cluster's etcd member data** (old cluster ID, old snapshot). etcd starts on stale data → effectively a point-in-time rollback; any CRs/RBAC/leases created after migration vanish from etcd (much re-syncs from PostgreSQL, but leases/certs churn). The `data-v2-*` PVCs sit unused. |

**Safe way to reclaim the `data` name later:** finish migration → soak → **delete the old `data-*` PVCs** so the name is free and there's no stale data to accidentally bind to. Do **not** flip `claimName` back as a routine config change.

---

## Option C — PV Retain + rebind (manual rename effect)

PVC names are **immutable** in Kubernetes, so you cannot literally rename `data-*` → `data-backup-*`. But you can preserve the old data under a new PVC name using the PV `Retain` policy, then let the StatefulSet create fresh `data-*` PVCs.

**Per member (0, 1, 2):**
```bash
# 1. Protect the PV so data survives PVC deletion
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 2. Scale etcd down to release the PVCs
kubectl scale statefulset bulk-konk-etcd -n aggregate --replicas=0

# 3. Delete the OLD PVC (PV + EBS data survive due to Retain)
kubectl delete pvc data-bulk-konk-etcd-0 -n aggregate

# 4. Clear the stale binding so the PV can be reused
kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'

# 5. Create a NEW "backup" PVC bound to that PV (preserves old data under new name)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-backup-bulk-konk-etcd-0
  namespace: aggregate
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 8Gi
  storageClassName: <sc>
  volumeName: <pv-name>
EOF
```

Then scale the StatefulSet back up — it provisions fresh empty `data-bulk-konk-etcd-{0,1,2}` while old data sits in `data-backup-*`.

**Pros:**
- ✅ Keeps the canonical `data-*` name for the running cluster
- ✅ No chart change required
- ✅ Old data preserved under `data-backup-*`

**Cons:**
- ❌ Manual, multi-step, per-member surgery on **prod** (high operator-error risk — see eu-stg)
- ❌ Requires Kyverno bypass label for PVC deletion on prod
- ⚠️ Still needs `initialClusterState: "new"` patch
- ⚠️ Reclaim policy must be restored to `Delete` afterward if that's the standard

---

## Option D — etcd snapshot backup (file-based insurance)

Take a logical etcd snapshot before the upgrade. **Only works on a HEALTHY cluster.**

```bash
# Save snapshot onto the PVC (image is distroless; cannot kubectl cp directly)
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl snapshot save /var/lib/etcd/backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key
```

> ⚠️ The etcd image is **distroless** — no `tar`/`sh`/`cat`. So `kubectl cp` will FAIL with `exec: "tar": not found`. To get the file off-cluster you must **EBS-snapshot the volume** (Option E) or restore in-place later.

**Restore (if needed):**
```bash
etcdutl snapshot restore /var/lib/etcd/backup.db --data-dir /var/lib/etcd/restored
# then point etcd data dir at the restored copy
```

**Pros:**
- ✅ Portable logical backup of all keys
- ✅ Standard etcd DR practice

**Cons:**
- ❌ Requires a healthy/quorate cluster (does NOT work in the current eu-stg broken state)
- ❌ Distroless image blocks `kubectl cp` — needs EBS snapshot to extract anyway
- ⚠️ Doesn't avoid the data-dir reuse problem by itself — still pair with Option A, B, or C

---

## Option E — EBS volume snapshot (block-level insurance)

Snapshot the underlying EBS volumes in AWS before any change. Works **regardless of cluster health** (block-level, no container tooling).

```bash
# Find the volume ID from the PV
kubectl get pv <pv-name> -o jsonpath='{.spec.awsElasticBlockStore.volumeID}{"\n"}'
kubectl get pv <pv-name> -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

# Snapshot in AWS
aws ec2 create-snapshot --volume-id vol-xxxx \
  --description "konk-etcd pre-upgrade <cluster> <date>"
```

**Reference (eu-stg etcd-0):** old volume `vol-06017e6686906abeb`.

**Pros:**
- ✅ Works even when etcd is down / no quorum (the eu-stg situation)
- ✅ Full block-level restore point
- ✅ No container tooling needed

**Cons:**
- ⚠️ Restore = create volume from snapshot + rebind PV (manual)
- ⚠️ Crash-consistent (not application-consistent) unless etcd was quiesced first

---

## Option F — Gated `pre-upgrade` Helm hook (opt-in, one-shot PVC cleanup)

If the goal is to "delete the PVCs as part of the upgrade flow" but **only when explicitly intended**, add a Helm `pre-upgrade` hook Job gated behind a values flag. This keeps `data-*` as the canonical name (no chart `claimName` rename) while still getting a clean data dir.

**values.yaml:**
```yaml
persistence:
  recreateOnUpgrade: false   # default safe — never deletes data
```

**templates/pvc-cleanup-hook.yaml** (only rendered when `recreateOnUpgrade: true`):
```yaml
{{- if .Values.persistence.recreateOnUpgrade }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "etcd.fullname" . }}-pvc-cleanup
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": hook-succeeded,before-hook-creation
spec:
  template:
    spec:
      serviceAccountName: {{ include "etcd.fullname" . }}-cleanup
      restartPolicy: Never
      containers:
        - name: cleanup
          image: bitnami/kubectl   # needs a shell+kubectl (NOT distroless etcd)
          command:
            - /bin/sh
            - -c
            - |
              kubectl scale statefulset {{ include "etcd.fullname" . }} --replicas=0
              for i in 0 1 2; do
                kubectl label pvc data-{{ include "etcd.fullname" . }}-$i \
                  k8s.infoblox.com/allow-user-action=enabled --overwrite || true
                kubectl delete pvc data-{{ include "etcd.fullname" . }}-$i --ignore-not-found
              done
{{- end }}
```

Usage: flip `recreateOnUpgrade: true` for the migration release only, then set it back to `false`. Pair with `initialClusterState: "new"`.

**Pros:**
- ✅ Keeps the canonical `data-*` name
- ✅ Deletion happens automatically inside the upgrade, but only when the flag is set
- ✅ Declarative / GitOps-friendly

**Cons:**
- ❌ **Does delete the old PVCs** — no automatic backup left behind (must pair with Option C/D first)
- ❌ More moving parts than Option A (RBAC + ServiceAccount + Job + a non-distroless kubectl image)
- ⚠️ Needs Kyverno bypass label baked into the Job (shown above)
- ⚠️ If you forget to set the flag back to `false`, a later upgrade silently wipes etcd

---

## Can we make the chart "always delete the PVC on every StatefulSet update"?

**No native mechanism exists, and it's not advisable.** Kubernetes' only built-in PVC auto-deletion is `persistentVolumeClaimRetentionPolicy`, which fires on exactly two events — **neither is a version upgrade / rolling update:**

| Field | Trigger | Fires on a version upgrade? |
|---|---|---|
| `whenScaled: Delete` | replica **scale-down** | ❌ No |
| `whenDeleted: Delete` | **StatefulSet deletion** | ❌ No |

There is no `whenUpdated` option, so no config switch means "wipe etcd data on every upgrade." Even if it existed:
- It would turn **every** routine etcd restart/upgrade into a full data-loss + rebootstrap event.
- It makes the StatefulSet non-idempotent; one accidental reschedule = wiped cluster.
- It defeats the purpose of persistence.

**Conclusion:** make data-dir cleanup an **explicit, gated, one-time action** (Option A's manual PVC deletion, Option B's fresh `claimName`, or Option F's flagged hook) — never an "always delete" policy.

---

## Comparison Matrix

| | A: Manual PVC delete | B: claimName | C: PV Retain rebind | D: etcd snapshot | E: EBS snapshot | F: Gated hook |
|---|---|---|---|---|---|---|
| Deletes PVCs? | ✅ Yes | ❌ No | ⚠️ Deletes then rebinds | ❌ No | ❌ No | ✅ Yes (gated) |
| Keeps backup automatically? | ❌ No (off-cluster only) | ✅ Yes (old `data-*`) | ✅ Yes (`data-backup-*`) | n/a | n/a | ❌ No |
| Live volume surgery? | ⚠️ Sequential delete | ❌ No | ✅ Yes (risky) | ❌ No | ❌ No | ⚠️ Automated in Job |
| Chart change needed? | ❌ No | ✅ Yes (one-time) | ❌ No | ❌ No | ❌ No | ✅ Yes (one-time) |
| Keeps canonical `data-*` name? | ✅ Yes | ❌ No (`data-v2`) | ✅ Yes | n/a | n/a | ✅ Yes |
| Works if etcd is down? | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No | ✅ Yes | ✅ Yes |
| Declarative / GitOps? | ❌ No (manual) | ✅ Yes | ❌ No | ❌ No | ❌ No | ✅ Yes |
| Rollback ease | ⚠️ Restore from snapshot | ✅ Easy (revert values) | ⚠️ Manual | ⚠️ Manual restore | ⚠️ Manual restore | ❌ Hard (data deleted) |
| Manual etcdctl surgery? | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No | ❌ No |
| Prod recommendation | ✅ Primary | Alternative | Fallback | Insurance | Insurance | Alternative |

---

## Recommended Prod Plan

> **Note on prod etcd image:** prod currently runs the **non-distroless** etcd image, so it *does* have a shell + `tar`. That means `etcdctl snapshot save` **and** `kubectl cp` both work on prod (unlike eu-stg). Take the logical snapshot too — it's cheap insurance.

1. **Insurance first (do both):**
   - `etcdctl snapshot save` on a healthy member, then `kubectl cp` it off-cluster (Option D — works on prod's non-distroless image).
   - EBS-snapshot all 3 etcd volumes (Option E) — works regardless of state.
2. **Migrate with Option A** (manual: scale to 0, delete PVCs, patch `initialClusterState: "new"`, scale back up). Old `data-*` PVCs are deleted but backed up off-cluster from step 1.
   - *Alternative:* Option B (chart `claimName: data-v2`) if you want old PVCs to remain on-cluster as instant rollback, at the cost of a chart change and permanent `data-v2-*` name.
   - *Alternative:* Option F (gated hook) to automate the PVC deletion within the Helm upgrade flow.
3. **Verify:** etcd member list (3 members), endpoint health, bulk-konk 1/1, konk-service re-registers APIServices.
4. **Post-migration:** revert `initialClusterState` back to `""` (so normal restarts compute `existing` and rejoin correctly — leaving it `new` risks a future restart re-bootstrapping).
5. **Soak**, then confirm no issues during confidence window.

**Rollback (Option A):** restore from the off-cluster etcd snapshot (`etcdutl snapshot restore`) or from the EBS volume snapshot (create volume from snapshot, rebind PV). Since konk etcd is reconstructable from PostgreSQL, in most cases a fresh bootstrap is simpler than a restore.

---

## Lessons from eu-stg (what NOT to do on prod)

- ❌ Do **not** manually `etcdctl member add` partial members — it changes quorum math (1→2 members needing 2 votes) and can take down the surviving node. This is exactly what broke eu-stg.
- ❌ Do **not** rely on `kubectl cp` for backups — the etcd image is distroless (no `tar`).
- ❌ Do **not** assume `initialClusterState: "new"` alone fixes it — etcd ignores it when it finds existing member data in the PVC.
- ✅ Prefer declarative, GitOps-driven changes over live cluster surgery.

---

## What data is in the konk etcd PVCs — and is it safe to delete?

> **Example: us-stg-1** (inspected 2026-06-19 after Bitnami recovery)

### PVC inventory

| PVC | Status | Size | Used | Pod |
|-----|--------|------|------|-----|
| `data-bulk-konk-etcd-0` | Bound | 8Gi | 123M (2%) | `bulk-konk-etcd-0` (Running) |
| `data-bulk-konk-etcd-1` | Bound | 8Gi | ~16K | **None** (orphaned) |
| `data-bulk-konk-etcd-2` | Bound | 8Gi | ~16K | **None** (orphaned) |

- PVCs 1 and 2 were created by the StatefulSet `volumeClaimTemplate` but **never used** — the operator forces `replicaCount: 1`, so only etcd-0 runs. They contain only `lost+found`.
- All 3 were created at the same time during the Bitnami bootstrap.

### etcd instance details (PVC 0)

| Property | Value |
|----------|-------|
| Version | `3.4.14` (Bitnami) |
| Members | 1 (single-node) |
| DB size | 651 kB |
| Total keys | **212** |

### Key breakdown (212 keys)

| Category | Count | What it is |
|----------|-------|------------|
| `clusterroles` | 74 | k8s built-in + Infoblox `*-edit` roles |
| `clusterrolebindings` | 43 | Bindings for the above |
| `apiregistration.k8s.io` | 32 | APIService registrations (Infoblox bulk + k8s built-in) |
| `flowschemas` | 13 | API priority & fairness (k8s built-in) |
| `services` | 11 | ExternalName services → KonkService endpoints |
| `namespaces` | 11 | atcapi, ddi, endpoints, hostapp, ngp-cp, ntp, redirect, tagging-v2, kube-system, kube-public, kube-node-lease |
| `prioritylevelconfigurations` | 8 | k8s built-in |
| `roles` | 7 | Namespace-scoped roles |
| `rolebindings` | 7 | Namespace-scoped bindings |
| `ranges` | 2 | Service IP/NodePort ranges |
| `priorityclasses` | 2 | k8s built-in |
| `configmaps` | 1 | cluster-info |

### What is NOT in there

- **Zero CRDs** — no CustomResourceDefinitions stored in this etcd
- **Zero custom resource instances** — the bulk APIs (dnsconfig, ipamdhcp, etc.) are extension API servers backed by **PostgreSQL**, not by this etcd
- **Zero user/application data** — no Deployments, Pods, Secrets, or app-owned objects

### How is this data reconstructed?

| Data | Recreated by | Timing |
|------|-------------|--------|
| APIServices, ExternalName Services, ClusterRoles, ClusterRoleBindings, Namespaces | KonkService `konk-service-kubectl-apiservice` pods (30s reconcile loop) | ~30-60s after apiserver is ready |
| FlowSchemas, PriorityLevelConfigs, PriorityClasses, Ranges | `kube-apiserver` on startup (built-in bootstrap) | Immediate |
| Roles, RoleBindings, ConfigMaps | KonkService pods + kubeadm init | ~30-60s |

### Conclusion: safe to delete

**The konk etcd is a pure metadata cache, not a data store.** Every key in it is either:
1. Auto-generated by `kube-apiserver` on startup (k8s built-ins), or
2. Continuously reconciled by the KonkService pods every 30 seconds

**PVC deletion impact:**
- Bulk aggregate APIs are unavailable for ~30-60s while KonkService pods re-register their APIServices
- No data loss — application data lives in PostgreSQL behind the extension API servers
- No manual intervention needed — recovery is fully automatic

**Recommendation for prod:**
- Take an off-cluster etcd snapshot before deleting PVCs (belt-and-suspenders), but know that a restore from this snapshot would never be necessary — the data reconstructs itself
- Delete orphaned PVCs (etcd-1, etcd-2) immediately — they're empty and waste 16Gi of EBS storage per cluster
- On the active PVC: deletion triggers a ~60s API disruption window. Schedule during a maintenance window for prod

```bash
# Clean up orphaned PVCs (safe anytime, no disruption)
for i in 1 2; do
  kubectl label pvc data-bulk-konk-etcd-$i -n aggregate \
    k8s.infoblox.com/allow-user-action=enabled --overwrite
  kubectl delete pvc data-bulk-konk-etcd-$i -n aggregate
done

# Delete active PVC (causes ~60s disruption — do during maintenance)
kubectl label pvc data-bulk-konk-etcd-0 -n aggregate \
  k8s.infoblox.com/allow-user-action=enabled --overwrite
kubectl delete pvc data-bulk-konk-etcd-0 -n aggregate
```
