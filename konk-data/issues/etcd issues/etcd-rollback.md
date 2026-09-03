# Etcd Downgrade to Bitnami — Recovery Procedure

## Overview

When rolling back from j180/j191 to j170, the j170 operator bundles the **Bitnami etcd chart** (`etcd-5.3.2`, image: `docker.io/bitnami/etcd:3.4.14-debian-10-r0`). If the Etcd CR gets reconciled by j170, it deploys the Bitnami chart template which is incompatible with upstream etcd data and/or images.

**This document covers the etcd-specific recovery.** For the full rollback procedure, see:
- [konk-rollback.md](../konk/konk-rollback.md) — overall rollback plan
- [us-stg-1-rollback issue from 191 to 170.md](us-stg-1-rollback%20issue%20from%20191%20to%20170.md) — original incident (j191→j170)

---

## When does this happen?

The Etcd CR gets reconciled by j170 in two scenarios:

| Scenario | How it happens | Preventable? |
|----------|---------------|--------------|
| **j191→j170** (Etcd CR annotations NOT fixed) | Someone annotates the Etcd CR to fix `InstallError` | Yes — DON'T annotate the Etcd CR |
| **j180→j170** (Etcd CR annotations already in place) | j170 operator starts and immediately reconciles | **No** — annotations from j180 fix are already there |

---

## Failure Modes

### Mode 1: Image/template mismatch (j180→j170 path)

**Symptom:** `exec /scripts/setup.sh: no such file or directory`

**Root cause:** The Etcd CR spec has an image override from j180 (`gcr.io/etcd-development/etcd:v3.6.8`). The j170 Bitnami chart template expects `/scripts/setup.sh` (which only exists in the Bitnami image). The upstream image doesn't have this script.

```
$ kubectl logs bulk-konk-etcd-0 -n aggregate
exec /scripts/setup.sh: no such file or directory
```

**Etcd CR spec (from j180):**
```yaml
spec:
  image:
    pullPolicy: IfNotPresent
    registry: gcr.io
    repository: etcd-development/etcd
    tag: v3.6.8
```

### Mode 2: Bitnami pod template bug (j191→j170 path, no image override)

**Symptom:** `Pod "bulk-konk-etcd-0" is invalid: spec.containers[0].env[4].valueFrom: Invalid value`

**Root cause:** The Bitnami chart template generates `ETCD_NAME` env var with both `value: $(MY_POD_NAME)` and `valueFrom: fieldRef: metadata.name`. Kubernetes rejects this.

### Mode 3: Stale PVC data causes election loop

**Symptom:** Etcd starts but loops on `is starting a new election at term N`

**Root cause:** PVCs contain upstream 3.6.x data with a 3-member cluster membership record. Bitnami etcd 3.4.14 reads the old member list and tries to reach etcd-1/etcd-2 — which don't exist if `replicaCount: 1`.

---

## Recovery Procedure

> **⚠️ DATA LOSS:** This procedure deletes all etcd PVCs. All konk CRDs/resources stored in etcd are lost. Acceptable for dev/staging — requires migration strategy for prod.

### Step 1: Scale down etcd

```bash
kubectl scale sts bulk-konk-etcd -n aggregate --replicas=0
```

### Step 2: Delete all etcd PVCs

```bash
for i in 0 1 2; do
  kubectl label pvc data-bulk-konk-etcd-$i -n aggregate \
    k8s.infoblox.com/allow-user-action=enabled --overwrite 2>/dev/null
  kubectl delete pvc data-bulk-konk-etcd-$i -n aggregate 2>/dev/null
done
```

### Step 3: Remove image override from Etcd CR

**Required if CR was previously managed by j180/j191** (has `spec.image` with upstream registry).

```bash
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate --type='json' \
  -p='[{"op":"remove","path":"/spec/image"}]'
```

Without this, the Bitnami template (`/scripts/setup.sh` entrypoint) gets the upstream image which doesn't have that script → CrashLoopBackOff forever.

