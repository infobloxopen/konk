# Konk-Service Memory Leak (PTOCP-5175)

## Issue

**Jira:** https://infoblox.atlassian.net/browse/PTOCP-5175  
**Title:** us-com-1: Aggregate API(s) has memory Leak  
**Reporter:** Akhil Singhal  
**Affected clusters:** us-com-1 (same pattern across all namespaces — hostapp, tagging-v2, etc.)

## Symptoms

- **us-com-1:** Sawtooth memory pattern in `kind` containers (ramp to ~384 MiB → OOMKill → restart) — process spawning leak
- **us-dev-5:** Steady memory growth in `apiservice` container (~8 MiB → ~14.5 MiB over 30 days, no OOMKill) — HTTP/2 transport leak
- Affects all konk-service pods: `*-kubectl-apiservice-*` and `*-kubeconfig-*`
- Grafana: https://grafana.csp.infoblox.com/d/e2a52df7-0ce3-4449-ad2e-25b194d3dea0/ankur-check-pod-usage?orgId=1&var-namespace=hostapp&var-container=kind&var-pod=All&from=now-30d&to=now

## Cluster Versions

| Cluster | Helm Chart | Container | Containers/Pod |
|---------|-----------|-----------|----------------|
| us-com-1 (prod) | `konk-operator-v0.2.1-138-g8b64bf7-j170` | `kind`: `node:v1.25.8` | 1/1 |
| us-dev-2 | `konk-operator-v0.2.1-154-gd45a403-j189` | `apiservice`: `konk-service:v0.2.1-154` + `kind`: `node:v1.25.8` (transitional) | 2/2 |
| us-dev-2 (target) | post-`f64afd9` | `apiservice`: `konk-service:<version>` | 1/1 |

**Prod (us-com-1):** Old single-container pod using `node:v1.25.8` (KinD node image with shell scripts + kubectl).

**us-dev-2 current (v0.2.1-154):** Transitional — added new `apiservice` container (Go binary) but old `kind` container (`node:v1.25.8`) not yet removed. Built from internal branch (`d45a403` not on public main).

**us-dev-2 target (main/f64afd9+):** Single container `apiservice` using distroless `konk-service` Go binary. The `node:v1.25.8` container is fully replaced.

## Root Causes

There are **two separate memory leak issues** depending on the image version:

### 1. Old images (prod today: v0.2.1-138) — Process spawning leak

- Pods use shell scripts that repeatedly exec `kubectl` as a subprocess
- Each invocation spawns a new process; memory accumulates from repeated process creation in constrained containers
- This is the leak currently observed on us-com-1

### 2. New images (distroless Go rewrite) — HTTP/2 transport leak

