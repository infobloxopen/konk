# Konk Grafana Dashboard Panels

Reference for what exists today, what to add now (Phase 1), and what is deferred (Phase 2).

**Source material:**
- `helm-charts/*/dashboards/*.json` — existing dashboards
- `scripts/e2e-konk-test.sh` (branch `etcd-upgrade-tests`, 3170 lines, 19 sections) — the failure modes these panels are designed to catch
- `.github/copilot-instructions.md` — architecture context

**Architecture constraint:** konk uses the Helm operator pattern with *no custom reconciliation logic* and defines *no custom Prometheus metrics* in Go. Every panel below must be sourced from kube-state-metrics, cert-manager, etcd, or the operator-sdk framework metrics.

---

## Part 1 — Existing Dashboards

Both are deployed as `GrafanaDashboard` CRs (integreatly `v1alpha1`) in the `konk` folder, gated on `dashboards.create=true`.

### 1.1 `konk-operator`

**File:** `helm-charts/konk-operator/dashboards/konk-operator.json`
**UID:** `8wi8LhdGk` · **Deployed by:** `helm-charts/konk-operator/templates/dashboard.yaml`

| Panel | Metric |
|-------|--------|
| Konk count | `count(resource_created_at_seconds{group="konk.infoblox.com",kind="Konk"})` |
| Kube API client requests | `sum(rate(rest_client_requests_total{app_kubernetes_io_instance="konk-operator"}[2m])) by (method, code)` |
| Konks ready | `kube_pod_status_ready` filtered to `.*-konk-[a-f0-9]+-[a-z0-9]+$` (positive=ready, negative=not-ready overlay) |

### 1.2 `etcd`

**File:** `helm-charts/etcd/dashboards/etcd.json`
**UID:** `etcd-konk-infoblox` · **Deployed by:** `helm-charts/etcd/templates/dashboard.yaml`
**Template variables:** `$namespace`, `$pod`

| Panel | Metric | Row |
|-------|--------|-----|
| Pod Start Time | `process_start_time_seconds` | Pod Restarts |
| Pods Ready | `kube_pod_status_ready` | Pod Restarts |
| Leader Changes Rate | `rate(etcd_server_leader_changes_seen_total[5m])` | Cluster Health |
| Proposals Failed | `etcd_server_proposals_failed_total` | Cluster Health |
| Proposals Pending | `etcd_server_proposals_pending` | Cluster Health |
| Peer RTT p99 | `etcd_network_peer_round_trip_time_seconds_bucket` | Cluster Health |
| WAL Sync Latency p99 | `etcd_disk_wal_fsync_duration_seconds_bucket` | Performance & Storage |
| Backend Commit Latency p99 | `etcd_disk_backend_commit_duration_seconds_bucket` | Performance & Storage |
| DB Size | `etcd_mvcc_db_total_size_in_bytes` | Performance & Storage |

### 1.3 KonkService coverage today

**None.** There is no dashboard, panel, or alert covering KonkService CRs, konk-service pods, APIService registration, kubeconfig certs, or backend endpoints. This is the largest observability gap and is the focus of Part 3.

---

## Part 2 — Changes to `konk-operator`

The operator dashboard stays the **landing page / overview**. Keep it small; drill-down lives in the new `konk-services` dashboard.

### Row: CR Overview

| Panel | Type | Metric | Reason |
|-------|------|--------|--------|
| KonkService count | Stat | `count(resource_created_at_seconds{group="konk.infoblox.com",kind="KonkService"})` | Only `Konk` CRs are counted today |
| Etcd CR count | Stat | `count(resource_created_at_seconds{group="konk.infoblox.com",kind="Etcd"})` | Etcd CRs untracked today |
| Operator 5xx error rate | Time series | `rate(rest_client_requests_total{app_kubernetes_io_instance="konk-operator",code=~"5.."}[5m])` | Operator reconcile failures against the Kube API |
| Konk pod restart count | Time series | `increase(kube_pod_container_status_restarts_total{pod=~".*-konk-[a-f0-9]+-[a-z0-9]+$"}[1h])` | kube-apiserver restarts per instance |

### Row: Provision Health

The `provision` component (`bulk-konk-init` Deployment) is a long-running loop — it provisions the PKI on startup, then sleeps until 30 days before each cert expires to trigger renewal. It exports no metrics, so health is inferred from pod-level signals.

| Panel | Type | Metric | Reason |
|-------|------|--------|--------|
| Provision pod ready | Stat | `kube_pod_status_ready{pod=~".*-konk-init-.*", condition="true"}` | Provision writes `/tmp/ready` only when healthy — a failing probe means cert provisioning/renewal is broken |
| Provision uptime | Stat | `time() - kube_pod_start_time{pod=~".*-konk-init-.*"}` | Long uptime = stable renewal cycle; a low value means a recent restart |
| Provision restarts (24h) | Stat | `increase(kube_pod_container_status_restarts_total{pod=~".*-konk-init-.*"}[24h])` | Each restart is a failed provisioning cycle |
| Provision restart history | Time series | `kube_pod_container_status_restarts_total{pod=~".*-konk-init-.*"}` | Correlate restart spikes with cert renewal windows |

### Row: Core PKI Cert Expiry

Covers the `provision`-managed certs only. KonkService certs live on the `konk-services` dashboard.

| Cert | TTL | Renewed by |
|------|-----|-----------|
| `apiserver-cert` | ~90 days | `provision` (wakes 30d before expiry) |
| `etcd-cert` | ~90 days | `provision` |
| `proxy-client` | ~90 days | `provision` |
| `bulk-konk-ca` | long-lived | cert-manager; annotated `helm.sh/resource-policy=keep` |

| Panel | Type | Metric | Alert |
|-------|------|--------|-------|
| Days until PKI cert expiry | Bar gauge | `(certmanager_certificate_expiration_timestamp_seconds{namespace="aggregate", name!~".*kubeconfig.*"} - time()) / 86400` | < 30d |
| Next provision wake-up (days) | Stat | `((certmanager_certificate_expiration_timestamp_seconds{namespace="aggregate", name!~".*kubeconfig.*"} - time()) / 86400) - 30` | < 0 = provision overdue to act |
| CA cert expiry | Stat | `(certmanager_certificate_expiration_timestamp_seconds{name=~".*bulk-konk-ca"} - time()) / 86400` | < 30d |
| cert-manager Certificates not Ready | Table | `certmanager_certificate_ready_status{namespace="aggregate", condition="True"} == 0` | any |

### Row: KonkService Summary (links to drill-down)

Four stat tiles only — full detail lives in `konk-services`. Add a Grafana dashboard link on each panel.

| Panel | Metric |
|-------|--------|
| KonkServices total | `count(resource_created_at_seconds{group="konk.infoblox.com",kind="KonkService"})` |
| KonkService Deployments unavailable | `count(kube_deployment_status_replicas_available{deployment=~".*-(kubeconfig\|konk-service-apiservice\|kubectl-apiservice)"} < 1)` |
| konk-service pods not Ready | `count(kube_pod_status_ready{pod=~".*-(kubeconfig\|apiservice\|apiservice-test)-.*", condition="true"} == 0)` |
| Min kubeconfig cert remaining (h) | `min((certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"} - time()) / 3600)` |

---

### Changes to `etcd` dashboard

| Panel | Type | Metric | Reason |
|-------|------|--------|--------|
| Has Leader | Stat | `etcd_server_has_leader` | Most critical health signal — no existing panel shows 0/1 directly |
| gRPC client traffic | Time series | `rate(etcd_network_client_grpc_received_bytes_total[5m])` + `rate(etcd_network_client_grpc_sent_bytes_total[5m])` | Detect load spikes from kube-apiservers |
| Proposals committed rate | Time series | `rate(etcd_server_proposals_committed_total[5m])` | Write throughput; complements failed/pending panels |
| Heartbeat send failures | Time series | `rate(etcd_server_heartbeat_send_failures_total[5m])` | Early warning before leader elections trigger |
| DB fragmentation ratio | Gauge | `1 - (etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes)` | High ratio = compaction + defrag needed |

