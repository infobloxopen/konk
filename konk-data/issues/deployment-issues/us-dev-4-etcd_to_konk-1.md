# us-dev-4 — etcd Migration + Konk Upgrade (Round 1)

**Date:** 2026-07-02
**Cluster:** us-dev-4
**Status:** RESOLVED

## Versions

| Step | Version | Purpose |
|------|---------|---------|
| etcd upgrade | `v0.2.1-154-g1de007e-j20` | Bitnami→upstream etcd migration (VCT `data`→`data-v2`, 1→3 replicas) |
| konk upgrade 1 | `v0.2.1-155-gd4614c2-j191` | KonkService chart refactor (kind→kubeconfig container) |

## Issues Encountered

### 1. Stale Node Container (Helm Merge Ghost)

**Symptom:** 9 pods with stale `/node:` container images after konk upgrade to j191.

**Root Cause:** Same as [us-stg-1 ghost issue](../stage-stale-ghost-node-container.md) — Helm releases at rev=1 (fresh install) couldn't three-way merge, so strategic merge patch added new `kubeconfig` container without removing old `kind` container.

**Affected Resources:**

| Type | Namespace | Resource |
|------|-----------|----------|
| Deployment | hostapp | hostapp-aggregate-api-infra-konk-service-kubeconfig |
| Deployment | hostapp | hostapp-aggregate-api-infra-konk-service-kubectl-apiservice |
| Deployment | hostapp | hostapp-aggregate-api-infra-konk-service-kubectl-apiservice-test |
| Deployment | ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-service-kubeconfig |
| Deployment | ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-service-kubectl-apiservice |
| Deployment | ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-service-kubectl-apiservice-test |
| Job | hostapp | hostapp-aggregate-api-apiservice-konk-servi-delete-apiservice |
| Job | hostapp | hostapp-aggregate-api-infra-konk-service-delete-apiservice |
| Job | ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-delete-apiservice |
| Job | ntp | ntp-aggregate-api-apiservice-konk-service-delete-apiservice |
| Job | tagging-v2 | tagging-aggregate-api-apiservice-konk-servi-delete-apiservice |

**Fix:** Deleted all 6 ghost deployments and 5 ghost jobs. Operator recreated deployments cleanly with single container within 30s.

```bash
CTX="teleport.services.sdp.infoblox.com-us-dev-4"

# Ghost deployments
kubectl --context $CTX delete deploy -n hostapp \
  hostapp-aggregate-api-infra-konk-service-kubeconfig \
  hostapp-aggregate-api-infra-konk-service-kubectl-apiservice \
  hostapp-aggregate-api-infra-konk-service-kubectl-apiservice-test

kubectl --context $CTX delete deploy -n ngp-cp \
  bootstrap-app-aggregate-api-apiservice-konk-service-kubeconfig \
  bootstrap-app-aggregate-api-apiservice-konk-service-kubectl-apiservice \
  bootstrap-app-aggregate-api-apiservice-konk-service-kubectl-apiservice-test

# Ghost completed jobs
kubectl --context $CTX delete job -n hostapp \
  hostapp-aggregate-api-apiservice-konk-servi-delete-apiservice \
  hostapp-aggregate-api-infra-konk-service-delete-apiservice

kubectl --context $CTX delete job -n ngp-cp \
  bootstrap-app-aggregate-api-apiservice-konk-delete-apiservice

kubectl --context $CTX delete job -n ntp \
  ntp-aggregate-api-apiservice-konk-service-delete-apiservice

kubectl --context $CTX delete job -n tagging-v2 \
  tagging-aggregate-api-apiservice-konk-servi-delete-apiservice
```

### 2. etcd Reset (pre-migration baseline recovery)

**Context:** Cluster had previously been upgraded to j16 (VCT=`data-v2`, 3 replicas) then rolled back to j170. The rollback only changed the operator image — the etcd StatefulSet remained stuck at VCT=`data-v2` (immutable).

**Issues during reset:**

1. **Bulk HelmRelease fail→rollback loop** — Flux tried to reconcile bulk chart with removed etcd values, but STS VCT was immutable. The upgrade timed out and Helm rolled back to the old revision (which still had `data-v2` values).

2. **Stale ConfigMap missing Helm annotations** — After deleting the STS and PVCs, the operator couldn't perform a Helm upgrade because `bulk-konk-etcd-scripts` ConfigMap lacked `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` annotations.

