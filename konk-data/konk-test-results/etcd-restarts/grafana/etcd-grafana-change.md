# etcd Grafana Observability — Investigation & Changes

**Date:** 2026-08-18  
**Author:** Rahul Satal  
**Clusters:** us-dev-2, us-dev-4  

---

## Background

Investigated why etcd pod restarts were invisible in Kubernetes. The goal was to add proper observability so future restarts (any pod, any cause) show up in Grafana.

---

## Root Cause of Invisible Restarts

`kubectl get pods` shows `RESTARTS: 0` for etcd pods even after they are recreated. This is because etcd runs as a **StatefulSet with rolling updates** — when a node is recycled by Karpenter or the StatefulSet spec changes, pods are deleted and recreated with a new UID. The `RESTARTS` counter only tracks container crashes within the same pod UID, not pod recreation.

**Confirmed incident:** `bulk-konk-etcd-1` on us-dev-2 was recreated at `2026-08-17T03:45:36Z` when node `ip-172-19-201-15.ec2.internal` was Karpenter-recycled. 26+ other pods on the same node were also rescheduled. The RESTARTS counter stayed at 0.

**Why `etcd_server_leader_changes_seen_total` is not enough:**  
This metric only fires when a leader election happens. A follower pod restart does not trigger a leader change, so it goes completely undetected by this metric.

**Correct signal:** `process_start_time_seconds` per pod — any restart (leader or follower) causes a step-jump in this metric's value.

---

## Metrics Infrastructure

The cluster uses **Grafana Alloy** (`infra-monitoring-v3`) as the metrics collector, not a standalone Prometheus scraper. Alloy uses `prometheus.operator.podmonitors` — it watches `PodMonitor` CRs to discover scrape targets.

Two Prometheus instances:
- `appinfra-prometheus` (uid `000000021`) — per-cluster scraper, receives etcd metrics
- `Prometheus` (uid `000000001`) — used by the etcd dashboard (the literal datasource named "Prometheus")

---

## Changes Made

### 1. konk repo — PR #681 `feat/etcd-metrics-podmonitor`

**Repo:** `infobloxopen/konk`  
**PR:** https://github.com/infobloxopen/konk/pull/681  
**Merged:** 2026-08-18T05:31:37Z  
**Shipped in:** `v0.2.1-168-gb8dabd8-j207`

Added to `helm-charts/etcd/`:

#### `values.yaml` — new sections

```yaml
## @section Metrics parameters
metrics:
  enabled: false          # opt-in: opens /metrics on port 2381
  port: 2381
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "2381"
  podMonitor:
    enabled: false        # opt-in: creates PodMonitor CR for Grafana Alloy
    interval: 60s
    scrapeTimeout: 10s

## @section Dashboard parameters
dashboards:
  create: false           # opt-in: creates GrafanaDashboard CR
  prometheusUid: "000000001"
```

#### `templates/statefulset.yaml` — metrics env var + port (when `metrics.enabled: true`)

```yaml
- name: ETCD_LISTEN_METRICS_URLS
  value: "http://0.0.0.0:2381"
```

Plus a `metrics` container port at 2381. This is a **plain HTTP** endpoint separate from the TLS client port 2379.

#### `templates/podmonitor.yaml` — new file

Creates a `PodMonitor` CR (monitoring.coreos.com/v1) in the etcd namespace so Grafana Alloy discovers and scrapes the metrics endpoint.

#### `templates/dashboard.yaml` — new file

Creates a `GrafanaDashboard` CR (integreatly.org/v1alpha1) with:
- Label `integreatly.org/operator: appinfra-grafana` for Grafana operator discovery
- `customFolderName: "konk"` — dashboard lands in the same folder as the konk-operator dashboard
- Prometheus UID substituted at Helm render time from `dashboards.prometheusUid`

#### `dashboards/etcd.json` — new file

Grafana 10 dashboard (schemaVersion 39) with template variables `namespace` and `pod` (multi-select).

**3 rows:**

