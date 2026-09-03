# KonkService Kubeconfig Permission Denied — us-dev-5

**Date:** 2026-06-24  
**Cluster:** us-dev-5  
**Related to:** [konk-service-imagepullbackoff-us-dev-5.md](konk-service-imagepullbackoff-us-dev-5.md)

## Symptom

After fixing the ImagePullBackOff issue, kubeconfig pods came up as 1/2 Running:

```
kubeconfig atcapi/atcapi-apiservice-konk-service-kubeconfig-668775bd46-jcmsj: 1/2 Running
```

Kubeconfig container logs:
```
Error writing kubeconfig: open /etc/kubernetes/admin.conf: permission denied
```

## Root Cause

**Race condition** between the two sidecar containers sharing an emptyDir volume at `/etc/kubernetes/`:

| Container | Image | Runs as | Role |
|-----------|-------|---------|------|
| `kind` | `infobloxcto/node:v1.25.8` | root (UID 0) | Creates `admin.conf` via `kubectl config set-...` |
| `kubeconfig` | `infobloxcto/konk-service:v0.2.1-155-gd4614c2` | nonroot (UID 65532) | Reconciles kubeconfig, writes `admin.conf` |

Both containers start simultaneously (no init container ordering). `kubectl config` creates files with mode `0600` (`-rw-------`).

- If `kind` writes first → file is `root:root 0600` → `kubeconfig` (UID 65532) gets **permission denied**
- If `kubeconfig` writes first → file is `65532:65532 0600` → both work (kind is root, can overwrite anything)

### Why it works on us-dev-2 and us-stg-1

On those clusters, the `kubeconfig` container won the race on existing pods (file owned by `65532:65532`). Same images, same digests — purely timing-dependent.

### Evidence

```
# us-dev-5 (broken): kind wrote first
-rw------- 1 root root 378 Jun 24 08:40 admin.conf

# us-dev-2 (working): kubeconfig wrote first
-rw------- 1 65532 65532 378 Jun 24 08:39 admin.conf
```

Both clusters confirmed:
- Same image digests (sha256:b5ce984f... for node, sha256:2872c659... for konk-service)
- Same pod/container security contexts
- Same Kubernetes version (v1.32.7-eks)
- `kind` container runs as root on both (`id` shows uid=0)
- New files created by `kind` are `root:root` on both

## Fix Applied

1. **First attempt — `fsGroup: 65532`**: Made the emptyDir group-owned by 65532, but `kubectl config` creates files with mode `0600` so group bits don't help.

2. **Working fix — `runAsUser: 65532` on `kind` container**: Patched the `kind` container's securityContext so it runs as the same UID as `kubeconfig`. Both containers write files as 65532 → no permission conflict.

```bash
kubectl --context us-dev-5 get deploy --all-namespaces --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' \
  | grep "konk-service-kubeconfig" | while read ns name; do
    ready=$(kubectl --context us-dev-5 get deploy "$name" -n "$ns" \
      -o jsonpath='{.status.unavailableReplicas}' 2>/dev/null)
    if [[ -n "$ready" && "$ready" != "0" ]]; then
      kubectl --context us-dev-5 patch deploy "$name" -n "$ns" --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{"runAsUser":65532,"runAsGroup":65532}}]'
    fi
  done
```

### Affected deployments

| Namespace | Deployment |
|-----------|-----------|
| atcapi | atcapi-apiservice-konk-service-kubeconfig |
| atcapi | atcapi-apiservice-v2-konk-service-kubeconfig |
| ddi | dns-data-importexport-apiservice-v2-konk-service-kubeconfig |
| ddi | ipam-importexport-apiservice-v3-konk-service-kubeconfig |
| ngp-cp | bootstrap-app-aggregate-api-apiservice-konk-service-kubeconfig |
| redirect | redirect-apiservice-konk-service-kubeconfig |

## Caveats

- The `kind` container runs a bash script using `kubectl` — running as non-root (65532) works because the `kindest/node` image has the binary at a world-executable path
- If the konk-operator re-reconciles these KonkService CRs, the `runAsUser` patch will be lost (the chart doesn't set it)
- **Proper fix**: The konk-service Helm chart should set `securityContext.runAsUser: 65532` on the `kind` container in `kubeconfig-deployment.yaml`, or use an initContainer to create the file with correct ownership before sidecars start
