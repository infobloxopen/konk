# Option B — Deploy & Verify Steps

**Date:** 2026-06-22
**Context:** Deploying the etcd PVC migration (Option B — parameterized `claimName`) via DC repo PRs.

---

## What We Did

### 1. Konk repo (`release/upgrade-etcd` branch)

Parameterized the `volumeClaimTemplate` name in `helm-charts/etcd/templates/statefulset.yaml`:

```yaml
# Before (hardcoded)
name: data

# After (3 locations)
name: {{ .Values.persistence.claimName | default "data" }}
```

Built and pushed chart version `v0.2.1-150-g97950c6-j15` to S3 (`s3://infoblox-helm-dev/charts`).

### 2. DC repo PRs

**PR #134529 — us-dev-4** (box-dev):
- `konk-operator-version.txt`: `v0.2.1-138-g8b64bf7-j170` → `v0.2.1-150-g97950c6-j15`
- `bulk-values.yaml` added:
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
  ```

**PR #134537 — us-stg-1** (com-stage):
- `konk-operator-version.txt`: `v0.2.1-138-g8b64bf7-j170` → `v0.2.1-150-g97950c6-j15`
- `bulk-values.yaml` added:
  ```yaml
  konk:
    custom:
      etcd:
        persistence:
          claimName: data-v2
        etcd:
          initialClusterState: "new"
        statefulset:
          replicaCount: 3
        resources:
          limits:
            memory: 4Gi
  ```

> **Note:** Both dev and stage PRs include `replicaCount: 3` and `initialClusterState: "new"` to test the exact prod migration path (prod defaults to 3 replicas).

### 3. Value flow path

```
DC bulk-values.yaml → konk.custom.etcd.persistence.claimName
  → bulk chart templates Konk CR → spec.etcd.persistence.claimName
    → konk chart {{ toYaml .Values.etcd }} → Etcd CR spec.persistence.claimName
      → etcd chart .Values.persistence.claimName → StatefulSet VCT name
```

---

## Verify After Merge + Deploy

Replace `$CTX` with the cluster's kubectl context and `$NS` with `aggregate`.

```bash
CTX=teleport.services.sdp.infoblox.com-us-dev-4
NS=aggregate
```

### Step 1: Confirm new StatefulSet VCT name

```bash
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'
# Expected: data-v2
```

### Step 2: Confirm fresh PVC provisioned

```bash
kubectl --context $CTX get pvc -n $NS | grep bulk-konk-etcd
# Expected:
#   data-v2-bulk-konk-etcd-0   Bound   ...   (NEW — fresh)
#   data-bulk-konk-etcd-0      Bound   ...   (OLD — orphaned, untouched backup)
```

### Step 3: etcd pod running

```bash
kubectl --context $CTX get pods -n $NS | grep bulk-konk-etcd
# Expected: bulk-konk-etcd-0   1/1   Running
# NOT: CrashLoopBackOff
```

### Step 4: etcd healthy

```bash
kubectl --context $CTX exec -n $NS bulk-konk-etcd-0 -- \
  etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key
# Expected: 127.0.0.1:2379 is healthy
```

### Step 5: etcd image is upstream (not Bitnami)

```bash
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: gcr.io/etcd-development/etcd:v3.6.8 (or similar upstream tag)
# NOT: bitnamilegacy/etcd:*
```

### Step 6: bulk-konk (kube-apiserver) running

```bash
kubectl --context $CTX get pods -n $NS | grep -E "bulk-konk-[a-f0-9]"
# Expected: Running 1/1
```

### Step 7: KonkServices re-registered APIServices

```bash
kubectl --context $CTX get konkservices -n $NS
# Expected: all show status Ready/Deployed

