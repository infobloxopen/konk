# Konk Operator Rollback Plan

## Rollback Versions

| Scenario | From | To | What it reverts |
|----------|------|----|-----------------|
| **Konk-only rollback** | `v0.2.1-155-gd4614c2-j191` | `v0.2.1-147-gaca7e33-j180` | Konk-specific changes only; etcd upgrade remains |
| **Full rollback (incl. etcd)** | `v0.2.1-155-gd4614c2-j191` | `v0.2.1-138-g8b64bf7-j170` | Everything including etcd (Bitnami chart bundled) |

---

## Konk-Only Rollback (j191 → j180)

### What changes

- **konk-operator image:** `v0.2.1-155-gd4614c2` → `v0.2.1-147-gaca7e33`
- **Konk-specific features** introduced in j191 are reverted
- **etcd remains on upstream `v3.6.x`** — the etcd upgrade from j180 is preserved

### What does NOT change

- **etcd image:** stays on upstream etcd (NOT Bitnami) — j180 already includes the etcd upgrade
- **etcd PVC data:** remains in upstream format, no migration needed
- **Etcd CR:** should reconcile normally since j180 operator bundles the upstream etcd chart

### DC PR changes

| File | Change |
|------|--------|
| `envs/<env>/<cluster>/konk-operator-version.txt` | `v0.2.1-155-gd4614c2-j191` → `v0.2.1-147-gaca7e33-j180` |
| `envs/<env>/<cluster>/konk-operator-values.yaml` | Revert any j191-specific values (check diff between j180 and j191 PRs) |

### Expected behavior after rollback

Since j180 already has the upstream etcd chart:
- **Etcd CR:** Should reconcile successfully (no Bitnami/upstream mismatch) — safe to annotate
- **Etcd pods:** Rolling restart triggered by operator reconcile; all 3 come up healthy
- **Konk CR:** Will hit `ReleaseFailed` / `InstallError` due to Helm annotation issue (resources from j191 release missing `meta.helm.sh/release-name`)
- **Init pod:** Chart default is `kindest/node:v1.25.8` (same as j170) — no `RELATED_IMAGE_*` needed
- **Apiserver:** Chart default is `k8s.gcr.io/kube-apiserver:v1.25.8`

**Note:** The `ghcr.io/infobloxopen/konk-provision:v1.25.8` ImagePullBackOff seen immediately after rollback is a **stale image from the j191 Helm release**, not j180's chart default. Once the annotation issue is fixed and the operator reconciles, it renders the correct `kindest/node:v1.25.8` image.

### Potential issues

1. **Konk CR annotation issue (WILL happen)** — The operator can't adopt resources from j191's Helm release. Multiple resources need annotating:

   **Use the fix script:**
   ```bash
   ./scripts/fix-konk-annotations.sh <context> aggregate
   ```
   See [annotation-issue.md](../annotation-issue.md) for details.

   **Resources that needed annotating on us-dev-5:**
   - ServiceAccount `bulk-konk`
   - ClusterRole `bulk-konk-certs-role`
   - ClusterRoleBinding `bulk-konk-certs-rb`
   - Deployment `bulk-konk`, `bulk-konk-init`
   - Service `bulk-konk`, `bulk-konk-etcd-headless`
   - Secret `bulk-konk-imagepullsecret`
   - Certificate `bulk-konk-ingress-client`, `bulk-konk-requestheader-proxy-client`, `bulk-konk-requestheader-self-signed`
   - Issuer `bulk-konk-requestheader`, `bulk-konk-requestheader-self-signed`
   - ClusterIssuer `bulk-konk-kubeadm-ca`
   - Etcd CR `bulk-konk-etcd` (safe for j180 — upstream chart)
   - Space CR `bulk-konk-imagepullsecret`

2. **PKI regeneration → CA mismatch on ALL KonkServices** — Reconciliation triggers `kubeadm init` which regenerates all certs. The etcd/apiserver recover automatically (etcd rolling restart from operator picks up new certs, apiserver reconnects after 1 restart). **But all KonkService kubeconfig secrets retain the OLD CA** → kubectl-apiservice pods get `x509: certificate signed by unknown authority` trying to talk to bulk-konk.