**How to check if needed:**
```bash
kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.spec.image.registry}' && echo
# If it shows "gcr.io" or "harbor..." → REMOVE IT
# If empty → skip this step
```

### Step 4: Trigger operator reconcile

```bash
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate --type='merge' \
  -p='{"spec":{"statefulset":{"replicaCount":3}}}'
```

> **Note:** The operator may override `replicaCount: 3` back to `1` (from chart defaults or Konk CR values). This is fine — with `replicaCount: 1`, the Bitnami chart bootstraps etcd as a standalone single-member cluster.

### Step 5: Wait for etcd readiness

The Bitnami etcd readiness probe has `initialDelaySeconds: 60`.

```bash
sleep 70
kubectl get pods -n aggregate | grep bulk-konk-etcd
# Should show: bulk-konk-etcd-0   1/1   Running
```

If etcd-0 is still crashing, check:
```bash
kubectl logs bulk-konk-etcd-0 -n aggregate --tail=10
```

- If `/scripts/setup.sh: no such file or directory` → Step 3 wasn't applied; remove image override
- If `env[4].valueFrom: Invalid value` → fix the STS template bug:
  ```bash
  # Find ETCD_NAME index
  kubectl get sts bulk-konk-etcd -n aggregate \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' | grep -n ETCD_NAME
  # Remove valueFrom at that index (0-based), e.g. index 4:
  kubectl patch sts bulk-konk-etcd -n aggregate --type='json' \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/env/4/valueFrom"}]'
  ```
- If `is starting a new election` → PVCs weren't deleted properly; go back to Step 1

### Step 6: Recover apiserver

The apiserver will be in CrashLoopBackOff (lost etcd connection). Delete the pod to clear the backoff:

```bash
kubectl delete pod -n aggregate -l app.kubernetes.io/name=bulk-konk
# Wait for replacement pod
sleep 30
kubectl get pods -n aggregate | grep bulk-konk
```

### Step 7: Verify

```bash
echo "=== All pods ===" && kubectl get pods -n aggregate | grep bulk-konk
echo "=== Etcd CR ===" && kubectl get etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' && echo
echo "=== Konk CR ===" && kubectl get konk.konk.infoblox.com bulk-konk -n aggregate \
  -o jsonpath='{.status.conditions[?(@.type=="Deployed")].reason}' && echo
```

**Expected end state:**