kubectl --context $CTX get apiservices 2>/dev/null | grep bulk
# Expected: APIServices present (True availability)
```

### Step 8: Konk CR status

```bash
kubectl --context $CTX get konk -n $NS
# Expected: STATUS = Deployed (not InstallError)
```

### Step 9: Etcd CR status

```bash
kubectl --context $CTX get etcd -n $NS
# Expected: shows the Etcd CR (status may show Deployed or similar)
```

### Step 10: (Optional) Confirm old PVCs still exist as backup

```bash
kubectl --context $CTX get pvc -n $NS | grep "data-bulk-konk-etcd"
# Old data-bulk-konk-etcd-* PVCs should still exist (untouched)
# These are your rollback safety net — do NOT delete yet
```

---

## Troubleshooting

### etcd CrashLoopBackOff with "server has already been initialized"

This means the old PVC was reused (VCT name didn't change). Check:
```bash
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'
```
If it shows `data` instead of `data-v2`, the konk-operator version wasn't upgraded (still using old chart with hardcoded `data`).

### etcd CrashLoopBackOff with "waiting for cluster to be stable"

For multi-replica: `ETCD_INITIAL_CLUSTER_STATE` is set to `existing` but there's no existing cluster. Verify:
```bash
kubectl --context $CTX get sts bulk-konk-etcd -n $NS \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool | grep -A1 INITIAL_CLUSTER_STATE
```
Expected: `"new"` (if multi-replica). If it shows `"existing"`, the `initialClusterState` value didn't propagate — check the Etcd CR spec.

### Konk CR shows InstallError

The konk-operator may need a reconcile trigger:
```bash
kubectl --context $CTX annotate konk bulk-konk -n $NS \
  reconcile-force="$(date +%s)" --overwrite
