# tagging-v2 — Service Issues (us-stg-1, 2026-08-12)

**Cluster:** `us-stg-1`
**Investigated:** 2026-08-12
**Namespaces affected:** `tagging-v2`, `aggregate`

---

## Summary

The `tagging-v2` service is under sustained memory pressure with all HPA replicas maxed out and no room to scale. This caused a bulk export to time out on 2026-08-05, and the cluster continues to show multiple active warnings today. A separate data integrity issue exists in the bulk operations database with 7,823 validation errors on tag value records.

---

## Issue 1 — tagging-v2 Memory Pressure (HPA at ceiling)

**Severity:** High
**Status:** Active

### Observed state

```
kubectl top pods -n tagging-v2

NAME                            CPU       MEMORY
tagging-v2-76bbd5d94b-6kdjp    87m       351Mi
tagging-v2-76bbd5d94b-ck7qb    68m       333Mi
tagging-v2-76bbd5d94b-jnjcc    52m       336Mi
tagging-v2-76bbd5d94b-ksd4s    113m      332Mi
tagging-v2-76bbd5d94b-xrbkv    20m       325Mi
```

```
kubectl describe hpa -n tagging-v2 tagging-v2

resource cpu on pods:     73% (132m) / 80%
resource memory on pods:  77% (342Mi) / 80%
Min replicas: 2   Max replicas: 5   Current replicas: 5
AbleToScale: True  ReadyForNewScale — recommended size matches current size
```

**Pod resource limits:**
```yaml
resources:
  requests:
    cpu: 100m
    memory: 250Mi
  limits:
    memory: 500Mi
```

### What this means

- All 5 replicas are running at 325–351 Mi each — 65–70% of the 500 Mi hard limit.
- HPA memory threshold is 80% of the 250 Mi request = **200 Mi per pod**. Actual usage of ~340 Mi is 136% above the request, well past the scale threshold.
- The HPA is already at `maxReplicas: 5` — it **cannot scale out further**. Any additional load or GC pressure has no relief valve.
- Under a bulk export that lists all tags (`GET /v2/tags?_limit=100`), GC pauses in the tagging pods can stall HTTP workers long enough to exceed the bulk client timeout.

### Impact

On **2026-08-05T13:14:27Z**, bulk called:
```
GET http://tagging.tagging-v2.svc.cluster.local:8081/v2/tags?_offset=0&_limit=100&_order_by=id
```
and received:
```
context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```
"Awaiting headers" means the TCP connection was established but the tagging HTTP server never sent a response — consistent with a GC pause or worker pool exhaustion under memory pressure.

A second timeout was also recorded in the ops log:
```
the server was unable to return a response in the time allotted, but may still be processing the request
```

### Fix

- Raise `tagging-v2` memory limit from `500Mi` to at least `750Mi` in the Helm values / DC repo.
- Raise `maxReplicas` from 5 to at least 8 to give the HPA room to absorb load spikes.
- Alternatively, raise the HPA memory target threshold above 80% of requests — but this only delays the problem if the limit stays at 500Mi.

---

## Issue 2 — bulk Pod OOMKilled

**Severity:** High
**Status:** Recovered (restarted, running)

### Observed state

```
kubectl describe pod -n aggregate bulk-89664d8f6-9gtw8

Last State: Terminated
  Reason:    OOMKilled
  Exit Code: 137
  Finished:  Wed, 12 Aug 2026 15:02:49 IST
Restart Count: 1
```

The bulk pod was killed by the OOM killer at 15:02:49 IST (09:32:49 UTC) today. A new pod was started immediately.

### Root cause

The bulk service loads tag records into memory during export operations. With 7,825 error records already in the DB and active export operations paging through `tagging.bulk.infoblox.com/v1alpha1/values`, the bulk pod heap grew beyond its limit. The bulk pod has no explicit memory limit set beyond the container default.

### Fix

Set an explicit memory limit and request for the bulk deployment. Investigate whether the export operation streams records or buffers them all in memory — if buffering, switch to a streaming approach.

---

## Issue 3 — konk Readiness Probe Flapping

**Severity:** Medium
**Status:** Active

### Observed state

```
kubectl get events -n tagging-v2 --sort-by='.lastTimestamp'

Warning  Unhealthy  39m (x467 over 14h)  kubelet
  Pod: tagging-aggregate-api-apiservice-konk-service-kubectl-apis75scr
  Readiness probe failed:
```

The readiness probe on this pod has failed **467 times over 14 hours** (~33 failures/hour, roughly every 2 minutes).

### How the probe works