---

## Part 3 — NEW Dashboard: `konk-services`

**Proposed file:** `helm-charts/konk-service/dashboards/konk-services.json`
**Proposed UID:** `konk-services-infoblox`
**Folder:** `konk` (same as existing dashboards)
**Template variables:** `$namespace` (multi-select, all), `$konkservice` (multi-select, all)

### Why a separate dashboard rather than adding to `konk-operator`

- **Scale** — far larger than it first appears. It is 9 namespaces × *N KonkServices per namespace* × 3 components. Observed in `ddi` alone: 8 KonkServices (`dns-config-importexport-apiservice-v2`, `dns-data-importexport-apiservice`, `ipam-importexport-apiservice`, `ipam-importexport-apiservice-v2`, `ipam-importexport-apiservice-v3`, `keys-importexport-apiservice`, …) ⇒ ~24 pods in that namespace alone. Fleet-wide this is well into the hundreds of pods. This would completely bury the 3 existing operator panels.
- **Different question** — `konk-operator` answers *"is the operator reconciling?"*; `konk-services` answers *"is tenant X's API actually registered and serving?"* Different audiences and different on-call responses.
- **Template variables** — the services view needs `$namespace`/`$konkservice` repeat rows; the operator view is deliberately cluster-wide with no variables.
- **Precedent** — `etcd` already has its own dashboard with its own variables.

Pattern: overview (`konk-operator`) → drill-down (`konk-services`).

### KonkService namespaces

`aggregate`, `ddi`, `atcapi`, `hostapp`, `ngp-cp`, `ntp`, `tagging-v2`, `redirect`, `endpoints`

### The three components per KonkService

Each KonkService produces three Deployments, matching the `konk-service` binary subcommands:

| Component label | Deployment name suffix | Subcommand | Loop |
|-----------------|----------------------|------------|------|
| `kubeconfig` | `-kubeconfig` | `reconcile-kubeconfig` | 30s — rebuilds admin kubeconfig from cert-manager secrets |
| `apiservice` | `-konk-service-apiservice` (v2) / `-kubectl-apiservice` (v1) | `reconcile-apiservice` | 30s — applies APIService + CRDs to the konk kube-apiserver |
| `apiservice-test` | `-apiservice-test` | `test-apiservice` | 30s ± 5s jitter — polls whether the APIService exists and its API group lists resources; writes `/tmp/healthy` to drive the readiness probe |

The **container name** inside each pod is the bare component name — `kubeconfig`, `apiservice`, `apiservice-test` — which is what cAdvisor metrics label on. Confirmed against a live `ddi` pod: `dns-config-importexport-apiservice-v2-konk-service-apiservichctbj-apiservice`, container `apiservice`.

> **Label caveat:** kube-state-metrics does not expose `app.kubernetes.io/component` / `app.kubernetes.io/instance` by default. Either (a) match by Deployment/pod name suffix regex as shown below — the chart truncates names to the 63-char DNS-1123 limit but always preserves the suffix — or (b) enable `--metric-labels-allowlist=deployments=[app.kubernetes.io/component,app.kubernetes.io/instance],pods=[...]` and join on `kube_deployment_labels`. Option (a) is used throughout below because it needs no KSM config change.

---

### Row 1 — Fleet Summary

No template variables; always visible at the top.

| Panel | Type | Metric |
|-------|------|--------|
| KonkServices total | Stat | `count(resource_created_at_seconds{group="konk.infoblox.com",kind="KonkService"})` |
| Deployments scaled to 0 | Stat (red if > 0) | `count(kube_deployment_spec_replicas{deployment=~".*-(kubeconfig\|konk-service-apiservice\|kubectl-apiservice\|apiservice-test)"} == 0)` |
| Deployments with 0 available | Stat (red if > 0) | `count(kube_deployment_status_replicas_available{deployment=~".*-(kubeconfig\|konk-service-apiservice\|kubectl-apiservice)"} < 1)` |
| Pods not Ready by component | Bar gauge | `count by (component) (kube_pod_status_ready{pod=~".*-(kubeconfig\|apiservice\|apiservice-test)-.*", condition="true"} == 0)` |
| Worst kubeconfig cert remaining | Stat (hours) | `min((certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"} - time()) / 3600)` |
| Backend services with no endpoints | Stat (red if > 0) | `count(kube_endpoint_address_available == 0)` |

---

### Row 2 — Deployment Completeness

**Covers e2e §5 and §6.** Every KonkService must have `kubeconfig` + `apiservice` Deployments with ≥1 available replica. `apiservice-test` is optional and not enforced.

e2e failure strings this catches:
- `"KonkService {ns}/{name}: Deployments scaled to 0: ..."`
- `"KonkService {ns}/{name}: missing component Deployments: ..."`
- `"KonkService {ns}/{name}: Deployments with no available replicas: ..."`
- `"KonkService {ns}/{name}: kubeconfig renewal Deployment '{d}' is scaled to 0 — client cert will expire (12h TTL)"`
- `"KonkService {ns}/{name}: kubeconfig Deployment '{d}' has 0 available replicas (desired={n})"`

| Panel | Type | Metric | Notes |
|-------|------|--------|-------|
| **kubeconfig Deployment scaled to 0** | Table (red) | `kube_deployment_spec_replicas{namespace=~"$namespace", deployment=~".*-kubeconfig"} == 0` | **Highest-value panel on the dashboard.** A scaled-to-0 kubeconfig Deployment silently expires the client cert within 12h with no other warning. Alert immediately. |
| Deployment desired vs available | Table | `kube_deployment_spec_replicas{namespace=~"$namespace", deployment=~".*-(kubeconfig\|konk-service-apiservice\|kubectl-apiservice\|apiservice-test)"}` joined with `kube_deployment_status_replicas_available{...}` | Red cell when `available < desired` |
| Unavailable replicas over time | Time series | `kube_deployment_status_replicas_unavailable{namespace=~"$namespace", deployment=~".*-(kubeconfig\|konk-service-apiservice\|kubectl-apiservice)"}` | Shows duration of degradation, not just current state |
| Missing component detection | Stat / table | `count by (namespace) (kube_deployment_spec_replicas{deployment=~".*-kubeconfig"})` compared against KonkService count per namespace | Non-zero delta = a KonkService is missing a required Deployment |

---

### Row 3 — Pod Health & Flapping

**Covers e2e §6.** Repeat this row per `$namespace`.

e2e failure strings this catches:
- `"kubectl-apiservice {ns}/{pod}: {ready} {status} — {not-ready duration}"`
- `"kubeconfig {ns}/{pod}: {ready} {status}"`
- `"apiservice-test {ns}/{pod}: {ready} Running — readiness probe failing (APIService unavailable)"`
- `"{component} {ns}/{pod}: {n} restart(s) — not running continuously since creation"`
- `"{component} {ns}/{pod}: recently recovered — became Ready {n}m ago (pod age: {n}m)"`

