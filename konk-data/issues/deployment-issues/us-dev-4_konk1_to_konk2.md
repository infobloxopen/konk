# us-dev-4 — Konk Upgrade 1 → Konk Upgrade 2

**Date:** 2026-07-02
**Cluster:** us-dev-4
**Status:** RESOLVED (2026-07-07) — awaiting v0.2.1-186+ build for bulk-konk Konk CR fix

## Versions

| From | To | Current |
|------|-----|--------|
| `v0.2.1-155-gd4614c2-j191` (konk 1) | `v0.2.1-165-ga70951a-j3` (konk 2) | `v0.2.1-185-gea83580-j31` (konk 4 — pre-install hook) |

## Pre-Upgrade State

- etcd: Bitnami 3.4.14, VCT=`data`, 1 replica, healthy
- Ghost containers: resolved (see [us-dev-4-etcd_to_konk-1.md](us-dev-4-etcd_to_konk-1.md))
- Konk CR: `UpgradeSuccessful`

## Changes in v0.2.1-165-ga70951a-j3



## Deployment Steps

1. Update `envs/box-dev/us-dev-4/konk-operator-version.txt` → `v0.2.1-165-ga70951a-j3`
2. Create DC PR
3. Merge and monitor

## Post-Upgrade Checks

- [ ] Operator pod running with new image
- [ ] Konk CR status: `UpgradeSuccessful`
- [ ] All KonkService pods healthy (single container, no ghosts)
- [ ] etcd healthy
- [ ] e2e-konk-test.sh passes all sections

## Issues Encountered

### Issue 1: CA Trust Chain Mismatch (Section 7, 9)

**Severity:** HIGH — breaks konk-service connectivity

All 5 kubeconfig secrets have a CA fingerprint (`28:E1:F5:1F:...`) that doesn't match the current bulk-konk CA (`1A:37:AE:5B:...`). This causes TLS x509 errors:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Affected namespaces:** hostapp, ngp-cp, ntp, tagging-v2 (all kubeconfig secrets)

**Likely cause:** The bulk-konk CA was regenerated (possibly during the etcd reset/migration) but the kubeconfig secrets still reference the old CA.

---

### Issue 2: Ghost konk-service Containers (Section 17)

**Severity:** MEDIUM — pods running but with extra container from Helm merge

4 kubeconfig pods have a ghost `/konk-service:` container (same Helm strategic merge issue as `/node:` ghosts but with the new image):

| Namespace | Pod |
|-----------|-----|
| hostapp | hostapp-aggregate-api-apiservice-konk-service-kubeconfig |
| hostapp | hostapp-aggregate-api-infra-konk-service-kubeconfig |
| ntp | ntp-aggregate-api-apiservice-konk-service-kubeconfig |
| tagging-v2 | tagging-aggregate-api-apiservice-konk-service-kubeconfig |

Additionally:
- `aggregate/bulk-konk` has ghost `/konk-app:` image (expected `/kube-apiserver:v1.25.8`)
- `aggregate/bulk-konk-init` has ghost `/konk-provision:` image (expected `/node:v1.25.8`)

**Fix:** Delete affected deployments; operator recreates cleanly.

---

### Issue 3: Bulk (atlas.bulk) CrashLoopBackOff (Section 2, 10)

**Severity:** HIGH — bulk service down

