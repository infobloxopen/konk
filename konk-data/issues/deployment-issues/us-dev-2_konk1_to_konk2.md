# us-dev-2 — Konk Upgrade (CVE Remediations July 2026)

**Date:** 2026-07-08
**Cluster:** us-dev-2
**Branch:** `release/cve-remediations-july26`
**Status:** IN PROGRESS — awaiting v0.2.1-192 build (RBAC readiness fix)

## Versions

| Step | Version | Notes |
|------|---------|-------|
| Prod baseline | `v0.2.1-155-gd4614c2-j191` | Rolled back to this from j40 |
| First deploy | `v0.2.1-190-g047b508-j40` | Had hooks but imagePullSecrets bugs |
| Rollback target | `v0.2.1-155-gd4614c2-j191` | No hooks — orphan errors already present |
| Second deploy | `v0.2.1-191-g90a7bbf-j41` | kindIs "string" fix for imagePullSecrets |
| Pending | `v0.2.1-192-g8b3e9cd-j42` | RBAC readiness retry in hook |

## Timeline

1. **v0.2.1-190-j40** deployed — introduced pre-install/post-upgrade hooks
2. Rollback to **v0.2.1-155-j191** (prod version) — errors already present (CA mismatch, orphans)
3. **v0.2.1-191-j41** deployed on top of j191 — hook ran once but RBAC not propagated, patched nothing
4. Hook never re-ran on retries (Helm skips hooks when resource conflict check fails before hook stage)
5. **v0.2.1-192** (pending) — adds RBAC readiness loop to hook

## Issues Encountered

### Issue 1: imagePullSecrets Bare Strings (v0.2.1-189)

**Severity:** HIGH — hooks fail to start
**Fixed in:** `a56bb79`

CRs like atcapi pass imagePullSecrets as bare strings (`["infobloxctokey"]`). The hook template rendered invalid Pod spec (`- infobloxctokey` instead of `- name: infobloxctokey`).

**Fix:** Changed template from `toYaml` to `- name: {{ . }}`.

---

### Issue 2: Post-upgrade Hook Same Bug (v0.2.1-190)

**Severity:** HIGH — post-upgrade hook broken
**Fixed in:** `047b508`

Same imagePullSecrets bare-string issue in `konk-service/templates/post-upgrade-hook.yaml` — missed during initial fix.

---

### Issue 3: imagePullSecrets as Objects (v0.2.1-191)

**Severity:** HIGH — hooks fail for NTP/ngp-cp/DDI CRs
**Fixed in:** `90a7bbf`

Some CRs pass imagePullSecrets as objects (`[{"name":"ntp-aggregate-api-imagepullsecret"}]`). Template rendered `map[name:...]` instead of structured YAML.

**Fix:** Added `kindIs "string"` conditional to handle both formats:
```yaml
{{- if kindIs "string" . }}
- name: {{ . }}
{{- else }}
- name: {{ .name }}
{{- end }}
```

Applied to all 3 hook templates (konk, konk-service pre-install, konk-service post-upgrade).

---

### Issue 4: Hook RBAC Propagation Delay (v0.2.1-192)

**Severity:** CRITICAL — hook runs but patches nothing
**Fixed in:** `8b3e9cd`

**Root cause:** The pre-install hook creates ClusterRole/Binding at weight -10 and Job at weight -5. The API server's authorizer cache hasn't propagated the new bindings by the time the Job starts. All `List` calls return 403 Forbidden, logged as warnings, Job exits 0 (success) having patched nothing.