| Panel | Type | Metric | Notes |
|-------|------|--------|-------|
| **apiservice-test readiness** | State timeline (red on 0) | `kube_pod_status_ready{namespace=~"$namespace", pod=~".*-apiservice-test-.*", condition="true"}` | **Ground truth.** This pod's probe only passes when the APIService exists *and* its API group lists resources inside konk. A failing probe = the API is not actually serving, regardless of what every other panel says. Give it the most prominent placement in this row. |
| kubeconfig pod readiness | State timeline | `kube_pod_status_ready{namespace=~"$namespace", pod=~".*-kubeconfig-.*", condition="true"}` | Not-ready > 12h ⇒ cert has already expired |
| apiservice pod readiness | State timeline | `kube_pod_status_ready{namespace=~"$namespace", pod=~".*-(konk-service-apiservice\|kubectl-apiservice)-.*", condition="true"}` | |
| Restarts (24h) by component | Bar gauge | `increase(kube_pod_container_status_restarts_total{namespace=~"$namespace", pod=~".*-(kubeconfig\|apiservice\|apiservice-test)-.*"}[24h])` | Script warns on any restart — these pods should run continuously since creation |
| **Readiness flapping** | Time series | `changes(kube_pod_status_ready{namespace=~"$namespace", pod=~".*-(kubeconfig\|apiservice\|apiservice-test)-.*", condition="true"}[6h])` | Metric-native equivalent of the script's "recently recovered" / probe-flapping warnings. > 2 transitions in 6h = flapping. Distinguishes a transient blip from sustained instability. |
| Pod age vs. ready duration | Table | `time() - kube_pod_start_time{namespace=~"$namespace", pod=~".*-(kubeconfig\|apiservice\|apiservice-test)-.*"}` | A young pod that is Ready means a recent recovery — worth investigating why it restarted |

---

### Row 4 — Certificate Health

**Covers e2e §7, §9, §12.** Three cert classes with very different lifetimes — they must be separate panels with separate units and thresholds, or the 12h cert gets lost against the 90-day ones.

| Cert | TTL | Renewed by | Panel unit | Alert |
|------|-----|-----------|-----------|-------|
| kubeconfig client cert | **12 hours** | `kubeconfig` Deployment (30s loop) | hours | < 2h |
| `*-konk-service-server` | ~90 days | cert-manager | days | < 7d (script warns at 7d) |
| `bulk-konk-ca` | long-lived | cert-manager, `resource-policy=keep` | days | < 30d |

e2e failure strings this catches:
- `"client cert EXPIRED: {ns}/{secret} (issued={t} expired={t})"`
- `"client cert EXPIRING SOON (<1h): {ns}/{secret}"`
- `"{ns} server cert EXPIRED: {secret}"` / `"server cert EXPIRING within 7 days"`
- `"Certificate {ns}/{name}: Ready={status}"`
- `"cert-manager Issuer {name}: Ready={status}"`

| Panel | Type | Metric | Alert |
|-------|------|--------|-------|
| **kubeconfig cert remaining (hours)** | Bar gauge, per ns | `(certmanager_certificate_expiration_timestamp_seconds{namespace=~"$namespace", name=~".*kubeconfig.*"} - time()) / 3600` | < 2h critical, < 4h warn |
| Server cert remaining (days) | Bar gauge, per ns | `(certmanager_certificate_expiration_timestamp_seconds{namespace=~"$namespace", name=~".*konk-service-server"} - time()) / 86400` | < 7d |
| Certificates not Ready | Table | `certmanager_certificate_ready_status{namespace=~"$namespace", condition="True"} == 0` | any |
| Cert renewal activity | Time series | `changes(certmanager_certificate_expiration_timestamp_seconds{namespace=~"$namespace", name=~".*kubeconfig.*"}[24h])` | A 12h cert should renew ~2×/day. Zero changes over 24h = renewal loop is stuck even though the pod may look Ready. |
| **CA rotated without propagation** | Stat (red if firing) | `changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*bulk-konk-ca"}[1h]) > 0 and on() (count(changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"}[1h]) > 0) == 0)` | Catches the us-dev-5 stale-CA outage ~20 min *before* pods start failing. See §4.4-A. |

> The last two panels are the metric-native detectors for the CA-mismatch and stale-secret-mount failures. Full rationale, the log-based counterparts, and the correlation technique are in **§4.4**.

---

### Row 5 — Backend Endpoints

**Covers e2e §15.** The script's harshest failure: `"KonkService {ns}/{name}: backend service '{svc}' has NO ready endpoints — APIService backend completely down"`.

| Panel | Type | Metric | Alert |
|-------|------|--------|-------|
| **Backend services with no ready endpoints** | Table (red) | `kube_endpoint_address_available{namespace=~"$namespace"} == 0` | any — APIService backend is completely down |
| Ready endpoint count per backend | Time series | `kube_endpoint_address_available{namespace=~"$namespace"}` | drop to 0 |
| Missing Endpoints object | Table | `absent(kube_endpoint_address_available{namespace=~"$namespace"})` per expected service | catches `"backend service has no Endpoints object"` |
| Backend pod readiness | State timeline | `kube_pod_status_ready{namespace=~"$namespace", condition="true"}` across all KonkService namespaces | Broad view of the pods actually serving the aggregated APIs |

> **KSM version note:** newer kube-state-metrics replaces `kube_endpoint_address_available` with `kube_endpoint_address{ready="true"}`. If on a newer KSM, use `sum by (namespace, endpoint) (kube_endpoint_address{ready="true"}) == 0`. Confirm which is available before building.

---

### Row 6 — Resource Usage (CPU & Memory)

Modelled on the existing ad-hoc "check pod usage" dashboard (`grafana-csp.us-dev-2` UID `e2a52df7-0ce3-4449-ad2e-25b194d3dea0`), but scoped to konk-service containers only. Layout: **CPU usage and Memory usage side by side**, each with request/limit reference lines overlaid.

**Container names** are the component names — `apiservice`, `kubeconfig`, `apiservice-test` — *not* `konk-service`.

#### Variables — self-discovering, chained

Rather than hardcoding the namespace list, derive it from pods that actually run konk-service containers, so new KonkServices appear automatically:

```
$namespace = label_values(container_memory_working_set_bytes{container=~"kubeconfig|apiservice|apiservice-test"}, namespace)
$container = label_values(container_memory_working_set_bytes{namespace=~"$namespace"}, container)
$pod       = label_values(container_memory_working_set_bytes{namespace=~"$namespace", container=~"$container"}, pod)
```

This reproduces the reference dashboard's `ddi` / `apiservice` / `All` selection, but stays correct as KonkServices are added or removed.

#### Panels

| Panel | Type | Metric |
|-------|------|--------|
| **CPU usage** | Time series, per pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=~"$namespace", container=~"$container", pod=~"$pod"}[5m]))` |
| ↳ CPU requests overlay | Dashed reference line | `avg(kube_pod_container_resource_requests{namespace=~"$namespace", container=~"$container", pod=~"$pod", resource="cpu"})` |
| ↳ CPU throttling | Time series | `rate(container_cpu_cfs_throttled_seconds_total{namespace=~"$namespace", container=~"$container", pod=~"$pod"}[5m])` |
| **Memory usage** | Time series, per pod | `sum by (pod) (container_memory_working_set_bytes{namespace=~"$namespace", container=~"$container", pod=~"$pod"})` |
| ↳ Memory requests overlay | Dashed reference line | `avg(kube_pod_container_resource_requests{namespace=~"$namespace", container=~"$container", pod=~"$pod", resource="memory"})` |
| ↳ Memory limits overlay | Dashed reference line | `avg(kube_pod_container_resource_limits{namespace=~"$namespace", container=~"$container", pod=~"$pod", resource="memory"})` |
| **Memory usage vs limit %** | Time series, thresholds at 80 / 90 | `container_memory_working_set_bytes{namespace=~"$namespace", container=~"$container", pod=~"$pod"} / container_spec_memory_limit_bytes{namespace=~"$namespace", container=~"$container", pod=~"$pod"} * 100` |
| Peak memory over window | Table, sorted desc | `max_over_time(container_memory_working_set_bytes{namespace=~"$namespace", container=~"$container", pod=~"$pod"}[$__range])` |
| **OOMKills** | Table (red) | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled", namespace=~"$namespace", container=~"$container"}` |

#### Notes

