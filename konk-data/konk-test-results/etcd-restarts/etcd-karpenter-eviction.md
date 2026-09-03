# bulk-konk-etcd Karpenter Eviction Issue

**Date observed:** 2026-08-13
**Investigated by:** rsatal
**Status:** Root cause confirmed — fix pending (konk chart change required)
**Related doc:** [etcd-restarts.md](etcd-restarts.md) — covers the earlier `recreateStatefulSet` hook issue (Aug 11-12), which is a separate root cause

---

## Summary

`bulk-konk-etcd` pods in the `aggregate` namespace are being continuously evicted by
Karpenter's node consolidation (`WhenEmptyOrUnderutilized`) on both **us-dev-2** and **gov-stg-2**.
The evictions are staggered (one pod at a time, respecting Karpenter's disruption budget), so
etcd quorum is never lost — but the cycle repeats indefinitely and will not stop without a fix.

The root cause is that the etcd container has an extremely low CPU request (`10m`), which makes
every node it schedules onto appear underutilized to Karpenter within the `consolidateAfter`
window. There is also no `PodDisruptionBudget` protecting the StatefulSet.

---

## Affected Clusters

| Cluster | Node Pool | consolidateAfter | Eviction cadence | PDB | etcd CPU request |
|---------|-----------|-----------------|-----------------|-----|-----------------|
| **us-dev-2** | `nodescaling-node-pool` | 1h | ~50–90 min per pod | None | `10m` |
| **gov-stg-2** | `bottlerocket-nodescaling-pool` | 2h | ~60–80 min per pod | None | `10m` |

---

## Observed Eviction Timeline

### us-dev-2

All three etcd pods have been evicted in rolling fashion since at least 13 Aug 2026 morning.
Karpenter cycles through all three pods and then repeats.

| Round | Pod | Approx eviction time | Node terminated |
|-------|-----|---------------------|-----------------|
| 1 | etcd-2 | ~08:00 IST 13 Aug | nodescaling-node-pool (unknown) |
| 1 | etcd-1 | ~10:30 IST 13 Aug | nodescaling-node-pool-9jzxd |
| 2 | etcd-0 | ~13:00 IST 13 Aug | nodescaling-node-pool (unknown) |
| 2 | etcd-0 (again) | ~15:30 IST 13 Aug | confirmed — 30m age at next observation |

Pod ages at each observation:

```
# Observation 1 (round 1 in progress)
bulk-konk-etcd-0   1/1  Running  5h50m   ← stable
bulk-konk-etcd-1   1/1  Running  51m     ← just evicted & rescheduled
bulk-konk-etcd-2   1/1  Running  102m    ← evicted ~50 min before etcd-1

# Observation 2 (round 2, etcd-0 now evicted)
bulk-konk-etcd-0   1/1  Running  30m     ← evicted again
bulk-konk-etcd-1   1/1  Running  144m
bulk-konk-etcd-2   1/1  Running  5h39m
```

### gov-stg-2

Same pattern, slower cadence (~60–80 min) due to `consolidateAfter: 2h`.

```
# Observation (Aug 13)
bulk-konk-etcd-0   2/2  Running  20m     ← just evicted & rescheduled
bulk-konk-etcd-1   2/2  Running  35h     ← stable (not yet cycled)
bulk-konk-etcd-2   2/2  Running  80m     ← evicted ~80 min before etcd-0
```

---

## Root Cause

### 1. etcd CPU request is 10m

The etcd container in the `bulk-konk-etcd` StatefulSet requests only `10m` CPU:

```yaml
# us-dev-2 (1 container per pod)
resources:
  requests:
    cpu:    10m      # ← too low
    memory: 64Mi
  limits:
    memory: 4Gi

# gov-stg-2 (2 containers — etcd + linkerd-proxy sidecar)
# etcd container:
resources:
  requests:
    cpu:    10m      # ← too low
    memory: 64Mi
  limits:
    memory: 4Gi
# linkerd-proxy sidecar:
resources:
  requests:
    cpu:    100m
    memory: 20Mi
```

With only `10m` CPU requested per etcd pod, every node hosting a single etcd pod will have
very low CPU utilization as seen by Karpenter (etcd is I/O-bound, not CPU-bound, so actual
usage also stays low). Karpenter marks such nodes as `Underutilized` within its
`consolidateAfter` window and evicts the pod to consolidate.

> **Note:** During one observation the CPU request showed `57m` instead of `10m` — this may
> be VPA adjusting requests dynamically. If VPA is active, it could fluctuate back down,
> making this even less predictable.

### 2. No PodDisruptionBudget

```
$ kubectl get pdb -n aggregate
No resources found in aggregate namespace.
```

Without a PDB, Karpenter is free to evict any etcd pod as long as its own node-level
disruption budget allows it. Other workloads in the cluster (e.g. `discovery-compositor`,
`dnstap-adapter`, `appinfra-grafana`) have PDBs and are correctly blocked from eviction.
The etcd StatefulSet has no such protection.

### 3. Karpenter NodePool consolidation policy

Both affected clusters use `consolidationPolicy: WhenEmptyOrUnderutilized` with a
disruption budget of `nodes: 1` for `Underutilized`. This means:

- Karpenter constantly evaluates nodes for consolidation every `consolidateAfter` window
- It can terminate **1 underutilized node at a time** — meaning it evicts all pods from
  that EC2 node, then terminates the EC2 instance itself. The evicted pods reschedule
  onto other existing nodes (or a new cheaper node Karpenter provisions)
- When the etcd pod reschedules onto a new node, that new node is also soon flagged
  underutilized (because etcd requests only 10m CPU) → the cycle repeats indefinitely
- The `nodes: 1` budget is the **only thing preventing a full etcd outage** right now —
  it ensures Karpenter evicts at most 1 etcd pod at a time, preserving quorum (2/3).
  If this budget were `nodes: 3`, all three etcd pods could be evicted simultaneously

```yaml
# us-dev-2 — nodescaling-node-pool
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 1h
  budgets:
    - nodes: "1"
      reasons: [Underutilized]

# gov-stg-2 — bottlerocket-nodescaling-pool
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 2h
  budgets:
    - nodes: "1"
      reasons: [Underutilized]
```

### 4. EBS Multi-Attach delay on every eviction

Each eviction triggers an EBS volume detach/reattach cycle:

```
Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-..."
         Volume is already exclusively attached to one node and can't be attached to another
Normal   SuccessfulAttachVolume  AttachVolume.Attach succeeded for volume "pvc-..."
```

The pod cannot start until the volume fully detaches from the old node and reattaches to the
new one. This adds 1–2 minutes of unavailability per eviction on top of image pull time.

---

## Eviction Event Chain (per pod, every cycle)

```
Karpenter marks node as Underutilized
        ↓
DisruptionTerminating — nodeclaim/nodescaling-node-pool-XXXX
        ↓
Killing pod/bulk-konk-etcd-N   (Stopping container etcd)
        ↓
Evicted pod/bulk-konk-etcd-N   (Evicted pod: Underutilized)
        ↓
Unhealthy — Readiness probe errored: rpc error: code=Canceled desc=context canceled
        ↓
TopologyAwareHintsDisabled — service/bulk-konk-etcd-headless
  Insufficient number of endpoints (2 endpoints, 3 zones)
        ↓
StatefulSet creates replacement pod
        ↓
FailedAttachVolume — Multi-Attach error (EBS still attached to old node)
        ↓
SuccessfulAttachVolume (after old node releases the volume)
        ↓
Image pull → Container created → Container started
        ↓
TopologyAwareHintsEnabled (cluster back to 3 members)
        ↓
[~1h/2h later] — new node flagged Underutilized → REPEAT
```

---

## Secondary Impact: KonkService Probe Failures

### Confirmed on gov-stg-2 — 2026-08-13

Each etcd eviction causes **one or two readiness probe failures** on KonkService pods across
namespaces. This was confirmed live on gov-stg-2 with the following event chain:

```
12:26 UTC  Evicted pod/bulk-konk-etcd-0  (Karpenter: Underutilized)
12:26 UTC  Killing pod/bulk-konk-etcd-0  (SIGTERM sent — etcd starts graceful shutdown)
12:26 UTC  FailedAttachVolume            (Multi-Attach: EBS still attached to old node)
12:26 UTC  TopologyAwareHintsDisabled    (2 endpoints, 3 zones — headless service degraded)
12:27 UTC  SuccessfulAttachVolume        (EBS detached from old node, attached to new)
12:27 UTC  TopologyAwareHintsEnabled     (endpoints back to 3)
12:28 UTC  bulk-konk-etcd-0 containers started
12:29 UTC  ⚠️  ddi/ipam-importexport-apiservice-konk-service-apiservice-test:
           Readiness probe errored: rpc error: code = Canceled desc = context canceled
```

The KonkService probe failure occurs **during the rejoin phase**, not during the eviction
itself. When etcd-0 rejoins the cluster with a fresh linkerd-proxy, the konk apiserver
briefly drops its gRPC connection to that member. Any in-flight `kubectl api-resources`
call in the apiservice-test health loop at that moment fails with `context canceled`,
which writes `1` to `/tmp/healthy` and fails the probe for one cycle.

### Mechanism

```
etcd pod receives SIGTERM
        ↓
etcd gracefully shuts down → cancels in-flight gRPC requests
        ↓
(if evicted pod was etcd leader)
        ↓
Remaining 2 members elect new leader (~1–2s pause)
        ↓
konk apiserver briefly unable to commit writes during election
        ↓
kubectl api-resources in apiservice-test health loop fails → "context canceled"
        ↓
Health loop writes 1 to /tmp/healthy
        ↓
Readiness probe fails for 1–2 cycles (5–10s window)
        ↓
etcd-0 rejoins → gRPC connections re-established → probe recovers
```

### Comparison with us-stg-1 `recreateStatefulSet` issue

| Attribute | Karpenter eviction (us-dev-2, gov-stg-2) | `recreateStatefulSet` hook (us-stg-1) |
|-----------|------------------------------------------|---------------------------------------|
| Quorum lost? | **No** — 2/3 always up | **Yes** — all 3 deleted simultaneously |
| Probe failures per event | 1–2 | Hundreds (467 over 14h on us-stg-1) |
| Disruption duration | < 2 minutes | Hours |
| KonkService error | `rpc error: code = Canceled` | `rpc error: code = Canceled` + prolonged `0/1 Running` |
| `'spec' section must contain a non-empty 'id' field` error | **Not seen** | **Seen** — only after prolonged full outage |

The `'spec' section must contain a non-empty 'id' field` error only appears after the
konk apiserver loses its state due to an extended complete outage (all 3 etcd members
gone). The Karpenter eviction scenario never triggers it because quorum is always
maintained and the outage window is too short to corrupt apiserver state.

### Also observed: Karpenter evicting KonkService pods directly

On gov-stg-2, Karpenter is also evicting KonkService pods (kubeconfig, apiservice-test)
directly — not just etcd pods:

```
ntp   Normal  Evicted  pod/ntp-aggregate-api-apiservice-konk-service-kubeconfig-5bd99jr6pb
      Evicted pod: Underutilized
```

When a konk-service pod is evicted by Karpenter, its own readiness probe is canceled
mid-check, producing the same `rpc error: code = Canceled desc = context canceled` event.
This is a separate trigger from the etcd-induced disruption — it means probe failures can
occur on any KonkService namespace, not only the ones whose apiservice-test pod happened
to be checking at the moment of the etcd eviction.

---

## Secondary Impact: bulk-hr-watcher CronJob Failures

The `bulk-hr-watcher` CronJob in the `aggregate` namespace is failing with
`BackoffLimitExceeded` every ~3 minutes on us-dev-2. This is a downstream effect:
`hr-watcher` queries the inner konk API server (backed by the etcd cluster). During
the brief window between eviction and pod readiness, the konk apiserver may be
degraded, causing the watcher to fail.

```
Warning  BackoffLimitExceeded  job/bulk-hr-watcher-29776674
Warning  BackoffLimitExceeded  job/bulk-hr-watcher-29776677
Warning  BackoffLimitExceeded  job/bulk-hr-watcher-29776680
... (repeating every ~3 min)
```

---

## Differences Between Clusters

| Attribute | us-dev-2 | gov-stg-2 |
|-----------|----------|-----------|
| Node pool | `nodescaling-node-pool` | `bottlerocket-nodescaling-pool` |
| OS | Amazon Linux 2023 | Bottlerocket FIPS |
| `consolidateAfter` | 1h | 2h |
| Eviction cadence | ~50–90 min | ~60–80 min |
| Linkerd injection | Skipped (no annotation) | Injected (2/2 containers) |
| Total pod CPU request | `10m` | `110m` (10m etcd + 100m linkerd-proxy) |
| Harbor registry | `harbor.services.sdp.infoblox.com` | `harbor-services.sdp.stg.infoblox-fedcloud.com` |
| etcd image tag | `etcd:3.7.0` | `etcd:v3.7.0` |
| PDB | None | None |

Despite different node pools and Linkerd configurations, **both clusters share the same root
cause** — `10m` etcd CPU request + no PDB + Karpenter `WhenEmptyOrUnderutilized`.

---

## Fix

Both fixes must be applied in the **konk chart** (not DC repo), as they affect the
`bulk-konk-etcd` StatefulSet template rendered by the konk operator.

### Fix 1 — Increase etcd CPU request (required)

Raise the etcd container CPU request to at least `200m`. This makes the host node
appear sufficiently utilized to Karpenter and prevents the consolidation trigger.

```yaml
# konk chart — etcd container resources
resources:
  requests:
    cpu:    200m    # was 10m
    memory: 128Mi
  limits:
    memory: 4Gi
```

On gov-stg-2 with Linkerd injected (total 300m: 200m etcd + 100m linkerd-proxy), the node
will no longer appear underutilized.

### Fix 2 — Add PodDisruptionBudget with minAvailable: 2 (required)

Add a PDB to the konk chart for the etcd StatefulSet with `minAvailable: 2`.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: bulk-konk-etcd
  namespace: {{ .Release.Namespace }}
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: etcd
      app.kubernetes.io/instance: bulk-konk-etcd
```

Without this, even after raising CPU requests, a future regression in resource sizing could
re-expose the cluster to unprotected evictions.

#### Why minAvailable: 2 and NOT 3

Setting `minAvailable: 3` on a 3-replica StatefulSet results in `disruptionsAllowed=0`,
which **completely blocks Karpenter node consolidation AND Kubernetes node drains during
cluster upgrades**. This is the same problem found in PTOCP-5191 (dapr):

> *"The dapr namespace has a blocking PodDisruptionBudget (disruptionsAllowed=0) that will
> block node drains during Kubernetes upgrades."*
> — [PTOCP-5191](https://infoblox.atlassian.net/browse/PTOCP-5191)

The correct value is `minAvailable: 2`:

| PDB setting | Replicas | disruptionsAllowed | Effect |
|-------------|----------|--------------------|--------|
| `minAvailable: 3` | 3 | **0** | Blocks Karpenter AND node drains — same as dapr bug |
| **`minAvailable: 2`** | **3** | **1** | **Quorum safe, 1 eviction at a time, upgrades work** ✅ |
| `minAvailable: 1` | 3 | 2 | Allows 2 simultaneous evictions — quorum unsafe |

With `minAvailable: 2`:
- Karpenter can still evict **1 pod at a time** — etcd quorum (2/3) always maintained
- Kubernetes node drains during upgrades still work (1 disruption allowed at a time)
- Any attempt to evict a second pod while the first is recovering is blocked by the PDB

#### What happens with a single-replica etcd (minAvailable: 1)

If etcd were ever configured with 1 replica and no PDB, Karpenter would freely evict the
only pod — causing a complete etcd outage until the pod reschedules and the EBS volume
reattaches (~1-2 min). A PDB with `minAvailable: 1` on a single-replica setup would
block Karpenter entirely (0 disruptions allowed), protecting the single instance at the
cost of Karpenter not being able to consolidate that node.

### Fix 3 — Immediate stopgap (optional, can apply now without chart change)

Add the `karpenter.sh/do-not-disrupt: "true"` annotation to etcd pods to block Karpenter
from evicting them entirely. This can be applied directly to the StatefulSet pod template
as a temporary measure while the chart fix is prepared:

```bash
kubectl patch statefulset bulk-konk-etcd -n aggregate \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/metadata/annotations/karpenter.sh~1do-not-disrupt","value":"true"}]'
```

> **Warning:** This will trigger a StatefulSet rolling update (pod restart) when applied.
> Apply during a low-traffic window.

---

## Fix Priority

| Fix | Location | Effort | Impact |
|-----|----------|--------|--------|
| Raise CPU requests to 200m | konk chart | Low | Stops eviction cycle |
| Add PDB (minAvailable: 2) | konk chart | Low | Prevents future unprotected evictions |
| `do-not-disrupt` annotation | kubectl patch (immediate) | Very low | Immediate stopgap, causes one rolling restart |

---

## Supporting Evidence Files

| File | Content |
|------|---------|
| [etcd-recreate-events-us-dev-2-round1.txt](etcd-recreate-events-us-dev-2-round1.txt) | First observed eviction round on us-dev-2 (etcd-1 and etcd-2) |
| [etcd-recreate-events-us-dev-2-round2.txt](etcd-recreate-events-us-dev-2-round2.txt) | Second round — etcd-0 evicted, confirms infinite loop |
| [etcd-recreate-events-gov-stg-2.txt](etcd-recreate-events-gov-stg-2.txt) | gov-stg-2 eviction events with cluster comparison |
