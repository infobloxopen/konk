# konk Dashboard Follow-ups

Outstanding items found while validating the deployed dashboards on **us-dev-5**
after konk PR #689 merged (`7bbe64c`) and DC PR #147190 rolled out
(`konk-operator v0.2.1-161-g7bbe64c-j32`).

**Verified state at the time of writing:** the deployed dashboards match the
merged #689 source exactly — etcd 17/17 panels, konk-operator 27/27 panels, zero
differing expressions. Everything below is a gap in the source, not a
deployment problem.

---

## Executive summary

The **etcd** dashboard received six presentation/robustness fixes during #689.
Four of them were never swept back across **konk-operator**. That is the single
root cause behind items 2, 3, 6 and 7 below — one systematic gap, not four
unrelated bugs.

| Fix applied to etcd in #689 | Also needed on konk-operator? |
|---|---|
| `or vector(0)` so a healthy count reads `0` not "No data" | ❌ missing (item 2) |
| `thresholdsStyle: off` so a healthy panel is not a red block | ❌ missing (item 3) |
| `axisSoftMax` on normally-zero panels | ❌ missing (item 7) |
| explicit `[5m]` rate windows instead of `$__rate_interval` | ❌ missing (item 1) |
| `noValue` text on ambiguous empties | ❌ missing (item 6) |
| per-pod aggregation (`max by (pod)`) | ✅ n/a — konk-operator has one pod |

---

## 1. `Container Restarts` renders "No data" — rate-window starvation

**Dashboard:** konk-operator · **Row:** konk-operator · **Severity:** bug

```promql
increase(kube_pod_container_status_restarts_total{namespace="konk", pod=~"konk-operator-.*"}[$__rate_interval])
```

`$__rate_interval` with no Min interval set. Grafana computes it as
`max($__interval + scrapeInterval, 4 × scrapeInterval)` where `scrapeInterval` is
the **datasource's** `timeInterval`. On this Grafana that datasource is Cortex
with `timeInterval: 6s` — **not** the 15s default I originally assumed — so the
expression is `max($__interval + 6s, 24s)`. At a 24h range `$__interval` is ~80s,
giving ~86s; at a 1h range it collapses to the floor of **24s**. Either way the
window holds one or two samples and `increase()` needs two, so it returns
*nothing at all*, not zero.

This is the identical defect fixed on the etcd dashboard in `b64718b`; the fix
was never applied here. Measured on a live Prometheus, series returned by
`increase()` per window: `[30s]` → 8, `[1m]` → 1904, `[4m]` → 1916.

**Fix:** explicit `[5m]`, matching every etcd rate panel.

---

## 2. `Deployments unavailable` and `konk-service pods not Ready` read "No data" when healthy

**Dashboard:** konk-operator · **Row:** KonkService Summary · **Severity:** bug

```promql
count(kube_deployment_status_replicas_available{deployment=~".*-(kubeconfig|konk-service-apiservice|kubectl-apiservice)"} < 1)
count(kube_pod_status_ready{pod=~".*konk-service.*", condition="true"} == 0)
```

Neither has `or vector(0)`. `count()` over an empty set returns **no series**, so
a healthy fleet renders "No data" instead of `0`.

Evaluated against live kube-state-metrics output:

| Query | Matching series | Failing |
|---|---|---|
| deployments (`available < 1`) | 34 | **0** |
| konk-service pods (`ready == 0`) | 51 | **0** |

So `0` is the correct reading and the panels cannot express it.

Both tiles also showed a **red `1`** in an earlier capture (02:42Z) while the
cluster was healthy — a transient artifact of the 02:14Z rollout. That is the
same defect wearing the opposite face: without a denominator or a `0` floor,
neither "No data" nor a stray `1` can be distinguished from a real failure.

**Fix:** add `or vector(0)`. Both sides are unlabelled here (`count()` without
`by()` drops all labels), so the fallback dedupes correctly and adds no phantom
series — unlike the `konks ready` case fixed in `c2cfdb6`.

**Consider also:** the denominator treatment applied to konk-services Row 1 in
`5cb43c2` (`1 of 34` rather than `1`). Had it been here, this item would have been
self-evident without a cluster check.

---

## 3. `Konk pod restart count (1h)` renders as a solid red block

**Dashboard:** konk-operator · **Row:** CR Overview · **Severity:** bug

`thresholdsStyle: line+area`, thresholds red at 3, no `axisSoftMax`, and no data
in the window. Grafana auto-scales the axis to 0–100 and shades everything above
3 red, so ~97% of the panel is red while nothing is wrong.

