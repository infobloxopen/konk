# ETcd Upgrade Issue - eu-stg (aggregate namespace)

**Date:** 2026-06-18  
**Cluster:** eu-stg (aggregate namespace)  
**Component:** bulk-konk-etcd StatefulSet  
**Status:** 🔴 CRITICAL - Etcd cluster incomplete, 2 of 3 pods stuck

---

## Summary

Attempted etcd version upgrade from 3.4.14 → 3.5.17 (Chart.yaml appVersion). The upgrade triggered a rolling restart, but etcd-1 and etcd-2 pods became stuck in `ContainerCreating` state due to missing EBS volumes.

**Current state:**
- ✅ bulk-konk-etcd-0: Running (1/1)
- ❌ bulk-konk-etcd-1: ContainerCreating (0/1) - **volume missing**
- ❌ bulk-konk-etcd-2: ContainerCreating (0/1) - **volume missing**

---

## Root Cause

**Stale PVCs referencing deleted EBS volumes — NOT caused by the rolling restart.**

The etcd StatefulSet was running **single-node** (only etcd-0) for at least 35 days before today's upgrade. etcd-1 and etcd-2 PVCs existed on the cluster but had no pods bound to them. The EBS volumes backing those PVCs were deleted from AWS at some unknown point in the past, but the PVC/PV objects were never cleaned up.

Today's upgrade scaled replicas from 1 → 3, which scheduled etcd-1 and etcd-2 pods. Kubernetes attempted to attach the volumes referenced in the existing PVCs — but those EBS volumes no longer exist in AWS.

**Error:** `InvalidVolume.NotFound: The volume 'vol-09145751fe4fe226b' does not exist.`

### Timeline
```
2024-09-09  etcd ran as 3 replicas — PVCs created (gp3)
    ↓
Some point later: etcd scaled down to 1 replica (etcd-0 only)
    ↓
PVCs for etcd-1 and etcd-2 kept (StatefulSets never auto-delete PVCs)
    ↓
EBS volumes vol-09145751fe4fe226b and vol-0ddbcf09ca8386f97 deleted in AWS
    ↓
2026-06-18  Upgrade scales replicas back to 3
    ↓
Pods try to attach deleted volumes → FailedAttachVolume
```

### PVC / PV Analysis

| Pod | PVC | PV | Volume Handle | StorageClass | Created | Status |
|-----|-----|----|---------------|--------------|---------|--------|
| etcd-0 | data-bulk-konk-etcd-0 | pvc-52bb7c70 | *(in-tree, no CSI handle)* | gp2 | 2023-09-27 | ✅ Running |
| etcd-1 | data-bulk-konk-etcd-1 | pvc-594aca44 | vol-09145751fe4fe226b | gp3 | 2024-09-09 | ❌ Volume missing |
| etcd-2 | data-bulk-konk-etcd-2 | pvc-80c900d6 | vol-0ddbcf09ca8386f97 | gp3 | 2024-09-09 | ❌ Volume missing |

**Key observations:**
- etcd-0 uses an older `gp2` StorageClass (2023 vintage) — a different deployment generation
- etcd-1 and etcd-2 PVCs are 646 days old, `gp3`, `reclaimPolicy: Delete`
- AZ affinity is correct (etcd-1 PV is pinned to `eu-central-1c`, node is also `eu-central-1c`) — **no AZ mismatch**
- The EBS volumes simply no longer exist in AWS; it is safe to delete the PVCs

---

## Pod Status Details

```
NAME                   READY   STATUS             RESTARTS   AGE
bulk-konk-etcd-0      1/1     Running            0          16m
bulk-konk-etcd-1      0/1     ContainerCreating  0          16m
bulk-konk-etcd-2      0/1     ContainerCreating  0          16m
```

### etcd-1 Events (sample)

```
Warning FailedAttachVolume  16m  attachdetach-controller
AttachVolume.Attach failed for volume "pvc-594aca44-8ba7-4993-b4f1-9408b7c33476": 
rpc error: code = Internal desc = Could not attach volume "vol-09145751fe4fe226b" to node: 
operation error EC2: AttachVolume, https response error StatusCode: 400, 
api error InvalidVolume.NotFound: The volume 'vol-09145751fe4fe226b' does not exist.
```