| Component | Image | Status |
|-----------|-------|--------|
| bulk-konk-etcd-0 | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` | 1/1 Running |
| bulk-konk (apiserver) | `k8s.gcr.io/kube-apiserver:v1.25.8` | 1/1 Running |
| bulk-konk-init | `kindest/node:v1.25.8` | 1/1 Running |
| Etcd CR | — | Deployed (UpgradeSuccessful) |
| Konk CR | — | Deployed |

---

## Incident: us-stg-1 (j191→j170) — 2026-06-19

### Timeline

1. Rollback PR merged: `konk-operator-version.txt` → `v0.2.1-138-g8b64bf7-j170`
2. Operator rolled to j170. Etcd CR entered `InstallError` (annotations missing from j191 release) — **this was protective**
3. Upstream etcd pods continued running unmanaged (3/3 healthy, quorum intact)
4. We annotated the Etcd CR (same pattern as Konk CR fix) — **this was a mistake**
5. j170 operator reconciled → deployed Bitnami chart (`etcd-5.3.2`)
6. **Failure Mode 2:** Pod template bug — `ETCD_NAME` has both `value` and `valueFrom` → `FailedCreate`, no pods created
7. All 3 upstream etcd pods deleted by the StatefulSet rolling update
8. Replicas changed from 3 → 1 (Bitnami chart defaults)
9. Attempted manual STS patch to fix `valueFrom` — worked
10. **Failure Mode 3:** Etcd started but entered infinite election loop (stale 3-member membership in PVC from upstream 3.6.x data)
11. Attempted manual env var patches (`ETCD_INITIAL_CLUSTER`, `ETCD_INITIAL_CLUSTER_STATE`) — **wrong approach**, operator kept overwriting them
12. **Final fix:** Deleted all 3 PVCs + patched Etcd CR `spec.statefulset.replicaCount: 3` → operator re-rendered clean → single-member bootstrap succeeded
13. Deleted crashing apiserver pod → all pods recovered

### What went wrong

- **Root mistake:** Annotating the Etcd CR when on j170. The `InstallError` was keeping the old upstream etcd alive and healthy.
- **Wasted time:** Manual STS env var patches (index-based JSON patches are fragile, operator overwrites them)
- **Data loss:** All konk CRDs/resources in etcd were lost (acceptable for staging)

### What we should have done

1. **Not annotated the Etcd CR at all** — leave it in `InstallError`; upstream etcd keeps running
2. If recovery was needed: go straight to PVC deletion + CR patch (skip the manual STS fixes)

---

## Incident: us-dev-5 (j180→j170) — 2026-06-23

### Context

us-dev-5 had already been rolled back from j191→j180 (2026-06-22). During that rollback, we annotated the Etcd CR (safe for j180 — it bundles the upstream etcd chart). Etcd was healthy with upstream `gcr.io/etcd-development/etcd:v3.6.8`.

### Timeline

1. Deployed j170 (`v0.2.1-138-g8b64bf7`) on us-dev-5 (replacing j180)
2. j170 operator started → found Etcd CR with annotations already in place → **immediately reconciled**
3. Operator rendered Bitnami chart template (entrypoint: `/scripts/setup.sh`)
4. But Etcd CR spec still had `spec.image: {registry: gcr.io, repository: etcd-development/etcd, tag: v3.6.8}` from j180
5. **Failure Mode 1:** Upstream image doesn't have `/scripts/setup.sh` → `CrashLoopBackOff`
6. Apiserver lost etcd connection → `CrashLoopBackOff`
7. **Fix:** Scale STS to 0 → delete all 3 PVCs → remove `spec.image` from Etcd CR → patch CR to trigger reconcile
8. Operator re-rendered with Bitnami default image (`bitnami/etcd:3.4.14`) → has `/scripts/setup.sh` → bootstrap succeeded
9. Deleted crashing apiserver pod → all pods recovered

### What went wrong

- **Unavoidable:** The j180 fix had already annotated the Etcd CR. When j170 took over, it reconciled immediately — no way to prevent it.
- **Image override persisted:** j180 set `spec.image` in the Etcd CR to use upstream registry. j170's Bitnami template is incompatible with that image.

### What we should have done

Remove `spec.image` from the Etcd CR BEFORE deploying j170, AND delete PVCs — so when it reconciles, it uses Bitnami's default image with fresh data. (See Approach C below.)

---

## The Prod Rollback Problem (j180→j170)

### Why this matters

If prod is promoted from j170→j180 and something goes wrong, we need to roll back to j170. But j170's Bitnami etcd chart is **fundamentally incompatible** with j180's upstream etcd:

| | j180 (upstream) | j170 (Bitnami) |
|---|---|---|
| Image | `gcr.io/etcd-development/etcd:v3.6.x` | `docker.io/bitnami/etcd:3.4.14` |
| Entrypoint | `/usr/local/bin/etcd` (native binary) | `/scripts/setup.sh` (Bitnami wrapper) |
| Data format | etcd 3.6 WAL + snap | etcd 3.4 (can read 3.6 raft data, but member list incompatible) |
| Cluster size | 3 (from CR spec) | 1 (Bitnami chart overrides) |
| Template | Upstream StatefulSet (no init scripts) | Bitnami StatefulSet (bash scripts, probes via `/scripts/probes.sh`) |

**There is NO way to make j170 manage upstream etcd without data loss.** The Bitnami chart template is a completely different architecture than upstream etcd.

### Why "leave in InstallError" is NOT acceptable for prod

Stripping Etcd CR annotations (Approach B below) keeps upstream etcd running unmanaged. This means:
- ❌ No operator auto-healing if etcd pods crash
- ❌ No cert rotation via operator reconcile
- ❌ No spec changes applied (can't scale, change resources, etc.)
- ❌ Etcd CR shows `InstallError` permanently — confusing for on-call
- ❌ If someone later annotates it (trying to "fix" the error), etcd dies immediately

This is a **temporary workaround** for dev/staging while investigating, NOT a prod solution.

### Viable prod rollback strategies (j180→j170)

---

## Approach A: Don't roll back etcd — only roll back Konk + KonkService

**Concept:** Roll back the konk-operator image to j170, but **prevent it from reconciling the Etcd CR**. Upstream etcd continues running on the j180 image. Only the Konk CR and KonkService CRs are managed by j170.

**How:**
```bash
# BEFORE deploying j170 operator:
# 1. Strip Etcd CR annotations so j170 can't reconcile it
kubectl annotate etcds.konk.infoblox.com bulk-konk-etcd -n aggregate \
  meta.helm.sh/release-name- meta.helm.sh/release-namespace-