2 bulk pods in CrashLoopBackOff, 0/2 replicas ready. ~~Likely caused by Issue 1 (CA mismatch — bulk can't connect to konk apiserver).~~

**Update (2026-07-06):** NOT a konk issue. After the konk CA fix, bulk no longer fails on TLS — it now crashes on `context deadline exceeded` connecting to Kafka schema registry (`ib-kafka-schema-registry.ib-kafka:8081`). This is a cluster-specific infrastructure dependency issue unrelated to konk. Ignoring.

---

### Issue 4: Missing Helm Ownership Annotations (Section 4, 5)

**Severity:** LOW — will cause `cannot be imported` errors on next reconcile

- 6/16 bulk-konk resources missing `meta.helm.sh` annotations (secrets: apiserver-cert, ca, etcd-ca, etcd-cert, imagepullsecret, kubeconfig)
- 10 konk-service Deployments missing `meta.helm.sh/release-name` annotation

---

### Issue 5: konk-service Image Version Mismatch (Section 3)

**Severity:** LOW — 4/7 namespaces have version mismatch

konk-service pods not yet updated to match operator version `v0.2.1-165-ga70951a`. Likely resolves after ghost container fix + reconcile.

---

### Issue 6: Konk API Inaccessible (Section 8, 13)

**Severity:** MEDIUM — can't query resources inside konk

Port-forward TLS handshake fails. Caused by Issue 1 (CA mismatch).

### Issue 7: Stale KonkService Deployments — Orphaned Name Patterns (Section 5)

**Severity:** MEDIUM — 10 stale deployments running with old naming convention, missing Helm annotations

The konk-service chart renamed deployments (truncated names in a prior PR). The operator created new deployments with shorter names but old longer-named deployments remain unmanaged (orphaned).

| Namespace | Stale Deployments |
|-----------|-------------------|
| hostapp | `hostapp-aggregate-api-apiservice-konk-s-kubectl-apiservice-test`, `hostapp-aggregate-api-apiservice-konk-servi-kubectl-apiservice` |
| hostapp | `hostapp-aggregate-api-infra-konk-servic-kubectl-apiservice-test`, `hostapp-aggregate-api-infra-konk-service-kubectl-apiservice` |
| ngp-cp | `bootstrap-app-aggregate-api-apiservice-konk-kubectl-apiservice`, `bootstrap-app-aggregate-api-apiservice-kubectl-apiservice-test` |
| ntp | `ntp-aggregate-api-apiservice-konk-servi-kubectl-apiservice-test`, `ntp-aggregate-api-apiservice-konk-service-kubectl-apiservice` |
| tagging-v2 | `tagging-aggregate-api-apiservice-konk-s-kubectl-apiservice-test`, `tagging-aggregate-api-apiservice-konk-servi-kubectl-apiservice` |

**Fix:** Run cleanup script with `--execute`:
```bash
/Users/rsatal/Library/CloudStorage/OneDrive-InfobloxInc/Documents/Issues/konk/scripts/cleanup-stale-konkservice-deployments.sh \
  --context teleport.services.sdp.infoblox.com-us-dev-4 --execute
```

**Update (2026-07-06):** Root cause identified — the previous post-upgrade hook detected stale deployments by missing `meta.helm.sh/release-name` annotations, but these old-name deployments DO have annotations (Helm created them). Fixed in `da118c2` — the hook now detects stale deployments by checking if the name matches the current chart's `FULLNAME_PREFIX`. Any deployment whose name doesn't start with the expected prefix is deleted. Will take effect on next operator reconcile (upgrade from v1→v2).

---

## Resolution Priority

1. **Fix CA mismatch** (Issue 1) — root cause of Issues 3, 6
2. **Delete ghost deployments** (Issue 2) — operator recreates cleanly
3. **Delete stale orphaned deployments** (Issue 7) — cleanup script
4. **Fix Helm annotations** (Issue 4) — prevent future reconcile failures
5. Issues 5, 6 should self-resolve after 1-2

## Resolution (2026-07-07)

| Issue | Status | Fix |
|-------|--------|-----|
| 1. CA mismatch | ✅ Resolved | cert-manager auto-renewed with correct CA after 12h cert expiry. kubeconfig now uses file refs (#624) so future CA rotations are transparent. |
| 2. Ghost containers | ✅ Resolved | Post-upgrade hook (`6f313aa`) deletes ghost deployments. Confirmed clean single-container pods. |
| 3. Bulk CrashLoop | ⚠️ Not konk | Kafka schema registry unreachable — cluster infra issue, not konk. |
| 4. Helm annotations (KonkService) | ✅ Resolved | Pre-install hook (`ea83580`) automatically patches orphaned resources before Helm install. Confirmed working on `hostapp-aggregate-api-apiservice` which was stuck in InstallError. |
| 4b. Helm annotations (Konk CR) | ⏳ Pending next build | Pre-install hook for Konk chart added in `66174fb`. Needs next image build to deploy. Currently `bulk-konk` SA missing annotations → InstallError. |
| 5. Image mismatch | ✅ Resolved (konk-service) | All 5 KonkService pods on v0.2.1-185-gea83580. bulk-konk still on v0.2.1-155 pending Issue 4b. |
| 6. Konk API access | ✅ Resolved | Konk apiserver /healthz returns 'ok'. APIServices available. |
| 7. Stale deployments | ✅ Resolved | Post-upgrade hook with FULLNAME_PREFIX detection cleaned all stale deployments. Section 18 confirms "no stale KonkService Deployments found". |

**Key commits:**
- `da118c2` — post-upgrade hook detects stale deployments by FULLNAME_PREFIX instead of missing annotations
- `30df9aa` — hook fires on `post-install,post-upgrade` (removes `Release.IsUpgrade` guard)
- `4bc9b16` — reconcile-kubeconfig restarts dependent deployments on cert rotation
- `ea83580` — **pre-install hook for konk-service chart** — patches orphaned resources automatically
- `66174fb` — **pre-install hook for konk chart** — same fix for Konk CR (bulk-konk), adds cluster-scoped scanning

## Why v0.2.1-185 Fixed KonkService But NOT bulk-konk

The pre-install hook in `ea83580` was added only to the **konk-service chart** (`helm-charts/konk-service/`). This chart manages KonkService CRs (per-namespace apiservice deployments). When the operator reconciles a KonkService CR, it renders the konk-service chart which now includes the pre-install hook → hook runs → patches annotations → Helm install succeeds.

However, the **Konk CR** (`bulk-konk`) is managed by the **konk chart** (`helm-charts/konk/`), which is a completely separate Helm chart. The konk chart did NOT have the hook, so:

1. Operator reconciles `bulk-konk` Konk CR → uses konk chart
2. Konk chart has no pre-install hook → Helm attempts install directly
3. ServiceAccount `bulk-konk` exists without `meta.helm.sh` annotations
4. Helm refuses to adopt → InstallError persists

The fix in `66174fb` adds the same pre-install hook pattern to the konk chart, with additional handling for:
- Cluster-scoped resources (ClusterRoles, ClusterRoleBindings, ClusterIssuers) — bulk-konk uses `scope: cluster`
- Additional resource types specific to the konk chart (Services, Secrets, StatefulSets, Etcd CRs, HPAs)



## e2e Results

### v0.2.1-185-gea83580-j31 (2026-07-07)

```
Passed:   56
Failed:   11
Warnings: 9
Skipped:  3
```

**Remaining failures:**
- `bulk-konk` Konk CR: `InstallError` (SA missing annotations) — **fixed in `66174fb`, awaiting next build**
- `bulk-konk-etcd`: `release: already exists` — related to Konk CR failure
- `bulk` pods CrashLoopBackOff — Kafka dependency, not konk
- 5 KonkService missing `kubectl-apiservice` deployment — **test false positive** (pods are running per section 6, this is a naming check issue in the test)
- bulk-konk images still v0.2.1-155 — blocked by Konk CR InstallError

**What's fixed vs July 2:**
- Section 5 (KonkService CRs): 15→0 failures (all 5 CRs Successful, all annotations correct)
- Section 7 (CA trust): 5→0 failures (all kubeconfig CAs match)
- Section 17 (ghost containers): 6→0 failures (all cleaned by post-upgrade hook)
- Section 18 (stale deployments): 10→0 (all cleaned by FULLNAME_PREFIX detection)

### v0.2.1-165-ga70951a-j3 (2026-07-02, initial upgrade)

<details>
<summary>Original e2e output (click to expand)</summary>

```
  Date (UTC):   2026-07-02 12:07:43 UTC
  Date (IST):   2026-07-02 17:37:43 IST
  Sample NS:    tagging-v2
  Flags:        skip-bulk=false skip-exec=false skip-ca=false skip-trigger-registration=false debug=false


── 1. konk-operator (namespace: konk) ──
  [PASS] konk-operator replicas ready
  [PASS] konk-operator pod phase
  [PASS] konk-operator pod Ready condition
  [PASS] konk-operator HelmRelease Ready: Helm upgrade succeeded for release konk/konk-operator.v36 with chart konk-operator@v0.2.1-165-ga70951a-j3

── 2. Core infrastructure (namespace: aggregate) ──
  [PASS] bulk-konk apiserver replicas ready
  [PASS] bulk-konk-init replicas ready
  [PASS] bulk-konk-etcd replicas ready
  [PASS] bulk-konk service exists (ClusterIP: 10.100.82.45)
  [PASS] bulk-konk has ready endpoints (100.64.52.83)
  [FAIL] aggregate pod in bad state: bulk-6559b55998-6zjjg (CrashLoopBackOff)
  [FAIL] aggregate pod in bad state: bulk-6559b55998-r9vf8 (CrashLoopBackOff)
  [PASS] bulk HelmRelease Ready: Helm upgrade succeeded for release aggregate/bulk.v5922 with chart bulk@v2.5.0-75-g9c9a1de3-j180

── 3. Image version consistency ──
  [INFO] konk-operator          : v0.2.1-165-ga70951a
  [PASS] bulk-konk (apiserver)  : v0.2.1-165-ga70951a
  [PASS] bulk-konk (provision)  : v0.2.1-165-ga70951a
  [WARN] konk-service (4/7 namespaces) : 4/4 namespace(s) have version mismatch

── 4. Konk CR + Etcd CR status (bulk-konk) ──
  [PASS] Konk CR reason=Successful
  [PASS] Konk CR Deployed=True
  [PASS] Konk CR: no helm InstallError/UpgradeError in status message
  [FAIL] Konk ownership check: 6/16 bulk-konk resources missing meta.helm.sh ownership annotations
       [WARN]   secret/bulk-konk-apiserver-cert
       [WARN]   secret/bulk-konk-ca
       [WARN]   secret/bulk-konk-etcd-ca
       [WARN]   secret/bulk-konk-etcd-cert
       [WARN]   secret/bulk-konk-imagepullsecret
       [WARN]   secret/bulk-konk-kubeconfig
       [WARN]   
  [PASS] Etcd CR reason=Successful
  [PASS] Etcd CR Deployed=True
  [PASS] Etcd CR 'bulk-konk-etcd': no ReleaseFailed condition
  [PASS] Konk CR 'bulk-konk': no ReleaseFailed condition

── 5. KonkService CRs (all namespaces) ──
  [INFO] fetching KonkService CRs and Deployments...
  [PASS] all 5 KonkService CRs report Successful with no ReleaseFailed and kubeconfig Deployments scaled up
  [FAIL] 10 konk-service Deployment(s) missing meta.helm.sh/release-name annotation (will cause 'cannot be imported' on next reconcile)
  [WARN]   hostapp/hostapp-aggregate-api-apiservice-konk-s-kubectl-apiservice-test
  [WARN]   hostapp/hostapp-aggregate-api-apiservice-konk-servi-kubectl-apiservice
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-servic-kubectl-apiservice-test
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-service-kubectl-apiservice
  [WARN]   ngp-cp/bootstrap-app-aggregate-api-apiservice-konk-kubectl-apiservice
  [INFO]   ... and 5 more

── 6. konk-service pods health (all namespaces) ──
  [PASS] all 10 kubectl-apiservice pods are Running and all containers ready
  [PASS] all 5 kubeconfig (reconcile) pods are Running and all containers ready
  [PASS] 10 apiservice-test pods present, none in error state (0/1 Running is normal)
  [PASS] all 5 KonkServices have their required konk-service Deployments running (kubeconfig + kubectl-apiservice)

── 7. CA trust chain (bulk-konk CA vs kubeconfig secrets) ──
  [PASS] bulk-konk CA fingerprint readable
  [PASS] bulk-konk CA certificate is not expired
  [FAIL] CA MISMATCH: hostapp/hostapp-aggregate-api-apiservice-konk-service-kubeconfig (got: 28:E1:F5:1F:21:9E:5B:3B:EC:E0:...)
  [FAIL] CA MISMATCH: hostapp/hostapp-aggregate-api-infra-konk-service-kubeconfig (got: 28:E1:F5:1F:21:9E:5B:3B:EC:E0:...)
  [FAIL] CA MISMATCH: ngp-cp/bootstrap-app-aggregate-api-apiservice-konk-service-kubeconfig (got: 28:E1:F5:1F:21:9E:5B:3B:EC:E0:...)
  [FAIL] CA MISMATCH: ntp/ntp-aggregate-api-apiservice-konk-service-kubeconfig (got: 28:E1:F5:1F:21:9E:5B:3B:EC:E0:...)
  [FAIL] CA MISMATCH: tagging-v2/tagging-aggregate-api-apiservice-konk-service-kubeconfig (got: 28:E1:F5:1F:21:9E:5B:3B:EC:E0:...)
  [INFO] CA chain: 0 match, 5 mismatch, 0 missing
  [PASS] all 5 kubeconfig client certs (tls.crt) are valid and not expiring soon

── 8. APIServices registered in konk ──
  [WARN] port-forward established but konk API not reachable (TLS handshake or auth failed)
  [WARN] no healthy konk API access available for API queries (no kubeconfig secret found or port-forward failed)
  [INFO] Ensure a kubeconfig secret exists: kubectl get secrets -A | grep konk-service-kubeconfig

── 9. Deep test: tagging-v2 namespace ──
  [PASS] KonkService tagging-v2/tagging-aggregate-api-apiservice deployed
  [PASS] tagging-v2 kubectl-apiservice pod ready (1/1)
  [PASS] tagging-v2 kubectl-apiservice pod: 0 restarts
  [FAIL] tagging-v2 kubeconfig CA matches bulk-konk (expected: '1A:37:AE:5B:41:E1:15:F7:FB:2D:5F:A4:59:C3:66:74:3E:C7:FA:87:6D:6C:18:8B:1F:F0:31:9F:8D:19:72:69', got: '28:E1:F5:1F:21:9E:5B:3B:EC:E0:33:F8:D6:E8:54:F6:48:37:3E:59:D9:5A:4E:6E:A6:DE:C3:81:37:6F:4A:C4')
  [FAIL] tagging-v2 kubectl-apiservice logs contain TLS/x509 errors
         2026/07/02 12:05:13 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 16s)
         2026/07/02 12:05:29 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 32s)
         2026/07/02 12:06:01 client.go:201: Retrying after error: applying Namespace /tagging-v2: Patch "https://bulk-konk.aggregate.svc:6443/api/v1/namespaces/tagging-v2?fieldManager=konk-service&force=true": tls: failed to verify certificate: x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "kubernetes") (delay 1m0s)
  [PASS] tagging-v2 kubectl-apiservice: APIService reconciliation succeeded
  [PASS] tagging-v2 konk-service pod: 2 successful APIService apply(s) in recent logs
  [PASS] tagging-v2 TLS server secret 'tagging-aggregate-api-apiservice-konk-service-server': has tls.crt + tls.key
  [PASS] all 4 APIService backend endpoints have ready addresses (no 503 risk)

── 10. Bulk (atlas.bulk) integration with konk ──
  [FAIL] bulk deployment replicas ready (expected: '2', got: '0')
  [WARN] no Running bulk pod found
  [PASS] bulk-konk proxy-client secret exists (keys: ca.crt tls.crt tls.key)
  [PASS] bulk --konk.host points to konk apiserver: bulk-konk.aggregate:6443
  [PASS] bulk-konk apiserver logs: no 'certificate has expired' rejections in last 2 min

── 11. konk-operator log health ──
  [PASS] konk-operator: no errors in last 100 log lines
  [PASS] konk-operator: release 'bulk-konk' — no 'Release failed' errors
  [PASS] konk-operator: release 'bulk-konk-etcd' — no 'Release failed' errors
  [PASS] bulk-konk (aggregate)                                   —  deployed   — updated 2026-07-02 12:04:34
  [PASS] bulk-konk-etcd (aggregate)                              —  deployed   — updated 2026-07-02 12:04:35
  [PASS] hostapp-aggregate-api-apiservice (hostapp)              —  deployed   — updated 2026-07-02 12:04:31
  [PASS] hostapp-aggregate-api-infra (hostapp)                   —  deployed   — updated 2026-07-02 12:04:26
  [PASS] bootstrap-app-aggregate-api-apiservice (ngp-cp)         —  deployed   — updated 2026-07-02 12:04:32
  [PASS] ntp-aggregate-api-apiservice (ntp)                      —  deployed   — updated 2026-07-02 12:04:30
  [PASS] tagging-aggregate-api-apiservice (tagging-v2)           —  deployed   — updated 2026-07-02 12:04:32

── 12. cert-manager CA integration ──
  [PASS] cert-manager Issuer bulk-konk-requestheader: Ready=True

── 13. Konk API deep test (query resources inside konk) ──
  [WARN] no konk API access available for deep test (no kubeconfig secret or port-forward failed)

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
  [PASS] no pods running stale node container images

── 17. Stale konk-service container image (ghost detection) ──
  [FAIL] 4 pod(s) have ghost konk-service container (Helm strategic merge leftover)
  [WARN]   hostapp/hostapp-aggregate-api-apiservice-konk-service-kubeconfig-8jxjzd  ready=true
  [WARN]   hostapp/hostapp-aggregate-api-infra-konk-service-kubeconfig-dc6f4bx64mt  ready=true
  [WARN]   ntp/ntp-aggregate-api-apiservice-konk-service-kubeconfig-6f7d5zrn5b  ready=true
  [WARN]   tagging-v2/tagging-aggregate-api-apiservice-konk-service-kubeconfig-5wdpc8  ready=true

  [INFO] Expected: only /node:v1.25.8 container
  [INFO] Found:    ghost /konk-service:<operator-version> container from Helm merge
  [INFO] Fix: delete the deployment (operator will recreate with correct single container):
  [INFO]   kubectl delete deploy -n <ns> <deployment-name>
  [FAIL] 1 pod(s) have ghost /konk-app: image in aggregate (expected /kube-apiserver:v1.25.8)
  [WARN]   aggregate/bulk-konk-b9d64f976-fjp4z  ready=true

  [INFO] Expected: /kube-apiserver:v1.25.8
  [INFO] Found:    ghost /konk-app:<operator-version> from Helm merge
  [INFO] Fix: kubectl delete deploy -n aggregate <deployment-name>
  [FAIL] 1 pod(s) have ghost /konk-provision: image in aggregate (expected /node:v1.25.8)
  [WARN]   aggregate/bulk-konk-init-d9559459-m8b5f  ready=true

  [INFO] Expected: /node:v1.25.8
  [INFO] Found:    ghost /konk-provision:<operator-version> from Helm merge
  [INFO] Fix: kubectl delete deploy -n aggregate <deployment-name>

================================================================
 Results
================================================================
  Passed:   47
  Failed:   15
  Warnings: 5
  Skipped:  1

END-TO-END VALIDATION FAILED — 15 check(s) failed. Review failures above.
```

</details>