Identical to the etcd `Heartbeat Send Failures` bug fixed in `b64718b`.

`Operator 5xx error rate` carries the same config (`line+area`, red at 0.01) and
will do the same the moment it has any data.

**Fix:** `thresholdsStyle: off` on both, plus `axisSoftMax`.

---

## 4. `Operator Start Time` y-axis spans 1970 → 2080

**Dashboard:** konk-operator · **Row:** konk-operator · **Severity:** presentation

Unit `dateTimeAsLocal`, no `min`/`max`. With a single flat series Grafana pads the
axis absurdly — the 15:19Z capture shows tick labels from `01/01/1970` to
`28/11/2080` for a value that is a fixed point in Aug 2026. The axis was sane in
the 02:42Z capture only because a second (transitional) series happened to bound
it.

The panel's stated purpose, from #686, is catching pod recreations that
`Container Restarts` misses: *"Eviction-based recreates show as 0 here because a
new pod starts with RESTARTS=0 — use Operator Start Time to catch those."*

**Fix options:**
- **(a)** plot uptime (`time() - process_start_time_seconds`) with unit `s` — a
  recreation is a sawtooth drop to zero, the axis is naturally bounded, and the
  stated purpose is preserved. Retitle to `Operator uptime`.
- **(b)** keep the timestamp and constrain the axis — not really possible, since
  a useful min/max would have to be dynamic.

(a) is recommended.

---

## 5. Panel title truncated: `Self-signed issuer cert expiry (`

**Dashboard:** konk-operator · **Row:** Core PKI Cert Expiry · **Severity:** cosmetic

37 characters in a `w4` panel; the `days)` is cut off. `Next provision wake-up
(days)` (29 chars) is at the same width and close to the limit.

**Fix:** shorten to e.g. `Self-signed CA expiry (d)` / `Next provision wake-up (d)`,
or widen and rebalance the row.

---

## 6. `Operator 5xx error rate` — "No data" is correct but ambiguous

**Dashboard:** konk-operator · **Row:** CR Overview · **Severity:** clarity

Prometheus only creates series for response codes actually observed. The live
operator exports `rest_client_requests_total` with codes **200, 201, 404, 409 and
no 5xx**, so `code=~"5.."` matches nothing and the panel is legitimately empty.

But a bare "No data" is indistinguishable from a broken query — the exact
ambiguity that concealed the `kube_endpoint_address_available` removal and the
dead CA-rotation detector.

**Fix:** `noValue: "no 5xx"`.

---

## 7. `Provision restart history` axis 0–100 for a metric that sits at 0

**Dashboard:** konk-operator · **Row:** Provision Health · **Severity:** cosmetic

No `axisSoftMax`, so a single restart would be an invisible wiggle at the floor
of a 0–100 axis. Same treatment as the etcd panels given `axisSoftMax` in
`b64718b`.

**Fix:** `axisSoftMax: 5`, `axisSoftMin: 0`.

---

## 8. `konks ready` plotted two series per pod

**Dashboard:** konk-operator · **Row:** konks · **Severity:** bug

A single-replica konk read as two legend entries that both named the same pod —
easy to misread as two pods. kube-state-metrics emits three series per pod:

```
kube_pod_status_ready{pod="bulk-konk-66f99c78b6-v9h7x",condition="true"}    1
kube_pod_status_ready{pod="bulk-konk-66f99c78b6-v9h7x",condition="false"}   0
kube_pod_status_ready{pod="bulk-konk-66f99c78b6-v9h7x",condition="unknown"} 0
```

The panel plotted `condition="true"` as positive and `condition="false"` negated.
For a binary readiness signal the second is simply the inverse of the first, so it
contributed **no information** — just a permanent flat line at zero for every
healthy pod, labelled `… not ready`.

Also had no `min`/`max`/`axisSoftMax`, so with only the flat-zero series visible
Grafana auto-scaled the axis to 0–100.

**Fix:** one series per pod from `condition="true"` (1 = Ready, 0 = Not Ready),
axis pinned 0..1, value mappings so the tooltip reads Ready/Not Ready, and
`max by (namespace, pod)` so a double-scraped pod cannot duplicate lines. Nothing
is lost — the only state where both true and false are 0 is `condition="unknown"`,
which reads as 0, and unknown is correctly not-ready.

> Supersedes the "not a defect" note previously recorded for this panel. The red
> negative half-plane *was* deliberate, but the duplicate series underneath it was
> not.

