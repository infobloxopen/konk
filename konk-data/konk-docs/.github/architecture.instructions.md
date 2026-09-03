---
applyTo: "cmd/**/*.go,helm-charts/konk/**,helm-charts/konk-service/**,watches.yaml"
---

# Konk — Architecture & Lifecycle Instructions

---

## How the CA Propagates to APIService Namespaces

Each KonkService CR deploys a `konk-service` Helm release in the target namespace. That release
includes a `reconcile-kubeconfig` Deployment (`kubeconfig-deployment.yaml`) which:
1. Runs `konk-service reconcile-kubeconfig` continuously in a loop (~2–3 min interval).
2. Reads the current bulk-konk CA from the kubeconfig mounted at `/etc/kubernetes/admin.conf`
   (sourced from the `*-kubeconfig-cert` secret, which is signed by the bulk-konk CA).
3. Detects if the `ca.crt` in the local kubeconfig secret (`*-konk-service-kubeconfig`) has changed.
4. If changed, **updates** the secret with the new CA and admin cert.

The `kubectl-apiservice` pods then mount this kubeconfig secret as a volume at `/etc/kubernetes`.
They read `ca.crt` **at pod start** — volume updates are reflected in the file, but the Go binary
reads the file once on startup, so **pod restart is required** to pick up a CA change.

---

## How It Is Configured

- CA secret name: `<release-fullname>-ca` (e.g. `bulk-konk-ca`) — in the konk namespace (e.g. `aggregate`).
- Apiserver cert: `<release-fullname>-apiserver-cert` — signed by the CA above.
- Kubeconfig cert: `<ns>-apiservice-konk-service-kubeconfig-cert` — short-lived admin cert (~12h).
- Kubeconfig secret: `<ns>-apiservice-konk-service-kubeconfig` — contains `ca.crt` (bulk-konk CA)
  and `admin.conf` (kubeconfig using the admin cert above).
- RBAC: The `reconcile-kubeconfig` ServiceAccount needs `create`, `get`, `delete`, `list`,
  `patch`, `update`, `watch` on `secrets` in its namespace (template: `kubeconfig-rbac.yaml`).

---

## What konk-operator Does

- Watches for `Konk` and `KonkService` custom resources.
- For each `Konk` CR:
  - Deploys a konk instance (API server, etcd, provisioner, etc.) using the Helm chart.
  - Passes the CR's `.spec` as Helm values.
- For each `KonkService` CR:
  - Deploys the konk-service Helm chart to register an APIService in the konk instance.
  - Handles ingress and certificate provisioning if enabled.

---

## KonkService Lifecycle

1. User creates a `KonkService` CR, specifying the target konk and service details.
2. konk-operator deploys the konk-service Helm chart, registering an APIService in the konk instance.
3. If ingress is enabled, front-proxy ingress and TLS certs are provisioned automatically.
4. The APIService is now accessible via the configured ingress and secured with the generated certificates.

---

## Useful Diagnostic Commands

```bash
# View konk operator pod
kubectl get po -n konk

# View bulk-konk apiserver, etcd, init, and related pods
kubectl get po -n aggregate

# Find all konk-service pods across all namespaces
kubectl get pods -A --no-headers | grep 'konk-service'

# View all KonkService CRs
kubectl get konkservice -A

# View all Konk CRs
kubectl get konk -A

# View all Etcd CRs (full name required — short name conflicts with EKS metrics)
kubectl get etcds.konk.infoblox.com -A
```

---

## How to Access APIs Inside Bulk-Konk

All konk-service pods are **distroless** — they contain no `kubectl`, no shell, and no debugging
tools. You cannot `kubectl exec ... -- sh` or `kubectl exec ... -- kubectl` into them.

### Method 1: Port-Forward to Bulk-Konk Service (Recommended)

Forward the bulk-konk API server port to your local machine and use `kubectl` with the admin kubeconfig:

```bash
# 1. Port-forward bulk-konk API server
kubectl port-forward -n aggregate svc/bulk-konk 6443:443 &

# 2. Extract the admin kubeconfig from the kubeconfig secret
kubectl get secret <ns>-apiservice-konk-service-kubeconfig -n <ns> \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/konk-kubeconfig.yaml

# 3. Edit the kubeconfig to point to localhost:6443
sed -i '' 's|server:.*|server: https://localhost:6443|' /tmp/konk-kubeconfig.yaml

# 4. Use it
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify get apiservices
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify api-resources
```