```yaml
readinessProbe:
  exec:
    command: ["/bin/bash", "-c", "exit $(</tmp/healthy)"]
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

A shell script runs a loop that:
1. Calls `kubectl get apiservice v1alpha1.tagging.bulk.infoblox.com`
2. Calls `kubectl api-resources --api-group=tagging.bulk.infoblox.com`
3. Writes the exit code to `/tmp/healthy`

The apiservice currently shows `AVAILABLE: True` and the pod is marked `Ready: True` at time of investigation — but the repeated historical failures indicate the apiservice has been intermittently unavailable, likely during periods of tagging-v2 pod restarts or memory pressure events.

### Impact

When the readiness probe fails, the pod is removed from the service endpoint pool. If this is the only pod backing the konk service at that moment, the `tagging.bulk.infoblox.com/v1alpha1` API group becomes temporarily unavailable, which would cause bulk export/import operations that go through konk to fail.

### Fix

Investigate the apiservice availability during the tagging-v2 memory pressure window. If the flapping correlates with GC pauses on tagging-v2, fixing Issue 1 should reduce probe failures. Additionally, consider increasing `failureThreshold` on the probe to tolerate transient apiservice slowness.

---

## Issue 4 — Ingress Sync Error (metacontroller)

**Severity:** Medium
**Status:** Active (ongoing for 11+ hours)

### Observed state

```
kubectl get events -n tagging-v2 --sort-by='.lastTimestamp'

Warning  SyncError  12m (x82 over 11h)  metacontroller
  Ingress: tagging-v2/tagging-v2-ingress
  Sync error: can't reconcile children for Ingress tagging-v2/tagging-v2-ingress:
  resourceVersion should not be set on objects to be created
```

### Root cause

Metacontroller is attempting to create a child resource for the `tagging-v2-ingress` but includes a `resourceVersion` field in the create request. Kubernetes rejects this — `resourceVersion` is only valid on update (PUT/PATCH) requests, not create (POST). This is a metacontroller bug or a misconfigured composite controller webhook.

### Impact

The ingress object is not being managed correctly by metacontroller. However, since the ingress was last successfully reconciled and is serving traffic (the external CSP URL is reachable), the immediate user impact is low. The concern is that any desired change to the ingress (e.g., a new path, TLS cert rotation) will not be applied until this is fixed.

### Fix

Check the metacontroller `CompositeController` or `DecoratorController` definition for `tagging-v2-ingress`. The controller's sync hook response is likely returning the existing object (with `resourceVersion` set) instead of a clean object spec. The hook should strip `resourceVersion` from any objects it wants to create.

---

## Issue 5 — Kafka Topic Replica Reassignment Failures

**Severity:** Low
**Status:** Active

### Observed state

```
Warning  topic-update  kafkatopic/captured-events-stg-1.tagging-dapr-component.dapr-x.io
  failed to update topic: replica reassignment unsupported

Warning  topic-update  kafkatopic/async-auditlog-events-stg-1.tagging-dapr-component.dapr-x.io
  failed to update topic: replica reassignment unsupported
```

### Root cause

The Kafka operator (Strimzi or similar) is attempting to reassign partition replicas on these topics but the Kafka cluster version or broker configuration does not support the requested reassignment. This is typically a mismatch between the operator version and the Kafka broker version.

### Impact

Dapr components that use these Kafka topics for eventing (`captured-events`, `async-auditlog-events`) are not affected operationally — the existing topic configuration continues to work. Only the desired configuration change (replica count change) is not being applied.

### Fix

Check the Kafka broker version vs the Strimzi operator version. If the operator was recently upgraded, this may require a Kafka broker upgrade to match. Alternatively, check whether the `replicas` field on the KafkaTopic resource was recently changed and revert if not intentional.

---

## Issue 6 — Tag Value Data Integrity (bulk ops DB)

**Severity:** Medium
**Status:** Active (persistent errors in DB)

### Observed state

Queried `GET /bulk/v1/operation?_limit=200` as `atlasautomation@infoblox.site` on 2026-08-12:

| Count | data_type | Error |
|------:|-----------|-------|
| 7,576 | `tagging.bulk.infoblox.com/v1alpha1/values` | `'spec' section must contain a non-empty 'id' field` |
| 247 | `tagging.bulk.infoblox.com/v1alpha1/values` | `'name' field from 'metadata' section must match the field from the 'spec' section defined as a key: matadata.name = <tag_id>_<value_id>, spec.<key> = <value_id>` |
| 1 | `tagging.bulk.infoblox.com/v1alpha1/tags` | `context deadline exceeded` (2026-08-05T13:14:27Z) |
| 1 | `tagging.bulk.infoblox.com/v1alpha1/tags` | `server unable to return a response in time allotted` |

### Root cause

**7,576 missing `id` errors:** Tag value records in the system have an empty `id` field in their spec. This could indicate records created before a schema change that made `id` required, or records imported from a file that omitted the field.

**247 name mismatch errors:** The `metadata.name` for tag values is composed as `<tag_id>_<value_id>`, but the validation expects `spec.<key>` to match just the `<value_id>` portion. These records were likely created via an import where the composite name format was not accounted for. Note: the error message itself contains a typo (`matadata` instead of `metadata`) — this is a bug in the bulk service error text.

### Impact

These errors accumulate in the bulk operations log and cause `test_error_log` to fail continuously. They also indicate that a significant portion of tag value data on us-stg-1 may be in an inconsistent state.

### Fix

1. Identify the source operations (operation IDs) for these errors and determine when they were first recorded.
2. Check whether the affected tag value records are orphaned test data or production-equivalent data.
3. If test data: clean up via the tagging API and re-run imports with corrected files.
4. Fix the typo `matadata` → `metadata` in the bulk service error message.