---

# konk-services dashboard

Validated separately. The deployment matches the merged #689 source exactly
(38/38 panels, zero differing expressions), so all of the following are gaps in
the source.

**Confirmed working:** the Row 1 inversions (`52 of 52`, `34 of 34`, `11 of 11`),
backend scoping (11 not 276), the `joinByField` fix on
`Deployment desired vs available`, column widths, Row 3 ordering, and the `noValue`
text on `none scaled to 0` / `no failed hooks`.

## 9. `Not-ready pods per namespace` counted completed Job pods

**Row:** 5 — Backend Endpoints · **Severity:** bug, high noise

A finished Job legitimately reports `ready=0`, so CronJob pods and
`delete-apiservice` pre-delete hooks were counted as failures. Restricting to
`phase="Running"` — verified against live kube-state-metrics output:

| | count | per namespace |
|---|---|---|
| before | **103** | ddi 78, ngp-cp 12, tagging-v2 7, aggregate 3, atcapi 1, ntp 1, hostapp 1 |
| after | **2** | atcapi 1, ntp 1 |

All 7 in `tagging-v2` were Completed: 6 `hr-watcher` CronJob pods and 1
`delete-apiservice` hook.

**The two survivors are real**, and one matters:
`ntp/ntp-config-service-dbapi-dbclaim-exporter-86dbf64ddb-925q5` is **1/2 Running
with 774 restarts** over 3d10h — a crash-looping sidecar that was buried under 101
false positives. The other is `atcapi/atcpdx-8599c8b4d9-dgz4t`.

**Fix:** join against `kube_pod_status_phase{phase="Running"}`.

## 10. Five timeseries render as red blocks when healthy

**Severity:** bug · **Third dashboard with this defect**

`thresholdsStyle: line+area` with a threshold and no `axisSoftMax`/`max`:
`Unavailable replicas over time`, `Readiness flapping (6h transitions)`,
`Cert renewal activity (24h)`, `Ready endpoint count per backend`,
`CPU throttling`.

**Fix:** shading off plus `axisSoftMax`. The generator now **asserts** no
timeseries retains unbounded alarm shading, so this class fails the build rather
than shipping a fourth time.

## 11. `kubeconfig Deployments vs KonkServices` never populated `missing`

**Row:** 2 — Deployment Completeness · **Severity:** bug

Used the `merge` transformation, which matches on **every** shared field including
`Time`. Three instant queries resolve at slightly different timestamps, so the
frames never joined and the `missing` column stayed blank — in the panel whose
entire purpose is that column.

Identical to the bug fixed on `Deployment desired vs available` in `146f804`; the
fix was not swept to its sibling.

**Fix:** `joinByField` on `namespace`. The generator now asserts every
multi-query table uses `joinByField`, not `merge`.

## 12. Row 3 state-timeline row labels truncated from the left

**Severity:** cosmetic

`vice-konk-service-kubectl-apiservice`,
`i-apiservice-konk-service-kubeconfig`. Grafana sizes the row-label gutter from
the label text and offers no width knob, so the only lever is a shorter label.

**Fix:** drop the `{{namespace}}/` prefix — these panels are already scoped by
`$namespace`, and the deployment name begins with the KonkService name.

## 13. Three panels had no empty-state text

**Severity:** clarity

`★ CA rotated without propagation` → `OK`, `Peak memory over window` and
`★ OOMKills` → explicit text, so empty is distinguishable from broken.

> `Certificates not Ready` and `★ Backends with no ready endpoints` appeared blank
> in the capture but **do** have `noValue` set, and `Failed delete-apiservice
> hooks` rendered its text correctly — so those two are most likely a PDF
> pagination artifact rather than a config gap. Worth confirming in the browser.

## 14. `Server cert remaining (days)` value overlaps its bar

**Severity:** cosmetic · **not fixed**

`362.5` is printed over the gradient fill. `displayMode: gradient` with
`valueMode: color`. Left alone rather than guess at a layout change that cannot be
verified without rendering.

---

## Cluster findings surfaced by the dashboards

Not dashboard defects — the dashboards working.

### Orphaned `apiservice-test` Deployment in `ddi`

`Components available` reported **apiservice-test = 18** against 17 KonkServices.
That count is correct; there are two Deployments for the same KonkService:

| Deployment | Helm release | Chart |
|---|---|---|
| `dns-config-importexport-apiservice-v2-k-kubectl-apiservice-test` | `dns-config-importexport-apiservice` ⚠️ **the v1 release** | `konk-service-0.1.0` |
| `dns-config-importexport-apiservice-v2-konk-service-kubectl-apiservice-test` | `dns-config-importexport-apiservice-v2` ✅ | `konk-service-0.2.0` |

