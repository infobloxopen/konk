# Ghost konk-service Container (Helm Strategic Merge Leftover)

**Date:** 2026-06-24  
**Clusters hit:** us-dev-4 (j15), us-dev-5 (j16)  
**Detected by:** `e2e-konk-test.sh --section 17`

## Symptom

Kubeconfig deployments have an **extra container** (`kubeconfig`) that shouldn't exist on pre-j191 operator versions. Pods show `1/2 ImagePullBackOff` because the ghost container references a non-existent image:

```
[FAIL] 5 pod(s) have ghost konk-service container (Helm strategic merge leftover)

hostapp/hostapp-aggregate-api-apiservice-konk-service-kubeconfig-5nh5hr  ready=true,false
hostapp/hostapp-aggregate-api-apiservice-konk-service-kubeconfig-6wdmkn  ready=true,false
ntp/ntp-aggregate-api-apiservice-konk-service-kubeconfig-8fc96lcbls      ready=true,false
tagging-v2/tagging-aggregate-api-apiservice-konk-service-kubeconfig-dcqd8l  ready=true,false
```

The ghost container tries to pull `ghcr.io/infobloxopen/konk-service:v1.25.8` — which doesn't exist (v1.25.8 is the K8s version from `.Chart.AppVersion`).

## Background: Chart Architecture Change

| Operator version | Chart design | Kubeconfig deployment containers |
|-----------------|-------------|----------------------------------|
| Pre-j191 (j15, j16) | Single `kind` container running bash script with `kubectl` | 1 container: `kind` using `kindest/node:v1.25.8` |
| j191+ (v0.2.1-155+) | Distroless Go binary split into two containers | 2 containers: `kind` + `kubeconfig` using `konk-service:<version>` |

## Root Cause: Helm Strategic Merge

When Helm performs an **upgrade** (or install-after-adopt) on a deployment, it uses Kubernetes strategic merge patch. The `containers` field is merged by container `name`:

1. Old chart (j191+) rendered: `containers: [{name: kind, ...}, {name: kubeconfig, ...}]`
2. New chart (j15/j16) renders: `containers: [{name: kind, ...}]`
3. Strategic merge **does not remove** containers that exist in the live spec but are absent from the patch — it only adds/updates by name

Result: the `kubeconfig` container persists as a ghost. It references the old image which falls back to `ghcr.io/infobloxopen/konk-service:v1.25.8` (non-existent).

### When this happens

- Operator downgrade from j191+ to pre-j191 (e.g., j15 or j16)
- Operator re-install (annotation loss → fresh Helm install) on a cluster that previously ran j191+
- Testing a newer chart version then reverting to older

## Fix

### Option A: Delete the deployment (operator recreates correctly)

```bash
CTX="teleport.services.sdp.infoblox.com-us-dev-4"

# Find affected deployments
kubectl --context "$CTX" get deploy --all-namespaces -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    if 'konk-service-kubeconfig' not in name:
        continue
    containers = item['spec']['template']['spec'].get('containers', [])
    images = [c['image'] for c in containers]
    if any('/konk-service:' in img for img in images):
        print(f'kubectl --context $CTX delete deploy {name} -n {ns}')
"

# Delete each affected deployment — operator will recreate with single container
kubectl --context "$CTX" delete deploy <name> -n <namespace>
```

The operator reconciles immediately and creates a fresh deployment with the correct single-container spec.

### Option B: Patch to remove the ghost container (no downtime)

```bash
# Remove the kubeconfig container from the deployment spec using JSON patch
kubectl --context "$CTX" patch deploy <name> -n <ns> --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/containers/1"}]'
```

**Note:** Verify container index — the ghost is typically at index 1 (`kubeconfig`). Check with:
```bash
kubectl --context "$CTX" get deploy <name> -n <ns> \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}'
```

## Fix Applied (us-dev-4, 2026-06-24)

- 4/5 pods self-healed (operator had already recreated the deployments)
- 1 remaining (`tagging-v2/tagging-aggregate-api-apiservice-konk-service-kubeconfig`) — deleted deploy, operator recreated with 1 container, pod came up healthy

## Prevention

- When downgrading the operator, delete all KonkService Helm release secrets first:
  ```bash
  kubectl get secrets -A | grep "sh.helm.release" | grep "konk-service" | awk '{print $1, $2}' | \
    while read ns name; do kubectl delete secret "$name" -n "$ns"; done
  ```
  This forces a clean Install (not Upgrade) which avoids the strategic merge issue.

- Alternatively, upgrade the operator back to j191+ which expects the two-container spec.

## Related

- [konk-service-imagepullbackoff-us-dev-5.md](../konk-service-imagepullbackoff-us-dev-5.md) — same `ghcr.io/infobloxopen/konk-service:v1.25.8` image issue but from missing `RELATED_IMAGE_KIND` env vars rather than ghost containers
- [annotation-issue-fix.md](../annotation/annotation-issue-fix.md) — Helm annotation loss triggering fresh installs