- The Go rewrite (PR #584) replaced shell scripts with a single long-running Go binary using `client-go`
- The Kubernetes client was created **once** outside the reconciliation loop
- Go's `net/http2` transport accumulates memory on long-lived connections (known Go issue)
- Without the additional fix, new images would exhibit a slower but similar memory growth

## Fixes

### Fix 1: Distroless Go rewrite (commit f64afd9, PR #619)

**Repo:** https://github.com/infobloxopen/konk  
**Commit:** https://github.com/infobloxopen/konk/commit/f64afd9a4e39d1ca7e2ed3d58ed115cd1391c8bf

Key changes:
- Replace all shell/bash scripts with Go binaries (`konk-service`, `provision`)
- Use distroless base images (no busybox, no shell, no `kubectl` binary)
- All API interactions via in-process `client-go` (no process spawning)
- Eliminates the process-spawning memory leak from old images

### Fix 2: Explicit HTTP/2 transport cleanup across all reconcile loops

**PR:** https://github.com/infobloxopen/konk/pull/625  
**Branch:** `fix/http2-transport-memory-leak`

**Why fresh-client-per-iteration alone is not enough:**

Go's HTTP/2 transport maintains background goroutines (ping handlers, keepalive loops) that hold a reference to the transport object. Even if the client goes out of scope, the transport is a GC root via those goroutines — it is **never collected**. This was the steady memory growth observed on us-dev-5 (~6.5 MiB/month on the `apiservice` container).

**The correct fix** is to explicitly call `httpClient.CloseIdleConnections()` after each iteration, which shuts down the HTTP/2 goroutines and releases the GC root.

Implementation:
- All client factories (`newInClusterClient`, `newKubeconfigClient`, `newDynamicInClusterClient`) now return a `closeFunc` using `rest.HTTPClientFor()` + `NewForConfigAndClient()` for explicit transport control
- `reconcile_kubeconfig.go`: client creation moved inside loop + `close()` called after each iteration
- `reconcile_apiservice.go`: `defer close()` added (client was already per-iteration but transport was never released)

```go
// client.go — all factories now return closeFunc
func newInClusterClient() (*kubernetes.Clientset, closeFunc, error) {
    rc, _ := rest.InClusterConfig()
    httpClient, _ := rest.HTTPClientFor(rc)
    cs, _ := kubernetes.NewForConfigAndClient(rc, httpClient)
    return cs, func() { httpClient.CloseIdleConnections() }, nil
}

// reconcile_kubeconfig.go — client created + closed each iteration
for {
    infraClient, close, err := newInClusterClient()
    if err != nil {
        log.Printf("Error creating infra client: %v", err)
    } else {
        reconcileOnce(ctx, infraClient, ...)
        close() // shuts down HTTP/2 goroutines, allows GC
    }
    time.Sleep(150*time.Second + jitter)
}

// reconcile_apiservice.go — defer close after each 30s iteration
_, dyn, close, err := newKubeconfigClient(kubeconfigPath)
if err != nil { return err }
defer close()
```

## Resolution Path

All three fixes are needed for a complete resolution:

1. **Distroless rewrite (Fix 1, PR #619)** — replaces `node:v1.25.8` shell/kubectl container with distroless `konk-service` Go binary; eliminates process-spawning leak
2. **Explicit HTTP/2 transport cleanup (Fix 2, PR #625)** — calls `httpClient.CloseIdleConnections()` after each iteration; eliminates the slower but persistent HTTP/2 goroutine leak in Go distroless images

> **Note:** Fix 2 supersedes the earlier documented "fresh client per iteration" approach. Relying on GC alone is insufficient because HTTP/2 background goroutines are GC roots that prevent the transport from being collected.

## Operator Configuration (us-dev-2)

```
RELATED_IMAGE_KIND=v0.2.1-154-gd45a403
RELATED_IMAGE_KIND_REPO=harbor.services.sdp.infoblox.com/infobloxcto/konk-service
RELATED_IMAGE_APISERVER=v0.2.1-154-gd45a403
RELATED_IMAGE_APISERVER_REPO=harbor.services.sdp.infoblox.com/infobloxcto/konk-app
RELATED_IMAGE_PROVISION=v0.2.1-154-gd45a403
RELATED_IMAGE_PROVISION_REPO=harbor.services.sdp.infoblox.com/infobloxcto/konk-provision
```

Note: `RELATED_IMAGE_KIND` is named after the Helm values path `kind.image.*` (historical naming from when the image was literally `kindest/node`). It now maps to the `konk-service` Go binary.

## Naming Clarification

| Term | Meaning |
|------|---------|
| `kind` (container name) | Historical container name in konk-service pods (from KinD = Kubernetes in Docker) |
| `kind` (Helm values key) | `.Values.kind.image.*` — configures the konk-service container image |
| `RELATED_IMAGE_KIND` | Operator env var mapping to `kind.image.tag` in watches.yaml |
| `node:v1.25.8` | Old KinD node image with shell + kubectl (the leaking image) |
| `konk-service` | New distroless Go binary replacement |

## us-dev-2 Investigation (2026-05-29)

### Operator Restart Did Not Fix 2/2 Pods

After restarting the konk-operator, some pods remain `2/2` because the **chart bundled inside the operator image** (`v0.2.1-154-gd45a403`) still defines 2 containers in `apiservice-deployment.yaml`:

```
# Deployment spec (still has both containers):
apiservice: harbor.services.sdp.infoblox.com/infobloxcto/konk-service:v0.2.1-154-gd45a403
kind: kindest/node:v1.25.8    ← hardcoded in the chart, NOT controlled by RELATED_IMAGE_KIND
```

The `RELATED_IMAGE_KIND_REPO` env var only configures the `apiservice` container (via `.Values.kind.image.*`). The old `kind` container is a **separate hardcoded entry** in the transitional chart — no operator env var controls it.

### Affected Deployments (still 2/2)

```
atcapi/atcapi-apiservice-konk-service-kubectl-apiservice
atcapi/atcapi-apiservice-konk-service-kubectl-apiservice-test
atcapi/atcapi-apiservice-v2-konk-service-kubectl-apiservice
ddi/ipam-importexport-apiservice-konk-service-kubectl-apiservice
ddi/keys-importexport-apiservice-konk-service-kubectl-apiservice
hostapp/hostapp-aggregate-api-infra-konk-service-kubectl-apiservice
ntp/ntp-aggregate-api-apiservice-konk-service-kubectl-apiservice
redirect/redirect-apiservice-konk-service-kubectl-apiservice
redirect/redirect-apiservice-konk-service-kubectl-apiservice-test
```

### Why Some Pods Are 1/1

The `1/1` pods (e.g., tagging-v2) are leftovers from the April deployment (`v0.2.1-172-gec39a16`, helm revision 14) which DID have the single-container chart. The current operator (`v0.2.1-154`) re-rendered some releases but not all, creating a mixed state.

### Why Rollout Restart Won't Help

Rollout restart recreates pods from the same Deployment spec. Since the spec itself still has 2 containers, new pods will also be `2/2`. The operator image must be upgraded to one that bundles the single-container chart (commit `f64afd9` or later).

### Chart Template Comparison

| Version | Template containers | Container name | Image |
|---------|-------------------|----------------|-------|
| Pre-rewrite (prod v0.2.1-138) | 1 | `kind` | `node:v1.25.8` (shell scripts) |
| Transitional (v0.2.1-154) | 2 | `apiservice` + `kind` | `konk-service` + `node:v1.25.8` |
| Fixed (main/f64afd9+) | 1 | `apiservice` | `konk-service` (distroless Go) |

Source: `helm-charts/konk-service/templates/apiservice-deployment.yaml`
- `bb306e9` (pre-merge): 1 container `kind`
- `f64afd9` (merge): 1 container `apiservice`
- `v0.2.1-154` (internal build): 2 containers (transitional)

## Action

- **PR #625** (`fix/http2-transport-memory-leak`) — fix HTTP/2 transport leak in distroless images — ready for review/merge
- **us-com-1 upgrade** — upgrade konk-operator to a version from `f64afd9` or later that includes both Fix 1 and Fix 2. Promotion planned within 1-2 weeks.

**Cannot fix us-dev-2 without a new operator image build** — the current `v0.2.1-154` bundles the transitional 2-container chart.