Both `ownerReferences` point at KonkService `dns-config-importexport-apiservice-v2`,
both Running 1/1, created one second apart on 2026-06-22 — so this has persisted
roughly two months. The first is annotated to the **wrong** Helm release and runs
the **older** chart: the Helm-ownership / ghost-resource class from
`konk-dashboard-panels.md` §4.1–4.2. Worth cleaning up.

### Crash-looping sidecar in `ntp`

See item 9. `ntp-config-service-dbapi-dbclaim-exporter-86dbf64ddb-925q5`, 774
restarts.

---

## Corrections to earlier analysis

Recorded because the reasoning was wrong even where the change was harmless.

**`app_kubernetes_io_instance` IS available.** During #689 I argued that pod
labels are not mapped into metrics by a default PodMonitor, and moved
`kube api client requests` and `Operator 5xx error rate` onto `namespace="konk"`
in `2f1f0d8`. Those were subsequently reverted to `app_kubernetes_io_instance`,
and that is correct: the merged chart's PodMonitor sets

```yaml
podTargetLabels:
  - app.kubernetes.io/instance
```

which is exactly the mechanism I claimed was missing. Confirmed on the deployed
PodMonitor. `kube api client requests` is populated as a result.

**The etcd chart's annotation gating renders but does not stick.** `7bbe64c`
gates `metrics.podAnnotations` behind `not metrics.podMonitor.enabled`, and it
works at every layer up to the live object:

| Layer | State |
|---|---|
| chart rendered with live values | 0 scrape annotations ✅ |
| Helm release v1 manifest, STS pod template | `annotations: null` ✅ |
| **live StatefulSet pod template** | `prometheus.io/{scrape,port}` **present** ❌ |

Something re-adds them to the running object; `managedFields` is stripped on this
cluster so the writer could not be identified, and there are ~14 mutating
webhooks. Practical consequence: **etcd may still be double-scraped**, and it is
the dashboard-side `max by (pod)` aggregation from `581d704` that keeps
`Has Leader` at three tiles — not the chart gating. Worth chasing separately for
the wasted cortex cardinality. The konk-operator side is clean: PodMonitor only,
pod annotations absent.

---

## Not defects

- **`Operator Start Time` duplicate series** (raw label blob in the 02:42Z
  capture) — transitional. The scrape path changed 30 min earlier; the
  pre-cutover series aged out of the 3h window and is gone in the 15:19Z capture.
- **`konks ready` red negative half-plane** — deliberate. Negative genuinely is
  the not-ready region and the shading marks it, unlike the Heartbeat case where
  an unbounded axis painted a healthy *zero* red. Not visible in the 15:19Z
  capture because there were no not-ready samples.
- **etcd `~07:45 IST` disturbance** — the rollout. etcd release is revision 1,
  created `02:14:41Z` (07:44 IST), all three pods restarted. `Pods Ready` dipped
  to 2, never below, so quorum held.

---

## Still open from `konk-dashboard-panels.md` §6.7

Unchanged by this round:

- CA-rotation detector rewired onto `kube_secret_metadata_resource_version` in
  `21aba7b`, but **no real rotation has occurred since**, so the firing path is
  unproven end to end. Treat as "should fire", not "verified fires".
- Chart versions not bumped for dashboard changes — etcd stays `1.2.0`, so
  content differs under an unchanged version. This is why the etcd release shows
  chart `etcd-1.2.0` both before and after #689.
- konk-services `$container`/`$pod` derive from cluster-wide
  `container_memory_working_set_bytes`; constraining the `allValue` in `9e02843`
  reduced the cost but the `label_values` query is still cAdvisor-scale.
- etcd has no `podAntiAffinity`; 2 of 3 members shared a node on us-dev-5.
  Accepted for lower clusters (single stable node), unaddressed for higher ones.

---

# Post-deploy verification (2026-08-24)

#690 merged as `beea16d`, deployed to us-dev-5 as
`konk-operator:v0.2.1-162-gbeea16d-j33`. The live `GrafanaDashboard/konk-operator`
diffs clean against `beea16d` — 21/21 panels, zero differences in expression,
legend, unit, min/max, `noValue`, `axisSoftMax` or shading.

**Items 1–8 all verified fixed**, each confirmed in the live panel config *and*
visible in the rendered dashboard:

