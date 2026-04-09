---
applyTo: "**/*_test.go,test/**,scripts/*test*,helm-charts/**/tests/**"
---

# Konk — Test Instructions

---

## Test Layers

Konk uses multiple test layers — no single `go test` covers everything:

| Layer | How to run | What it tests |
|-------|-----------|---------------|
| Helm chart tests | `make test-konk`, `make test-konk-service` | Chart deploys correctly, pods healthy, APIService registered |
| Go unit tests | `cd cmd/<binary> && go test ./...` | Individual functions in konk-service / provision |
| Smoke tests | `scripts/konk-smoke-test.sh` | End-to-end: deploy konk → deploy KonkService → verify API access |
| Failure tests | `make test-konk-local` | Negative cases with `test/konk.fail.yaml` |
| E2E tests (CI) | `.github/workflows/pr.yaml` | Full lifecycle on KIND: deploy → test → upgrade → extension apiserver → ingress → delete |

---

## Helm Test Hooks

Primary testing is via Helm test hooks (annotation `helm.sh/hook: test`):

- `helm-charts/konk/templates/tests/test-connection.yaml` — verifies konk API server is reachable
- `helm-charts/konk-service/templates/tests/test-setup.yaml` — verifies RBAC and CRD resources exist
- `helm-charts/konk-service/templates/apiservice-test-deployment.yaml` — polls APIService health

Test hooks run inside the cluster via `helm test <release>`. They use the `konk-service` image with subcommands like `test-connection`, `test-setup`, `test-apiservice`.

---

## Go Tests

- Located in `cmd/konk-service/` and `cmd/provision/` alongside source files
- Use standard `testing` package
- Use `testify/assert` for assertions — never bare `if` checks
- `test/apiserver/` contains example apiserver controller tests (reference implementation)

---

## Smoke Test Script

`scripts/konk-smoke-test.sh` performs full lifecycle validation:
1. Deploys a Konk CR
2. Waits for konk pod to be ready
3. Deploys a KonkService CR
4. Verifies APIService registration
5. Creates/gets/deletes a sample custom resource
6. Cleans up

---

## E2E Tests (CI)

`.github/workflows/pr.yaml` runs a comprehensive end-to-end test on every PR using KIND:

1. **Matrix:** tests against multiple K8s versions (`v1.31.4`, `v1.25.11`) and includes an upgrade scenario
2. **Setup:** KIND cluster → cert-manager → ingress-nginx → build & load images
3. **Deploy:** `deploy-crds` → `deploy-konk-operator` → create Konk CR → wait for etcd + apiserver
4. **Test Konk:** `make test-konk` (Helm tests) + `make test-konk-local` (failure cases)
5. **Extension APIServer:** build example-apiserver → deploy with KonkService → `make test-apiserver` + `make test-apiserver-konk-service`
6. **Ingress:** verify front-proxy ingress routes to extension API via `kubectl -s localhost:80 get contacts`
7. **Delete:** delete all Konk/KonkService CRs → verify Helm releases are cleaned up
8. **Upgrade scenario:** deploys from `main` branch first, then upgrades to PR branch and re-tests

---

## Key Rules

- Always test chart changes with `make helm-lint-konk` / `make helm-lint-konk-service` before deploying
- Helm tests require a running cluster — use `make kind` to create a KIND cluster for local testing
- cert-manager must be installed before konk tests: `make deploy-cert-manager`
- Test containers are distroless — all test logic is in Go subcommands, not shell scripts