- **Use `container_memory_working_set_bytes`, not `container_memory_usage_bytes`.** Working set is what the OOM killer evaluates; `usage_bytes` includes reclaimable page cache and reads alarmingly high for no reason.
- **Always filter `container!="" , container!="POD"`** on cAdvisor metrics, or the pause container and the pod-level rollup double-count. The `container=~"$container"` selector handles this implicitly, but keep it explicit if a panel drops the variable.
- **The usage-vs-limit % panel is the one worth alerting on**, more than raw bytes.
- **Pair OOMKills with Row 3.** These are 30-second reconcile loops, so a silent OOMKill surfaces in Row 3 only as an unexplained restart. This row supplies the *why*.
- **Requires cAdvisor/kubelet metrics** (`container_*`) — a different scrape source from the kube-state-metrics that Rows 1–5 use. See prerequisites in 4.3.

---

## Part 4 — Deferred (Phase 2) & Open Findings

Nothing below is being built now. Recorded so it is not lost.

### 4.1 TODO — Row 7: Ghost / Stale Resource Detection

**Deferred to Phase 2 — explicitly not being built now.** Covers e2e §16, §17, §18. Genuinely queryable from Prometheus via `kube_pod_container_info{image=...}`, so this is buildable whenever we choose to pick it up.

Background from the script:

> `# Helm's strategic merge on fresh install can leave ghost "kind" containers.`
> `# konk-service image is a ghost container left by Helm strategic merge — the pod`

e2e failure strings this would catch:
- `"{n} pod(s) have ghost konk-service container (Helm strategic merge leftover)"`
- `"{n} pod(s) still have stale /node: container images (ghost from Helm adopt/merge)"`
- `"{n} pod(s) have ghost /konk-app: image in aggregate (expected /kube-apiserver:v1.25.8)"`
- `"{n} pod(s) have ghost /konk-provision: image in aggregate (expected /node:v1.25.8)"`
- `"{n} namespace(s) have kubectl-apiservice pods stuck on stale secret mount"`
- `"stale secret mount: {ns} — {n} kubectl-apiservice pod(s) still 0/1 (CA correct, pod needs restart)"`

Proposed panels:

| Panel | Metric |
|-------|--------|
| Pods running ghost `konk-service` containers | `kube_pod_container_info{namespace=~"$namespace", container="konk-service", image!~".*konk-service:$expected_tag"}` |
| Stale `/node:` images | `kube_pod_container_info{namespace="aggregate", image=~".*/node:.*"}` where the pod should not have a node image |
| Ghost `/konk-app:` in aggregate | `kube_pod_container_info{namespace="aggregate", image=~".*/konk-app:.*"}` — expected `/kube-apiserver:v1.25.8` |
| Ghost `/konk-provision:` in aggregate | `kube_pod_container_info{namespace="aggregate", image=~".*/konk-provision:.*"}` — expected `/node:v1.25.8` |
| Image drift vs. operator expectation | `kube_pod_container_info` compared against the operator's `RELATED_IMAGE_*` env values |
| Old chart-name Deployments | `kube_deployment_spec_replicas{deployment=~".*-kubectl-apiservice"}` — v1 chart name; v2 uses `-konk-service-apiservice` |

**Open question for Phase 2:** the expected image tag comes from the operator's `RELATED_IMAGE_APISERVER` / `RELATED_IMAGE_PROVISION` / `RELATED_IMAGE_KIND` env vars, which are not exported as a metric. Either hardcode the expected tag per release in the dashboard JSON (brittle), or add a recording rule / small exporter that publishes the expected tags. Decide before building.

### 4.2 Signals NOT observable from Prometheus today

Roughly 40% of the e2e script's highest-value checks cannot be expressed as PromQL against the current metric set. Each needs a decision.

| Signal | e2e section | Why not observable | Possible fix |
|--------|-------------|--------------------|--------------|
| KonkService `.status.conditions` — `Deployed` reason, `ReleaseFailed` status/reason/time | §5 | CR status subresource is not exported by default kube-state-metrics | Add a **kube-state-metrics `CustomResourceStateMetrics`** config for `Konk`, `KonkService`, `Etcd`. Highest-leverage fix — unlocks `"Deployed='UNKNOWN'"` and `"ReleaseFailed=True reason=..."` as real metrics. |
| Helm ownership conflicts — missing `meta.helm.sh/release-name` / `release-namespace` annotations | §4, §5 | Annotation-level state, not exported | Same KSM CustomResourceState config, or `--metric-annotations-allowlist` |
| **CA fingerprint mismatch** — kubeconfig secrets signed by a stale CA after etcd bootstrap rotated it | §7, §9 | Comparing raw Secret *contents* is not possible from metrics | **Partially solved — see §4.4.** The rotation-without-propagation pattern is detectable from cert-manager metrics alone, and the x509 failure is detectable from logs. A custom exporter is now a *nice-to-have* for exact fingerprint comparison, no longer a prerequisite. Script's message: `"CA mismatch detected — kubeconfig secrets are signed by a stale CA (etcd bootstrap rotated the CA)"`, remediated by `./fix-ca-mismatch.sh` |
| APIService `Available` condition **inside** konk | §8 | The inner konk cluster is not a Prometheus scrape target from the parent cluster | Either scrape the inner apiserver, or rely on `apiservice-test` pod readiness (Row 3) as the proxy — currently the only signal we have |
| APIService re-registration after deletion (60s SLO) | §8 | Behavioural test, not a state metric | Keep in e2e; not a dashboard concern |
| konk-operator log errors — `"Release failed"`, reconcile errors | §11 | Log-derived | Loki / log-based metrics, if available |
| External CSP API integration (tagging, bulk export/import) | §13, §14 | Black-box API tests against the CSP endpoint | Belongs in the k6 smoke-test dashboard, not here |

**Recommendation:** the kube-state-metrics `CustomResourceStateMetrics` config is the single highest-value follow-up — it unlocks the KonkService CR condition and Helm-ownership panels, which are the two most common real-world failure modes seen in the e2e runs. Worth scoping as its own task.

### 4.3 Prerequisites to confirm before building

- [ ] kube-state-metrics is deployed and scraped on the target clusters
- [ ] cAdvisor / kubelet metrics are scraped (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_spec_memory_limit_bytes`) — required by Row 6 only, and a different scrape source from KSM
- [ ] Confirm konk-service containers actually have memory **limits** set — the Row 6 usage-vs-limit % panel and `container_spec_memory_limit_bytes` return nothing if limits are unset
- [ ] Which KSM version — determines `kube_endpoint_address_available` vs `kube_endpoint_address{ready="true"}`
- [ ] cert-manager metrics are scraped (`certmanager_certificate_expiration_timestamp_seconds`, `certmanager_certificate_ready_status`)
- [ ] Confirm the Deployment/pod name suffix regexes match on a live cluster (v1 `-kubectl-apiservice` vs v2 `-konk-service-apiservice` both still present?)
- [ ] Decide whether to enable `--metric-labels-allowlist` for `app.kubernetes.io/component` and `app.kubernetes.io/instance` — would make every query in Part 3 cleaner and less brittle than name regexes
- [ ] **Is Loki (or another log backend) deployed and wired into Grafana on these clusters?** Determines how much of §4.4 is buildable

---

### 4.4 Log-based detection for cert / CA failures

Several of the highest-impact real-world incidents leave no metric trace but a very distinctive **log** trace. Source incidents:

- [`issues/Client-cert-issue/x509_issue-us-dev-5.md`](../issues/Client-cert-issue/x509_issue-us-dev-5.md) — CA rotation after etcd `claimName` migration (PR #634), all `kubectl-apiservice` pods `0/1` across 8 namespaces
- [`issues/CA-cert-x509-issue.md/kubeconfig-cert-expiry-503.md`](../issues/CA-cert-x509-issue.md/kubeconfig-cert-expiry-503.md) — 12h kubeconfig cert expiry causing `503` via the aggregation layer

#### A. Metric-only detectors (no log backend required) ✅

These work with the cert-manager metrics already in Part 5, and should be built regardless of whether Loki exists.

| Detector | PromQL | Catches |
|----------|--------|---------|
| **CA rotated without propagation** | `changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*bulk-konk-ca"}[1h]) > 0 and on() (count(changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"}[1h]) > 0) == 0)` | The exact us-dev-5 failure: `kubeadm init` generated a new CA, but the per-namespace `kubeconfig-cert` secrets were never re-issued |
| **12h cert not rotating** | `changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"}[24h]) == 0` | A 12h cert should re-issue ~2×/day. Zero changes in 24h = the renewal path is stuck even though pods look Ready |