# 2. Also strip from STS and headless Service
kubectl annotate sts/bulk-konk-etcd svc/bulk-konk-etcd-headless -n aggregate \
  meta.helm.sh/release-name- meta.helm.sh/release-namespace- 2>/dev/null

# THEN deploy j170
```

**Result:**
- Konk CR: j170 manages it (annotation fix needed, same as always)
- KonkService CRs: j170 manages them
- Etcd CR: `InstallError` — upstream etcd runs unmanaged
- **No data loss**

**Risks:**
- Etcd is unmanaged (no auto-healing)
- Long-term: must either roll forward to j180 again or accept data loss to let j170 manage etcd

**Best for:** Short-term prod rollback while investigating the j180 issue. Roll forward again once fixed.

---

## Approach B: Parameterized PVC migration (j15 operator — BEST for prod)

**Concept:** Instead of rolling back to j170, use a new operator version (`v0.2.1-150-g97950c6-j15`) that has the upstream etcd chart BUT with parameterized `persistence.claimName`. This creates fresh PVCs alongside old ones — zero-downtime migration with instant rollback capability.

```yaml
# Forward migration: j170 → j15 (upstream etcd with fresh PVCs)
konk:
  custom:
    etcd:
      persistence:
        claimName: data-v2
      initialClusterState: "new"
```

**Result:**
- New `data-v2-bulk-konk-etcd-{0,1,2}` PVCs provisioned
- Upstream etcd bootstraps as new cluster on fresh PVCs
- Old `data-bulk-konk-etcd-{0,1,2}` PVCs preserved (can roll back by reverting `claimName`)
- **No data loss**

**Rollback:** Change `persistence.claimName` back to `data` + set `initialClusterState: "existing"` → etcd mounts old PVCs → original data restored.

**Best for:** Production. No data loss, instant rollback, forward-compatible.

---

## Approach C: Accept data loss — clean Bitnami bootstrap (what we did)

**Concept:** Delete PVCs, remove image override, let j170 deploy fresh Bitnami etcd. All konk CRDs/resources in etcd are lost.

```bash
# 1. Remove image override from Etcd CR
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate --type='json' \
  -p='[{"op":"remove","path":"/spec/image"}]'

# 2. Scale down + delete PVCs
kubectl scale sts bulk-konk-etcd -n aggregate --replicas=0
for i in 0 1 2; do
  kubectl label pvc data-bulk-konk-etcd-$i -n aggregate \
    k8s.infoblox.com/allow-user-action=enabled --overwrite 2>/dev/null
  kubectl delete pvc data-bulk-konk-etcd-$i -n aggregate 2>/dev/null
done

# 3. Trigger reconcile
kubectl patch etcds.konk.infoblox.com bulk-konk-etcd -n aggregate --type='merge' \
  -p='{"spec":{"statefulset":{"replicaCount":3}}}'

