# Upgrade konk-app kube-apiserver to Kubernetes v1.32.13

## Problem

The `bulk-konk` extension API server pod was stuck in a crash loop (`0/1 Running`,
repeated restarts) on the EKS v1.32.12 host cluster. Pod logs showed an infinite
reinitializing loop:

```
W  cacher (*flowcontrol.PriorityLevelConfiguration): failed to list: no kind
   "PriorityLevelConfiguration" is registered for version
   "flowcontrol.apiserver.k8s.io/v1"

E  cacher (*flowcontrol.FlowSchema): unexpected ListAndWatch error: failed to list
   *flowcontrol.FlowSchema: no kind "FlowSchema" is registered for version
   "flowcontrol.apiserver.k8s.io/v1" in scheme; reinitializing...
```

### Root Cause

The `konk-app` image was built from Kubernetes v1.25.8 source, which only knows
`flowcontrol.apiserver.k8s.io/v1beta1` and `v1beta2`. The host EKS cluster (v1.32)
only serves `flowcontrol.apiserver.k8s.io/v1` (the v1beta versions were removed in
k8s 1.32). When the extension apiserver tried to watch FlowSchema resources from the
host, it received v1 responses it could not decode, causing a continuous error loop
that prevented the pod from becoming Ready.

### Version Gap

| Component         | Version   | flowcontrol versions        |
|-------------------|-----------|-----------------------------|
| Host cluster (EKS)| v1.32.12  | v1 only                     |
| konk-app (old)    | v1.25.8   | v1beta1, v1beta2            |
| konk-app (new)    | v1.32.13  | v1 (v1beta2/v1beta3 removed)|

## Changes

### Makefile
- `K8S_RELEASE`: `v1.25.8` → `v1.32.13`

### build/kubernetes/Dockerfile
- Default `K8S_VERSION` ARG: `v1.25.8` → `v1.32.13`
- Removed otelhttp/CVE-2023-45142 source patches (k8s 1.32 ships otelhttp v0.53.0, already fixed)
- Removed `go mod edit -droprequire` hacks for otelhttp/contrib
- Added `ENV GOWORK=off` (k8s 1.32+ uses Go workspaces; disabled for single-module vendor build)

### build/kubernetes/go.mod
- Fully regenerated for k8s v1.32.13 source tree via `make update-kubernetes-deps`
- Go directive: `go 1.19` → `go 1.23.0` (with `godebug default=go1.23`)
- All `golang.org/x/*` packages upgraded to latest
- k8s staging module `replace` directives reflect the 1.32 layout

### build/kubernetes/update-deps.sh
- Default `K8S_VERSION`: `v1.25.8` → `v1.32.13`
- Removed `PINNED_PACKAGES` for otel/grpc/docker-distribution (k8s 1.32 already ships safe versions)
- Removed otel sub-package `dropreplace` workarounds
- Fixed empty-array bash expansion with `${arr[@]+"${arr[@]}"}` syntax

### helm-charts/konk/Chart.yaml
- `appVersion`: `v1.25.8` → `v1.32.13`

### helm-charts/konk-service/Chart.yaml
- `appVersion`: `v1.25.8` → `v1.32.13`

## Why the otelhttp patches were removed

The previous build applied source-level patches (`build/kubernetes/patches/traces.go`
and `patches/utils.go`) to replace otelhttp usage with no-op passthroughs, working
around CVE-2023-45142 in otelhttp v0.20.0 (k8s 1.25).

Kubernetes v1.32.13 ships:
- `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` v0.53.0 (CVE fixed in v0.46.0)
- `google.golang.org/grpc` v1.65.0 (CVE-2023-44487 fixed)
- `github.com/golang-jwt/jwt/v4` v4.5.2

These patches are no longer needed. The `patches/` directory files remain in the repo
but are no longer referenced by the Dockerfile.

## Testing

- Docker build verified locally: `DOCKER_BUILDKIT=1 docker build --build-arg K8S_VERSION=v1.32.13 build/kubernetes/`
- Binary confirmed `flowcontrol.apiserver.k8s.io/v1` is registered (accepts `--runtime-config=flowcontrol.apiserver.k8s.io/v1=false` without crashing)
- CI end-to-end tests run via PR workflow on KIND clusters