> **The first detector is the single highest-value alert in this document.** Per the us-dev-5 timeline, the new CA was generated at ~14:13 and pods only began failing at ~14:33 — a **20-minute warning window**. This alert fires inside that window, i.e. *before* the outage, not after. It also needs nothing that isn't already scraped.

#### B. Log-based detectors (require Loki or equivalent)

Exact strings, taken verbatim from the incident write-ups and the e2e script:

| Signal | Source pods | Query |
|--------|-------------|-------|
| **x509 unknown authority** | `kubectl-apiservice` / `konk-service-apiservice`, all KonkService namespaces | `sum by (namespace) (count_over_time({namespace=~"aggregate\|ddi\|atcapi\|hostapp\|ngp-cp\|ntp\|tagging-v2\|redirect\|endpoints"} \|= "x509: certificate signed by unknown authority" [5m]))` |
| **Client cert expired rejections** | `bulk-konk` apiserver, `aggregate` ns | `count_over_time({namespace="aggregate", pod=~"bulk-konk-.*"} \|= "certificate has expired" [2m])` — e2e §10 fails on any hit in a 2-min window: `"bulk-konk apiserver: {n} 'certificate has expired' rejection(s) in last 2 min — clients holding stale certs"` |
| **Aggregation-layer 503** | konk apiserver | `count_over_time({...} \|= "error trying to reach service" \|= "INTERNAL_ERROR" [5m])` |
| **Operator release failures** | `konk-operator`, `konk` ns | `count_over_time({namespace="konk", pod=~"konk-operator-.*"} \|~ "Release failed\|reconcile error" [5m])` |
| **Helm hook failures** | `konk-operator` | `count_over_time({namespace="konk", pod=~"konk-operator-.*"} \|~ "(pre\|post)-(install\|upgrade) hooks failed" [5m])` |