# 4. Wait 70s, then delete crashing apiserver pod
```

**Result:** Bitnami etcd 3.4.14 running, single-member, fresh data. All previous konk CRD registrations lost (aggregate APIs will 404 until re-registered).

**Best for:** Dev/staging only. NOT acceptable for prod without a data migration strategy.

---

## Approach D: etcd data export/import (theoretical — not tested)

**Concept:** Export all etcd data from upstream 3.6 cluster, deploy j170 with fresh Bitnami etcd, import data into Bitnami 3.4.

```bash
# Export from upstream etcd (while still on j180)
kubectl exec bulk-konk-etcd-0 -n aggregate -- \
  etcdctl snapshot save /tmp/snapshot.db \
  --endpoints=https://localhost:2379 \
  --cert=/etc/etcd/certs/server.crt \
  --key=/etc/etcd/certs/server.key \
  --cacert=/etc/etcd/certs/ca.crt
kubectl cp aggregate/bulk-konk-etcd-0:/tmp/snapshot.db ./etcd-backup.db

# After j170 is deployed with fresh Bitnami etcd:
# Import snapshot into Bitnami etcd
kubectl cp ./etcd-backup.db aggregate/bulk-konk-etcd-0:/tmp/snapshot.db
kubectl exec bulk-konk-etcd-0 -n aggregate -- \
  etcdctl snapshot restore /tmp/snapshot.db --data-dir=/bitnami/etcd/data
```

**Risks:**
- etcd 3.6 snapshot may not be restorable on 3.4 (snapshot format version mismatch)
- Bitnami's `/scripts/setup.sh` may overwrite the restored data on restart
- TLS cert paths differ between upstream and Bitnami images
- **Not tested** — high risk for prod

**Best for:** Only if data preservation is critical AND Approach B (parameterized PVCs) is not available.

---

## Recommendation for Prod

| Priority | Approach | Data loss? | Tested? | Use when |
|----------|----------|-----------|---------|----------|
| 1 | **B: Parameterized PVC (j15)** | No | Testing on us-dev-5 | Forward migration (j170→j15) — preferred path |
| 2 | **A: Unmanaged etcd** | No | Yes (us-stg-1) | Emergency rollback from j180→j170 (short-term) |
| 3 | **C: Clean Bitnami bootstrap** | Yes | Yes (both clusters) | Dev/staging or if data loss is acceptable |
| 4 | **D: Export/import** | No (theory) | No | Last resort if B unavailable and data critical |

**The prod upgrade path should be:**
```
j170 → j15 (with persistence.claimName: data-v2)
```
NOT `j170 → j180`. The j15 operator gives us instant rollback capability via PVC name switching.

If prod must roll back from j15→j170:
- Old PVCs (`data-bulk-konk-etcd-{0,1,2}`) still exist with Bitnami 3.4.14 data
- j170 can manage them natively (same chart, same format)
- Use Approach A (strip annotations) during the transition to verify, then annotate to let j170 reconcile

---

## Prevention

To avoid this issue entirely:
- **Don't promote j180 to prod** — skip j180, go directly from j170 to j15 (which has the PVC migration feature)
- If j180 is already on prod: roll forward to j15, don't roll back to j170
- If j170 rollback is truly needed: use Approach A (unmanaged etcd) for short-term, plan data migration

---

## Anti-patterns (don't do these)

1. **Don't patch the STS env vars manually** — the operator will overwrite on next reconcile. Use CR spec changes instead.
2. **Don't annotate the Etcd CR on j170** (j191→j170 path) — the `InstallError` is protective.
3. **Don't try to make upstream etcd work with j170's Bitnami template** — the chart template fundamentally expects Bitnami's entrypoint scripts.
4. **Don't deploy j170 without checking Etcd CR annotations first** — if annotations exist (from j180 fix), the operator will reconcile immediately and break etcd.
5. **Don't promote j180 to prod without j15's PVC migration feature** — you lose the ability to cleanly roll back.
