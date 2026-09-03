# Konk Issues Index

Catalog of known konk-related issues encountered across clusters. Each entry links to its detailed investigation doc.

---

## 1. x509 CA Mismatch After etcd Migration

**Severity:** High — all KonkService pods fail  
**Trigger:** Fresh etcd bootstrap (e.g. claimName migration) causes CA rotation  
**Symptom:** `kubectl-apiservice` pods `0/1` with `x509: certificate signed by unknown authority`  
**Root cause:** cert-manager-issued `kubeconfig-cert` secrets still embed the old CA after bulk-konk CA rotates  
**Fix:** Delete stale kubeconfig-cert secrets → cert-manager re-issues → restart pods  
**Docs:**
- [x509_issue-us-dev-5.md](./Client-cert-issue/x509_issue-us-dev-5.md) — full investigation & timeline
- [fix-x509-issues.sh](./x509-issue.md/fix-x509-issues.sh) — automated fix script
**Clusters hit:** us-dev-5 (2026-06-23)

---

## 2. Kubeconfig Client Certificate Expiry (12h) — 503s

**Severity:** Medium — individual aggregate-api pods lose auth after 12h  
**Trigger:** Time (12h cert TTL expires, pod doesn't hot-reload)  
**Symptom:** `503 stream error: INTERNAL_ERROR` from KONK on list operations; `Unauthorized` in logs  
**Root cause:** `k8s.io/apiserver` caches the client TLS cert in memory and does NOT reload from disk when the secret rotates  
**Fix (workaround):** Rollout restart the affected aggregate-api pod  
**Fix (permanent):** Implement cert-checksum annotation in konk-service to trigger rollout on cert rotation (pending)  
**Docs:** [kubeconfig-cert-expiry-503.md](./x509-issue.md/kubeconfig-cert-expiry-503.md)  
**Clusters hit:** us-dev-2 (2026-05-18)

---

## 3. Helm Ownership Annotation Missing — Reconcile Failure

**Severity:** Medium — operator can't reconcile Konk/KonkService CRs  
**Trigger:** Helm release secret lost (operator restart during install, storage corruption, fresh etcd wipe)  
**Symptom:** Operator logs: `"exists and cannot be imported into the current release: invalid ownership metadata; missing key meta.helm.sh/release-name"`  
**Root cause:** Helm 3 requires `meta.helm.sh/release-name` + `release-namespace` annotations on all managed resources. When release history is lost, existing resources become "orphaned" and Helm refuses to adopt them  
**Fix:** Annotate orphaned resources with correct Helm ownership, then trigger reconcile  
**Docs:** [annotation-issue.md](./annotation-issue.md)  
**Clusters hit:** us-dev-5 (2026-06-12, 2026-06-23)

---

## 4. Cascading APIService Dependency During Mass Restart

**Severity:** Low — self-resolving, but extends recovery time  
**Trigger:** Mass restart of `kubectl-apiservice` pods (e.g. after CA fix)  
**Symptom:** Pods remain `0/1` with `unable to retrieve the complete list of server APIs: <api-group>: the server is currently unable to handle the request`  
**Root cause:** `kubectl apply` performs full API discovery against bulk-konk before applying. If ANY aggregated APIService backend is unavailable (e.g. `atcapi-v2` not started yet), discovery fails → ALL other kubectl-apiservice pods fail, even though their own service is healthy  
**Fix:** Self-resolves once the blocking APIService comes up (next retry, 60s loop). No manual intervention needed — just wait  
**Potential improvement:** Use `--server-side=true` in konk-service, or skip discovery for unrelated API groups  
**Clusters hit:** us-dev-5 (2026-06-23)

---

## 5. KonkService Test-Pod ImagePullBackOff

**Severity:** Low — only affects test pods, not production traffic  
**Trigger:** Stale or missing image reference in KonkService `-test` Deployment  
**Symptom:** `kubectl-apiservice-test` pods stuck in `ImagePullBackOff`; e.g. `dns-config-importexport-apiservice-v2-k-kubectl-apiservicexhlpp 0/1 ImagePullBackOff`  
**Root cause:** The KonkService chart deploys a `-test` Deployment alongside the main one. If the image tag is outdated or the image was never pushed to the registry (Harbor), the test pod can't pull it  
**Fix:** Update the image reference in the KonkService CR or the chart values, OR delete the stuck test pod (it will be recreated by the Deployment with the same image — won't self-heal until image is available)  
**Clusters hit:** us-dev-5 (2026-06-23, `ddi/dns-config-importexport-apiservice-v2`)

---

## 6. KonkService ImagePullBackOff After Operator Downgrade

**Severity:** High — all konk-service pods fail, aggregate APIs unavailable  
**Trigger:** Downgrading konk-operator to a version whose `watches.yaml` doesn't map `RELATED_IMAGE_KIND*` env vars, leaving stale image references from the previous operator  
**Symptom:** `konk-service-kubeconfig` and `kubectl-apiservice` pods in `ImagePullBackOff` pulling `ghcr.io/infobloxopen/konk-service:v1.25.8` (non-existent tag — falls back to `.Chart.AppVersion` which is a Kubernetes version)  
**Root cause:** Operator pod missing `RELATED_IMAGE_KIND` / `RELATED_IMAGE_KIND_REPO` env vars; Helm 3-way merge doesn't update existing deployments; chart default `kindest/node:v1.25.8` is stale  
**Fix:** Manually patch all affected deployments to use `harbor.services.sdp.infoblox.com/infobloxcto/konk-service:<correct-tag>`  
**Docs:** [konk-service-imagepullbackoff-us-dev-5.md](./konk-service-imagepullbackoff-us-dev-5.md)  
**Clusters hit:** us-dev-5 (2026-06-24)

---

## 7. KonkService Kubeconfig Permission Denied (Container UID Race)

**Severity:** Medium — kubeconfig pods 1/2 Running, aggregate APIs lose auth refresh  
**Trigger:** Fresh pod creation where `kind` container (root) wins the startup race and writes `/etc/kubernetes/admin.conf` as `root:root 0600` before `kubeconfig` container (UID 65532) can  
**Symptom:** `kubeconfig` container logs: `Error writing kubeconfig: open /etc/kubernetes/admin.conf: permission denied`  
**Root cause:** Both `kind` and `kubeconfig` are regular sidecars sharing an emptyDir. `kubectl config` creates files with mode 0600. If root writes first, non-root can't access it. Race-dependent — works on some clusters, fails on others with identical images  
**Fix:** Patch `kind` container with `securityContext: {runAsUser: 65532, runAsGroup: 65532}` so both containers write as the same UID  
**Docs:** [konk-service-kubeconfig-permission-denied-us-dev-5.md](./konk-service-kubeconfig-permission-denied-us-dev-5.md)  
**Clusters hit:** us-dev-5 (2026-06-24)

---

## Quick Reference

| # | Issue | Auto-resolves? | Fix script? |
|---|-------|---------------|-------------|
| 1 | x509 CA mismatch | No | [fix-x509-issues.sh](./x509-issue.md/fix-x509-issues.sh) |
| 2 | 12h cert expiry | No (needs restart) | — |
| 3 | Helm annotation | No | [annotation-issue.md § Nuclear option](./annotation-issue.md) |
| 4 | Cascading APIService | Yes (~2-5 min) | — |
| 5 | Test-pod ImagePull | No (needs image fix) | — |
| 6 | ImagePullBackOff (downgrade) | No | [konk-service-imagepullbackoff-us-dev-5.md](./konk-service-imagepullbackoff-us-dev-5.md) |
| 7 | Kubeconfig permission denied | No | [konk-service-kubeconfig-permission-denied-us-dev-5.md](./konk-service-kubeconfig-permission-denied-us-dev-5.md) |