# x509 Certificate Authority Mismatch — us-dev-5 (2026-06-23)

## Problem

After the etcd `claimName` migration (PR #634, j16 upgrade), all `kubectl-apiservice` pods across KonkService namespaces failed with TLS errors:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
(possibly because of "crypto/rsa: verification error" while trying to verify
candidate authority certificate "kubernetes")
```

Pods were `0/1 Running` — they could start but couldn't connect to `bulk-konk.aggregate.svc:6443`.

## Root Cause

The etcd migration caused a **CA certificate rotation** that wasn't propagated to KonkService kubeconfigs:

1. **Pre-upgrade hook** deleted the etcd StatefulSet → fresh bootstrap (`initialClusterState: new`) → empty etcd
2. `konk-provision` init container ran `kubeadm init` on the fresh cluster → **new CA generated** and stored in `bulk-konk-ca` secret (aggregate namespace)
3. cert-manager's `bulk-konk-kubeadm-ca` ClusterIssuer references the `bulk-konk-ca` secret → it now signs certs with the **new CA**
4. The `bulk-konk` apiserver serving cert was re-issued with the new CA
5. **BUT** — the `kubeconfig-cert` secrets in each KonkService namespace (tagging-v2, ddi, endpoints, etc.) were issued by cert-manager **before** the CA rotation and still embedded the **old CA** in their `ca.crt` field
6. The `reconcile-kubeconfig` pods compared the old cert (mounted via volume) against what was in the kubeconfig secret → saw "unchanged" → never updated

### Certificate chain

```
ClusterIssuer: bulk-konk-kubeadm-ca
  └─ reads CA from: secret/bulk-konk-ca (aggregate ns) ← NEW CA after migration
       └─ issues: Certificate "...-konk-service-kubeconfig" (per namespace)
            └─ creates: secret "...-kubeconfig-cert" with ca.crt + tls.crt/key ← STALE (old CA)
                 └─ mounted by: reconcile-kubeconfig pod
                      └─ writes: kubeconfig secret (with embedded ca.crt) ← STALE
                           └─ mounted by: kubectl-apiservice pod → TLS FAIL
```

### CA fingerprints

| Source | Fingerprint (SHA-256) |
|--------|----------------------|
| `bulk-konk-ca` secret (new, post-migration) | `C3:1B:E2:E8:50:55:DA:B8:EF:73:44:78:CE:11:1C:6B:45:AE:93:5F:43:27:DC:38:AD:FE:7B:BF:40:54:0B:BD` |
| `kubeconfig-cert` secrets (stale, pre-migration) | `C6:4E:A2:C5:BA:F8:E0:66:89:CE:36:CD:70:38:C8:9C:72:BD:AE:01:B6:F4:3B:EB:06:F3:C6:33:CF:94:2E:5E` |

### Why automatic reconciliation didn't work

The `reconcile-kubeconfig` pod:
- Mounts the `kubeconfig-cert` secret as a volume (`/tmp/certs`)
- Compares the mounted cert against what's in the kubeconfig secret
- If unchanged → skips update ("Certs unchanged, skipping update")

The cert in the secret WAS unchanged (cert-manager hadn't re-issued it) — so the reconciler correctly determined nothing changed. The problem was upstream: cert-manager didn't re-issue the certificate because the Certificate CR wasn't marked for renewal and the cert wasn't expired.

## Impact

- **All KonkService pods** (kubectl-apiservice) across all namespaces: `0/1 Running`
- Services couldn't register their APIServices inside konk
- Bulk import/export operations that depend on aggregate APIs would fail
- Working pods that started before the migration (already connected) were unaffected

### Affected namespaces

tagging-v2, endpoints, hostapp, ntp, ddi, atcapi, redirect, ngp-cp

## Detection

Detected via e2e-konk-test.sh **Section 9** (Deep test):

```
── 9. Deep test: tagging-v2 namespace ──
  [FAIL] tagging-v2 kubeconfig CA matches bulk-konk
         (expected: 'C3:1B:E2:E8:...', got: 'C6:4E:A2:C5:...')
  [FAIL] tagging-v2 kubectl-apiservice logs contain TLS/x509 errors
```

Also detectable via **Section 7** (CA trust chain) and operator logs showing no errors (operator was fine — this was a cert-manager / KonkService layer issue).

## Fix

### Step 1: Delete stale kubeconfig-cert secrets (force cert-manager re-issue)

```bash
CTX=us-dev-5
for ns in tagging-v2 endpoints hostapp ntp ddi atcapi redirect ngp-cp; do
  kubectl --context $CTX get certificate.cert-manager.io -n $ns --no-headers 2>/dev/null \
    | grep kubeconfig | awk '{print $1}' | while read -r cert; do
      secret=$(kubectl --context $CTX get certificate.cert-manager.io "$cert" -n "$ns" \
        -o jsonpath='{.spec.secretName}' 2>/dev/null)
      if [[ -n "$secret" ]]; then
        echo "Deleting $ns/$secret..."
        kubectl --context $CTX delete secret "$secret" -n "$ns"
      fi
    done
done
```

cert-manager detects the missing secret and re-creates it, now using the **new CA** from `bulk-konk-kubeadm-ca` ClusterIssuer.

### Step 2: Restart reconcile-kubeconfig pods

The pods have the old cert cached in their volume mount. Restart them to pick up the new secret:

```bash
for ns in tagging-v2 endpoints hostapp ntp ddi atcapi redirect ngp-cp; do
  kubectl --context $CTX get pods -n $ns --no-headers 2>/dev/null \
    | grep 'konk-service-kubeconfig' | awk '{print $1}' | while read -r pod; do
      kubectl --context $CTX delete pod "$pod" -n "$ns" --grace-period=5
    done
done
```

### Step 3: Restart stale kubectl-apiservice pods (0/1)

After the kubeconfig secrets are updated with the new CA, restart the stuck pods:

```bash
for ns in tagging-v2 endpoints hostapp ntp ddi atcapi redirect ngp-cp; do
  kubectl --context $CTX get pods -n $ns --no-headers 2>/dev/null \
    | grep 'kubectl-api' | grep '0/1' | awk '{print $1}' | while read -r pod; do
      kubectl --context $CTX delete pod "$pod" -n "$ns" --grace-period=5
    done
done
```

### Step 4: Verify

```bash
# CA should now match
kubectl --context $CTX get secret tagging-aggregate-api-apiservice-konk-service-kubeconfig \
  -n tagging-v2 -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -fingerprint -sha256 -noout
# Expected: C3:1B:E2:E8:50:55:DA:B8:...

# Pods should be 1/1
kubectl --context $CTX get pods -n tagging-v2 --no-headers | grep kubectl-api
# Expected: 1/1 Running
```

## Timeline

| Time (UTC) | Event |
|------------|-------|
| ~14:13 | etcd pre-upgrade hook fires, deletes STS |
| ~14:13–14:33 | etcd bootstraps fresh, konk-provision generates new CA |
| ~14:33 | bulk-konk apiserver starts serving with new CA |
| ~14:33+ | kubectl-apiservice pods start failing (TLS mismatch) |
| 15:10 | Detected via e2e test Section 9 |
| 15:15 | Root cause identified: stale `kubeconfig-cert` secrets |
| 15:20 | Deleted 16 kubeconfig-cert secrets across 8 namespaces |
| 15:25 | cert-manager re-issued certs with new CA (verified: `C3:1B:E2:E8:...`) |
| 15:30 | Restarted reconcile-kubeconfig pods (picked up new certs) |
| 15:30 | Kubeconfig secrets updated with correct CA |
| 15:35 | Restarted stale kubectl-apiservice pods |
| 15:36 | tagging-v2 pods: `1/1 Running` ✅ |
| 15:40 | Remaining pods recovering (cascading APIService dependency) |

## Related issues

- **Helm annotation issue** (same cluster, same event): 6 KonkService Deployments also needed `meta.helm.sh/release-name` annotations. See [annotation-issue.md](../annotation-issue.md).
- Both issues triggered by the same etcd migration but are independent problems.

## Prevention

1. **Add CA rotation awareness to the pre-upgrade hook**: After STS deletion, the hook should annotate all KonkService kubeconfig Certificates with `cert-manager.io/issuing` to trigger immediate re-issuance.
2. **Use `cert-manager.io/ca-injector`**: Instead of embedding CA in secrets, use cainjector to inject the CA from a source. This would auto-propagate on rotation.
3. **reconcile-kubeconfig should compare against source CA**: Instead of comparing the mounted cert volume, it should read the ClusterIssuer's CA secret directly via the API. This would detect the mismatch even without cert-manager re-issuing.
4. **Document as a known consequence of fresh etcd bootstrap**: Any migration that causes `kubeadm init` to regenerate the CA will trigger this cascade.