### Method 2: Ephemeral Debug Container

Attach a debug container with kubectl to a running konk-service pod:

```bash
# Attach a debug container with shell + kubectl
kubectl debug -n <ns> <konk-service-pod> -it --image=bitnami/kubectl -- sh

# Inside the debug container, the kubeconfig volume is accessible:
kubectl --kubeconfig=/etc/kubernetes/admin.conf get apiservices
```

---

## Running Commands Inside Bulk-Konk

Common operations against the bulk-konk API server (using port-forward method):

```bash
# List all API resources registered in konk
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify api-resources

# List all registered APIServices
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify get apiservices

# Get specific APIService details
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify \
  describe apiservice v1alpha1.tagging.bulk.infoblox.com

# Check APIService health (Available=True means healthy)
kubectl --kubeconfig=/tmp/konk-kubeconfig.yaml --insecure-skip-tls-verify \
  get apiservices -o wide | grep -v 'True'
```

---

## Pods Created by Konk Infrastructure

Each KonkService CR triggers the konk-service Helm chart, which deploys a set of **long-running
Deployments** (not Jobs) in the target namespace. All pods run the same `konk-service` Go binary
(`ghcr.io/infobloxopen/konk-service`) with different subcommands.

### a) `*-konk-service-kubeconfig-*` — Kubeconfig Reconciler

| Field | Value |
|---|---|
| **Command** | `/usr/local/bin/konk-service reconcile-kubeconfig` |
| **Kind** | Deployment (long-running) |
| **Replicas** | 1 |
| **Purpose** | Continuously monitors the bulk-konk CA and admin certs. Updates the `*-konk-service-kubeconfig` secret when certs change (every ~2–3 min loop). |
| **Mounts** | `*-kubeconfig-cert` secret (from cert-manager) → `/tmp/certs` |

### b) `*-konk-service-kubectl-apiservice-*` — APIService Reconciler

| Field | Value |
|---|---|
| **Command** | `/usr/local/bin/konk-service reconcile-apiservice` |
| **Kind** | Deployment (long-running) |
| **Replicas** | 1–2 |
| **Purpose** | Registers and maintains the APIService object inside the bulk-konk apiserver. Reads the CA cert, templates the APIService manifests, and applies them via `client-go`. Loops every 30 seconds. |
| **Mounts** | `*-konk-service-kubeconfig` secret → `/etc/kubernetes/admin.conf`; `*-konk-service-server` secret → `/certs` (CA cert for caBundle) |
| **Legacy name** | Named `kubectl-apiservice` historically because it used to shell out to `kubectl apply`. The current distroless image uses `client-go` directly — **no `kubectl` binary exists in the pod**. |

### c) `*-konk-service-kubectl-apiservice-test-*` — APIService Health Checker

| Field | Value |
|---|---|
| **Command** | `/usr/local/bin/konk-service test-apiservice` |
| **Kind** | Deployment (long-running) |
| **Replicas** | 1 |
| **Purpose** | Verifies the APIService is reachable inside konk. Runs periodic health checks against the registered APIService endpoint. Reports readiness via a health file. |
| **Mounts** | Same kubeconfig as the apiservice reconciler |

### d) `*-konk-service-delete-apiservice-*` — Cleanup Job

| Field | Value |
|---|---|
| **Command** | `/usr/local/bin/konk-service delete-apiservice` |
| **Kind** | Job (Helm pre-delete hook) |
| **Purpose** | Deletes the APIService registration from konk when the KonkService is uninstalled. Only runs during `helm uninstall`. |

### Relationship Summary

```
KonkService CR (e.g., tagging-aggregate-api-apiservice)
  │
  ├─ konk-operator watches CR
  │    └─ deploys konk-service Helm chart in target namespace
  │
  └─ konk-service Helm chart creates:
       ├─ kubeconfig Deployment        → reconciles kubeconfig secret (CA + admin cert)
       ├─ kubectl-apiservice Deployment → registers APIService in bulk-konk (via client-go)
       ├─ apiservice-test Deployment   → health-checks the registered APIService
       ├─ delete-apiservice Job        → Helm pre-delete hook (cleanup)
       ├─ kubeconfig-cert Certificate  → cert-manager issues short-lived admin cert
       ├─ server Certificate           → TLS serving cert for the aggregate API
       └─ RBAC (Role + RoleBinding)    → permissions for secret management
```
