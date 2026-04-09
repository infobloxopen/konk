# Konk — Repository Instructions

## Overview

konk — Kubernetes On Kubernetes — is a tool for deploying an independent Kubernetes API server within Kubernetes.

konk can be used as part of a larger application to manage resources via CustomResourceDefinitions and implement a CRUD API for those resources by leveraging kube-apiserver. Or implement an [extension API server](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/) without worrying about [breaking the parent cluster with a non-compliant API](https://github.com/kubernetes/kubernetes/issues/96066).

konk does not start a kubelet and therefore does not support any resources that require a node such as deployments and pods.

This repo provides a konk helm chart that can be used to deploy an instance of konk with helm, and a konk-operator that watches for konk CRs and will deploy a konk instance for each of them.

**Organization:** `github.com/infobloxopen/konk`
**Go version:** 1.25
**Operator SDK:** v1.42.0 (Helm operator)
**Kubernetes base:** v1.25.8 (configurable via `K8S_RELEASE`)

## Architecture

- **Helm operator pattern** — watches CRs, applies `.spec` as Helm chart values; no custom reconciliation logic
- **Three CRDs** (`konk.infoblox.com/v1alpha1`): `Konk`, `KonkService`, `Etcd`
- **No gRPC/REST API surface** — this is an infrastructure operator, not a microservice
- **No database** — state is Kubernetes resources (CRs, Secrets, ConfigMaps)

## Key Components

| Component | Image | Purpose |
|-----------|-------|---------|
| konk (operator) | `ghcr.io/infobloxopen/konk` | Helm operator watching Konk/KonkService/Etcd CRs |
| konk-app | `ghcr.io/infobloxopen/konk-app` | Patched kube-apiserver + kubeadm (distroless) |
| konk-provision | `ghcr.io/infobloxopen/konk-provision` | Init container: cert generation + kubeadm init |
| konk-service | `ghcr.io/infobloxopen/konk-service` | APIService lifecycle manager — see [cmd/konk-service/main.go](../cmd/konk-service/main.go) for subcommands: `reconcile-kubeconfig`, `reconcile-apiservice`, `delete-apiservice`, `test-apiservice`, `test-connection`, `test-setup`, `wait-for-resource`, `example-test`, `healthz` |
| etcd | `gcr.io/etcd-development/etcd` | Distributed key-value store backing the API server |

## Key Conventions

- **Multiple Go modules** — `cmd/konk-service/`, `cmd/provision/`, and `build/kubernetes/` each have their own `go.mod`; no root-level Go module
- **Distroless images** — all Go binaries statically linked (`CGO_ENABLED=0`), no shell in containers, run as nonroot (UID 65534)
- **cert-manager dependency** — TLS certificates managed by cert-manager; CA stored in Kubernetes secrets
- **Env var overrides** — `watches.yaml` uses `overrideValues` with env vars set in operator deployment: `RELATED_IMAGE_*` for image refs, plus `CERT_MANAGER_NAMESPACE`, `SPACE`, `VAULT_PATH`, `AUTH_URL`
- **Image tags:** all images (`konk`, `konk-app`, `konk-provision`, `konk-service`) use `GIT_VERSION` (`git describe --always --long --tags`)
- **Registry:** GHCR (`ghcr.io/infobloxopen/`) — [charts repo](https://github.com/Infoblox-CTO/charts/tree/main/konk) replicates images from GHCR to Harbor; DC repo references images from Harbor

## Detailed Instructions

- `go.instructions.md` — Go code conventions for cmd/ binaries
- `go.test.instructions.md` — test patterns: Helm tests, Go tests, smoke tests
- `helm.instructions.md` — Helm chart structure, operator watches, CRD conventions
- `build.instructions.md` — Docker builds, Makefile targets, CI/CD, KIND local dev
- `architecture.instructions.md` — CA propagation, operator lifecycle, pod roles, accessing konk APIs

## Reference Docs (read on demand)

- `README.md` — project overview, chart usage, operator, KonkService, front-proxy ingress
- `helm-charts/konk/README.md` — Konk chart spec and values documentation
- `helm-charts/konk-service/README.md` — KonkService chart spec and values documentation
- [atlas.bulk README](https://github.com/Infoblox-CTO/atlas.bulk/blob/main/README.md) — bulk-konk deployment and usage in the Atlas platform