Full x509 error text for reference:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
(possibly because of "crypto/rsa: verification error" while trying to verify
candidate authority certificate "kubernetes")
```

#### C. The correlation panel — why a single query is not enough

This is the subtle part, and the reason a naive "grep the reconciler logs" approach fails. From the us-dev-5 write-up:

> The cert in the secret WAS unchanged (cert-manager hadn't re-issued it) — so the reconciler correctly determined nothing changed. The problem was upstream.

`reconcile-kubeconfig` logs `"Certs unchanged, skipping update"` and **looks completely healthy** while every consumer downstream is failing TLS. The diagnostic signature is the *pair*, not either line alone:

| Panel | Query | Meaning |
|-------|-------|---------|
| Stale-CA correlation | `{...} \|= "x509: certificate signed by unknown authority"` **and** `{...} \|= "Certs unchanged, skipping update"` rendered on one time axis | Both firing together ⇒ stale CA and the reconciler is blind to it. Either alone is ambiguous. |

Build this as a single panel with two queries so the overlap is visually obvious.

#### D. Scope note

The `kubeconfig-cert-expiry-503` incident is ultimately an **`atlas.tagging.aggregateapi`** defect — `k8s.io/apiserver` caches the client TLS cert in memory and never reloads it from disk when the mounted secret rotates. Split the ownership:

- **This dashboard** covers the konk-side signal: *is the cert rotating on schedule?* (§4.4-A, Row 4)
- **The consuming service's dashboard** covers: *did the consumer pick up the rotation?*

The planned konk-side fix — annotating dependent Deployments with `konk.infoblox.com/cert-checksum` in `cmd/konk-service/reconcile_kubeconfig.go` to force a rolling restart — is still pending. Once shipped, add a panel on Deployment generation changes correlated with cert rotation to confirm it is working.

---

## Part 5 — Metric Sources

| Source | How scraped | Metrics used |
|--------|-------------|--------------|
| operator-sdk framework | `ServiceMonitor` at `config/prometheus/monitor.yaml` — operator pod `/metrics`, port `https` | `resource_created_at_seconds`, `rest_client_requests_total` |
| etcd | `PodMonitor` at `helm-charts/etcd/templates/podmonitor.yaml` — etcd pods, port `metrics` (2381) | all `etcd_*` |
| kube-state-metrics | Cluster-wide (assumed present) | `kube_pod_status_ready`, `kube_pod_start_time`, `kube_pod_container_status_restarts_total`, `kube_pod_container_info`, `kube_deployment_spec_replicas`, `kube_deployment_status_replicas_available`, `kube_deployment_status_replicas_unavailable`, `kube_endpoint_address_available` |
| cert-manager | Cluster-wide (assumed present) | `certmanager_certificate_expiration_timestamp_seconds`, `certmanager_certificate_ready_status` |
| cAdvisor / kubelet | Cluster-wide (assumed present) — **Row 6 only** | `container_cpu_usage_seconds_total`, `container_cpu_cfs_throttled_seconds_total`, `container_memory_working_set_bytes`, `container_spec_memory_limit_bytes` |

---

## Reference Dashboards

| Dashboard | URL | Note |
|-----------|-----|------|
| "ankur check pod usage" | `grafana-csp.us-dev-2.eng.test.infoblox.com/d/e2a52df7-0ce3-4449-ad2e-25b194d3dea0` | Ad-hoc CPU/memory-by-pod dashboard that Row 6 is modelled on. SSO-gated. To mirror its panel definitions exactly, export via **Dashboard settings → JSON Model**. |

---

## Part 6 — Implementation Notes & Corrections

Parts 2 and 3 were built in konk PR #688 (merged) and corrected in PR #689 after
validating every panel against live us-dev-5 data. This section records what the
spec got wrong, because most of it was only discoverable by looking at rendered
panels — `helm lint`, PromQL parsing and Helm render checks all passed throughout.

A third round followed once #689 was deployed to us-dev-5 and all three dashboards
were reviewed in the browser: konk PR **#690**, written up in
[`konk-dashboard-followups.md`](konk-dashboard-followups.md) (items 1–14). See
6.9 — its single root cause is that the fixes in 6.5 and 6.6 were applied to the
etcd dashboard only and never swept to the other two.

### 6.1 `★ CA rotated without propagation` could never fire

**This is the most important correction in this document**, because §4.4-A calls
this detector "the single highest-value alert" — the one that should catch the
us-dev-5 stale-CA outage ~20 minutes before pods start failing TLS.

**As specified, it was permanently empty.** The query was:

```promql
changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*bulk-konk-ca"}[1h]) > 0
  and on() (count(changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"}[1h]) > 0) == 0)
```

Two independent defects:

**(a) `.*bulk-konk-ca` matches no Certificate.** The konk CA is generated by
kubeadm inside the `provision` container and stored as a plain
`kubernetes.io/tls` Secret. cert-manager never *issues* it, so no
`Certificate` object exists and `certmanager_*` metrics cannot see it. Verified
on us-dev-5:

- `secret/bulk-konk-ca` exists in `aggregate` (type `kubernetes.io/tls`, no
  cert-manager annotations)
- the `aggregate` namespace holds exactly three Certificates —
  `bulk-konk-ingress-client`, `bulk-konk-requestheader-proxy-client`,
  `bulk-konk-requestheader-self-signed` — none matching

With no series on the left of the `and`, the whole expression returned nothing.

**(b) `count(...) == 0` cannot fire either.** `count()` over an empty set returns
*no series*, not `0`, so even a working left-hand side would never find a match.
Needs `(count(...) or vector(0)) == 0`.

**Why this was easy to miss:** the panel has a null-value mapping that renders
`OK` in green. A dead detector and a healthy cluster look identical — arguably
worse than no panel at all.

**The fix.** The CA *is* observable, just not through cert-manager:

- kube-state-metrics exports secret metadata on these clusters —
  `kube_secret_created`, `kube_secret_info`,
  `kube_secret_metadata_resource_version` (often disabled for security; present
  here)
- `ClusterIssuer bulk-konk-kubeadm-ca`, which every kubeconfig Certificate
  references via `issuerRef`, resolves `spec.ca.secretName: bulk-konk-ca` —
  confirming that Secret is the CA

```promql
(max(changes(kube_secret_metadata_resource_version{secret=~".*-konk-ca"}[1h])) > 0)
  and on()
((count(changes(certmanager_certificate_expiration_timestamp_seconds{name=~".*kubeconfig.*"}[1h]) > 0) or vector(0)) == 0)
```

Design points:

- **`resource_version`, not `kube_secret_created`** — rotation may update the
  Secret in place, leaving the creation timestamp untouched.
- **Deliberately unscoped by namespace.** The Secret exists twice: in the konk
  namespace, and in `cert-manager`, because cert-manager resolves ClusterIssuer
  CAs from `--cluster-resource-namespace` (verified `$(POD_NAMESPACE)`). `max()`
  over both means a change to either copy trips the alert, which also covers the
  copy drifting from its source. On us-dev-5 their resourceVersions already
  differ (`5.465e9` in `aggregate` vs `5.457e9` in `cert-manager`).

**Residual limitation, not yet closed.** The detector assumes a CA change bumps
the Secret's `resourceVersion`. True for in-place update and for
delete/recreate; **false** if rotation is performed by replacing the whole
ClusterIssuer. A real rotation has not been observed since the fix, so the
firing path is unproven end to end — treat as "should fire" rather than
"verified fires". §4.4-B's log-based detector remains the independent
cross-check.

### 6.2 Other spec queries that could not work as written

| § | Query | Why it failed | Fix |
|---|-------|---------------|-----|
| Row 1 | `count by (component) (...)` | kube-state-metrics exposes no `component` label — the spec's own label caveat says so | one series per component |
| Row 1/5 | `kube_endpoint_address_available` | **removed in KSM v2.10+**; this cluster runs v2.17.0. Returned empty, which `or vector(0)` rendered as a confident `0` — a false all-clear on the most severe check | `kube_endpoint_info` **unless** `kube_endpoint_address{ready="true"}` |
| Row 5 | `sum(kube_endpoint_address{ready="true"}) == 0` (the spec's own suggested replacement) | a backend with no ready addresses has **no** `ready="true"` series, so the sum is empty and `== 0` never matches — same trap in new clothes | set difference against `kube_endpoint_info` |
| Row 2 | `count by (namespace) (A) - on(namespace) (count by (namespace) (B) or vector(0))` | `vector(0)` is unlabelled so `- on(namespace)` can never match it; empty in exactly the missing-Deployment case it exists for | label-preserving zero: `or (A * 0)` |
| Rows 1/3 | pod-name suffix regexes | see 6.3 | deployment names |
| Row 2/3 | `app_kubernetes_io_instance="konk-operator"` | pod labels are not mapped into metrics by annotation discovery or by a default PodMonitor | scope by `namespace="konk"` |

Any `count(X == 0)` pattern needs `or vector(0)` to render `0` rather than
"No data" — but only where both sides are unlabelled. `count()` without `by()`
drops all labels, so the fallback dedupes correctly; with `by (...)` it does not,
and leaves a phantom series named after the raw query.

### 6.3 Pod names cannot identify components

§Part 3's label caveat offers "(a) match by Deployment/pod name suffix regex —
the chart truncates names to the 63-char DNS-1123 limit but always preserves the
suffix". **That is true for Deployments and false for pods.** Kubernetes
truncates the ReplicaSet name to fit 63 chars and *then* appends the pod hash,
cutting through the component name.

Measured across all 51 konk-service pods on us-dev-5, per component out of 17:

| Component | Matched by the spec's regex |
|-----------|---------------------------|
| kubeconfig | 13 / 17 |
| apiservice | 6 / 17 |
| apiservice-test | 3 / 17 |

Two pods matched nothing at all. Worse, **`apiservice` and `apiservice-test` are
indistinguishable by pod name** — the only difference is the trailing `-test`,
exactly what truncation removes first. Every candidate fragment matches both
identically:

```
'kubect'            apiservice 17/17   apiservice-test 17/17
'kubectl-apis'                 13/17                   13/17
'kubectl-apise'                 9/17                    9/17
'kubectl-apiservi'              7/17                    7/17
```

Container names are not a fallback either: 51 pods carry a container named
`kind` and only 10/5/2 carry component-named containers — the v1/v2 chart split
plus the ghost-container problem in §4.1.

**What is reliable:** Deployment names — 17/17/17 per component, mutually
exclusive, 51/51 total, because the *chart* truncates and then re-appends the
suffix. Per-component panels now read
`kube_deployment_status_replicas_available`; with `replicaCount: 1`
"0 available" is exactly "its pod is not ready", and the deployment name also
identifies the KonkService, which a truncated pod name cannot. Panels needing no
component split use `.*konk-service.*` — 51/51, zero over-match.

### 6.4 Endpoint panels must be scoped to real backends

Scoping only by namespace counted **all 276** Endpoints objects in the nine konk
namespaces and reported unrelated workloads (`ddi/gmr-ui`,
`ngp-cp/prometheus-service`, `aggregate/worker`, `endpoints/cache`) as failures —
11 false positives in red.

The real backends are declared in each KonkService's `spec.service.name`: 11
distinct Services for 17 KonkServices, since v1 and v2 share one. All end in
`-apiservice`, and `endpoint=~".*-apiservice"` is exactly precise here — 11
matched, 0 backends missed, 0 extras.

### 6.5 Rate windows must exceed the scrape interval

The chart scrapes etcd every 60s (`metrics.podMonitor.interval`). `$__rate_interval`
resolves to less than that, which is one or two samples, and `rate()`/`increase()`
need two — so those panels returned **nothing at all**, not zero.

Grafana computes `$__rate_interval = max($__interval + scrapeInterval, 4 × scrapeInterval)`
where `scrapeInterval` is the **datasource's** `timeInterval`. A panel's Min
interval only floors `$__interval`; it does **not** feed the 4× term, so setting
Min interval to `1m` does not rescue it. All rate windows are now an explicit `[5m]`.

> **Corrected 2026-08-24.** This section originally said the datasource default is
> 15s and that `$__rate_interval` therefore resolves to ~60–75s. The actual
> datasource is Cortex with **`timeInterval: 6s`** (verified on the
> `GrafanaDataSource` object, uid `000000001`), so the expression is
> `max($__interval + 6s, 24s)`: ~86s at a 24h range, and a hard floor of **24s**
> at short ranges. Smaller than originally stated, so the starvation is worse than
> described — the conclusion and the fix are unchanged.

Measured on a live Prometheus, series returned by `increase()` per window:
`[30s]` → 8, `[1m]` → 1904, `[4m]` → 1916.

### 6.6 Healthy states must not render as alarms

Three separate instances, all of which made a healthy cluster look broken:

- **"No data" in an alarm colour** — 10 panels used a red *base* threshold for
  "lower is worse" metrics. Grafana paints the no-series case with the base
  colour, so absent metrics were indistinguishable from a critical alarm. Fixed
  with a neutral base plus an explicit red step. Cert panels needed a red step at
  a large negative sentinel, since "hours remaining" goes negative once expired —
  a naive neutral base would have traded a false alarm for a missed one.
- **Threshold area shading** — `thresholdsStyle: line+area` with a 0.01 ops/s
  threshold and an auto-scaled axis painted ~100% of Heartbeat Send Failures red
  while it read zero.
- **`DB Fragmentation Ratio`** — read 0.92 (RED) on a healthy cluster. etcd
  pre-allocates and never shrinks its file, so a mostly-empty 4 MiB DB is ~92%
  "fragmented" while the reclaimable space is ~4 MiB. Now only evaluated above
  512 MiB; below that it reads `n/a`.

Also: duplicate per-pod series. The etcd chart set both `metrics.podAnnotations`
(`prometheus.io/scrape`) **and** a PodMonitor, and Grafana Alloy discovers via
both paths — so every pod was scraped twice and `Has Leader` rendered four tiles
for three members. Fixed at both layers: the chart now emits the annotations only
when the PodMonitor is disabled, and all 14 `etcd_*` targets aggregate per pod.

### 6.7 Still open

| Item | Status |
|------|--------|
| Operator panels empty until `metrics.enabled` **and** `metrics.podMonitor.enabled` are set for konk-operator in the DC repo | ✅ **resolved** on us-dev-5 — DC PR [#147190](https://github.com/Infoblox-CTO/deployment-configurations/pull/147190) merged `envs/box-dev/us-dev-5/konk-operator-values.yaml`. Not yet set on any other cluster |
| Enabling that PodMonitor while `prometheus.io/scrape` annotations remain (injected from DC values) will **double-scrape** the operator | ✅ **resolved** for konk-operator — the same DC PR sets `podAnnotations: null`, and the live pod has no scrape annotations. `{}` would **not** have worked: DC's `deep_merge` treats an empty map as a no-op, so only `null` replaces the inherited value. ❌ **still open for etcd** — see 6.9 |
| `certmanager_certificate_expiration_timestamp_seconds` is per-Certificate only | the kubeadm CA is not a Certificate — see 6.1 |
| Chart versions not bumped for the dashboard changes | etcd stays `1.2.0`; content differs under an unchanged version |
| konk-services `$container`/`$pod` derive from cluster-wide `container_memory_working_set_bytes` | expensive `label_values`; a plausible source of Grafana "Failed to fetch". Container names are fixed by the chart, so `$container` could be a static custom variable |
| etcd `podAntiAffinity` | chart has none; 2 of 3 members shared a node on us-dev-5. Accepted for lower clusters (single stable node), unaddressed for higher ones |
| Row 3 readiness is now per-Deployment, not per-pod | equivalent at `replicaCount: 1`; would lose per-pod visibility above that |

### 6.8 Corrections to Part 5

- `kube_endpoint_address_available` → **`kube_endpoint_address{ready="true"}`** plus
  `kube_endpoint_info` (KSM ≥ 2.10)
- add **`kube_secret_metadata_resource_version`** (kube-state-metrics) — CA
  rotation detection, 6.1
- add **`kube_job_status_failed`** (kube-state-metrics) — failed
  `delete-apiservice` pre-delete hooks
- add **`kube_service_info`** (kube-state-metrics) — backends with no Endpoints
  object
- the operator is scraped by a **PodMonitor** at
  `helm-charts/konk-operator/templates/podmonitor.yaml`, not the ServiceMonitor
  at `config/prometheus/monitor.yaml`
- add **`kube_pod_status_phase`** (kube-state-metrics) — required alongside
  `kube_pod_status_ready` to exclude completed Job pods, 6.9

### 6.9 Fixes must be swept across all three dashboards

Third round, after #689 was deployed to us-dev-5 (`v0.2.1-161-g7bbe64c-j32`) and
all three dashboards were reviewed panel by panel in the browser. Every deployed
dashboard matched its merged source exactly — etcd 17/17 panels, konk-operator
27/27, konk-services 38/38, zero differing expressions — so all 14 findings were
gaps in the source, not rollout drift. Fixed in konk PR **#690**; full write-up in
[`konk-dashboard-followups.md`](konk-dashboard-followups.md).

**The finding that matters for future work is not any individual panel.** Six
presentation/robustness fixes landed on the etcd dashboard during #689. Four were
never applied to the other two dashboards, and that single omission accounts for
11 of the 14 items:

| Fix (section) | etcd | konk-operator | konk-services |
|---|---|---|---|
| `or vector(0)` so a healthy count reads `0` | #689 | **#690** ×2 | — |
| `thresholdsStyle: off` + `axisSoftMax` (6.6) | #689 | **#690** ×3 | **#690** ×5 |
| explicit `[5m]` instead of `$__rate_interval` (6.5) | #689 | **#690** | — |
| `noValue` on ambiguous empties (6.6) | #689 | **#690** | **#690** ×3 |
| `joinByField` instead of `merge` | — | — | **#690** |

Each was fixed as a one-off panel bug rather than as a class, so it recurred once
per dashboard. Two now have **generator assertions** in the patch scripts, so a
regression fails the build instead of shipping a fourth time:

- no `timeseries` may keep `thresholdsStyle: line+area` with a non-null threshold
  step and no `axisSoftMax`/`max`
- no `table` with more than one target may use the `merge` transformation

Anything added to one dashboard from here should be checked against the other two
before it is called done.

#### The one genuinely new class: completed Job pods count as not-ready

`Not-ready pods per namespace` used `kube_pod_status_ready{condition="true"} == 0`
alone. A finished Job legitimately reports `ready=0` forever, so every CronJob pod
and every `delete-apiservice` pre-delete hook was counted as a failure. Verified
against live KSM:

| | count | breakdown |
|---|---|---|
| before | **103** | ddi 78, ngp-cp 12, tagging-v2 7, aggregate 3, atcapi 1, ntp 1, hostapp 1 |
| after | **2** | atcapi 1, ntp 1 |

All 7 in `tagging-v2` were `Completed` — 6 `hr-watcher` CronJob pods and one
`delete-apiservice` hook. The fix intersects with the Running phase:

```promql
count by (namespace) (
  (kube_pod_status_ready{namespace=~"$namespace", condition="true"} == 0)
  * on (namespace, pod) group_left ()
  (kube_pod_status_phase{namespace=~"$namespace", phase="Running"} == 1)
)
```

This is the readiness counterpart to 6.3: readiness alone cannot distinguish "not
ready yet" from "finished and gone", and the phase is the only signal that can.

**The 2 survivors are real, and one is significant** —
`ntp/ntp-config-service-dbapi-dbclaim-exporter-…` was 1/2 Running with **774
restarts** over 3d10h. A crash-looping sidecar, invisible for as long as it sat
behind 101 false positives. That is the concrete cost of a noisy panel: it does
not merely annoy, it conceals.

#### `merge` cannot join instant queries

`kubeconfig Deployments vs KonkServices` never populated its `missing` column —
the column the panel exists for. Grafana's `merge` transformation matches on
**every** shared field including `Time`, and three separate instant queries
resolve at slightly different timestamps, so the frames never joined. `joinByField`
on `namespace` is the correct transformation for any multi-query table. The same
fix had already been applied to the sibling panel `Deployment desired vs available`
in #689 and simply not carried across.

#### Presentation limits worth recording

- **State-timeline row labels truncate from the left.** Grafana sizes the row-label
  gutter from the label text and exposes no width knob, so the only lever is a
  shorter label. `{{namespace}}/{{deployment}}` lost its prefix; these panels are
  already scoped by `$namespace`, so `{{deployment}}` alone is both shorter and
  no less informative.
- **A datetime unit on a single flat series pads the axis unusably.**
  `Operator Start Time` with `dateTimeAsLocal` spanned **1970 → 2080**. Replaced
  with `time() - process_start_time_seconds` as `Operator uptime`: naturally
  bounded, and a recreate still shows as a sawtooth to zero, which preserves the
  panel's original purpose from #686 — catching pod recreates that
  `Container Restarts` cannot see, because a fresh pod starts at `RESTARTS=0`.
- **KSM's `condition` label is three-valued.** `konks ready` plotted two series
  per pod, one pod reading as two legend entries naming the same pod, because
  `kube_pod_status_ready` emits `condition` true/false/unknown. For a binary
  signal `condition="false"` is just the inverse of `condition="true"`, so it
  added a permanent flat-zero line. Select one condition explicitly.
- **Titles truncate at `w4`.** `Self-signed issuer cert expiry (days)` rendered as
  `Self-signed issuer cert expiry (`.

#### Cluster findings surfaced by the dashboards, not defects in them

**`Components available` reported apiservice-test = 18 against 17 KonkServices.**
The count was correct. Two Deployments exist for the same KonkService in `ddi`:

| Deployment | Helm release annotation | Chart |
|---|---|---|
| `…-v2-k-kubectl-apiservice-test` | `dns-config-importexport-apiservice` ⚠️ **v1** | `konk-service-0.1.0` |
| `…-v2-konk-service-kubectl-apiservice-test` | `…-apiservice-v2` ✅ | `konk-service-0.2.0` |

Both owned by KonkService `…-v2`, both Running, created a second apart on
2026-06-22 — so it persisted roughly two months unnoticed. The first is annotated
to the wrong Helm release and runs the older chart: exactly the Helm-ownership /
ghost-resource class described in 4.1–4.2, which is what Row 7 was meant to catch.
Cleanup is a cluster action, not a dashboard change.

#### Still open after #690

| Item | Status |
|------|--------|
| etcd chart annotation gating does not stick on the live object | chart renders 0 annotations with live values ✅ and the Helm release manifest shows `annotations: null` ✅, but the **live StatefulSet pod template still carries `prometheus.io/{scrape,port}`** ❌. `managedFields` is stripped on this cluster so the writer could not be identified. etcd may therefore still be double-scraped, and it is the dashboard-side `max by (pod)` keeping `Has Leader` at three tiles, not the chart |
| Chart versions still not bumped | dashboard content differs under an unchanged chart version, across all of #688/#689/#690 |
| CA detector firing path still unproven | rewired onto `kube_secret_metadata_resource_version` in #689 and it now *can* fire (6.1), but no rotation has occurred since, so the positive case is untested |
| etcd `podAntiAffinity` | chart still has none |
| `Server cert remaining (days)` value overlaps its bar | cosmetic; left alone rather than guess at a layout change that cannot be verified without rendering |
| `Certificates not Ready` / `★ Backends with no ready endpoints` appeared blank | both **do** set `noValue`, and a sibling table rendered its text correctly, so most likely a PDF pagination artifact. Confirm in the browser before chasing it |

### 6.10 Post-deploy verification of #690

#690 merged as `beea16d` and deployed to us-dev-5 as
`konk-operator:v0.2.1-162-gbeea16d-j33`. The live `GrafanaDashboard/konk-operator`
was diffed against `beea16d` — 21/21 panels, **zero** differences in expression,
legend, unit, min/max, `noValue`, `axisSoftMax` or shading — so the rendered
dashboard is the merged source.

**All eight konk-operator items verified fixed**, each confirmed in the live panel
config and visible in the rendered dashboard:

| # | Item | Evidence |
|---|------|----------|
| 1 | `Container Restarts` rate window | `[5m]` in live config; Cortex returns 3 series over 24h (116/5/170 points, one per pod rollout) where `$__rate_interval` returned none |
| 2 | healthy counts read `0` | both panels carry `or vector(0)`; both render green `0` |
| 3 | `Konk pod restart count` red block | `shading=off softMax=5`; axis renders 0–4 |
| 4 | `Operator Start Time` → uptime | title renamed, `unit=s min=0`; axis 0s–2.89 days, **and the sawtooth worked** — the drop at 07:40 local is a real pod recreate at 02:10 UTC, exactly the event the redesign was meant to expose |
| 5 | truncated titles | `Self-signed CA expiry (d)`, `Next provision wake-up (d)` both render in full |
| 6 | `Operator 5xx` ambiguity | `noValue='no 5xx'`; renders `no 5xx` |
| 7 | `Provision restart history` axis | `softMax=5`; axis renders 0–4 |
| 8 | `konks ready` double series | `max by (namespace, pod)` + `condition="true"`, `min=0 max=1`; one legend entry, Ready/Not Ready axis |

#### The datasource is Cortex, not an in-cluster Prometheus

Worth recording because it invalidated three earlier verification attempts. The
dashboards resolve `${DS_PROMETHEUS_UID}` to uid `000000001`, which is:

```
url:  http://cortex.services.sdp.infoblox.com/prometheus
header: X-Scope-OrgID: us-dev-5      (jsonData.httpHeaderName1 / secureJsonData)
timeInterval: 6s
```

Neither `prometheus/federated-prometheus` nor `prometheus/prometheus-operated`
holds these series — `prometheus-operated` returns **0 series** for
`count(kube_pod_status_ready)`. Cortex is also not reachable from a laptop; it
answers only from inside the cluster, and without the `X-Scope-OrgID` header it
replies `no org id`. Any future panel verification must query Cortex through an
in-cluster pod with that header, or it is measuring nothing.

#### Two defects that survived #690

Both fixed in the follow-on PR; both are again the *sweep* failure, one panel deep.

**`Container Restarts` was invisible, not empty.** The `[5m]` fix worked — the
series is present with three pods over 24h — but all values are 0, and with
`min: 0`, no `max` and no `axisSoftMax` the axis auto-scaled to **0–100**, pinning
a flat zero line to the bottom pixel. Every sibling in this class already got
`axisSoftMax` in #689/#690: `Proposals Failed`, `Konk pod restart count (1h)`,
`Provision restart history`, `Operator 5xx error rate`. This one panel was missed.

A blanket rule would be wrong here. Auditing all three dashboards for
"`min: 0`, no `max`, no `axisSoftMax`" flags **11** panels, and 10 of them are
correct — latency percentiles, DB size, gRPC traffic, CPU and memory are
legitimately unbounded and a soft max on them would be arbitrary. The class that
matters is narrower: *counters that read zero on a healthy cluster*. Scoped to
targets matching `restarts_total|_failed|_errors?_total|oom|code=~"5`, the audit
returns exactly one gap — `Container Restarts` — and that is now the assertion.

**`konk count` printed raw PromQL as its legend.** No `legendFormat`, so Grafana
fell back to the expression:
`count(resource_created_at_seconds{group="konk.infoblox.com",kind="Konk"})`. Now
`Konk CRs`, asserted for **timeseries** panels only — stat panels show a value
with no series name, and row panels carry a vestigial target, so the broader form
of this assertion produces false failures.

#### Proof the DC annotation fix took effect

`Operator uptime` showed a third legend entry that was a 16-label dump instead of
a pod name. This is **not** a dashboard defect — it is the annotation-scrape path
disappearing mid-window. Querying the oldest pod's series directly:

```
job                  = kubernetes-pods          ← Alloy annotation discovery
kubernetes_namespace = konk
kubernetes_pod_name  = konk-operator-fff4f7654-4nh6l
(no `pod` label)
```

versus the current series:

```
job       = konk/konk-operator                  ← PodMonitor
namespace = konk
pod       = konk-operator-8c4f5d69d-lbl4s
```

Annotation discovery emits `kubernetes_pod_name`; a PodMonitor emits `pod`. The
unlabelled series covers the first ~14h of the window and stops at the pod
recreate; every series after it has a proper `pod` label. So `podAnnotations: null`
from DC PR #147190 did what 6.7 claims, and the ugly legend entry is historical
residue that ages out of the window. It does confirm konk-operator was previously
scraped via annotations, which is the precondition for the double-scrape.

#### Non-defects confirmed by range query

`konk count` and `konks ready` appeared in a PDF export to stop before the right
edge of the plot. They do not: over 24h at 300s step they return **288 and 289
points** — full coverage with no gap. That was a misread of the rasterised export,
and the range query is what settles such questions rather than looking harder at
the image.

#### Cluster cleanup outstanding

Three `dashtest-*` `GrafanaDashboard` objects from the manual test-manifest stage
are still on us-dev-5 in the `konk` folder, duplicating the real ones:

```
dashtest-etcd-dashtest
dashtest-konk-operator-dashtest
dashtest-konk-operator-konk-services-dashtest
```

They are not chart-managed, so nothing will reap them. Delete them.
