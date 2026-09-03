# Testing Konk

## Automated: e2e-konk-test.sh

The script lives at `konk/scripts/e2e-konk-test.sh` and validates the full konk data path end-to-end.

### Prerequisites

- `kubectl` configured to target the cluster (e.g. `us-dev-5`)
- `openssl`, `jq` (optional but recommended)
- `curl` (only for section 13 external API tests)

### Basic Usage

```bash
# Full run (all 14 sections)
./e2e-konk-test.sh

# Run specific section(s)
./e2e-konk-test.sh --section 7
./e2e-konk-test.sh --section 7 --section 12

# Verbose / debug
./e2e-konk-test.sh -v          # show all passing details
./e2e-konk-test.sh -d          # show commands + full output

# Skip destructive/slow tests
./e2e-konk-test.sh --skip-exec                # no kubectl exec into pods
./e2e-konk-test.sh --skip-trigger-registration # skip pod delete/re-register test in section 7
./e2e-konk-test.sh --skip-bulk                 # skip bulk integration (section 9)
./e2e-konk-test.sh --skip-ca                   # skip CA chain validation (section 6)

# External API test (section 13)
./e2e-konk-test.sh --section 13 --csp-url https://csp.infoblox.com --token <TOKEN>
# Or via env:
export KONK_E2E_TOKEN=<token>
./e2e-konk-test.sh --section 13
```

### What Each Section Tests

| # | Section | What it validates |
|---|---------|-------------------|
| 1 | konk-operator | Operator deployment ready in `konk` ns |
| 2 | Core infrastructure | bulk-konk, etcd, init pods in `aggregate` ns |
| 3 | Konk CR status | `bulk-konk` CR conditions (Ready, Deployed) |
| 4 | KonkService CRs | All KonkService CRs across namespaces |
| 5 | konk-service pods | Pod health for all konk-service deployments |
| 6 | CA trust chain | bulk-konk CA matches kubeconfig secret CAs |
| 7 | APIServices in konk | Port-forward to konk API, list APIServices, trigger re-registration |
| 8 | Sample namespace | Deep check of one namespace (default: tagging-v2) |
| 9 | Bulk integration | atlas.bulk pods + konk /healthz via port-forward |
| 10 | Operator logs | Check for error patterns in konk-operator logs |
| 11 | cert-manager CA | cert-manager issuer + CA secret health |
| 12 | Konk API deep test | Query actual resources inside konk (tagging, dnsconfig, etc.) |
| 13 | External API | Test tagging + bulk export/import via CSP endpoint |
| 14 | Backend pod health | All pods in konk-registered namespaces |

### Interpreting Results

```
Passed:   22    ← all good
Failed:   0     ← any > 0 means something is broken
Warnings: 2     ← non-critical issues (e.g. some APIServices unavailable)
Skipped:  1     ← explicitly skipped via flags
```

- **PASS** = healthy
- **FAIL** = broken, needs attention
- **WARN** = degraded but non-critical (e.g. 9/25 APIServices unavailable is normal for unused APIs)
- **INFO** = contextual output

---

## Manual Testing

### 1. Check konk operator is running

```bash
kubectl get deploy -n konk
kubectl get pods -n konk
```

### 2. Check core components (aggregate namespace)

```bash
kubectl get pods -n aggregate
# Expect: bulk-konk-0 (Running), etcd-bulk-konk-0 (Running), init pod (Completed)
```

### 3. Check Konk CR status

```bash
kubectl get konk bulk-konk -n aggregate -o yaml | grep -A5 conditions
# Expect: type: Deployed, status: "True"
```

### 4. Check KonkService CRs

```bash
kubectl get konkservice -A
# All should show DEPLOYED=True
```

### 5. Check konk-service pods

```bash
kubectl get pods -A -l app.kubernetes.io/name=konk-service
# All should be Running and ready
```

### 6. Port-forward to konk API

```bash
# Extract client certs from kubeconfig secret
SECRET=$(kubectl get secrets -A --no-headers -l app.kubernetes.io/name=konk-service \
  --field-selector type=Opaque | grep "konk-service-kubeconfig " | head -1)
NS=$(echo "$SECRET" | awk '{print $1}')
NAME=$(echo "$SECRET" | awk '{print $2}')

TMPD=$(mktemp -d)
kubectl get secret "$NAME" -n "$NS" -o "jsonpath={.data.tls\.crt}" | base64 -d > "$TMPD/tls.crt"
kubectl get secret "$NAME" -n "$NS" -o "jsonpath={.data.tls\.key}" | base64 -d > "$TMPD/tls.key"

# Start port-forward
kubectl port-forward svc/bulk-konk -n aggregate 6443:6443 &
PF_PID=$!
sleep 5

# Create kubeconfig
cat > "$TMPD/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://localhost:6443
  name: bulk-konk
contexts:
- context:
    cluster: bulk-konk
    user: kubernetes-admin
  name: bulk-konk
current-context: bulk-konk
users:
- name: kubernetes-admin
  user:
    client-certificate: ${TMPD}/tls.crt
    client-key: ${TMPD}/tls.key
EOF

# Query konk
kubectl --kubeconfig="$TMPD/kubeconfig" get --raw /healthz
# → "ok"

kubectl --kubeconfig="$TMPD/kubeconfig" get apiservices
# Shows all registered bulk.infoblox.com APIServices

kubectl --kubeconfig="$TMPD/kubeconfig" api-resources
# Shows all CRD-backed resources in konk

# Cleanup
kill $PF_PID
rm -rf "$TMPD"
```

### 7. Check APIService registration

```bash
# Using the kubeconfig from step 6:
kubectl --kubeconfig="$TMPD/kubeconfig" get apiservices -o wide | grep bulk.infoblox.com
# AVAILABLE=True means konk can route to the backend service
```

### 8. Verify a specific resource in konk

```bash
# Example: list tagging resources
kubectl --kubeconfig="$TMPD/kubeconfig" get tags.tagging.bulk.infoblox.com --all-namespaces

# Example: list DNS config
kubectl --kubeconfig="$TMPD/kubeconfig" get -A dnsconfigs.dnsconfig.bulk.infoblox.com
```

### 9. Check konk-service logs

```bash
# Pick any konk-service pod
POD=$(kubectl get pods -A -l app.kubernetes.io/name=konk-service --no-headers | head -1)
NS=$(echo "$POD" | awk '{print $1}')
NAME=$(echo "$POD" | awk '{print $2}')
kubectl logs -n "$NS" "$NAME" --tail=50
# Look for "Applied APIService" or "reconcile-apiservice" success messages
```

### 10. Trigger APIService re-registration

```bash
# Delete an APIService inside konk to test if konk-service re-creates it
kubectl --kubeconfig="$TMPD/kubeconfig" delete apiservice v1.dnsconfig.bulk.infoblox.com
# Wait ~30s, then verify it comes back:
kubectl --kubeconfig="$TMPD/kubeconfig" get apiservice v1.dnsconfig.bulk.infoblox.com
```

---

## Notes

- **Distroless images**: konk-service pods have no shell/kubectl — cannot `exec` into them. Use port-forward instead.
- **TLS**: konk server cert SANs are `bulk-konk.aggregate.svc`, not `localhost`. Use `insecure-skip-tls-verify: true` in kubeconfig when port-forwarding. Client certs are still validated.
- **Port-forward timing**: Through Teleport, port-forward needs ~5s to establish. The script uses `nc -z -w 1` in a retry loop.
- **9 unavailable APIServices**: Normal — corresponds to APIs with no active backend (e.g. atcapi v2, redirect).