3. **KonkService kubeconfig RBAC (WILL happen)** — The kubeconfig pods detect the CA change and try to update the kubeconfig secrets with the new CA, but the Role is missing the `update` verb. Kyverno silently strips `update` from patched Roles. Fix with supplemental Role+RoleBinding:
   ```bash
   # Create supplemental update Roles for all KonkServices
   for line in $(kubectl get konkservices.konk.infoblox.com -A --no-headers 2>/dev/null | awk '{print $1 "/" $2}'); do
     ns=$(echo "$line" | cut -d/ -f1)
     name=$(echo "$line" | cut -d/ -f2)
     sa="${name}-konk-service"
     cat <<EOF | kubectl apply -f - 2>/dev/null
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: ${name}-konk-service-kubeconfig-update
     namespace: ${ns}
   rules:
   - apiGroups: [""]
     resources: ["secrets"]
     verbs: ["update"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: ${name}-konk-service-kubeconfig-update
     namespace: ${ns}
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: ${name}-konk-service-kubeconfig-update
   subjects:
   - kind: ServiceAccount
     name: ${sa}
     namespace: ${ns}
   EOF
     echo "Created supplemental Role+RoleBinding for $ns/$name"
   done
   ```
   See [us-stg-1 doc](../etcd%20issues/us-stg-1-rollback%20issue%20from%20191%20to%20170.md#konkservice-kubeconfig-pods--12-running-rbac-missing-update-verb) for full details.

4. **Orphan KonkService deployments from j191** — The j191 Helm release created deployments with truncated names (e.g. `dns-config-importexport-apiservice-konk-ser-kubectl-apiservice`). After rollback + reconcile, the chart renders deployments with slightly different (full) names. The old truncated-name deployments persist as orphans pulling `ghcr.io/infobloxopen/konk-service:v1.25.8` (which doesn't exist). These need manual deletion:
   ```bash
   # Find orphan deployments (truncated names with ImagePullBackOff pods)
   kubectl get deploy -A --no-headers | grep konk-ser-kubectl | awk '{print $1, $2}'
   kubectl get deploy -A --no-headers | grep konk-kubectl-apiservice-test | awk '{print $1, $2}'
   kubectl get deploy -A --no-headers | grep konk-s-kubectl | awk '{print $1, $2}'
   # Delete each orphan deployment
   ```

### Verification

```bash
# Operator version
kubectl get deploy konk-operator -n konk -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should contain: v0.2.1-147-gaca7e33

# Konk CR status
kubectl get konk.konk.infoblox.com bulk-konk -n aggregate -o jsonpath='{.status.conditions[0].type}'
# Should be: Deployed

# Etcd healthy
kubectl get po -n aggregate -l app.kubernetes.io/name=etcd
# All pods 1/1 Running

# Init pod running
kubectl get po -n aggregate | grep bulk-konk-init
# 1/1 Running

# Apiserver healthy
kubectl get po -n aggregate | grep 'bulk-konk-[a-f0-9]'
# 1/1 Running
```

---

## Full Rollback Including etcd (j191 → j170)

### ⚠️ DANGER: This rolls back to Bitnami etcd chart

Operator `v0.2.1-138-g8b64bf7-j170` bundles the **Bitnami etcd chart** (`etcd-5.3.2`, `bitnami/etcd:3.4.14`). If etcd PVCs already contain **upstream etcd data** (from the j180/j191 upgrade), the Bitnami image will fail on startup due to data format mismatch.

### When to use j170

- Cluster where the etcd upgrade was **never applied** (PVCs still have Bitnami data)
- Or you are willing to **delete all etcd PVCs** and lose konk CRD data

### What changes

- **konk-operator image:** `v0.2.1-155-gd4614c2` → `v0.2.1-138-g8b64bf7`
- **Etcd chart:** upstream → Bitnami (if operator reconciles the Etcd CR)
- **Etcd image:** `etcd:v3.6.x` → `bitnami/etcd:3.4.14` (if operator reconciles)
- **Apiserver image:** `konk-app` → `kube-apiserver:v1.25.8` (chart default, no `RELATED_IMAGE_*` vars)
- **Provision image:** `konk-provision` → `kindest/node:v1.25.8` (chart default)

### Critical: Etcd CR must NOT be reconciled

If the cluster already ran the upstream etcd upgrade, the Etcd CR **must remain in `InstallError`/`ReleaseFailed`** state. This is protective — it prevents the old operator from deploying the Bitnami chart over upstream data.

**DO NOT** annotate the Etcd CR or fix its Helm annotations. The upstream etcd pods will continue running unmanaged.

### Recovery if Etcd CR is accidentally reconciled

See [etcd-rollback.md](../etcd%20issues/etcd-rollback.md) for the full recovery procedure and [us-stg-1 doc](../etcd%20issues/us-stg-1-rollback%20issue%20from%20191%20to%20170.md) for the original incident.

**This means data loss** — all konk CRDs/resources stored in etcd are gone.

---

## Decision Matrix

| Cluster state | Recommended rollback target |
|---------------|----------------------------|
| etcd upgrade already applied (upstream data in PVCs) | **j180** (konk-only rollback) |
| etcd upgrade NOT applied (Bitnami data in PVCs) | **j170** (full rollback) is safe |
| Need to revert everything + accept data loss | **j170** + delete etcd PVCs |

---

## Clusters

| Cluster | Previous version | Rolled back to | Etcd upgraded? | Status |
|---------|-----------------|----------------|----------------|--------|
| us-dev-5 | j191 → j180 → j170 | j170 | Yes (upstream) | ✅ Complete (2026-06-23) — see [etcd-rollback.md](../etcd%20issues/etcd-rollback.md) |
| us-stg-1 | j191 | j170 | Yes (upstream) | ✅ Complete (2026-06-19) — see [us-stg-1 doc](../etcd%20issues/us-stg-1-rollback%20issue%20from%20191%20to%20170.md) |
| eu-stg-1 | | | | |
| us-dev-2 | | | | |

## us-dev-5 Rollback Results (2026-06-22)

- **PR:** Reverted `konk-operator-version.txt` to `v0.2.1-147-gaca7e33-j180`, deleted `konk-operator-values.yaml`
- **Annotation fix:** ~12 resources annotated across multiple types (no `relatedImages` needed)
- **Etcd CR:** Safely annotated and reconciled (j180 has upstream etcd chart v3.6.8)
- **bulk-konk pods:** All 1/1 Running within 3 minutes of annotation fix

| Component | Image |
|-----------|-------|
| konk-operator | `infoblox/konk:v0.2.1-147-gaca7e33-j180` |
| bulk-konk (apiserver) | `k8s.gcr.io/kube-apiserver:v1.25.8` |
| bulk-konk-init | `kindest/node:v1.25.8` |
| bulk-konk-etcd-{0,1,2} | `gcr.io/etcd-development/etcd:v3.6.8` |

### Issues encountered and resolved (post annotation fix)

**Root cause chain:**
1. Annotation fix → operator reconcile → `kubeadm init` → **new CA generated**
2. KonkService kubeconfig-cert secrets still signed by **old CA** (Certificate CRs deleted by operator)
3. Kubeconfig pods detect no cert change → never update kubeconfig secrets
4. kubectl-apiservice pods use kubeconfig with old CA → `x509: certificate signed by unknown authority`
5. Orphan deployments (truncated names from j191) pull non-existent `ghcr.io/infobloxopen/konk-service:v1.25.8`
6. j180 operator renders `ghcr.io/infobloxopen/konk-service:v1.25.8` for KonkService kubeconfig (bad image from embedded chart)

**Fixes applied (in order):**

1. **Supplemental RBAC Roles** — Created 17 Role+RoleBinding pairs with `update` verb for secrets (Kyverno strips `update` from patched Roles; supplemental Roles with ONLY `["update"]` bypass this)

2. **Deleted 19 orphan deployments** — Truncated-name deployments from j191 pulling non-existent `ghcr.io/infobloxopen/konk-service:v1.25.8`

3. **Rollout undo kubeconfig deployments** — j180 operator rendered kubeconfig deployments with `ghcr.io/infobloxopen/konk-service:v1.25.8` (doesn't exist). Rolled back to previous RS using `harbor.../konk-service:v0.2.1-155-gd4614c2` (j191 Go-based reconciler). All 17 deployments became 1/1 Ready.

4. **Recreated Certificate CRs** — The j191 Certificate CRs for kubeconfig-cert were deleted when the operator reconciled (j180 chart doesn't include them). Created new Certificate CRs pointing to ClusterIssuer `bulk-konk-kubeadm-ca` (which now has the new CA). Cert-manager re-issued all 17 kubeconfig-cert secrets with the new CA before the operator cleaned up the Certificate CRs again.

5. **Rollout restart kubeconfig deployments** — Pods needed restart to mount the renewed kubeconfig-cert secrets. After restart, pods detected the cert change and updated all 17 kubeconfig secrets with the new CA.

6. **Rollout restart kubectl-apiservice deployments** — Restarted to pick up the updated kubeconfig secrets with new CA.

7. **Scale down bad ReplicaSets** — After `rollout undo`, the bad RS (with `ghcr.io/infobloxopen/konk-service:v1.25.8`) still has replicas > 0 and keeps recreating ImagePullBackOff pods. Must scale those RS to 0 or delete the stuck pods AND scale the RS:
   ```bash
   # Find and scale down all RS using the bad image
   for line in $(kubectl get rs -A -o json | python3 -c "
   import json, sys
   data = json.load(sys.stdin)
   for rs in data['items']:
       ns = rs['metadata']['namespace']
       name = rs['metadata']['name']
       replicas = rs['spec'].get('replicas', 0)
       if replicas == 0: continue
       containers = rs['spec']['template']['spec']['containers']
       for c in containers:
           if 'ghcr.io/infobloxopen/konk-service:v1.25.8' in c.get('image', ''):
               print(f'{ns}/{name}')
               break
   "); do
     ns=$(echo "$line" | cut -d/ -f1)
     rs=$(echo "$line" | cut -d/ -f2)
     kubectl scale rs "$rs" -n "$ns" --replicas=0
   done
   ```
   **Note:** Simply deleting the stuck pods is NOT enough — the RS controller will immediately recreate them.

**Status (post fixes 1-6, pre fix 7):**

| Section | Status | Notes |
|---------|--------|-------|
| konk-operator | ✅ PASS | `v0.2.1-147-gaca7e33-j180` |
| Core infrastructure | ✅ PASS | apiserver, init, etcd all healthy |
| Konk CR + Etcd CR | ✅ PASS | Both Deployed/Successful |
| KonkService CRs | ✅ PASS | All 17 report Successful |
| kubeconfig pods | ✅ PASS | All 17 deployments 1/1 Ready |
| kubectl-apiservice pods | ✅ PASS | All 17 deployments 1/1 Ready |
| CA trust chain | ✅ PASS | 17/17 kubeconfig secrets match new CA |
| Deep test (tagging-v2) | ✅ PASS | APIService exists, resources discoverable |
| Stale ImagePullBackOff pods | ❌ FAIL | ~19 pods from bad RS keep respawning (fix #7 needed) |
| kubectl-apiservice-test pods | ⚠️ PARTIAL | 5/18 Ready, 13 at 0/1 (readiness probe — may need time) |

### Retrospective: What we should have done differently

**Unresolved mystery:** The j180 operator (`aca7e33`) chart template for kubeconfig has only ONE container using `kind.image` (`kindest/node:v1.25.8`). Yet the operator rendered deployments with TWO containers — one pulling `ghcr.io/infobloxopen/konk-service:v1.25.8`. This suggests the j180 **operator binary** embeds a different (newer) chart than what's at commit `aca7e33` in the repo. The Docker image may have been built from a branch tip that included the two-container change. This needs investigation.

**Simpler approach (recommended for future rollbacks):**

Instead of the 7-step fix sequence we performed, the optimal order would be:

1. **Fix annotations** (same as we did — unavoidable)
2. **Immediately `rollout undo` all kubeconfig + kubectl-apiservice deployments** — Before the operator reconciles KonkService CRs with the bad image. The old RS has working pods. Do this ASAP after annotation fix.
3. **Recreate Certificate CRs + restart kubeconfig pods** in one pass — Don't wait for the reconciler to detect changes; just restart pods after certs are re-issued.
4. **Scale bad RS to 0** immediately after rollout undo — Don't wait for ImagePullBackOff pods to accumulate.

**What was unnecessary:**
- **Supplemental RBAC Roles (fix #1)** — The rolled-back pods use the j191 Go reconciler which does `update` on secrets. The RBAC fix IS needed for this. However, we applied it BEFORE understanding that the real blocker was the cert not changing (not an RBAC denial). The RBAC fix is still correct and needed, but we spent time on it before diagnosing the actual root cause.

**What was risky:**
- **Fix #4 (Certificate CRs)** relied on cert-manager re-issuing certs BEFORE the operator deleted the Certificate CRs (~20s race window). This worked but is not guaranteed. A safer alternative: manually patch the `kubeconfig-cert` secrets with the new CA cert directly:
  ```bash
  # Get new CA from ClusterIssuer's backing secret
  NEW_CA=$(kubectl get secret bulk-konk-ca -n aggregate -o jsonpath='{.data.tls\.crt}')
  # Patch each kubeconfig-cert secret
  for line in $(kubectl get deploy -A --no-headers | grep 'konk-service-kubeconfig' | awk '{print $1 "/" $2}'); do
    ns=$(echo "$line" | cut -d/ -f1)
    deploy=$(echo "$line" | cut -d/ -f2)
    kubectl patch secret "${deploy}-cert" -n "$ns" -p "{\"data\":{\"ca.crt\":\"$NEW_CA\"}}"
  done
  ```
  This bypasses cert-manager entirely and doesn't depend on timing.

**Ideal runbook order for j191→j180 rollback:**

```
1. DC PR: version → j180, delete values yaml
2. Wait for operator pod to roll
3. Run fix-konk-annotations.sh (includes Etcd CR — safe for j180)
4. Wait for Konk CR → Deployed
5. Immediately rollout undo ALL konk-service deployments (kubeconfig + kubectl-apiservice + test)
6. Scale down ALL bad RS (ghcr.io/infobloxopen/konk-service:v1.25.8)
7. Create supplemental RBAC Roles
8. Patch kubeconfig-cert secrets with new CA (⚠️ PREFERRED — see below)
9. Rollout restart kubeconfig deployments
10. Rollout restart kubectl-apiservice + test deployments
11. Verify: CA match, pods healthy, deep test passes
```

> **⚠️ Step 8 — Why direct patching is preferred for j180:**
> 
> On j180, the operator **deletes Certificate CRs** because its chart doesn't include them.
> Recreating them (approach B) works only if cert-manager re-issues within the ~20s window
> before the operator deletes them again — this is a **race condition** and not guaranteed.
> 
> **Direct patching (approach C) is deterministic and safe:**
> ```bash
> # Get the new CA from the ClusterIssuer's backing secret
> NEW_CA=$(kubectl get secret bulk-konk-ca -n aggregate -o jsonpath='{.data.tls\.crt}')
> # Patch each kubeconfig-cert secret with the new CA
> for line in $(kubectl get deploy -A --no-headers | grep 'konk-service-kubeconfig' | awk '{print $1 "/" $2}'); do
>   ns=$(echo "$line" | cut -d/ -f1)
>   deploy=$(echo "$line" | cut -d/ -f2)
>   kubectl patch secret "${deploy}-cert" -n "$ns" \
>     -p "{\"data\":{\"ca.crt\":\"$NEW_CA\"}}"
> done
> ```
> This bypasses cert-manager entirely. No timing dependency, no race condition.

> **⚠️ Step 7 — RBAC supplemental Roles are the ONLY cluster-side fix:**
> 
> The kubeconfig Go reconciler calls `client.CoreV1().Secrets().Update()` which requires
> the `update` verb. Kyverno silently strips `update` from any Role you patch — the only
> workaround is creating a **separate** Role with ONLY `["update"]` (Kyverno doesn't strip
> single-verb Roles).
> 
> **Long-term fix:** Change the konk-service code to use `Patch()` instead of `Update()` —
> the existing Role already grants `patch`. This eliminates the Kyverno conflict entirely.

> **⚠️ Steps 5+6 — Rollout undo + scale bad RS MUST be done together and immediately:**
> 
> The j180 operator renders `ghcr.io/infobloxopen/konk-service:v1.25.8` which **does not exist**.
> Deleting deployments doesn't help — the operator recreates them with the same bad image.
> `rollout undo` is the **only** viable approach (reverts to old RS with working Harbor image).
> 
> **Critical:** After `rollout undo`, the bad RS still has `replicas > 0` and the RS controller
> will immediately recreate ImagePullBackOff pods. Simply deleting pods is NOT enough.
> You **MUST scale the bad RS to 0** in the same pass:
> ```bash
> # Immediately after rollout undo — scale bad RS to 0
> kubectl get rs -A -o json | python3 -c "
> import json, sys
> data = json.load(sys.stdin)
> for rs in data['items']:
>     ns = rs['metadata']['namespace']
>     name = rs['metadata']['name']
>     if rs['spec'].get('replicas', 0) == 0: continue
>     for c in rs['spec']['template']['spec']['containers']:
>         if 'ghcr.io/infobloxopen/konk-service:v1.25.8' in c.get('image', ''):
>             print(f'{ns} {name}')
>             break
> " | while read ns name; do
>   kubectl scale rs "$name" -n "$ns" --replicas=0
> done
> ```

> **⚠️ Unresolved: Why does j180 render a bad image?**
> 
> The j180 chart at commit `aca7e33` has only ONE container (`kind`) using `kindest/node:v1.25.8`.
> Yet the operator deployed TWO containers with `ghcr.io/infobloxopen/konk-service:v1.25.8`.
> The Docker image `konk:v0.2.1-147-gaca7e33-j180` likely embeds a **different chart version**
> than what's at that Git commit — possibly built from a branch tip after the two-container
> change was merged. **This needs investigation before rolling back other clusters.**

---

### Comparison: us-stg-1 (j170) vs us-dev-5 (j180) — Common Issues & Alternative Approaches

Both rollbacks hit the same core problems (annotation issue, PKI regeneration, CA mismatch, RBAC) but the fixes diverged due to different target versions. This section lists **all possible approaches** for each common issue so we can pick the best one for future rollbacks.

#### Issue 1: Helm Annotation Issue (Konk CR stuck in Irreconcilable)

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. One-by-one annotation** — Fix each resource as the operator reports it in the error message | us-stg-1 | Simple, targeted | Slow (operator reports one at a time; multiple cycles needed) |
| **B. Batch script (`fix-konk-annotations.sh`)** — Annotate all known resource types at once | us-dev-5 | Fast, single pass | Requires pre-built resource list; may miss new resources |
| **C. `--sweep` mode** — API discovery scan to find ALL resources missing annotations | us-dev-5 (available) | Catches everything | Slow (~2 min); API-heavy |

**Recommendation:** Use **B** (batch script) for known clusters. Fall back to **A** if the script misses something.

#### Issue 2: PKI Regeneration → CA Mismatch on KonkService Secrets

After annotation fix → operator reconciles → `kubeadm init` regenerates ALL PKI. KonkService kubeconfig secrets retain the old CA.

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. Wait for cert-manager** — Certificate CRs exist; cert-manager auto-renews kubeconfig-cert secrets with new CA; pods detect change and update kubeconfig secrets | us-stg-1 (j170) | Fully automatic once RBAC is fixed | Only works if Certificate CRs exist (j170/j191 charts include them; j180 does NOT) |
| **B. Recreate Certificate CRs** — Manually create Certificate CRs pointing to `ClusterIssuer: bulk-konk-kubeadm-ca`; cert-manager re-issues; restart pods | us-dev-5 (j180) | Works when CRs are missing | Race condition — operator may delete CRs before cert-manager acts (~20s window) |
| **C. Direct secret patch** — Manually copy new CA from `bulk-konk-ca` secret into each `kubeconfig-cert` secret's `ca.crt` field | Not used (documented as alternative) | No race condition; no cert-manager dependency; deterministic | Manual; doesn't renew the TLS cert itself (only the CA); cert may expire eventually |
| **D. Delete kubeconfig secrets** — Delete the output `*-konk-service-kubeconfig` secrets; reconciler recreates them on next cycle using mounted cert | Not used | Simple | Only works if mounted cert (`kubeconfig-cert`) already has the new CA; otherwise recreates with stale CA |
| **E. Delete kubeconfig-cert secrets + trigger cert-manager** — Delete the cert secrets AND their Certificate CRs; cert-manager recreates both from scratch | Not used | Clean re-issuance | If Certificate CRs don't exist (j180), nothing recreates the secrets |

**Recommendation:** 
- **j170/j191 rollback** (Certificate CRs exist): Use **A** — just fix RBAC and wait.
- **j180 rollback** (Certificate CRs deleted by operator): Use **C** (direct patch) as safest. Fall back to **B** if you need a full cert renewal.

#### Issue 3: RBAC — Missing `update` Verb (Kyverno strips it)

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. Supplemental Role+RoleBinding** — Create separate Role with ONLY `["update"]` verb; bypasses Kyverno policy | Both clusters | Works; Kyverno doesn't strip single-verb Roles | Creates extra RBAC objects per namespace; not operator-managed |
| **B. Patch existing Role** — Add `update` to the chart-rendered Role | Attempted on us-stg-1 (failed) | Would be simpler | Kyverno silently strips it — does NOT work |
| **C. Modify Kyverno policy** — Add exception for konk-service Roles | Not used | Permanent fix | Risky; requires cluster-admin; may have side effects |
| **D. Use `patch` verb instead of `update`** — The Go reconciler calls `Update()` (PUT); switching to `Patch()` (PATCH) would use the already-allowed `patch` verb | Not used (code change required) | Fixes root cause in code | Requires konk-service code change + new operator release |

**Recommendation:** Use **A** (supplemental Roles) as the cluster-side fix. Long-term, fix in code with **D** or update the chart to include `update`.

#### Issue 4: Bad Image in KonkService Deployments

This issue is **j180-specific** — the operator renders `ghcr.io/infobloxopen/konk-service:v1.25.8` which doesn't exist.

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. `rollout undo`** — Revert deployments to previous RS (which has working `harbor.../konk-service:v0.2.1-155`) | us-dev-5 | Fast; old pods already cached; proven image | Old RS has j191 binary (may have different behavior); must also scale bad RS to 0 |
| **B. Delete deployments** — Let operator recreate from scratch | Not used | Clean slate | Operator renders the SAME bad image again — doesn't fix the problem |
| **C. Patch deployment image** — `kubectl set image` to override to a working image (e.g. `harbor.../konk-service:v0.2.1-155` or `harbor.../node:v1.25.8`) | Not used | Direct fix; bypasses operator chart bug | Operator will overwrite on next reconcile |
| **D. Set `RELATED_IMAGE_*` env vars on operator** — Add env vars to operator deployment to override KonkService chart images | Not used | Fixes at operator level; survives reconcile | Requires knowing the correct env var names; may not apply to j180 watches.yaml (which has no `overrideValues` for KonkService) |

**Recommendation:** Use **A** (rollout undo) + scale bad RS to 0. This is the only approach that works immediately without operator cooperation. Long-term fix: upgrade to an operator with the correct embedded chart.

#### Issue 5: Orphan Deployments (Truncated Names from j191)

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. Manual deletion** — Find and `kubectl delete deploy` each orphan | us-dev-5 | Definitive cleanup | Must identify all orphans; could miss some |
| **B. Leave them** — Orphan pods will be in ImagePullBackOff but don't affect healthy pods | Not used | Zero effort | Noise in monitoring; wastes cluster resources; confuses debugging |
| **C. Label-based cleanup** — Find deployments whose RS pods are ALL in ImagePullBackOff | Not used | Automated; less error-prone | Could accidentally target a deployment in temporary image pull failure |

**Recommendation:** Use **A** with pattern matching (`grep konk-ser-kubectl`, `grep konk-s-kubectl`) to find truncated-name orphans.

#### Issue 6: Stale ReplicaSets Keep Recreating ImagePullBackOff Pods

| Approach | Used on | Pros | Cons |
|----------|---------|------|------|
| **A. Scale RS to 0** — Find all RS with bad image and `kubectl scale rs --replicas=0` | us-dev-5 (needed) | Stops pod recreation; preserves RS for forensics | Must identify correct RS; Python/jq needed to filter by image |
| **B. Delete the RS** — `kubectl delete rs` | Not used | Cleaner; no stale RS left | Can't inspect later; deployment controller may recreate RS on next change |
| **C. Rollout undo first, then immediately delete old RS** — Combine rollout undo + RS deletion in one pass | Not used | No lingering bad pods at all | Slightly more complex script |

**Recommendation:** Use **A** (scale to 0) immediately after `rollout undo`. Run both in the same script:
```bash
# After rollout undo, immediately scale down bad RS
kubectl get rs -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for rs in data['items']:
    ns = rs['metadata']['namespace']
    name = rs['metadata']['name']
    if rs['spec'].get('replicas', 0) == 0: continue
    for c in rs['spec']['template']['spec']['containers']:
        if 'ghcr.io/infobloxopen/konk-service:v1.25.8' in c.get('image', ''):
            print(f'{ns} {name}')
            break
" | while read ns name; do
  kubectl scale rs "$name" -n "$ns" --replicas=0
done
```
