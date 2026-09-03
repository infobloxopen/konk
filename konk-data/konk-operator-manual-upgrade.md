# Konk Operator Manual Upgrade

Manual upgrade process for testing a new konk-operator image on a cluster before merging the DC PR.

## Prerequisites

- kubectl access to the target cluster via Teleport
- New chart version (e.g. `v0.2.1-155-gd4614c2-j191`)
- New image tag (e.g. `v0.2.1-155-gd4614c2`)

## Steps

### 1. Suspend the HelmRelease (prevent Flux from reverting)

```bash
kubectl --context <CONTEXT> \
  -n vela-system patch helmrelease konk-operator \
  --type merge -p '{"spec":{"suspend":true}}'
```

### 2. Update the konk-operator deployment image

```bash
kubectl --context <CONTEXT> \
  -n konk set image deployment/konk-operator \
  manager=harbor.services.sdp.infoblox.com/infobloxcto/konk:<NEW_TAG>
```

Example:
```bash
kubectl --context teleport.services.sdp.infoblox.com-us-dev-5 \
  -n konk set image deployment/konk-operator \
  manager=harbor.services.sdp.infoblox.com/infobloxcto/konk:v0.2.1-155-gd4614c2-j191
```

### 3. Verify the rollout

```bash
kubectl --context <CONTEXT> -n konk rollout status deployment/konk-operator
kubectl --context <CONTEXT> -n konk get pods -l app.kubernetes.io/name=konk-operator
```

### 4. Validate the new version

```bash
kubectl --context <CONTEXT> -n konk get deployment konk-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 5. Resume Flux after validation (before or after PR merge)

```bash
kubectl --context <CONTEXT> \
  -n vela-system patch helmrelease konk-operator \
  --type merge -p '{"spec":{"suspend":false}}'
```

## Notes

- The `helm.sh/chart` label and `app.kubernetes.io/version` annotation only update after a full Helm upgrade (i.e. when Flux reconciles after PR merge).
- `kubectl set image` only updates the container image — metadata labels remain unchanged until Flux applies the new HelmRelease.
- Always resume the HelmRelease after testing to avoid drift.

## Cluster Contexts

| Cluster   | Context                                          |
|-----------|--------------------------------------------------|
| us-dev-2  | teleport.services.sdp.infoblox.com-us-dev-2      |
| us-dev-4  | teleport.services.sdp.infoblox.com-us-dev-4      |
| us-dev-5  | teleport.services.sdp.infoblox.com-us-dev-5      |

## DC Repo Files

- Version: `envs/box-dev/<cluster>/konk-operator-version.txt`
- Values: `envs/box-dev/<cluster>/konk-operator-values.yaml`
