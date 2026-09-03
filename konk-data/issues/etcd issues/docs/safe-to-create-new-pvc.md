# Is It Safe to Create New PVCs for the etcd Upgrade?

## Context

When upgrading the konk etcd from `bitnami/etcd:3.4.14` to `cgr.dev/infoblox.com/etcd:3.7.x`,
the new chart uses `claimName: data-v2` instead of `claimName: data`. This creates brand-new
PVCs and starts etcd from scratch rather than migrating data from the old `data-*` PVCs.

This document explains why that is safe, what the key count difference means, and how to
verify this yourself.

---

## Why `data-v2` Instead of Reusing `data`?

The two images store etcd data at different paths inside the container:

| Image | Data directory | PVC path layout |
|-------|---------------|-----------------|
| `bitnami/etcd:3.4.14` | `/bitnami/etcd/data` | `data/member/` on the PVC |
| `cgr.dev/infoblox.com/etcd:3.7.x` | `/var/lib/etcd` | `member/` on the PVC |

If the new image reused the old `data` PVC, the etcd process would look for data at
`member/` but the existing files are under `data/member/` — a path mismatch. etcd would
either fail to start or start as a new cluster ignoring the existing data anyway.

Creating `data-v2` PVCs with `initialClusterState: new` is the correct approach: clean
slate, correct path layout from the first write.

---

## What Happens to the Old `data-*` PVCs?

They are **not deleted** by the upgrade. They remain Bound in the `aggregate` namespace
and can be inspected at any time. They will stay until manually deleted.

```bash
# Verify both old and new PVCs coexist after upgrade
kubectl get pvc -n aggregate | grep -E "data-bulk|data-v2"
```

Example output after upgrade:

```
data-bulk-konk-etcd-0      Bound    pvc-bc9d7bc6-...   8Gi   RWO   gp3   29h
data-bulk-konk-etcd-1      Bound    pvc-fa9416e4-...   8Gi   RWO   gp3   10h
data-bulk-konk-etcd-2      Bound    pvc-21e2d06f-...   8Gi   RWO   gp3   10h
data-v2-bulk-konk-etcd-0   Bound    pvc-1020b0bc-...   8Gi   RWO   gp3   14m
data-v2-bulk-konk-etcd-1   Bound    pvc-57ddb242-...   8Gi   RWO   gp3   14m
data-v2-bulk-konk-etcd-2   Bound    pvc-61f97690-...   8Gi   RWO   gp3   14m
```

---

## Key Count: Pre-upgrade vs Post-upgrade

After the upgrade, the etcd key count drops significantly. This looks alarming but is expected.

| Metric | Pre-upgrade (bitnami, 1 replica) | Post-upgrade (cgr.dev, 3 replicas) |
|--------|----------------------------------|-------------------------------------|
| Total keys | 213 | 54 (initial), grows over time |
| System RBAC keys | ~159 (clusterroles, bindings, etc.) | 0 initially |
| Application keys | ~54 | 54 |
| etcd version | 3.4.14 | 3.7.x |
| Cluster age | Long-lived (accumulated state) | Fresh start |

**The 54 post-upgrade keys are ALL the application objects** — exactly what the bulk
services need. They are written by the long-running `bulk` pods re-registering their
APIs immediately after the new etcd comes up.

**The ~159 "missing" system keys** are standard Kubernetes bootstrap objects written by
kube-apiserver over the lifetime of the old cluster. Analysis of every missing key:

| Key type | Count | Description | Auto-recovers? |
|----------|-------|-------------|----------------|
| `clusterroles` | 62 | Built-in K8s roles: `cluster-admin`, `system:controller:*`, `admin`, `edit`, `view` | Yes — kube-apiserver bootstrapper |
| `clusterrolebindings` | 43 | Built-in system bindings for controllers | Yes — kube-apiserver bootstrapper |
| `apiregistration.k8s.io` | 16 | Core API group registrations: `v1.`, `v1.rbac`, etc. | Yes — kube-aggregator on startup |
| `flowschemas` | 13 | API priority and fairness configs | Yes — bootstrapped by kube-apiserver |
| `prioritylevelconfigurations` | 8 | Request flow control | Yes — bootstrapped |
| `roles` + `rolebindings` | 14 | System roles in `kube-system`/`kube-public` | Yes — bootstrapped |
| `priorityclasses` | 2 | `system-cluster-critical`, `system-node-critical` | Yes — bootstrapped |
| `configmaps` | 1 | `extension-apiserver-authentication` | Yes — written by kube-apiserver |

**Zero application data is missing.** No custom resources, no user-created Secrets,
no app ConfigMaps.

---

## Why System RBAC Is Not Needed in konk

The konk inner cluster uses `--authorization-mode=Node,RBAC` but it does **not** run
`kube-controller-manager` or `kube-scheduler` inside the inner cluster. konk's inner
cluster is an API aggregation platform, not a full Kubernetes cluster.

The `system:controller:*` roles and bindings only matter when a controller-manager is
running and making calls against the apiserver. Since konk has none, those objects are
present in etcd but never exercised. Their absence after a fresh-start upgrade causes
no functional issues.

The only RBAC objects konk actually uses are the custom ones for application API groups
(`*.bulk.infoblox.com-edit`), which ARE present from the first minute.

---

## How to Verify: Inspect the Old PVC

You can inspect what was in the old etcd PVC after the upgrade to confirm no data loss.
Use `--force-new-cluster` to start a standalone etcd against the old PVC without needing
the other cluster members.