| # | Item | Live config | Rendered evidence |
|---|------|-------------|-------------------|
| 1 | `Container Restarts` rate window | `[5m]` | Cortex returns 3 series over 24h (116/5/170 points, one per pod rollout) where `$__rate_interval` returned none |
| 2 | healthy counts read `0` | `or vector(0)` on both | both render green `0` (was "No data") |
| 3 | `Konk pod restart count` red block | `shading=off softMax=5` | axis renders 0–4, no red field |
| 4 | `Operator Start Time` → uptime | title renamed, `unit=s min=0` | axis 0s–2.89 days; sawtooth drop at 07:40 local |
| 5 | truncated titles | `w=4` titles shortened | `Self-signed CA expiry (d)` and `Next provision wake-up (d)` both render in full |
| 6 | `Operator 5xx` ambiguity | `noValue='no 5xx'` | renders `no 5xx` |
| 7 | `Provision restart history` axis | `softMax=5` | axis renders 0–4 (was 0–100) |
| 8 | `konks ready` double series | `max by (namespace, pod)` + `condition="true"`, `min=0 max=1` | one legend entry; Ready / Not Ready axis |

Two are worth more than a checkmark:

- **Item 4 did more than bound an axis.** `Operator uptime` shows a sawtooth
  dropping at 07:40 local, which is a genuine pod recreate at 02:10 UTC. That is
  precisely the event `Container Restarts` cannot see (a fresh pod starts at
  `RESTARTS=0`), so the panel earned its redesign rather than merely looking
  tidier. The panel was rewritten for axis reasons and turned out to work for its
  original purpose too.
- **Item 1's fix is confirmed by data, not by absence of error.** Cortex returns
  3 series over 24h (116/5/170 points) for the `[5m]` form where
  `$__rate_interval` returned none. "The panel no longer errors" would not have
  been evidence of anything.

## 15. `Container Restarts` axis auto-scaled to 0–100

**Dashboard:** konk-operator · **Severity:** bug · **Fixed:** follow-on PR

The item-1 fix worked — the series is present — but every value is 0, and with
`min: 0`, no `max` and no `axisSoftMax` the axis auto-scaled to **0–100**, pinning
a flat zero line to the bottom pixel. Indistinguishable from the "No data" it
replaced.

This is the same sweep failure #690 was written about, one panel deep. Every
sibling in the identical class already had `axisSoftMax` from #689/#690:

| Panel | Dashboard | `axisSoftMax` before #691 |
|---|---|---|
| `Proposals Failed` | etcd | 5 ✅ |
| `Konk pod restart count (1h)` | konk-operator | 5 ✅ |
| `Provision restart history` | konk-operator | 5 ✅ |
| `Operator 5xx error rate` | konk-operator | 1 ✅ |
| **`Container Restarts`** | konk-operator | **none** ❌ |

**Fix:** `axisSoftMax: 5`, `axisSoftMin: 0`.

**The assertion had to be narrow.** Auditing all three dashboards for `min: 0`
with no `max` and no `axisSoftMax` flags **11** panels, of which 10 are correct —
latency percentiles, DB size, gRPC traffic, CPU, memory are legitimately unbounded.
Scoping to targets matching `restarts_total|_failed|_errors?_total|oom|code=~"5`
— counters that read zero on a healthy cluster — returns exactly one gap. That
scoped form is now asserted.

## 16. `konk count` legend printed raw PromQL

**Dashboard:** konk-operator · **Severity:** cosmetic · **Fixed:** follow-on PR

No `legendFormat`, so Grafana fell back to the expression as the series name:
`count(resource_created_at_seconds{group="konk.infoblox.com",kind="Konk"})`.

**Fix:** `legendFormat: "Konk CRs"`, plus a description. Asserted for **timeseries**
panels only — stat panels legitimately have no series name, and row panels carry a
vestigial target, so a broader assertion fails on correct config.

## Corrections from this round

**`$__rate_interval` arithmetic (item 1, and `konk-dashboard-panels.md` §6.5).**
I asserted the datasource scrape interval was the 15s default, making
`$__rate_interval` ~60–75s. The real datasource sets **`timeInterval: 6s`**, so it
is `max($__interval + 6s, 24s)` — about 86s at a 24h range and a hard floor of
**24s** at short ranges. Starvation is worse than described; conclusion and fix
unchanged. Both docs and the panel tooltip corrected.

**The dashboards query Cortex, not an in-cluster Prometheus.** `${DS_PROMETHEUS_UID}`
resolves to uid `000000001`:

