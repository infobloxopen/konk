# KONK Kubeconfig Certificate Rotation — Options Analysis

**Date:** 2026-05-19  
**Updated:** 2026-05-19  
**Context:** The distroless Go rewrite of `reconcile-kubeconfig` introduced a regression: kubeconfig now embeds cert data instead of using file references, breaking automatic cert reload.

---

## Scope of This Fix — What It Does and Doesn't Fix

**This is a latent regression fix, NOT the cause of the original smoke test 503 failures.**

| Issue | Caused by | Fixed by |
|-------|-----------|----------|
| Original 503s on `SMOKE-TAG-002` | `makeslice` panic in `tag.go` | [PR #83](https://github.com/Infoblox-CTO/atlas.tagging.aggregateapi/pull/83) — already merged ✅ |
| Cert expiry log noise after 12h | Distroless rewrite (embedded data) | This fix (`fix/kubeconfig-file-refs`) |
| Future cert-related failures | Distroless rewrite | This fix |
| Distroless behavior regression vs prod | Distroless rewrite | This fix |

**Why the original 503s weren't cert-related:**
- Smoke tests use **front-proxy auth** (proxy-client cert), which doesn't depend on the kubeconfig cert
- The kubeconfig cert is only used by **delegated auth** controllers calling back to KONK
- Cert expiry produces `Unauthorized` log noise but doesn't directly cause `503` on API requests
- Production (`8b64bf7`, shell-based) has zero cert errors in 30 days — the bug never affected real users

---

## Root Cause (Discovered 2026-05-19)

**This is a regression introduced by the distroless migration, NOT a pre-existing problem.**

Production (at commit `8b64bf7`, shell-based) has **zero** cert expiry errors in the last 30 days. The issue only manifests in dev environments running the new Go-based `reconcile-kubeconfig`.

### Old approach (shell, production `8b64bf7`) — WORKS:
```bash
kubectl config set-credentials kubernetes-admin \
  --client-certificate tls.crt \
  --client-key tls.key
sed -i 's@ /@ @' $KUBECONFIG_PATH
```
Produces kubeconfig with **file references**:
```yaml
users:
- name: kubernetes-admin
  user:
    client-certificate: tls.crt   # ← relative file path
    client-key: tls.key            # ← relative file path
```

### New approach (Go rewrite) — BROKEN:
```go
kubeconfig.AuthInfos["kubernetes-admin"] = &clientcmdapi.AuthInfo{
    ClientCertificateData: tlsCert,  // ← embedded bytes
    ClientKeyData:         tlsKey,   // ← embedded bytes
}
```
Produces kubeconfig with **embedded data**:
```yaml
users:
- name: kubernetes-admin
  user:
    client-certificate-data: LS0tLS1C...  # ← base64 blob
    client-key-data: LS0tLS1C...          # ← base64 blob
```

### Why This Matters

`k8s.io/client-go` TLS transport behavior:
- **File references** → `dynamicClientCert` → re-reads cert from disk on **every TLS handshake** → always picks up rotated certs
- **Embedded data** → bytes loaded once into memory → **never re-reads** → cert expires after 12h

### The Broken Flow (distroless only)

```
cert-manager → rotates cert every 8h (12h duration, renewBefore: 4h)
    ↓
reconcile-kubeconfig (3 min loop) → detects rotation, updates K8s Secret
    ↓
K8s Secret volume → file updated in pod filesystem (~60-120s kubelet sync)
    ↓
Consumer pod reads kubeconfig with EMBEDDED DATA → cert already in memory
    ↓
After 12h → in-memory cert expires → Unauthorized → 503
```

### The Working Flow (production / after fix)

```
cert-manager → rotates cert every 8h
    ↓
reconcile-kubeconfig → updates K8s Secret (admin.conf + tls.crt + tls.key)
    ↓
K8s Secret volume → files updated in pod filesystem
    ↓
Consumer pod reads kubeconfig with FILE REFS → client-go re-reads tls.crt on each TLS handshake
    ↓
Always gets fresh cert → no expiry → no 503
```

### Current Certificate Config

```yaml
# helm-charts/konk-service/templates/kubeconfig-certificate.yaml
spec:
  duration: 12h        # Total validity
  renewBefore: 4h      # cert-manager triggers renewal at 8h mark
  subject:
    organizations: [system:masters]
  commonName: kubernetes-admin
```

### Affected Consumers

| Deployment | Secret Mounted | Reloads Cert? |
|-----------|----------------|---------------|
| `{fullname}-kubectl-apiservice` | `{fullname}-kubeconfig` | **YES** — re-reads file every 30s in reconcile loop |
| `{fullname}-delete-apiservice` | `{fullname}-kubeconfig` | N/A — short-lived job |
| Application pods (e.g. `tagging-aggregate-api`) | `{fullname}-kubeconfig` | **NO** — cached at startup |

---

## Options

### Option 1: Increase Certificate Duration

**Change:** Set `duration: 8760h` (1 year) and `renewBefore: 720h` (30 days).

**Pros:**
- Simplest change (1-line YAML edit)
- Eliminates the 12h window entirely
- No code changes needed

**Cons:**
- ❌ **Security risk** — a compromised cert remains valid for up to 1 year
- ❌ Violates principle of least privilege (cert grants `system:masters` access)
- ❌ The underlying problem (no reload) is masked, not fixed
- ❌ If cert-manager rotation fails silently, you won't know for a year

**Verdict:** NOT RECOMMENDED — this cert has `system:masters` privileges. Short-lived certs are a security best practice for privileged credentials.

---

### Option 2: Rolling Restart on Cert Rotation (DEFENSE-IN-DEPTH)

**Change:** When `reconcile-kubeconfig` detects cert rotation, patch dependent deployments with a `konk.infoblox.com/cert-checksum` annotation to trigger pod restart.

**Mechanism:**
1. `reconcile-kubeconfig` runs every ~3 min
2. Computes MD5 of `ca.crt + tls.crt + tls.key`
3. If changed (and not first run), lists all deployments in namespace
4. For each deployment that mounts the kubeconfig secret, patches pod template annotation
5. Kubernetes rolling update replaces pods → new pods read fresh cert at startup

**Pros:**
- Keeps short cert duration (good security posture)
- Dynamic discovery — automatically handles new consumers
- Rolling restart means zero downtime (if replicas > 1)
- Already works with existing cert-manager setup
- No changes needed in consumer applications

**Cons:**
- Pod restarts every 8h (when cert-manager renews) — adds churn
- Brief request disruption during pod replacement (mitigated by readiness probes)
- If multiple konk-service instances exist in the namespace, all consumers restart
- Requires RBAC change (`list` + `patch` on deployments)
- 3-minute detection delay (worst case: 3 min with expired cert after rotation)

**RBAC change required:**
```yaml
- apiGroups: ["apps"]
  resources: [deployments]
  verbs: [get, list, patch]  # was: [get]
```

**Implementation:** Done in `cmd/konk-service/reconcile_kubeconfig.go`

**Verdict:** DEFENSE-IN-DEPTH — not the primary fix (see Option 7), but useful as a safety net.

---

### Option 3: Dynamic Certificate Reload in konk-service (Client-Side)

**Change:** Implement a file watcher (fsnotify) or periodic reload in the konk-service apiservice/delete-apiservice commands that re-reads the kubeconfig cert from disk.

**Mechanism:**
- Watch `/etc/kubernetes/admin.conf` for changes (kubelet updates Secret-backed volumes)
- When changed, create a new `rest.Config` with fresh TLS credentials
- Swap the transport in the HTTP client

**Pros:**
- No pod restarts needed
- Instant cert pickup (no 3-min delay)
- No RBAC expansion needed

**Cons:**
- Only fixes konk-service's own processes — does NOT fix third-party consumers (tagging-aggregate-api, etc.)
- Complex implementation: need to handle in-flight requests during transport swap
- `k8s.io/client-go` doesn't have a built-in cert reload mechanism for file-based kubeconfigs
- Still need Option 2 or 4 for application pods

**Verdict:** INSUFFICIENT alone — fixes konk-service internal processes but not the actual affected consumers (application pods).

---

### Option 4: Use `projected` Volume with Auto-Rotation Annotation

**Change:** Have consumers use Kubernetes projected volumes with rotation annotation, and a sidecar or init logic that watches for cert changes and signals the main process.

**Mechanism:**
- Consumer pods declare an annotation like `konk.infoblox.com/restart-on-secret-change: <secret-name>`
- A controller (or the existing reconcile-kubeconfig) watches for this annotation and triggers restarts

**Pros:**
- Opt-in per deployment (not blanket restart of all)
- Consumer controls whether it wants automatic restart

**Cons:**
- More complex than Option 2 (annotation convention + discovery logic)
- Still results in pod restart (same effect as Option 2)
- Requires coordination between chart authors

**Verdict:** Over-engineered — Option 2 already discovers consumers dynamically via volume inspection.

---

### Option 5: Upstream Fix — Dynamic TLS Reload in Consumer Apps

**Change:** Modify consumer applications (tagging-aggregate-api, etc.) to periodically reload the kubeconfig file or use `k8s.io/client-go`'s `NewClientCertificateManager` for on-disk cert rotation.

**Mechanism:**
- Use `transport.TLSConfigFor` with a cert getter function that reads from disk each time
- Or implement a `CertificateManager` that watches the file

**Pros:**
- No pod restarts
- Each app handles its own lifecycle
- Transparent to the cluster

**Cons:**
- Requires changes in every consumer application (tagging, redirect, atcapi, etc.)
- `k8s.io/apiserver` framework doesn't easily support swapping `--authentication-kubeconfig` dynamically
- Significant development effort across multiple teams/repos
- Testing burden: each app must verify hot-reload works

**Verdict:** IDEAL long-term but IMPRACTICAL short-term — requires changes in every consumer.

---

### Option 6: Increase Duration Moderately (24h–72h) + Rollout Restart

**Change:** Increase cert duration to 72h (renewBefore: 24h) AND keep the rollout restart as a safety net.

**Mechanism:**
- Cert rotates every 48h instead of every 8h → fewer restarts
- Rollout restart still catches any pod that misses rotation

**Pros:**
- Fewer pod restarts (every 48h vs every 8h)
- Defense in depth: even if restart fails, cert is valid for 72h
- Moderate security posture (not ideal, but cert is namespace-scoped)

**Cons:**
- Compromised cert valid for 72h (vs 12h currently)
- Still requires the rollout restart code (Option 2)
- More moving parts than pure Option 2

**Verdict:** ACCEPTABLE compromise if the 8h restart churn from Option 2 is problematic.

---

### Option 7: Use File References in Kubeconfig (ROOT CAUSE FIX)

**Change:** In `reconcile_kubeconfig.go`, write the kubeconfig with file path references (`ClientCertificate`, `ClientKey`, `CertificateAuthority`) instead of embedded data (`ClientCertificateData`, `ClientKeyData`, `CertificateAuthorityData`).

**Mechanism:**
- Kubeconfig references `tls.crt`, `tls.key`, `ca.crt` as relative file paths
- Consumer pods mount the Secret at `/etc/kubernetes/` → files resolve to `/etc/kubernetes/tls.crt`, etc.
- `client-go` uses `dynamicClientCert` for file-based certs → re-reads from disk on every TLS handshake
- When kubelet syncs the updated Secret to the pod filesystem, the next TLS handshake picks up the fresh cert

**Code change (5 lines):**
```go
// Before (broken — embedded data):
kubeconfig.Clusters[konkName] = &clientcmdapi.Cluster{
    Server:                   "https://" + konkFQDN + ":6443",
    CertificateAuthorityData: caCert,
}
kubeconfig.AuthInfos["kubernetes-admin"] = &clientcmdapi.AuthInfo{
    ClientCertificateData: tlsCert,
    ClientKeyData:         tlsKey,
}

// After (fixed — file references):
kubeconfig.Clusters[konkName] = &clientcmdapi.Cluster{
    Server:               "https://" + konkFQDN + ":6443",
    CertificateAuthority: "ca.crt",
}
kubeconfig.AuthInfos["kubernetes-admin"] = &clientcmdapi.AuthInfo{
    ClientCertificate: "tls.crt",
    ClientKey:         "tls.key",
}
```

**Pros:**
- ✅ Restores production behavior (matches shell script at `8b64bf7`)
- ✅ Zero pod restarts needed — cert reload is automatic via `client-go`
- ✅ Minimal code change (5 lines)
- ✅ No RBAC changes needed
- ✅ No changes needed in consumer applications
- ✅ Works with existing 12h cert duration
- ✅ Proven in production for years

**Cons:**
- None identified

**Verdict:** ✅ **PRIMARY FIX** — this is the correct solution. Restores the behavior that worked in production for years.

---

## Recommendation

**Primary fix:** Option 7 (file references) — fixes the root cause regression from the distroless migration.

**Optional defense-in-depth:** Option 2 (rollout restart) — catches edge cases where kubelet Secret sync is delayed beyond cert expiry. Not strictly needed but adds resilience.

---

## Implementation Status

| Option | Status | Branch | Files Changed |
|--------|--------|--------|---------------|
| Option 7 (file refs) | ✅ IMPLEMENTED | `fix/kubeconfig-file-refs` | `cmd/konk-service/reconcile_kubeconfig.go` |
| Option 2 (rollout restart) | ✅ IMPLEMENTED | `fix/cert-rotation-rollout-restart` | `cmd/konk-service/reconcile_kubeconfig.go`, `helm-charts/konk-service/templates/kubeconfig-rbac.yaml` |
| Option 6 (increase to 24h) | ⬜ NOT NEEDED | — | — |

**PR Links:**
- Option 7: https://github.com/infobloxopen/konk/pull/new/fix/kubeconfig-file-refs
- Option 2: https://github.com/infobloxopen/konk/pull/new/fix/cert-rotation-rollout-restart

---

## Testing Plan

### For Option 7 (primary fix):
1. Deploy konk-service with file-ref kubeconfig
2. Verify kubeconfig Secret contains `client-certificate: tls.crt` (not `client-certificate-data:`)
3. Wait for cert-manager rotation (or delete Certificate CR to force it)
4. Verify: consumer pods continue working without restart
5. Verify: `kubectl exec <consumer-pod> -- cat /etc/kubernetes/admin.conf` shows file refs
6. Verify: no cert expiry errors in logs after 12h+

### For Option 2 (defense-in-depth, if also deployed):
1. Verify: `reconcile-kubeconfig` logs show "Restarting deployment X"
2. Verify: consumer pods get annotation `konk.infoblox.com/cert-checksum`
3. Verify: pods restart and come up healthy

---

## Post-Merge Verification & Debugging

Use these commands after the fix is deployed to confirm the cert rotation mechanism is working end-to-end.

### Step 1: Verify kubeconfig Secret has file references (not embedded data)

```bash
# Check the actual Secret content
kubectl -n aggregate get secret bulk-konk-konkservice-kubeconfig -o jsonpath='{.data.admin\.conf}' | base64 -d

# Expected output should contain:
#   client-certificate: tls.crt        ✅ FIXED
#   client-key: tls.key                ✅ FIXED
#   certificate-authority: ca.crt      ✅ FIXED
#
# Should NOT contain:
#   client-certificate-data: <base64>  ❌ BROKEN
#   client-key-data: <base64>          ❌ BROKEN
```

### Step 2: Verify the Secret contains all 4 files

```bash
kubectl -n aggregate get secret bulk-konk-konkservice-kubeconfig -o jsonpath='{.data}' | jq 'keys'
# Expected: ["admin.conf", "ca.crt", "tls.crt", "tls.key"]
```

### Step 3: Verify consumer pods see the files

```bash
# Pick a consumer pod (e.g. tagging-aggregate-api)
POD=$(kubectl -n tagging-v2 get pod -l app=tagging-aggregate-api -o jsonpath='{.items[0].metadata.name}')

# List mounted files
kubectl -n tagging-v2 exec $POD -- ls -la /kubeconfig/
# Expected: admin.conf, ca.crt, tls.crt, tls.key

# Show admin.conf content
kubectl -n tagging-v2 exec $POD -- cat /kubeconfig/admin.conf
# Expected: file references, not -data: blobs
```

### Step 4: Verify the on-disk cert is fresh

```bash
# Check cert expiry inside the pod
kubectl -n tagging-v2 exec $POD -- cat /kubeconfig/tls.crt | openssl x509 -noout -dates
# Expected: notAfter should be ~12h in the future

# Compare with cert-manager Certificate resource
kubectl -n aggregate get certificate bulk-konk-konkservice-kubeconfig -o jsonpath='{.status.notAfter}'
```

### Step 5: Force a cert rotation and verify reload

```bash
# Delete the cert-manager Certificate to force rotation
kubectl -n aggregate delete certificate bulk-konk-konkservice-kubeconfig
# cert-manager will recreate it immediately with a new cert

# Watch the cert-manager Secret update
kubectl -n aggregate get secret bulk-konk-konkservice-kubeconfig-cert -w

# Wait ~3 min for reconcile-kubeconfig to pick up and update the consumer Secret
kubectl -n aggregate logs -l app.kubernetes.io/component=kubeconfig --tail=20
# Expected: "Certs changed, updating secret bulk-konk-konkservice-kubeconfig"
```

### Step 6: Verify consumer picks up new cert WITHOUT restart

```bash
# Get pod start time BEFORE rotation
kubectl -n tagging-v2 get pod $POD -o jsonpath='{.status.startTime}'

# After rotation, get cert serial seen by the pod
kubectl -n tagging-v2 exec $POD -- cat /kubeconfig/tls.crt | openssl x509 -noout -serial
# Should match the new cert serial within ~60-120s (kubelet sync)

# Pod start time should be UNCHANGED (no restart needed)
kubectl -n tagging-v2 get pod $POD -o jsonpath='{.status.startTime}'
```

### Step 7: Check for cert expiry errors after 12h+

```bash
# Wait at least 13 hours after deployment
# Then check KONK apiserver logs for cert errors
kubectl -n aggregate logs -l app=bulk-konk --tail=200 | grep -iE "certificate has expired|x509|unable to authenticate"
# Expected: zero matches

# Check consumer pod logs
kubectl -n tagging-v2 logs $POD --tail=200 | grep -iE "certificate|x509|unauthorized"
# Expected: zero new cert errors
```

### Step 8: Compare against production behavior

```bash
# In production (kubectl context to prod), check the same secret
kubectl -n aggregate get secret bulk-konk-konkservice-kubeconfig -o jsonpath='{.data.admin\.conf}' | base64 -d | head -20
# Production should show file refs (matches our fix)
```

### Troubleshooting

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| Secret still has `-data:` blobs | New image not deployed | Check `kubectl get deploy bulk-konk-konkservice-kubeconfig -o yaml \| grep image:` |
| Pod can't find cert files | Mount path mismatch | Verify `volumeMounts.mountPath` matches KUBECONFIG dirname |
| Cert expires despite file refs | Consumer not using client-go transport stack | Check consumer app's cert loading code |
| Reconciler not detecting rotation | MD5 cache stuck | Restart `bulk-konk-konkservice-kubeconfig` pod |
| 5-min reload delay too long | `CertCallbackRefreshDuration` in client-go | Acceptable — it's the upstream default |

### Key Log Patterns

**Healthy (after fix):**
```
reconcile-kubeconfig: Certs changed, updating secret bulk-konk-konkservice-kubeconfig
reconcile-kubeconfig: Certs unchanged, skipping update
```

**Broken (before fix):**
```
E0518 ... reflector.go:158] ... Unauthorized
E0518 ... certificate has expired or is not yet valid: current time ... is after ...
```
