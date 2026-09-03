---
applyTo: "helm-charts/**,watches.yaml,config/**,examples/**"
---

# Konk — Helm Chart & Operator Instructions

---

## Chart Structure

| Chart | Path | Purpose |
|-------|------|---------|
| konk | `helm-charts/konk/` | Deploys kube-apiserver + etcd + provision init container |
| konk-operator | `helm-charts/konk-operator/` | Deploys the Helm operator itself |
| konk-service | `helm-charts/konk-service/` | Registers APIService in a konk instance (reconcile, test, RBAC) |
| etcd | `helm-charts/etcd/` | Standalone etcd deployment |
| example-apiserver | `helm-charts/example-apiserver/` | Reference implementation for extension API servers |

---

## Operator Watches (`watches.yaml`)

The Helm operator watches three CRDs and maps each CR's `.spec` to Helm chart values:

```yaml
- group: konk.infoblox.com
  version: v1alpha1
  kind: Konk          # → helm-charts/konk/     (has overrideValues)
- group: konk.infoblox.com
  version: v1alpha1
  kind: KonkService   # → helm-charts/konk-service/ (has overrideValues)
- group: konk.infoblox.com
  version: v1alpha1
  kind: Etcd           # → helm-charts/etcd/     (no overrideValues)
```

`Konk` and `KonkService` watches use **overrideValues** with environment variables (set in operator Deployment) to inject image references and config. The `Etcd` watch has no overrideValues — it uses chart defaults only.
```yaml
overrideValues:
  - name: apiserver.image.repository
    value: $RELATED_IMAGE_APISERVER
```

This pattern avoids hardcoded image refs in the chart and supports air-gapped registries.

---

## CRDs

- Defined in `config/crd/bases/` as Kustomize YAML
- Three CRDs: `konk.infoblox.com_konks.yaml`, `konk.infoblox.com_konkservices.yaml`, `konk.infoblox.com_etcds.yaml`
- All are `v1alpha1`, namespaced scope
- Spec uses `x-kubernetes-preserve-unknown-fields: true` — allows arbitrary Helm values
- `Konk` spec has one typed field: `scope` (pattern: `^cluster|namespace$`)
- Deploy CRDs via `make deploy-crds` (applies kustomize output)

---

## Values Conventions

- **konk chart:** Key sections are `apiserver` (image, resources, disabled APIs), `etcd` (image, resources), `certManager` (namespace), `provision` (image)
- **konk-service chart:** Key sections are `konk` (name, namespace, scope), `service` (name, caSecretName), `group` (name, kinds, verbs), `kind` (image for konk-service binary)
- Image references follow: `image.repository` + `image.tag` pattern
- Resource limits are set conservatively (konk apiserver: 4Gi memory; konk-service: 256Mi)

---

## cert-manager Integration

- konk chart creates cert-manager `Issuer` and `Certificate` resources for TLS
- CA secret: `<release>-ca` — self-signed CA used to sign all certs in the konk instance
- Apiserver cert, front-proxy cert, and kubeconfig certs are all signed by this CA
- `helm.sh/resource-policy: keep` annotation prevents CA deletion on Helm uninstall/upgrade
- cert-manager namespace is configurable via `certManager.namespace` (default: `cert-manager`)

---

## Key Rules

- **Never hardcode image tags** in chart templates — use `{{ .Values.image.repository }}:{{ .Values.image.tag }}`
- **Always lint** before committing: `make helm-lint-konk`, `make helm-lint-konk-service`
- **Test hooks** use annotation `helm.sh/hook: test` — they run via `helm test`, not `go test`
- **Security contexts** are strict: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, drop all capabilities
- Chart README is auto-generated via `helm-docs` — edit `README.md.gotmpl`, not `README.md` directly

For CA lifecycle and cert propagation details, see `architecture.instructions.md`.