3. **Konk CR not updated by j170 operator** — The j170 operator doesn't propagate removal of `persistence.claimName` from Konk CR to Etcd CR. Required manual patch of both CRs.

**Fix sequence:**

```bash
# 1. Delete STS (immutable VCT can't be changed in-place)
kubectl --context $CTX delete sts bulk-konk-etcd -n aggregate --wait=true

# 2. Delete ALL PVCs (both data-* and data-v2-*)
kubectl --context $CTX delete pvc -n aggregate \
  data-bulk-konk-etcd-0 data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 \
  data-v2-bulk-konk-etcd-0 data-v2-bulk-konk-etcd-1 data-v2-bulk-konk-etcd-2 \
  --ignore-not-found

# 3. Patch Konk CR to remove migration values
kubectl --context $CTX patch konk.konk.infoblox.com bulk-konk -n aggregate \
  --type=merge -p '{"spec":{"etcd":{"persistence":null,"statefulset":{"replicaCount":1},"etcd":null,"recreateStatefulSet":null,"resources":{"limits":{"memory":"4Gi"}}}}}'

# 4. Patch Etcd CR directly (j170 doesn't propagate)
kubectl --context $CTX patch etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  --type=merge -p '{"spec":{"persistence":null,"statefulset":{"replicaCount":1},"etcd":null}}'

# 5. Fix Helm ownership annotations on stale resources
kubectl --context $CTX annotate cm -n aggregate bulk-konk-etcd-scripts \
  meta.helm.sh/release-name=bulk-konk-etcd meta.helm.sh/release-namespace=aggregate --overwrite
kubectl --context $CTX annotate svc -n aggregate bulk-konk-etcd \
  meta.helm.sh/release-name=bulk-konk-etcd meta.helm.sh/release-namespace=aggregate --overwrite
kubectl --context $CTX annotate svc -n aggregate bulk-konk-etcd-headless \
  meta.helm.sh/release-name=bulk-konk-etcd meta.helm.sh/release-namespace=aggregate --overwrite

# 6. Nudge operator to reconcile
kubectl --context $CTX annotate etcd.konk.infoblox.com bulk-konk-etcd -n aggregate \
  konk.infoblox.com/reconcile-nudge="$(date +%s)" --overwrite
```

**Result:** STS recreated with VCT=`data`, 1 replica, Bitnami etcd 3.4.14, healthy with 182 keys.

## Final State (pre-migration baseline)

| Check | Value |
|-------|-------|
| Operator | `v0.2.1-138-g8b64bf7-j170` |
| VCT | `data` |
| Replicas | `1/1` |
| etcd image | `etcd:3.4.14-debian-10-r0` (Bitnami) |
| PVC | single `data-bulk-konk-etcd-0` |
| etcd health | healthy |
| Key count | 182 |
| Konk CR | `UpgradeSuccessful` |
| Ghost pods | 0 |

## Lessons Learned

- Rollback of konk-operator version does NOT revert the etcd StatefulSet (VCT is immutable)
- The j170 operator doesn't remove fields from Etcd CR that were set by j16 — requires manual patching
- Deleting STS+PVCs can leave orphan resources (ConfigMap, Services) without proper Helm annotations
- Always check for stale Helm annotations after manual resource deletion


Script run


── 1. konk-operator (namespace: konk) ──
  [PASS] konk-operator replicas ready
  [PASS] konk-operator pod phase
  [PASS] konk-operator pod Ready condition
  [PASS] konk-operator HelmRelease Ready: Helm upgrade succeeded for release konk/konk-operator.v35 with chart konk-operator@v0.2.1-155-gd4614c2-j191

── 2. Core infrastructure (namespace: aggregate) ──
  [PASS] bulk-konk apiserver replicas ready
  [PASS] bulk-konk-init replicas ready
  [PASS] bulk-konk-etcd replicas ready
  [PASS] bulk-konk service exists (ClusterIP: 10.100.63.136)
  [PASS] bulk-konk has ready endpoints (100.64.29.194)
  [FAIL] aggregate pod in bad state: bulk-6559b55998-6zjjg (CrashLoopBackOff)
  [FAIL] aggregate pod in bad state: bulk-6559b55998-r9vf8 (CrashLoopBackOff)
  [PASS] bulk HelmRelease Ready: Helm upgrade succeeded for release aggregate/bulk.v5922 with chart bulk@v2.5.0-75-g9c9a1de3-j180