```

---

## Rollback

Revert the DC PR (remove `persistence.claimName: data-v2` and revert `konk-operator-version.txt`). The StatefulSet will fail to update (VCT is immutable), but since the old `data-*` PVCs still exist, you can manually delete the new STS and let the operator recreate it with the old chart version.

---

## Post-Migration Cleanup (after soak period)

Once verified healthy and stable:

1. **Remove `initialClusterState: "new"`** from bulk-values (staging/prod) so future restarts use `"existing"`
2. **Delete old orphaned PVCs** (the `data-bulk-konk-etcd-*` ones) to free EBS storage
3. **Keep `persistence.claimName: data-v2`** permanently — do NOT revert it

---

## Test Results

### us-dev-4 — 2026-06-22

**PR #134529 merged.** Flux deployed `konk-operator@v0.2.1-150-g97950c6-j15` successfully.

**Blocker encountered:** The `bulk` HelmRelease was blocked by `authz` dependency (not ready), preventing the Konk CR from being updated with new values. Additionally, the Konk CR was in `InstallError` for 451 days due to missing Helm ownership annotations on bulk-konk resources.

**Resolution:**
1. Manually patched the Konk CR with migration values (`persistence.claimName: data-v2`, `statefulset.replicaCount: 3`, `etcd.initialClusterState: "new"`)
2. Applied Helm ownership annotations (`meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`) to all bulk-konk resources (ServiceAccount, Services, Deployments, StatefulSet, Secrets, Certificates, Issuers, ClusterRoles, ClusterRoleBindings, CRDs) — per the known annotation-issue playbook
3. Triggered reconcile on Konk CR and Etcd CR

**Result: ✅ SUCCESS**

| Check | Status | Details |
|-------|--------|---------|
| Konk CR status | ✅ | `InstallSuccessful` |
| Etcd CR status | ✅ | `InstallSuccessful` |
| etcd pods | ✅ | 3/3 Running (1/1 ready) |
| etcd image | ✅ | `harbor.services.sdp.infoblox.com/infobloxcto/etcd:v3.6.8` (upstream, not Bitnami) |
| New PVCs | ✅ | `data-v2-bulk-konk-etcd-{0,1,2}` all Bound (fresh gp3 volumes) |
| Old PVCs | ✅ | `data-bulk-konk-etcd-{0,1,2}` untouched (orphaned backup) |
| etcd cluster | ✅ | 3 members, all `started`, leader elected |
| DB size | ✅ | 283 kB |
| Total keys | ✅ | 177 keys reconstructed |
| Key categories | ✅ | clusterroles (65), clusterrolebindings (43), apiregistration (19), flowschemas (13), prioritylevelconfigs (8), roles (7), rolebindings (7), namespaces (6), services (3), ranges (2), priorityclasses (2), configmaps (1) |
| APIServices | ✅ | `bootstrap.bulk.infoblox.com`, `onprem.bulk.infoblox.com`, `tagging.bulk.infoblox.com` registered |
| KonkServices | ✅ | hostapp, bootstrap-app, ntp, tagging — all present |

**Key observations:**
- Data fully reconstructed by KonkService reconcile loops (~30-60s after apiserver ready)
- us-dev-4 had fewer APIServices/services than us-stg-1 (normal — fewer KonkServices deployed)
- The `initialClusterState: "new"` + `replicaCount: 3` successfully bootstrapped a 3-member cluster from scratch
- Old PVCs (`data-*`) were never touched — instant rollback available

**Prod readiness:** This validates the exact prod migration path (3-replica etcd + fresh data-v2 PVCs + initialClusterState new). The only additional step for prod is the Helm annotation fix (same playbook) if the Konk CR is in `InstallError` there too.

---

### us-com-1 (prod) — Pre-migration baseline

**Date:** 2026-06-23
**Access:** No direct access — state captured via shared screenshot.

**Current state (aggregate namespace):**

| Resource | Details |
|----------|---------|
| bulk-konk-etcd-0 | 1/1 Running, 199d |
| bulk-konk-etcd-1 | 1/1 Running, 199d |
| bulk-konk-etcd-2 | 1/1 Running, 199d |
| bulk-konk (apiserver) | 1/1 Running, 199d |
| bulk-konk-init | 1/1 Running, 199d |
| bulk pods (2x) | 2/2 Running, 20d |
| bulk-cleaner jobs | Completed (recent) |
| bulk-dbapi-dbclaim-exporter | 2/2 Running, 21d |

**PVCs (old — migration targets):**

| PVC | Status | Capacity | StorageClass | Age |
|-----|--------|----------|--------------|-----|
| data-bulk-konk-etcd-0 | Bound | 8Gi | gp3 | 224d |
| data-bulk-konk-etcd-1 | Bound | 8Gi | gp3 | 224d |
| data-bulk-konk-etcd-2 | Bound | 8Gi | gp3 | 224d |

**Why 3 replicas with no DC override on us-com-1?**
- The Konk CR spec in k8s.manifests (`com-prod/us-com-1/bulk/manifest.yaml`) has no etcd overrides — just `scope: cluster`
- No environment-level override exists for `com-prod` (unlike `box-dev` which overrides to 1)
- The **konk chart default** (`helm-charts/konk/values.yaml`) sets `etcd.statefulset.replicaCount: 3` → applies directly

**Why dev/stg clusters run 1 replica by default:**
- `envs/box-dev/bulk-values.yaml` sets `konk.custom.etcd.statefulset.replicaCount: 1` at environment level (comment: "non-HA so no quorum issues on startup")
- `envs/com-stage/eu-stg-1/bulk-values.yaml` explicitly sets `replicaCount: 1`
- us-stg-1 had no cluster-level override → inherited chart default of 3 (but was previously running 1 from older deployment)

**Why `replicaCount: 3` is REQUIRED in dev PR (us-dev-5):**
- Environment-level `envs/box-dev/bulk-values.yaml` sets `replicaCount: 1`
- Cluster-level override to `3` in `envs/box-dev/us-dev-5/bulk-values.yaml` takes precedence
- k8s.manifests PR [#83132](https://github.com/Infoblox-CTO/k8s.manifests/pull/83132) shows the rendered change: `replicaCount: 1` → `replicaCount: 3`
- Without this override, migration would create a single-node etcd (not matching prod's 3-node cluster)

**Key observations:**
- us-com-1 already running 3-replica etcd (from konk chart default — no env-level override in com-prod)
- PVCs use `data` prefix (VCT name = `data`) — confirms migration will create `data-v2-*` PVCs
- All pods healthy and stable (199d uptime)
- PVCs are 224d old — pre-date the pods (pods were likely restarted ~25d after PVC creation)
- Migration PR for prod does NOT need `replicaCount: 3` — no env-level override to fight, chart default already applies