| Row | Panel | Metric | Purpose |
|-----|-------|--------|---------|
| Pod Restarts | Pod Start Time | `process_start_time_seconds` | Step-jump = any restart (leader or follower) |
| Pod Restarts | Pods Ready | `kube_pod_status_ready` sum | Drops from 3→2→3 during restart window |
| Cluster Health | Leader Changes Rate | `increase(etcd_server_leader_changes_seen_total[...])` | Spike = leader-disrupting event |
| Cluster Health | Proposals Failed/Pending | `etcd_server_proposals_failed_total` + `etcd_server_proposals_pending` | Write failures during disruption |
| Performance | WAL Sync Latency p99 | `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[...]))` | Disk pressure |
| Performance | Backend Commit Latency p99 | `histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[...]))` | MVCC/snapshot pressure |
| Performance | DB Size | `etcd_mvcc_db_total_size_in_bytes` + `etcd_mvcc_db_total_size_in_use_in_bytes` | Compaction health |
| Performance | Peer RTT p99 | `histogram_quantile(0.99, rate(etcd_network_peer_round_trip_time_seconds_bucket[...]))` | Network between etcd members |

---

### 2. DC repo — PR #146264 (us-dev-4)

**Repo:** `Infoblox-CTO/deployment-configurations`  
**PR:** https://github.com/Infoblox-CTO/deployment-configurations/pull/146264  
**File:** `envs/box-dev/us-dev-4/bulk-values.yaml`

```yaml
konk:
  custom:
    etcd:
      metrics:
        enabled: true
        podMonitor:
          enabled: true
      dashboards:
        create: true
```

### 3. DC repo — PR #146250 (us-dev-2)

**Repo:** `Infoblox-CTO/deployment-configurations`  
**PR:** https://github.com/Infoblox-CTO/deployment-configurations/pull/146250  
**File:** `envs/box-dev/us-dev-2/bulk-values.yaml`

Same block added (us-dev-2 had no prior `konk.custom.etcd` section).

---

## Value Flow

```
DC bulk-values.yaml  (konk.custom.etcd.metrics/dashboards)
  → bulk Helm chart  → Konk CR spec.etcd
  → konk chart etcd.yaml  → Etcd CR spec
  → konk-operator  → etcd Helm chart values
  → StatefulSet (ETCD_LISTEN_METRICS_URLS) + PodMonitor + GrafanaDashboard
```

---

## Deployment Issues on us-dev-4

### What happened

1. PR #146264 merged → Jenkins rendered → k8s.manifests updated → Flux applied the new Konk CR.
2. konk-operator updated the Etcd CR → etcd StatefulSet rolling update started (adding `ETCD_LISTEN_METRICS_URLS` changes the pod spec).
3. During the rolling update, the konk-apiserver briefly restarted → `bulk-konk-kubeconfig` secret was temporarily unavailable.
4. The Helm upgrade for the `bulk` HelmRelease (10m timeout) was waiting on bulk pod readiness. Bulk pods (spawned during the upgrade) could not mount the kubeconfig volume → upgrade timed out.
5. Helm attempted rollback → rollback also timed out → HelmRelease entered `RollbackFailed` terminal state.
6. The GrafanaDashboard CR was created, submitted to Grafana successfully, then deleted by the rollback.

### Root cause of timeout

Adding `ETCD_LISTEN_METRICS_URLS` to a 3-node etcd cluster triggers a full StatefulSet rolling restart. During the restart window (~3-5 min), new `bulk` deployment pods cannot start (kubeconfig volume mount fails). The `bulk` HelmRelease 10m timeout fires before the rolling update completes.

**Note:** The `bulk-konk-kubeconfig` secret was already missing from the cluster (pre-existing issue — stuck `Init:0/1` bulk pods were 3 days old). Our change exposed this gap.

### Resolution

Forced the HelmRelease out of `RollbackFailed` state using:

```bash
flux reconcile helmrelease bulk -n vela-system --context=us-dev-4 --reset
```

On the retry, the etcd pods rolled faster (images already cached, nodes warm). The upgrade completed within the 10m window. The GrafanaDashboard CR was resubmitted to Grafana successfully at `2026-08-18T~11:57Z`.

---

## Final State (us-dev-4)

| Resource | Status |
|----------|--------|
| `ETCD_LISTEN_METRICS_URLS` in StatefulSet | ✅ `http://0.0.0.0:2381` |
| PodMonitor `bulk-konk-etcd` in `aggregate` ns | ✅ Created |
| GrafanaDashboard submitted to Grafana | ✅ Submitted (CR may be ephemeral) |
| Dashboard in Grafana | ✅ `konk` folder → `etcd` (uid: `etcd-konk-infoblox`) |

---

## Accessing the Dashboard

In Grafana on us-dev-4:
- **Folder:** konk
- **Title:** etcd
- **URL path:** `/d/etcd-konk-infoblox/etcd`

Filter by `namespace=aggregate` and `pod=bulk-konk-etcd-*` to see the 3 etcd pods.