**Evidence:**
- Hook Job ran once (14:33:49), completed (14:34:01), count=1
- Install failed at 14:34:05 (SA can't be imported)
- 18 retries over next 11 min — hook never re-ran

**Fix:** Added retry loop (15 attempts × 2s = 30s max) that verifies RBAC by listing serviceaccounts before scanning.

---

### Issue 5: Hook Doesn't Re-run on Retries

**Severity:** HIGH — single point of failure
**Status:** MITIGATED (not fully resolved)

After the hook's single execution (first reconcile after operator start), subsequent operator retries do NOT re-trigger the hook. Helm's `install` action detects resource conflicts before reaching the pre-install hook stage when no release history exists.

**Mitigation:** RBAC retry ensures the hook succeeds on its one shot. If it fails, operator pod restart is needed.

---

### Issue 6: Bulk-konk Orphan Resources (10+ resources)

**Severity:** CRITICAL — blocks Konk chart install
**Status:** Will be fixed by Issue 4 fix

Orphaned resources (have `app.kubernetes.io/managed-by: Helm` label but no `meta.helm.sh/release-name` annotation):

| Type | Name | Namespace |
|------|------|-----------|
| ServiceAccount | bulk-konk | aggregate |
| Service | bulk-konk | aggregate |
| Secret | bulk-konk-imagepullsecret | aggregate |
| Deployment | bulk-konk | aggregate |
| Deployment | bulk-konk-init | aggregate |
| Certificate | bulk-konk-ingress-client | aggregate |
| Certificate | bulk-konk-requestheader-proxy-client | aggregate |
| Certificate | bulk-konk-requestheader-self-signed | aggregate |
| Issuer | bulk-konk-requestheader | aggregate |
| Issuer | bulk-konk-requestheader-self-signed | aggregate |
| ClusterRole | bulk-konk-certs-role | cluster |
| ClusterRoleBinding | bulk-konk-certs-rb | cluster |

---

### Issue 7: CA Trust Chain Mismatch (17 kubeconfigs)

**Severity:** HIGH — all konk-service pods fail with x509
**Status:** Expected to self-heal on v0.2.1-192 deploy

All 17 kubeconfig secrets have stale CA (`63:F4:01:2B:...`) while bulk-konk CA is now `C5:23:40:15:...`.

**Cause:** CA was rotated/regenerated during rollback cycle. Kubeconfig secrets were never regenerated because bulk-konk install keeps failing (can't fix kubeconfigs without working konk).

**Expected resolution:** New image tag forces kubeconfig pod restarts → pods read current CA from aggregate secret → regenerate kubeconfigs with correct CA.

---

### Issue 8: All 17 konk-service Deployments 0/1 Replicas

**Severity:** HIGH — no APIService connectivity
**Status:** Consequence of Issue 7

Apiservice pods fail readiness probes due to x509 errors when connecting to bulk-konk. Will resolve once kubeconfigs have correct CA.

---

### Issue 9: Unrelated Backend Failures

**Severity:** LOW (not konk operator issues)
**Status:** Pre-existing

- `keys-importexport-f75684549-r5l9r` (ddi): CrashLoopBackOff — backend app issue
- `redirect-apiservice-85cd59b648-7mjqp` (redirect): CrashLoopBackOff — backend app issue
- Tagging API `GET /tags`: HTTP 500 (but POST/DELETE work fine)

---

## Resolution Chain (Expected with v0.2.1-192)

```
1. Deploy v0.2.1-192 → new operator pod starts
2. First reconcile → Helm install bulk-konk → pre-install hook triggers
3. Hook waits for RBAC (new retry loop) → patches 12 orphaned resources
4. Helm adopts resources → install succeeds → bulk-konk Deployed=True
5. New image tag forces ALL konk-service pod restarts
6. Kubeconfig pods regenerate secrets with current CA (C5:23:...)
7. Apiservice pods connect to bulk-konk → healthy → 17/17 available
```

## Commits (release/cve-remediations-july26)

| SHA | Message |
|-----|---------|
| `a56bb79` | fix imagePullSecrets format in pre-install hooks |
| `6fc79bc` | make hooks configurable via values |
| `047b508` | fix imagePullSecrets in post-upgrade hook |
| `90a7bbf` | handle both string and object imagePullSecrets with kindIs |
| `8b3e9cd` | fix: add RBAC readiness check to fix-helm-orphans hook |

## Post-Deploy Verification

```bash
# Verify hook ran successfully
kubectl --context teleport.services.sdp.infoblox.com-us-dev-2 -n aggregate \
  get events --field-selector involvedObject.name=bulk-konk-fix-helm-orphans

# Check bulk-konk status
kubectl --context teleport.services.sdp.infoblox.com-us-dev-2 -n aggregate \
  get konk.konk.infoblox.com bulk-konk -o jsonpath='{.status.conditions}'

# Verify CA mismatch resolved
scripts/e2e-konk-test.sh --cluster us-dev-2 --section 7

# Full test
scripts/e2e-konk-test.sh --cluster us-dev-2
```