---

## Chart Configuration

**Deployed version:** 
- Chart: etcd-1.0.0
- App Version: 3.5.17 (declared)
- Actual image deployed: 3.6.8 (gcr.io/etcd-development/etcd:v3.6.8)

**StatefulSet image:**
```yaml
image: gcr.io/etcd-development/etcd:v3.6.8
```

**Persistence config:**
```yaml
persistence:
  enabled: true
  size: 8Gi
```

---

## Flux/Helm Release Status

**Secondary issue: konk-operator HelmRelease stuck in failed state**
- Status: UpgradeFailed (lasted 107 days before today's attempt)
- Actual Helm release: ✅ Deployed successfully (revision 2)
- Root cause: Flux artifact digest mismatch, not actual deployment failure

**Fix applied:** Deleted v1 release secret to clear stale state

---

## Resolution Steps

### Step 1: Delete stale PVCs
```bash
kubectl delete pvc data-bulk-konk-etcd-1 data-bulk-konk-etcd-2 -n aggregate
```

**Safe to delete** — the EBS volumes referenced by these PVCs no longer exist in AWS. There is no data to lose.

This will:
- Remove the stale PVC/PV objects pointing to non-existent EBS volumes
- Allow the StatefulSet controller to provision new PVCs with fresh EBS volumes
- Unblock etcd-1 and etcd-2 pods from `ContainerCreating`

### Step 2: Monitor cluster reformation
```bash
kubectl get pods -n aggregate -l app.kubernetes.io/name=etcd -w
```

Expected sequence:
1. etcd-1 and etcd-2 move to Pending
2. New volumes provisioned
3. Pods enter Running state
4. Etcd cluster member discovery completes (may take 30-60 seconds)

### Step 3: Verify cluster health
```bash
# Once all pods are running:
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl member list

# Check etcd endpoint health
kubectl exec -n aggregate bulk-konk-etcd-0 -- etcdctl endpoint health
```

Expected output (all 3 members healthy):
```
127.0.0.1:2379, 7d6a9d87754d3a0f, healthy
```

---

## Post-Resolution Validation

- [ ] All 3 etcd pods reach Running (1/1)
- [ ] Etcd cluster membership shows 3 members
- [ ] All endpoints report healthy
- [ ] bulk-konk operator pod restarts after etcd stabilizes
- [ ] bulk-konk-init pod completes successfully
- [ ] KonkService APIs become available

---

## Notes

- **Data loss risk: NONE** — The EBS volumes referenced by etcd-1 and etcd-2 PVCs no longer exist in AWS. The PVCs are already pointing to nothing. Deleting them only cleans up dead Kubernetes objects.
- **Etcd data integrity:** etcd-0 has been the sole member for at least 35 days and holds the full data set. Once etcd-1 and etcd-2 join the cluster with fresh volumes, etcd replication will sync them from the leader automatically.
- **Chart version discrepancy:** Chart.yaml declares `appVersion: 3.5.17` but the actual deployed image is `gcr.io/etcd-development/etcd:v3.6.8`. This is set via Helm values overriding the chart default. Verify if intentional.
- **Operator dependency:** `bulk` HelmRelease depends on `konk-operator` being ready. The konk-operator HelmRelease showed a stale `UpgradeFailed` status but the actual release was deployed successfully (revision 2). May need a `flux reconcile helmrelease bulk -n vela-system` after etcd stabilizes.
- **Single-node risk:** Running a 3-node etcd as single-node for extended periods is unsafe — quorum is lost if etcd-0 restarts. Consider ensuring replicas=3 is maintained going forward.

---

## Related Issues

- Konk operator HelmRelease failure (resolved by cache clearing)
- etcd chart versioning discrepancy (3.5.17 vs 3.6.8)

---

## References

- Helm release: bulk-konk-etcd@etcd-1.0.0 (revision 5)
- Statefulset: bulk-konk-etcd (-n aggregate)
- Chart path: helm-charts/etcd/Chart.yaml
- Commit: aca7e33