── 3. Image version consistency ──
  [INFO] konk-operator          : v0.2.1-155-gd4614c2
  [PASS] bulk-konk (apiserver)  : v0.2.1-155-gd4614c2
  [PASS] bulk-konk (provision)  : v0.2.1-155-gd4614c2
  [PASS] konk-service (4/7 namespaces) : v0.2.1-155-gd4614c2

── 4. Konk CR + Etcd CR status (bulk-konk) ──
  [PASS] Konk CR reason=Successful
  [PASS] Konk CR Deployed=True
  [PASS] Konk CR: no helm InstallError/UpgradeError in status message
  [PASS] Konk ownership check: all 16 bulk-konk resources have Helm annotations
  [PASS] Etcd CR reason=Successful
  [PASS] Etcd CR Deployed=True
  [PASS] Etcd CR 'bulk-konk-etcd': no ReleaseFailed condition
  [PASS] Konk CR 'bulk-konk': no ReleaseFailed condition

── 5. KonkService CRs (all namespaces) ──
  [INFO] fetching KonkService CRs and Deployments...
  [PASS] all 5 KonkService CRs report Successful with no ReleaseFailed and kubeconfig Deployments scaled up
  [PASS] all konk-service Deployments have Helm ownership annotations

── 6. konk-service pods health (all namespaces) ──
  [PASS] all 6 kubectl-apiservice pods are Running and all containers ready
  [PASS] all 5 kubeconfig (reconcile) pods are Running and all containers ready
  [PASS] 7 apiservice-test pods present, none in error state (0/1 Running is normal)
  [PASS] all 5 KonkServices have their required konk-service Deployments running (kubeconfig + kubectl-apiservice)

── 7. CA trust chain (bulk-konk CA vs kubeconfig secrets) ──
  [PASS] bulk-konk CA fingerprint readable
  [PASS] bulk-konk CA certificate is not expired
  [PASS] all 5 kubeconfig secrets have correct bulk-konk CA
  [PASS] all 5 kubeconfig client certs (tls.crt) are valid and not expiring soon

── 8. APIServices registered in konk ──
  [INFO] connected to konk API via port-forward (localhost:39706)
  [PASS] all 4 non-Local APIServices in konk are Available=True
  [PASS] konk serves 4 bulk.infoblox.com API version(s)
  [INFO] trigger-registration enabled: forcing reconcile for an existing APIService
  [INFO] deleted pod hostapp/hostapp-aggregate-api-apiservice-konk-s-kubectl-apiservicex2z2x; waiting for deployment/hostapp-aggregate-api-apiservice-konk-s-kubectl-apiservice-test rollout
  [PASS] trigger reconcile: deployment/hostapp-aggregate-api-apiservice-konk-s-kubectl-apiservice-test restarted cleanly — all APIServices already registered, no re-apply needed
  [INFO] deleting konk APIService v1alpha1.bootstrap.bulk.infoblox.com to trigger re-registration ...
  [PASS] APIService v1alpha1.bootstrap.bulk.infoblox.com re-registered by konk-service after deletion (state: ngp-cp/bootstrap-app-aggregate-api-apiservice)

── 9. Deep test: tagging-v2 namespace ──
  [PASS] KonkService tagging-v2/tagging-aggregate-api-apiservice deployed
  [PASS] tagging-v2 kubectl-apiservice pod ready (1/1)
  [PASS] tagging-v2 kubectl-apiservice pod: 0 restarts
  [PASS] tagging-v2 kubeconfig CA matches bulk-konk
  [FAIL] tagging-v2 kubectl-apiservice logs contain TLS/x509 errors
         2026/07/02 11:30:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
         2026/07/02 11:31:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
         2026/07/02 11:32:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
  [WARN] tagging-v2 kubectl-apiservice: no recent reconciliation log entry
  [FAIL] tagging-v2 konk-service pod: 50 konk connectivity error(s) in recent logs
         2026/07/02 11:01:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
         2026/07/02 11:02:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
         2026/07/02 11:03:44 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
  [PASS] tagging-v2 TLS server secret 'tagging-aggregate-api-apiservice-konk-service-server': has tls.crt + tls.key
  [PASS] all 4 APIService backend endpoints have ready addresses (no 503 risk)