```
url:          http://cortex.services.sdp.infoblox.com/prometheus
header:       X-Scope-OrgID: us-dev-5
timeInterval: 6s
```

This invalidated three earlier verification attempts. `prometheus/prometheus-operated`
returns **0 series** for `count(kube_pod_status_ready)`; `federated-prometheus` was
the same trap earlier. Cortex is unreachable from a laptop and returns `no org id`
without the header, so verification must run from an in-cluster pod with
`X-Scope-OrgID` set.

## Not defects, confirmed

- **`Operator uptime`'s third legend entry** — a 16-label dump rather than a pod
  name. Not a dashboard bug: it is the annotation-scrape path disappearing
  mid-window. The old series is `job=kubernetes-pods` with `kubernetes_pod_name`
  and **no `pod` label** (Alloy annotation discovery); the current one is
  `job=konk/konk-operator` with `pod` (PodMonitor). The unlabelled series stops at
  the pod recreate. So `podAnnotations: null` from DC PR #147190 worked as §6.7
  claims — and it confirms konk-operator *was* annotation-scraped before, the
  precondition for the double-scrape. The legend entry ages out of the window.
- **`konk count` / `konks ready` appearing to stop before the right edge of the
  plot** — they do not. Over 24h at 300s step they return **288 and 289 points**,
  full coverage. A misread of the rasterised PDF; the range query is what settles
  it.

## Cluster cleanup outstanding

Three `dashtest-*` `GrafanaDashboard` objects from the manual test-manifest stage
are still on us-dev-5 in the `konk` folder, duplicating the real dashboards:

```
dashtest-etcd-dashtest
dashtest-konk-operator-dashtest
dashtest-konk-operator-konk-services-dashtest
```

Not chart-managed, so nothing reaps them. Delete them.

## What PR #691 contains

Branch `fix/dashboard-axis-legend`, base `release/upgrade-etcd`, commit `9238655`.
One file, `+8/−4`:

| Change | Item |
|--------|------|
| `Container Restarts`: `axisSoftMax: 5`, `axisSoftMin: 0` | 15 |
| `konk count`: `legendFormat: "Konk CRs"` + description | 16 |
| `Container Restarts` tooltip: corrected `$__rate_interval` arithmetic | corrections |
| assertion: zero-when-healthy counters must have a bounded axis | 15 |
| assertion: every **timeseries** target must set `legendFormat` | 16 |

Everything else in this section is verification or a non-defect — no code change.

### Assertions now guarding the dashboards

Cumulative across #689–#691. Each exists because the defect recurred rather than
because it was anticipated:

| Assertion | Added |
|-----------|-------|
| no `$__rate_interval` in any target | #690 |
| no timeseries keeps `line+area` shading with a threshold and an unbounded axis | #690 |
| no multi-query table uses the `merge` transformation | #690 |
| zero-when-healthy counters (`restarts_total\|_failed\|_errors?_total\|oom\|code=~"5`) must set `axisSoftMax` or `max` | #691 |
| every timeseries target sets `legendFormat` | #691 |

Two of the #691 assertions had to be **narrowed** before they were usable, and
that is the reusable lesson: the natural broad form of each produced false
failures on correct config.

- axis rule: the broad form (`min: 0` and no `max` and no `axisSoftMax`) flags 11
  panels of which 10 are correct — latency percentiles, DB size, gRPC traffic,
  CPU, memory.
- legend rule: the broad form (every target on every panel) fails on stat panels,
  which show a value with no series name, and on row panels, which carry a
  vestigial empty target with only a `datasource` and `refId`.

### How the verification was done

Reproducible method, since three earlier attempts measured the wrong backend:

1. Confirm what is deployed:
   `kubectl get deploy -n konk -o custom-columns=…IMAGE` → must match the merge commit.
2. Pull the live dashboard from the CR, not from Grafana:
   `kubectl get grafanadashboards.integreatly.org -A -o json` → `.spec.json`.
3. Diff it against the merge commit
   (`git show <sha>:helm-charts/konk-operator/dashboards/konk-operator.json`) on
   expression, legend, unit, min/max, `noValue`, `axisSoftMax`, shading. A clean
   diff is what makes any finding a *source* gap rather than rollout drift.
4. Query **Cortex** from an in-cluster pod with `X-Scope-OrgID: us-dev-5`, using
   `query_range` for anything about gaps or history — an instant query cannot
   distinguish "no data now" from "no data ever", and a rasterised PDF cannot be
   trusted for either.
