---
applyTo: "Dockerfile*,Makefile*,Jenkinsfile,*.yml,.github/workflows/**"
---

# Konk — Build, Docker & CI Instructions

---

## Docker Images

| Image | Dockerfile | Base | Contents |
|-------|-----------|------|----------|
| konk (operator) | `Dockerfile` | `gcr.io/distroless/static-debian12:nonroot` | helm-operator binary from operator-sdk |
| konk-app | `build/kubernetes/` | `gcr.io/distroless/static-debian12:nonroot` | Patched kube-apiserver + kubeadm (rebuilt from K8S source) |
| konk-provision | `Dockerfile.provision` | `gcr.io/distroless/static-debian12:nonroot` | Go binary from `cmd/provision/` |
| konk-service | `Dockerfile.konk-service` | `gcr.io/distroless/static-debian12:nonroot` | Go binary from `cmd/konk-service/` |

All images are **distroless** — no shell, no package manager, no debugging tools at runtime.

---

## Build Conventions

- **Static linking:** All Go binaries built with `CGO_ENABLED=0 GOOS=linux`
- **Nonroot:** All containers run as UID 65534 (`nonroot` user)
- **Multi-stage builds:** Compile in Go builder image, copy binary to distroless
- **Custom Kubernetes build:** `build/kubernetes/` patches and rebuilds kubeadm + kube-apiserver from Kubernetes source with updated dependencies (x/crypto, opentelemetry) to eliminate CVEs

---

## Image Tags

| Image | Tag Format | Example |
|-------|-----------|---------|
| konk, konk-app, konk-provision, konk-service | `GIT_VERSION` | `v0.2.1-162-g8ea244a` |

`GIT_VERSION` is derived from `git describe --always --long --tags`.
CI also pushes a `:latest` tag on `main` builds for convenience, but charts and deployments must always reference explicit version tags.

---

## Key Makefile Targets

| Target | Purpose |
|--------|---------|
| `make all` | Build all Docker images (default) |
| `make docker-build` | Build konk operator image |
| `make docker-build-kubernetes` | Build konk-app (patched kube-apiserver) |
| `make docker-build-provision` | Build konk-provision image |
| `make docker-build-konk-service` | Build konk-service image |
| `make docker-push*` | Push images to GHCR |
| `make helm-lint-konk` | Lint konk Helm chart |
| `make helm-lint-konk-service` | Lint konk-service Helm chart |
| `make deploy-crds` | Apply CRDs via kustomize |
| `make deploy-cert-manager` | Install cert-manager (prerequisite) |
| `make deploy-konk` | Deploy konk chart |
| `make deploy-konk-service` | Deploy konk-service chart |
| `make test-konk` | Run Helm tests for konk |
| `make kind` | Create KIND cluster for local dev |
| `make package` | Package Helm charts for release |

---

## CI/CD

**GitHub Actions** (`.github/workflows/`):
- `push-images.yml` — builds & pushes all images to GHCR on `main` and `release/*`
- `pr.yaml` — PR validation (lint, build)
- `release.yaml` — chart release workflow

**Jenkinsfile** (legacy):
- Stages: Prepare → Push Images → Package Charts → Push Chart
- Publishes Helm charts to AWS-hosted chart repo

---

## KIND Local Development

```bash
make kind                    # Create KIND cluster
make deploy-cert-manager     # Install cert-manager
make deploy-crds             # Apply CRDs
make deploy-konk-operator    # Deploy operator
make deploy-konk             # Deploy a konk instance
make test-konk               # Run Helm tests
```

KIND cluster uses `kindest/node:v1.31.4` (configurable via `NODE_VERSION`).

---

## Key Rules

- **Never use `latest` tag in charts or deployments** — always reference explicit version tags derived from git (`:latest` is pushed by CI but only for local dev convenience)
- **Always rebuild** konk-app when patching Kubernetes dependencies
- **Registry:** All images push to `ghcr.io/infobloxopen/` — do not use Docker Hub
- **Helm in Docker:** Makefile runs Helm commands via a Docker container (`HELM_IMAGE`) for reproducibility