── 10. Bulk (atlas.bulk) integration with konk ──
  [FAIL] bulk deployment replicas ready (expected: '2', got: '0')
  [FAIL] bulk pod not fully ready (1/2)
  [PASS] konk apiserver /healthz returns 'ok' (via port-forward)
  [PASS] bulk-konk proxy-client secret exists (keys: ca.crt tls.crt tls.key)
  [PASS] bulk --konk.host points to konk apiserver: bulk-konk.aggregate:6443
  [PASS] bulk pod logs: no errors in last 50 lines
  [PASS] bulk-konk apiserver logs: no 'certificate has expired' rejections in last 2 min

── 11. konk-operator log health ──
  [PASS] konk-operator: no errors in last 100 log lines
  [PASS] konk-operator: release 'bulk-konk' — no 'Release failed' errors
  [PASS] konk-operator: release 'bulk-konk-etcd' — no 'Release failed' errors
  [PASS] bulk-konk (aggregate)                                   —  deployed   — updated 2026-07-02 11:47:09
  [PASS] bulk-konk-etcd (aggregate)                              —  deployed   — updated 2026-07-02 11:47:11
  [PASS] hostapp-aggregate-api-apiservice (hostapp)              —  deployed   — updated 2026-07-02 09:53:58
  [PASS] hostapp-aggregate-api-infra (hostapp)                   —  deployed   — updated 2026-07-02 09:53:07
  [PASS] bootstrap-app-aggregate-api-apiservice (ngp-cp)         —  deployed   — updated 2026-07-02 11:46:51
  [PASS] ntp-aggregate-api-apiservice (ntp)                      —  deployed   — updated 2026-07-02 09:53:57
  [PASS] tagging-aggregate-api-apiservice (tagging-v2)           —  deployed   — updated 2026-07-02 09:53:57

── 12. cert-manager CA integration ──
  [PASS] cert-manager Issuer bulk-konk-requestheader: Ready=True

── 13. Konk API deep test (query resources inside konk) ──
  [INFO] using konk API via port-forward for deep queries
  [WARN] konk api-resources missing group: tagging.bulk.infoblox.com (service may not be deployed)
  [WARN] konk api-resources missing group: dnsconfig.bulk.infoblox.com (service may not be deployed)
  [WARN] konk api-resources missing group: dnsdata.bulk.infoblox.com (service may not be deployed)
  [PASS] konk: tagging API reachable (response: error: the server doesn't have a resource type "tags")
  [PASS] konk: tagging values API reachable
  [PASS] konk resource type 'hosts' registered (group: Host)
  [PASS] konk apiserver /livez returns 'ok'

── 14. External API integration (tagging + bulk via CSP) ──
  [SKIP] secret tagging-v2/tagging-v2-k6-smoke-test-credentials not found on this cluster — skipping external API tests (use --token TOKEN)

── 15. Konk APIService backend health ──
  [PASS] KonkService hostapp/hostapp-aggregate-api-apiservice: backend 'hostapp-aggregate-api-apiservice' has 1 ready pod(s)
  [PASS] KonkService hostapp/hostapp-aggregate-api-infra: backend 'hostapp-aggregate-api-apiservice' has 1 ready pod(s)
  [PASS] KonkService ngp-cp/bootstrap-app-aggregate-api-apiservice: backend 'bootstrap-app-aggregate-api-apiservice' has 1 ready pod(s)
  [PASS] KonkService ntp/ntp-aggregate-api-apiservice: backend 'ntp-aggregate-api-apiservice' has 1 ready pod(s)
  [PASS] KonkService tagging-v2/tagging-aggregate-api-apiservice: backend 'tagging-aggregate-api-apiservice' has 1 ready pod(s)
  [INFO] 5 backend pod(s) checked across all KonkService APIService endpoints
── 16. Stale node containers (Helm merge ghost detection) ──
  [FAIL] 9 pod(s) still have stale /node: container images (ghost from Helm adopt/merge)
  [WARN]   hostapp/hostapp-aggregate-api-apiservice-konk-servi-delete-apiserv8kh7h
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-service-kubeconfig-65d789sc7bn
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-service-kubectl-apiservicf6lct
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-service-kubectl-apiservicwf6jz
  [WARN]   ngp-cp/bootstrap-app-aggregate-api-apiservice-konk-service-kubeco8n2m7
  [INFO]   ... and 4 more

  [INFO] Fix: delete the Helm release secret + deployment, let the operator re-create cleanly:
  [INFO]   kubectl delete secret -n <ns> sh.helm.release.v1.<release>.v1
  [INFO]   kubectl delete deploy -n <ns> <deployment-name>
