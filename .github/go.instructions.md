---
applyTo: "**/*.go,!**/*_test.go"
---

# Konk — Go Instructions

---

## Module Structure

- **No root-level Go module** — the Helm operator has no custom Go code
- Two independent Go modules under `cmd/`:
  - `cmd/konk-service/` — APIService lifecycle manager (reconcile, test, healthz subcommands)
  - `cmd/provision/` — init container for cert generation + kubeadm bootstrap
- Each has its own `go.mod` with module path `github.com/infobloxopen/konk/cmd/<binary>`

---

## Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Binary | Matches directory name | `konk-service`, `provision` |
| Subcommand function | `<verb><Noun>` | `reconcileKubeconfig`, `testApiservice`, `deleteApiservice` |
| Config struct | `config` (package-scoped) | Loaded from ConfigMap or flags |
| Constants | `camelCase` or `ALL_CAPS` for env vars | `pkiDir`, `renewalBuffer` |
| Kubernetes client | Standard `client-go` patterns | `kubernetes.NewForConfig(cfg)` |

---

## Subcommand Pattern

Both binaries use a simple `os.Args[1]` dispatcher — no CLI framework (cobra, urfave):

```go
func main() {
    if len(os.Args) < 2 {
        log.Fatal("subcommand required")
    }
    switch os.Args[1] {
    case "reconcile-kubeconfig":
        reconcileKubeconfig()
    case "healthz":
        healthz(os.Args[2])
    // ...
    }
}
```

Follow this pattern for new subcommands — do not introduce a CLI framework.

---

## Configuration

- `cmd/provision/` reads config from environment variables (`os.Getenv()` / `mustEnv()`)
- `cmd/konk-service/` reads config from environment variables and command-line arguments
- No Viper — plain `os.Getenv()` and `json.Unmarshal()` (for parsing LABELS env var)

---

## Distroless Constraints

All binaries run in `gcr.io/distroless/static-debian12:nonroot` containers:

- **No shell** — cannot use `os/exec` to call shell commands; all logic must be pure Go
- **No filesystem tools** — file operations via Go's `os`/`io` packages only
- **Static linking required** — build with `CGO_ENABLED=0`
- **Nonroot** — runs as UID 65534; file paths must be accessible to nonroot user

---

## Kubernetes Client Usage

- Use `client-go` for all Kubernetes API interactions
- In-cluster config via `rest.InClusterConfig()`
- Standard patterns: `kubernetes.NewForConfig()`, typed clients for core/v1, apps/v1
- For CRD operations, use dynamic client or typed client if available

---

## Certificate & PKI Operations

- `cmd/provision/` manages TLS certificates using Go's `crypto/x509`, `crypto/rsa`, `encoding/pem`
- PKI directory: `/etc/kubernetes/pki/` (apiserver certs), `/etc/kubernetes/pki/etcd/` (etcd certs)
- CA secret: `<release-fullname>-ca` in the konk namespace
- Renewal buffer: 30 days before expiry
- cert-manager handles certificate lifecycle; provision code detects and reuses existing CA secrets

---

## Error Handling

- Use `log.Fatalf()` for unrecoverable errors (binary exits, Kubernetes restarts the container)
- Use `klog` for Kubernetes-style structured logging where appropriate
- Return errors up the call stack; handle at the subcommand level
- No gRPC status codes — these are not API servers

For architecture details, see `architecture.instructions.md`.