> **Note:** The old bitnami image stored data at `/bitnami/etcd/data`. Mount the PVC
> there when using a cgr.dev or upstream etcd image.

```bash
# 1. Create a debug pod mounting the old PVC
kubectl apply -n aggregate -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: etcd-inspect-old
  namespace: aggregate
spec:
  containers:
  - name: etcd
    image: gcr.io/etcd-development/etcd:v3.4.14
    command:
    - /bin/sh
    - -c
    - |
      etcd \
        --data-dir=/bitnami/etcd/data \
        --force-new-cluster \
        --listen-client-urls=http://127.0.0.1:2379 \
        --advertise-client-urls=http://127.0.0.1:2379 \
        --logger=zap 2>/dev/null &
      sleep 8
      ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 \
        get "" --prefix --keys-only | sort > /tmp/old-keys.txt
      echo "KEY_COUNT=$(wc -l < /tmp/old-keys.txt)"
      cat /tmp/old-keys.txt
      sleep 3600
    volumeMounts:
    - name: data
      mountPath: /bitnami/etcd/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-bulk-konk-etcd-0   # adjust if needed
  restartPolicy: Never
EOF

# 2. Wait for pod to run and dump keys
kubectl wait pod/etcd-inspect-old -n aggregate --for=condition=Ready --timeout=60s
sleep 15
kubectl logs etcd-inspect-old -n aggregate | grep "^KEY_COUNT="
kubectl logs etcd-inspect-old -n aggregate | grep "^/registry" | sort > /tmp/old-keys.txt

# 3. Dump current cluster keys (cgr.dev cert path)
kubectl exec -n aggregate bulk-konk-etcd-0 -- \
  etcdctl get "" --prefix --keys-only \
  --cacert=/etc/etcd/certs/client/ca.crt \
  --cert=/etc/etcd/certs/client/server.crt \
  --key=/etc/etcd/certs/client/server.key \
  --endpoints=https://localhost:2379 2>/dev/null | sort > /tmp/new-keys.txt

# 4. Compare
echo "=== Missing from new cluster ==="
comm -23 /tmp/old-keys.txt /tmp/new-keys.txt
echo "Missing count: $(comm -23 /tmp/old-keys.txt /tmp/new-keys.txt | wc -l)"

echo "=== Net-new in new cluster ==="
comm -13 /tmp/old-keys.txt /tmp/new-keys.txt
echo "Net-new count: $(comm -13 /tmp/old-keys.txt /tmp/new-keys.txt | wc -l)"

# 5. Categorize missing keys by type
echo "=== Missing key breakdown ==="
comm -23 /tmp/old-keys.txt /tmp/new-keys.txt \
  | sed 's|/registry/||' | cut -d/ -f1 | sort | uniq -c | sort -rn

# 6. Clean up
kubectl delete pod etcd-inspect-old -n aggregate
```

---

## Cert Paths by Image

The etcd client cert path differs between images. Use the correct path for `etcdctl` calls:

| Image | Cert directory | Example `etcdctl` flags |
|-------|---------------|------------------------|
| `bitnami/etcd:3.4.14` | `/opt/bitnami/etcd/certs/client/` | `--cacert=.../ca.crt --cert=.../server.crt --key=.../server.key` |
| `cgr.dev/infoblox.com/etcd:3.7.x` | `/etc/etcd/certs/client/` | same flag names, different base path |

The endpoint for both is `https://localhost:2379` when exec-ing from inside the pod.

---

## kube-apiserver Restart Behavior During Upgrade

When the etcd StatefulSet is recreated with fresh PVCs, the inner kube-apiserver loses
its etcd connection momentarily. The liveness probe (`/livez`, timeout=1s, failure=3,
period=10s) kills the container when etcd is unavailable for >30s.

Expected pattern during upgrade:

1. etcd StatefulSet deleted → kube-apiserver loses etcd → liveness probe kills it
2. New etcd starts (3-node, fresh data) → kube-apiserver restarts → connects
3. Application pods re-register their API services → 54 keys appear within minutes
4. kube-apiserver bootstrapper writes system objects → key count grows toward 200+
5. Cluster stabilizes — typically 3–8 restarts over 15–20 minutes is normal

The restarts show up as `x restarts over Nh` in `kubectl describe pod` events. Exit
code 0 (clean shutdown) is expected — the liveness probe issues a graceful kill.

---

## Old PVC Stale Data Notes

Running `etcdctl get "" --prefix --keys-only` only returns **live keys** — it does not
show deleted-object tombstones or compaction history. So the key counts from inspecting
the old PVC reflect genuine live objects at the time of the last write, not accumulated
garbage.

However, the total etcd DB size on disk (from `etcdctl endpoint status`) may be larger
than expected because etcd retains revision history between compactions. The key count
alone is the reliable measure.

---

## Summary: Safe to Use data-v2?

Yes.

- The old `data-*` PVCs are incompatible with the new image's data path — reusing them
  would cause a path mismatch at best, silent data corruption at worst.
- All keys in the old cluster that matter (application API registrations, namespaces,
  services) are re-created automatically by running pods within minutes of the new
  cluster starting.
- The system RBAC objects that go "missing" are bootstrap objects that konk doesn't
  actively use (no controller-manager runs inside the inner cluster).
- The old PVCs are preserved after upgrade and can be inspected using the debug pod
  recipe above if there is any concern.
