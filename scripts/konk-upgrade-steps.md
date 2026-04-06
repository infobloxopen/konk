Both Bulk and Konk deployments are closely related. Earlier, Bulk was deployed with Kubernetes v1.32.12, which created certain entries in bulk-konk-etcd specific to that version.

However, this Kubernetes v1.32.12 setup in Bulk is causing compatibility issues with Konk, which is currently running on Kubernetes v1.25.8.

Therefore, we will need to first revert the Bulk version before proceeding with the Konk deployment, and then follow the steps below.


## Steps

### 1. Deploy bulk image - v2.5.0-74-g55442220-j3 to revert the v1.32.12 k8s version change.

### 2. Clean stale flowschemas

```bash
kubectl -n aggregate exec bulk-konk-etcd-0 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key \
  del /registry/flowschemas --prefix
```

### 3. Clean stale prioritylevelconfigurations

```bash
kubectl -n aggregate exec bulk-konk-etcd-0 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key \
  del /registry/prioritylevelconfigurations --prefix
```

### 4. Confirm stale flowschemas are removed. Count should be zero

```bash
kubectl -n aggregate exec bulk-konk-etcd-0 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key \
  get /registry/flowschemas --prefix --keys-only | wc -l
```

### 5. Confirm stale prioritylevelconfigurations are removed. Count should be zero

```bash
kubectl -n aggregate exec bulk-konk-etcd-0 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key \
  get /registry/prioritylevelconfigurations --prefix --keys-only | wc -l
```

### 6. Disable the APF flag

Check if the flag is already present:

```bash
kubectl -n aggregate get deploy bulk-konk -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | rg -- '--enable-priority-and-fairness=false' >/dev/null && echo APF_DISABLED || echo APF_ENABLED
```

If it shows `APF_ENABLED`, disable APF by adding the flag to the bulk-konk apiserver args:

```bash
kubectl -n aggregate patch deploy bulk-konk --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-priority-and-fairness=false"}]'
```

Verify it is now disabled:

```bash
kubectl -n aggregate get deploy bulk-konk -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | rg -- '--enable-priority-and-fairness=false' >/dev/null && echo APF_DISABLED || echo APF_ENABLED
```

### 7. Deploy Konk image: v0.2.1-172-gec39a16-j38

### 8. After Konk deployment, if the bulk-konk-init pod in the aggregate namespace is failing, then it might be due to the stale bash command from earlier deployments

The new konk-provision image is distroless (no bash/shell). If the deployment still has `command: ["bash", "-c"]` from an older release, the pod will fail with `RunContainerError: exec: "bash": executable file not found in $PATH`.

Check if the deployment has a stale bash command:

```bash
kubectl -n aggregate get deploy bulk-konk-init -o jsonpath='{.spec.template.spec.containers[0].command[0]}'
```

If it shows `bash`, remove the stale command/args:

```bash
kubectl -n aggregate patch deploy bulk-konk-init --type='json' \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"},{"op":"remove","path":"/spec/template/spec/containers/0/args"}]'
```

If the pod is still failing after patching, delete it to force a fresh restart:

```bash
kubectl -n aggregate delete pod -l app.kubernetes.io/name=konk,app.kubernetes.io/component=init
```

### 9. Run the e2e testing script

Script located here: https://github.com/rsatal/konk/blob/add-e2e-testing-script/scripts/e2e-konk-test.sh
