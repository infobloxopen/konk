# us-dev-2 — Konk v0.2.1-187 Deployment Issues

**Date:** 2026-07-08  
**Cluster:** us-dev-2  
**Operator version:** v0.2.1-187-g3bdbf21-j35  
**Context:** `teleport.services.sdp.infoblox.com-us-dev-2`

---

## Summary

Deployed konk operator v0.2.1-187 (with pre-install/pre-upgrade hooks for Helm orphan annotation fix). The hook has a bug that causes **4 out of 17 KonkService CRs** to fail on upgrade.

### Overall CR Status

| CRD | Status |
|-----|--------|
| Konk (`aggregate/bulk-konk`) | ✅ InstallSuccessful |
| Etcd (`aggregate/bulk-konk-etcd`) | ✅ UpgradeSuccessful |
| KonkService (13/17) | ✅ Successful (Install or Upgrade) |
| KonkService (4/17) | ❌ ReleaseFailed (UpgradeError) |

---

## Issue 1: Pre-upgrade hook fails — imagePullSecrets format bug

### Symptom

```
pre-upgrade hooks failed: warning: Hook pre-upgrade konk-service/templates/pre-install-hook.yaml failed: 1 error occurred:
  * Job in version "v1" cannot be handled as a Job: json: cannot unmarshal string into Go struct field PodSpec.spec.template.spec.imagePullSecrets of type v1.LocalObjectReference
```

### Root Cause

The KonkService CRs pass `imagePullSecrets` as a **list of bare strings**:
```yaml
spec:
  imagePullSecrets:
    - infobloxctokey
```

The hook template used `toYaml` which rendered:
```yaml
imagePullSecrets:
  - infobloxctokey
```

But Kubernetes expects:
```yaml
imagePullSecrets:
  - name: infobloxctokey
```

### Affected CRs (all use bare string format)

| Namespace | KonkService | imagePullSecrets value |
|-----------|------------|----------------------|
| atcapi | atcapi-apiservice | `["infobloxctokey"]` |
| atcapi | atcapi-apiservice-v2 | `["infobloxctokey"]` |
| endpoints | endpoints-api-service-apiservice | `["infobloxctokey"]` |
| redirect | redirect-apiservice | `["infobloxctokey"]` |

### NOT affected (correct object format)

| Namespace | KonkService | imagePullSecrets value |
|-----------|------------|----------------------|
| ddi | dns-config-importexport-apiservice | `[{"name":"dns-config-infobloxctokey"}]` |
| ddi | dns-data-importexport-apiservice | `[{"name":"dns-data-infobloxctokey"}]` |
| ddi | ipam-importexport-apiservice | `[{"name":"ipam-infobloxctokey"}]` |
| ngp-cp | bootstrap-app-aggregate-api-apiservice | `[{"name":"bootstrap-app-aggregate-api-imagepullsecret"}]` |
| ntp | ntp-aggregate-api-apiservice | `[{"name":"ntp-aggregate-api-imagepullsecret"}]` |

### Fix

Commit `a56bb79` — changed hook templates from `toYaml` to `range` with `- name: {{ . }}`:
```yaml
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
```

Fixed in both `konk-service` and `konk` chart hooks. The `etcd` chart already had the correct pattern via its `etcd.imagePullSecrets` helper.

---

## Issue 2: Operator stuck in retry loop after hook failure

### Symptom

170 reconciler errors in 2 minutes. Three distinct error messages:

1. `upgrade failed; rollback required`
2. `rollback failed: no Deployment with the name "<old-name>-kubectl-apiservice" found`
3. `failed to get candidate release: another operation (install/upgrade/rollback) is in progress`

### Root Cause

1. Initial upgrade attempt failed (hook bug above)
2. Helm recorded a failed upgrade → operator tries to rollback
3. Rollback references old Deployment names from a **previous chart version** that no longer exist (e.g., `atcapi-apiservice-v2-konk-service-kubectl-apiservice`)
4. Since rollback fails, condition stays `ReleaseFailed`, operator retries indefinitely

### Release Secret State

| CR | Secrets | Notes |
|----|---------|-------|
| atcapi-apiservice | v3 (2026-06-12) | Only good release, no failed secrets created |
| atcapi-apiservice-v2 | v2 (2026-06-12), v3 (2026-07-08) | v3 is failed upgrade |
| endpoints-api-service-apiservice | v8 (2026-06-12) | Only good release |
| redirect-apiservice | v3 (2026-06-12), v4, v5 (2026-07-08) | v4/v5 are failed |

### Expected Resolution

Once the fixed image (v0.2.1-188+) is deployed:
- Hook will succeed (imagePullSecrets rendered correctly)
- `enableFailureRollbacks` should clean failed release secrets
- Operator will retry upgrade successfully

If CRs remain stuck after deploying the fix, manually deleting the failed release secrets (v3/v4/v5 created on 2026-07-08) should unblock them.

---

## Issue 3: Grafana dashboard processing error

```
Warning ProcessingError grafanadashboard/konk-operator: error creating dashboard, expected status 200 but got 500
```

Non-blocking — Grafana API returned 500 when trying to create/update the konk-operator dashboard. Likely a transient Grafana issue.

---

## Issue 4: Readiness probe failures on konk-service pods

Multiple pods in `atcapi` show readiness probe failures:
```
Readiness probe failed: cat: /tmp/healthy: No such file or directory
Readiness probe errored: rpc error: code = Unknown desc = failed to exec in container: container is in CONTAINER_EXITED state
```

These are the `kubectl-apiservice` pods (test and apiservice reconciler). They're likely failing because the upgrade itself didn't complete — the pods are from the previous version (v0.2.1-155) and may be cycling due to the failed upgrade state.

---

## Cluster-wide noise (unrelated to konk)

- `FailedMount` — ConfigMap/Secret cache timeouts on various pods (kube-proxy, fluentd, asset-insight-engine)
- `TerminationGracePeriodExpiring` — Node `ip-172-19-204-215.ec2.internal` being drained (dated 2026-06-10)
- `FailedToRetrieveImagePullSecret` — Multiple namespaces (authz, spire-server, debug-teleport, ddi) — pre-existing issue unrelated to this deployment
- `TopologyAwareHintsDisabled` — iq-evaluator service
- Readiness timeouts in `ddi` namespace — context deadline exceeded (network/load issue)

---

## Next Steps

1. **Build and deploy v0.2.1-188** with the imagePullSecrets fix (commit `a56bb79`)
2. Monitor the 4 failing CRs — they should self-heal once the fixed hook doesn't fail
3. If still stuck, delete failed release secrets manually:
   - `atcapi/sh.helm.release.v1.atcapi-apiservice-v2.v3`
   - `redirect/sh.helm.release.v1.redirect-apiservice.v4`
   - `redirect/sh.helm.release.v1.redirect-apiservice.v5`
