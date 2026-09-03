# etcd 3.4.14 → 3.7.1 Migration — Changes & Deployment Checks

**Konk-operator:** `v0.2.1-138-g8b64bf7-j170` → `v0.2.1-162-gbeea16d-j33`
**Chart line:** `main` (prod baseline) → `release/upgrade-etcd`
**Last updated:** 2026-09-01 — us-dev-2 migrated and validated (Appendix A)

---

## Scope and how to use this

This document is **cluster-agnostic**. It describes what the upgrade changes, what
to verify before/during/after deploying it, and what the current and expected
state is for every cluster.

Read it in this order when running a migration:

| Phase | Where |
|---|---|
| Understand the change | Part 1, Part 2, Part 3 — this document |
| Know where the target cluster starts | Part 4 — this document |
| How the rollout behaves in practice | Part 5 — this document |
| **Actually deploying it** | **[Phase 1 Deployment Checklist](phase-1-deployment-checklist.md)** |

> **This document explains what changed and why.** The step-by-step runbook —
> pre-checks, the install-vs-upgrade gate, hook watching, post-checks, E2E and
> rollback — lives in **[phase-1-deployment-checklist.md](phase-1-deployment-checklist.md)**.

Everything below is grounded in the konk repo at `8b64bf7` (baseline) and
`beea16d` (target). File/line references are to those commits.

---

## Part 1 — What changed

### 1.1 Image lineage

| Stage | Image | Landed in |
|---|---|---|
| Baseline | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` | prod today |
| Bitnami legacy | `bitnamilegacy/etcd` | `65860e4` (#548) |
| Upstream | `gcr.io/etcd-development/etcd:v3.6.7` | `7c13757` (#572) |
| CVE bump | `v3.6.8` | `aca7e33` (#583) |
| Chainguard | `cgr.dev/infoblox.com/etcd:3.7.0` | `e13f6ed` |
| **Target** | **`cgr.dev/infoblox.com/etcd:3.7.1`** | `9deaa9d` |

The jump is **three minor versions** (3.4 → 3.7). etcd does not support skipping
minor versions on upgrade, which is why this migration provisions fresh volumes
and bootstraps a new cluster rather than upgrading in place.

The image is pinned in **two** places on the target chart — keep them in sync:

- `helm-charts/etcd/values.yaml` → `image.tag`
- `helm-charts/konk/values.yaml` → `etcd.image.tag`

### 1.2 Commit inventory — `8b64bf7..beea16d` (24 commits)

`8b64bf7` is an **ancestor** of `beea16d`, so this is a linear advance; nothing is
given up.

```
git merge-base --is-ancestor 8b64bf7 beea16d && echo linear
git rev-list --count 8b64bf7..beea16d      # 24
```

Grouped by theme:

**Base image / CVE**
| Commit | |
|---|---|
| `77b5df1` (#568) | distroless base migration |
| `7c13757` (#572) | replace deprecated bitnami etcd with upstream |
| `aca7e33` (#583) | etcd `v3.6.7` → `v3.6.8` |
| `e13f6ed` | move to `cgr.dev/infoblox.com/etcd:3.7.0` |
| `9deaa9d` | etcd `3.7.0` → `3.7.1` |

**PVC migration machinery**
| Commit | |
|---|---|
| `895772e` (#631) | parameterize `volumeClaimTemplate` name → `persistence.claimName` |
| `fd9ed6b` (#634) | declarative StatefulSet recreate hook |
| `372db4e` (#636) | always recreate STS when the hook is enabled |
| `1de007e` (#635) | `meta.helm.sh` ownership annotations on chart templates |

**Correctness**
| Commit | |
|---|---|
| `f8540d7` | **restore `statefulset.replicaCount` in chart templates** (see 1.5) |
| `2606165` (#683) | prevent Karpenter eviction loops — see Part 3 |

**Observability** — see Part 2
| Commit | |
|---|---|
| `e03a23d` (#688) | Karpenter eviction mitigation + Prometheus/Grafana observability — see Parts 2 and 3 |
| `7bbe64c` (#689) | correct wrong/misleading dashboard data |
| `beea16d` (#690) | sweep the etcd fixes across konk-operator and konk-services |

**CI / housekeeping:** `f9d9ddb`, `b379b6d`, `97950c6`, `aaac905`, `518eac5`,
`668daf2`, `2459821`, `135603a`, `12c0598`, `65860e4`

### 1.3 New / changed values surface

Keys that do not exist on the baseline chart and become available on the target:

| Key | Default | Purpose |
|---|---|---|
| `persistence.claimName` | `data` | Name of the `volumeClaimTemplate`. Set to `data-v2` to provision fresh PVCs. |
| `recreateStatefulSet.enabled` | `false` | Pre-upgrade hook that deletes + recreates the STS when `claimName` changes. |
| `recreateStatefulSet.image.*` | `registry.k8s.io/kubectl` | Image for the hook Job (override for air-gapped). |
| `etcd.initialClusterState` | `""` | `new` / `existing`. Empty → chart derives it. |
| `etcd.dataDir` | `/var/lib/etcd` | New mount path — see 1.4. |
| `metrics.enabled` | `false` | Expose etcd metrics on port `2381`. |
| `metrics.podMonitor.enabled` | `false` | Emit a PodMonitor instead of scrape annotations. |
| `dashboards.create` | `false` | Render the Grafana dashboard ConfigMaps. |

Also added chart-side on `beea16d` (no DC action needed):

- `podmonitor.yaml` — etcd PodMonitor (Part 2)
- `poddisruptionbudget.yaml` — etcd PDB, plus `pdb.enabled` / `pdb.minAvailable` (Part 3)
- `tolerations` / `affinity` populated on the etcd and konk-service charts (Part 3)
- etcd resource requests raised `cpu 10m → 200m`, `memory 64Mi → 128Mi` (Part 3)

### 1.4 The data-path change — why this is a bootstrap, not an upgrade

This is the single most important mechanical difference.

| | Mount path | `ETCD_DATA_DIR` |
|---|---|---|
| Bitnami `8b64bf7` | `/bitnami/etcd` (`statefulset.yaml:79`) | `/bitnami/etcd/data` (`:126`) |
| Upstream `beea16d` | `/var/lib/etcd` (`statefulset.yaml:258`) | `.Values.etcd.dataDir` (`:90`) |

On the old chart the PVC is mounted at `/bitnami/etcd` and etcd writes into the
`data/` subdirectory of that volume. On the new chart the same volume would be
mounted at `/var/lib/etcd` and etcd reads the volume **root**.

**Consequence:** even if the old PVC were reused, the existing member data sits
under `data/` and is invisible to the new etcd. It starts empty. This is why:

- the migration is non-destructive to the old bytes (they are orphaned, not deleted), **and**
- the cluster **must** bootstrap with `ETCD_INITIAL_CLUSTER_STATE=new`, or the pods
  crash-loop trying to join a cluster whose data they cannot see.

### 1.5 The `replicaCount` regression and its fix

Worth recording because it caused real confusion and produced at least one
incorrect PR description.

| Chart | `replicas:` renders from |
|---|---|
| `8b64bf7` (baseline) | `.Values.statefulset.replicaCount` — `statefulset.yaml:14` |
| `7c13757`..`f8540d7^` | `.Values.replicaCount` ← **regression**, always resolved to 1 |
| `f8540d7`..`beea16d` | `.Values.statefulset.replicaCount` — `statefulset.yaml:11` |

PR #572 rewrote the chart and silently changed the key the StatefulSet reads, and
also moved the konk chart default from `etcd.statefulset.replicaCount` to
`etcd.replicaCount`. `f8540d7` restored both.

**The key is live on the baseline chart.** Any DC file setting
`konk.custom.etcd.statefulset.replicaCount` takes effect today. See Part 4.3 for
what that means per cluster.

The replica count is also load-bearing for bootstrap. `statefulset.yaml:100` gates
these behind `gt (int .Values.statefulset.replicaCount) 1`:

- `ETCD_INITIAL_CLUSTER`
- `ETCD_INITIAL_CLUSTER_TOKEN`
- `ETCD_INITIAL_CLUSTER_STATE`

**At `replicaCount: 1` none of them are emitted** — so an `initialClusterState: "new"`
set in DC values is silently dropped. Pin `replicaCount: 3` *and* `initialClusterState`
together, or neither works.

`initialClusterState` resolution (`statefulset.yaml:106-111`):

```
explicit .Values.etcd.initialClusterState   → wins
else .Release.IsInstall                     → "new"
else                                        → "existing"
```

---

## Part 2 — Grafana / observability changes

### 2.1 Chart-side

**#688 (`e03a23d`) — etcd metrics + Karpenter mitigation**
- etcd metrics on a dedicated port (`2381`), PodMonitor template
- Also carries the Karpenter scheduling work — covered in **Part 3**

**#689 (`7bbe64c`) — correct wrong and misleading dashboard data**
- Explicit `[5m]` rate windows instead of `$__rate_interval` (the datasource sets
  `timeInterval 6s`, so `$__rate_interval` collapsed to 24s — below the scrape
  interval, so `increase()` returned nothing)
- Pinned Min interval so `$__rate_interval` cannot outrun the scrape interval
- Collapsed duplicate per-pod series caused by double scraping
- Stopped "No data" rendering as a critical alarm; scoped panels when template
  variables are empty
- Deduped cert panels; repointed CA expiry at a real Certificate
- **Gated the chart's `metrics.podAnnotations` behind `not metrics.podMonitor.enabled`**
  (`statefulset.yaml:34`) so etcd is discovered once, not twice

**#690 (`beea16d`) — sweep across konk-operator and konk-services**
- Excluded completed Jobs; unbounded alarm shading; repaired the namespace join
- One series per pod in "konks ready", not two
- Renamed `ns` column to `namespace`; widened Deployment/identifier columns
- Showed denominators alongside Row 1 counts

**#691 — OPEN, not in `beea16d`** (branch `fix/dashboard-axis-legend`, commit `9238655`)
- `axisSoftMax: 5` / `axisSoftMin: 0` on *Container Restarts* (the series was
  present but flat-zero against a 0–100 auto-scaled axis, indistinguishable from
  "No data")
- `legendFormat: "Konk CRs"` on *konk count* (Grafana was printing the raw PromQL
  as the series name)

> Two E2E checks on #691 were failing as of 2026-08-24. It must be merged into
> `release/upgrade-etcd` and rebuilt before any cluster can pick it up — dashboards
> ship in the chart, so there is no DC-side shortcut.

### 2.2 DC-side values

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

All three default to `false`, so on a cluster that sets none of them there are no
etcd metrics or dashboards today and enabling them is **purely additive**.

For konk-operator's own metrics (`konk-operator-values.yaml`):

```yaml
metrics:
  enabled: true
  podMonitor:
    enabled: true
podAnnotations: null
```

> ⚠️ **`podAnnotations: null` is only correct on clusters with no `podAnnotations`
> of their own.** us-stg-1 needs a different form. **Read Part 2.4 before applying
> this to any new cluster, prod included.**

### 2.3 The double-scrape trap — and the `podAnnotations` hazard

Discovery mechanism determines which labels exist:

```
annotation discovery (prometheus.io/scrape) → kubernetes_namespace, kubernetes_pod_name
PodMonitor                                  → namespace, pod
```

konk-operator dashboard panels scoped by `namespace="konk"` (*Operator Start Time*,
*Container Restarts*, *kube api client requests*, *Operator 5xx error rate*) return
nothing under annotation discovery. The `count(resource_created_at_seconds{...})`
tiles work either way — they carry no namespace selector.

**Consumer:** `infra-monitoring-alloy` (ns `infra-monitoring`). Its
`prometheus.operator.podmonitors` component has **no selector**, so it picks up
every PodMonitor regardless of labels. It is **not deployed from the DC repo** —
`grafana-alloy-infra` is `dnd` on every non-gov cluster — so it is easy to miss.

It is **not** `federated-prometheus`, which selects PodMonitors on
`app.kubernetes.io/{name,instance}=federated-prometheus`, a label neither konk
PodMonitor carries.

### 2.4 Suppressing annotation discovery — pick the right form per cluster

**Read this before enabling `podMonitor` on any new cluster, prod included.**
Getting it wrong either doubles every series or silently unmeshes konk-operator.

#### The constraint: `deep_merge` cannot subtract a key

`scripts/flatten-app.py:43`:

```python
if key in result and isinstance(result[key], dict) and isinstance(value, dict):
    result[key] = deep_merge(result[key], value)   # two dicts -> merge
else:
    result[key] = copy.deepcopy(value)             # anything else -> replace wholesale
```

There is no way to express "remove `prometheus.io/scrape`". Only two moves exist:

| Form | Effect | Use when |
|---|---|---|
| `podAnnotations: null` | **replaces** the inherited map wholesale — all inherited annotations gone | the cluster has no `podAnnotations` of its own that must survive |
| explicit keys incl. `prometheus.io/scrape: "false"` | **merges** over the inherited map — overrides `scrape`, keeps everything else | the cluster carries `podAnnotations` that must survive (e.g. `linkerd.io/inject`) |

`{}` is **not** a third option — an empty dict merges with a dict, so it is a
no-op and leaves the inherited annotations fully intact. The chart guards with
`{{- with .Values.podAnnotations }}`, which skips nil but not `{}`.

#### Why `"false"` works — and why it must be quoted

Overriding is sufficient because Alloy's annotation-discovery rule is an
**exact-match keep**, not a presence check:

```
rule {
    source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
    regex         = "true"
    action        = "keep"
}
```

Any value other than `"true"` drops the pod from that discovery path, so
`"false"` is as effective as deleting the key. A leftover
`prometheus.io/port: "8080"` is harmless — discovery keys off `scrape` alone.

> ⚠️ **Quote it.** Kubernetes annotation values must be strings. An unquoted
> `false` renders as a YAML boolean and the API server rejects the pod spec.

#### Which form each cluster needs

Verified against `origin/master`, 2026-09-02. **Only us-stg-1 differs.**

| Cluster | cluster-level `podAnnotations` | Form to use |
|---|---|---|
| us-dev-2, us-dev-4, us-dev-5 | none | `podAnnotations: null` |
| eu-stg-1 | none *(file did not exist — create it)* | `podAnnotations: null` |
| **us-stg-1** | **`linkerd.io/inject: enabled`** | **explicit keys + `scrape: "false"`** |
| us-com-1 | none | `podAnnotations: null` |
| eu-com-1, prd-1, integration | none *(file does not exist — create it)* | `podAnnotations: null` |
| gov-stg-2, gov-prd-2 | none | `podAnnotations: null` |

No lifecycle-level `podAnnotations` exists anywhere; the only inherited source is
the global `envs/konk-operator-values.yaml`
(`prometheus.io/scrape: "true"`, `prometheus.io/port: "8080"`).

**Do not trust this table blind — re-check before each cluster**, since a mesh
annotation can be added at any time:

```bash
# does this cluster carry podAnnotations that must survive?
git show origin/master:envs/<lifecycle>/<cluster>/konk-operator-values.yaml | grep -A6 podAnnotations

# ground truth: is konk-operator actually meshed there?
kubectl --context <ctx> -n konk get pods \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
  # a linkerd-proxy sidecar => must use the explicit-keys form
```

#### The us-stg-1 form, for reference

```yaml
metrics:
  enabled: true
  podMonitor:
    enabled: true

podAnnotations:
  linkerd.io/inject: enabled       # preserved
  prometheus.io/scrape: "false"    # overrides the global "true"
```

Effective after merge: `linkerd.io/inject: enabled`,
`prometheus.io/scrape: "false"`, `prometheus.io/port: "8080"`.

#### Sequencing caveat

`helm-charts/konk-operator/templates/podmonitor.yaml` exists at `beea16d` but
**not** at `8b64bf7`. Applying the annotation change to a cluster still on the
baseline chart switches annotation discovery off while nothing renders the
PodMonitor — operator metrics go dark until the `-162` rollout. Safe in practice
because `konk-operator-version.txt` and `konk-operator-values.yaml` belong to the
**same DC app** and therefore deploy together, but do not split them across
separate rollouts.

#### ⚠️ The k8s.manifests preview will NEVER show the PodMonitor

**Do not read its absence as "the values didn't take".** Both PodMonitor
templates — konk-operator and etcd — are gated on a *cluster capability*:

```
{{- if and .Values.metrics.enabled .Values.metrics.podMonitor.enabled
         (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") }}
```

The gate exists so that enabling metrics can never break a cluster without
prometheus-operator. But `.Capabilities.APIVersions` is only populated when Helm
renders **against a live cluster**. The DC build and the k8s.manifests preview
render offline, so the gate is always false there and the resource is silently
dropped.

Verified 2026-09-02 — every cluster renders `konk:v0.2.1-162-gbeea16d-j33` with
**zero** `kind: PodMonitor` in its konk-operator manifest, including clusters
where it has been enabled for weeks:

| Cluster | `kind: PodMonitor` in manifest | live PodMonitor |
|---|---|---|
| us-dev-2 | 0 | ✅ present |
| us-dev-5 | 0 | ✅ present |
| us-stg-1 | 0 | pending rollout |
| eu-stg-1 | 0 | pending rollout |

The live objects carry `helm.toolkit.fluxcd.io/name: konk-operator`,
`helm.toolkit.fluxcd.io/namespace: vela-system` and
`meta.helm.sh/release-name: konk-operator` — i.e. konk-operator is applied by a
**Flux HelmRelease that re-renders on-cluster**, where `Capabilities` is
populated and the gate passes. The k8s.manifests file is a preview, not the
authoritative apply.

**So when reviewing a k8s.manifests PR for this change, check the annotations —
that is the only part that can appear offline:**

```diff
       annotations:
         linkerd.io/inject: enabled          # must survive
         prometheus.io/port: "8080"
-        prometheus.io/scrape: "true"
+        prometheus.io/scrape: "false"       # quoted string, not a boolean
```

A **one-line diff is the complete and correct** offline expression of enabling
the operator PodMonitor. `metrics.enabled` has exactly one other use in the chart
— `containerPort: {{ .Values.metrics.port }}` on the Deployment, which is
**ungated** and therefore already present — so nothing else should move.

Confirm the PodMonitor itself on-cluster after Flux reconciles:

```bash
kubectl --context <ctx> -n konk get podmonitor konk-operator
kubectl --context <ctx> -n aggregate get podmonitor bulk-konk-etcd
```

---

## Part 3 — Karpenter eviction mitigation

Landed via konk **#683** (`2606165`) on `release/upgrade-etcd`, a port of **#682**
from `main`, and carried forward by **#688** (`e03a23d`). Tracked as **DEVOPS-47739**.

This is an independent fix that happens to ride along with the etcd upgrade. It is
not required by the version bump, but it ships in the same image — so it must be
verified after any deployment of `beea16d`.

### 3.1 Why it was needed

`bulk-konk-etcd` pods in the `aggregate` namespace were being **continuously evicted
in a rolling loop** by Karpenter node consolidation. Observed on **us-dev-2** and
**gov-stg-2**. The cycle never stopped on its own:

```
Karpenter marks node Underutilized (consolidateAfter window expires)
  -> evicts etcd pod            (Stopping container etcd / Evicted: Underutilized)
  -> pod reschedules onto a new node
  -> EBS Multi-Attach error     (volume still attached to the old node, 1-2 min)
  -> pod starts; the new node also looks Underutilized (same root cause)
  -> [1h on us-dev-2 / 2h on gov-stg-2 later] REPEAT
```

On gov-stg-2, Karpenter was **also** evicting KonkService pods directly, independent
of the etcd cycle:

```
ntp  Normal  Evicted  pod/ntp-aggregate-api-apiservice-konk-service-kubeconfig-...
             Evicted pod: Underutilized
```

**Downstream effect:** every eviction opens a 1-2 minute window where the konk
kube-apiserver loses its backing store, or its health/reconciliation pods are
cancelled mid-check. All konk-served API traffic fails on that cluster for the
duration.

### 3.2 Root causes

**1 — CPU requests were `10m`.**

Karpenter's `WhenEmptyOrUnderutilized` consolidation policy evaluates a node by the
**sum of pod resource requests**, not actual usage. At `cpu: 10m`, a node hosting an
etcd or KonkService pod looks nearly empty. Once `consolidateAfter` expires,
Karpenter evicts the pod and terminates the node.

```yaml
# helm-charts/konk/values.yaml (before)
etcd:
  resources:
    requests:
      cpu: 10m       # far too low
      memory: 64Mi

# helm-charts/konk-service/values.yaml (before)
kind:
  resources:
    requests:
      cpu: 10m       # far too low
```

> **Why the etcd chart's own `100m` default did not help.** The konk chart dumps
> `.Values.etcd` straight into the Etcd CR spec, and the operator then uses that CR
> spec as the Helm values when rendering the etcd chart — **overriding the etcd
> chart's own defaults**. The fix had to land in `helm-charts/konk/values.yaml`, not
> `helm-charts/etcd/values.yaml`. This is the same value-chain trap behind the
> `replicaCount` regression in Part 1.5.

**2 — There was no PodDisruptionBudget on etcd.**

```
$ kubectl get pdb -n aggregate
No resources found in aggregate namespace.
```

Nothing enforced quorum at the Kubernetes API level. Quorum survived only because
of Karpenter's internal `nodes: 1` disruption budget — a Karpenter setting, not a
Kubernetes guarantee, and not respected by `kubectl drain` or any other eviction
actor.

### 3.3 What was changed

| Chart | Change | Version |
|---|---|---|
| `konk` | etcd `requests.cpu` `10m` → **`200m`**, `requests.memory` `64Mi` → **`128Mi`** | `0.1.0` → `0.2.0` |
| `konk` | etcd `tolerations` + `affinity` added | |
| `konk-service` | kind `requests.cpu` `10m` → **`100m`** | `0.1.0` → `0.2.0` |
| `konk-service` | `tolerations` / `affinity` values, wired into the `apiservice`, `kubeconfig` and `apiservice-test` deployment templates | |
| `etcd` | new `templates/poddisruptionbudget.yaml`; `pdb.enabled: true`, `pdb.minAvailable: 2` | `1.1.2` → `1.2.2` |
| `etcd` | `tolerations` / `affinity` populated (were empty stubs) | |

The scheduling block, identical on both the etcd and konk charts:

```yaml
tolerations:
  - key: infoblox.com/do-not-disrupt
    operator: Exists
    effect: NoSchedule

affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-group-type
              operator: In
              values:
                - stable
```

> #683 also aligned the konk chart's etcd replica key with the release-branch etcd
> chart (`replicaCount` → `statefulset.replicaCount`). See Part 1.5 — without it the
> StatefulSet scaled 3 → 1 on upgrade and left `etcd-0` with stale 3-node cluster
> data that failed health checks.

### 3.4 Why the affinity is *soft*

`stable-node-pool` uses `consolidationPolicy: WhenEmpty` — it only reclaims a node
once all pods have left naturally, and never evicts pods to consolidate. etcd pods
landing there are fully protected.

`preferredDuringSchedulingIgnoredDuringExecution` (soft) is deliberate:

| Cluster | Behaviour |
|---|---|
| Has `stable-node-pool` (e.g. us-dev-2) | etcd lands on stable nodes → `WhenEmpty` never evicts it |
| No `stable-node-pool` (gov-stg-2, prod clusters) | no matching nodes → scheduler falls back to any node; **current behaviour fully preserved** |

A *hard* (`required...`) affinity would leave etcd unschedulable on every cluster
without that node pool. The toleration is needed because `stable-node-pool` carries
the `infoblox.com/do-not-disrupt:NoSchedule` taint; on clusters where no node has
that taint the toleration is inert.

### 3.5 The PodDisruptionBudget — and where it does *not* apply

```yaml
{{- if and .Values.pdb.enabled (gt (int .Values.statefulset.replicaCount) 1) }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}   # 2
```

`minAvailable: 2` on 3 replicas gives `disruptionsAllowed: 1` — one member may be
evicted at a time, quorum is never broken. Defense in depth: it is respected by
Karpenter, `kubectl drain`, and every other eviction actor, independent of whether
the CPU-request fix or the stable node pool did their job.

> ⚠️ **The PDB is not rendered at `replicaCount: 1`.** The template is guarded on
> `gt (int .Values.statefulset.replicaCount) 1`, so any single-member cluster — which
> is every box-dev cluster inheriting the lifecycle default, plus eu-stg-1 (Part 4.3)
> — gets **no PDB at all**. On those clusters the only Karpenter protection is the
> raised CPU request and the soft affinity. Do not read "PDB missing" as a failed
> deployment there; check the replica count first.

### 3.6 What to verify after deploying

```bash
# PDB present, and allowing exactly one disruption (3-replica clusters only)
kubectl -n aggregate get pdb
kubectl -n aggregate get pdb bulk-konk-etcd \
  -o jsonpath='{.spec.minAvailable}{" allowed="}{.status.disruptionsAllowed}{"\n"}'

# CPU/memory requests actually raised
kubectl -n aggregate get sts bulk-konk-etcd \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'
  # expect: {"cpu":"200m","memory":"128Mi"}

# toleration + affinity landed
kubectl -n aggregate get sts bulk-konk-etcd -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
kubectl -n aggregate get sts bulk-konk-etcd -o jsonpath='{.spec.template.spec.affinity}{"\n"}'

# KonkService pods too
kubectl get deploy -A -l app.kubernetes.io/name=konk-service \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}{end}'
  # expect: 100m

# the loop should be gone — no recurring Evicted events
kubectl get events -A --field-selector reason=Evicted \
  --sort-by=.lastTimestamp | grep -Ei 'etcd|konk' | tail -20

# which node pool did etcd land on?
kubectl -n aggregate get pods -l app.kubernetes.io/name=etcd \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
kubectl get nodes -L node-group-type
```

Expect **no** `Evicted: Underutilized` events for etcd or konk-service pods after
the deployment settles. Recurring evictions on a ~1h/~2h cadence mean the CPU
request did not take effect — check the Etcd CR spec, since the konk chart value is
what actually reaches the etcd chart (3.2).

---

## Part 4 — Cluster state matrix

### 4.1 Current state

| Cluster | Lifecycle | konk-operator | `konk.custom.etcd` overrides |
|---|---|---|---|
| us-dev-2 | box-dev | `v0.2.1-162-gbeea16d-j33` | `data-v2`, **`new`**, recreate **`true`**, `replicaCount 3`, metrics, dashboards ⚠️ |
| us-dev-4 | box-dev | `v0.2.1-168-gb8dabd8-j207` | — |
| us-dev-5 | box-dev | `v0.2.1-162-gbeea16d-j33` | `data-v2`, `existing`, recreate `false`, `replicaCount 3`, metrics, dashboards |
| integration | integration | `v0.2.1-189-g6fc79bc-j39` | — |
| us-stg-1 | com-stage | `v0.2.1-158-gf8540d7-j26` | `data-v2`, `existing`, recreate `false`, `replicaCount 3`, `4Gi` |
| eu-stg-1 | com-stage | `v0.2.1-138-g8b64bf7-j170` | `replicaCount 1`, `4Gi` |
| prd-1 | prod | `v0.2.1-138-g8b64bf7-j170` | *none* |
| us-com-1 | com-prod | `v0.2.1-138-g8b64bf7-j170` ¹ | *none* |
| eu-com-1 | com-prod | `v0.2.1-138-g8b64bf7-j170` | *none* |
| gov-stg-2 | gov-box-stage | `v0.2.1-164-gbd3f28a-j203` | — |
| gov-prd-2 | gov-box-prod | `v0.2.1-164-gbd3f28a-j203` | — |

¹ `envs/com-prod/us-com-1/konk-operator-version.txt` is a **symlink** to
`../../prod/prd-1/konk-operator-version.txt` — bumping prd-1 moves us-com-1 with it.

⚠️ us-dev-2 migrated on **2026-09-01** (Appendix A) and is still carrying the
migration-only flags. It needs the steady-state flip
([checklist Step 7](phase-1-deployment-checklist.md)) before it is in a stable
configuration.

Lifecycle-level default that applies to every box-dev cluster
(`envs/box-dev/bulk-values.yaml`):

```yaml
konk:
  # Run konk-etcd in non-HA (single pod) mode so that there are no quorum issues on startup
  custom:
    etcd:
      statefulset:
        replicaCount: 1
      resources:
        limits:
          memory: 4Gi
```

### 4.2 Expected state after migration

**During migration** (the cluster being migrated):

```yaml
konk:
  custom:
    etcd:
      persistence:
        claimName: data-v2
      etcd:
        initialClusterState: "new"
      recreateStatefulSet:
        enabled: true
      statefulset:
        replicaCount: 3
```

**Steady state** (flip these once the members are healthy on `data-v2`):

```yaml
      etcd:
        initialClusterState: "existing"
      recreateStatefulSet:
        enabled: false
```

Leaving `new` in place means any future reconcile that recreates a pod bootstraps
it as a new cluster instead of rejoining. Leaving `recreateStatefulSet: true` keeps
an STS-deleting hook armed. **The post-migration flip is a required second PR**, not
an optional cleanup.

### 4.3 Replica count — three different routes to a number

A recurring source of confusion. There are three distinct ways a cluster arrives
at its etcd replica count:

| Route | Clusters | Effective |
|---|---|---|
| Explicit cluster-level pin | us-dev-5, us-stg-1 | **3** |
| Lifecycle default | any box-dev cluster with no cluster pin, eu-stg-1 | **1** |
| Inherited konk chart default (`etcd.statefulset.replicaCount: 3`) | prd-1, us-com-1, eu-com-1 | **3** |

So **prod runs 3 members while box-dev runs 1** — and both are the config working
as written. When "matching prod state" on a box-dev cluster, the replica count is
*not* matched by default; pinning `replicaCount: 3` is a deliberate 1 → 3 scale-up.

---

---

## Part 5 — How the change actually reaches a cluster

Observed on **us-dev-2, 2026-09-01**, during the first end-to-end run of this
migration. Recorded here because none of it is visible from the chart diffs alone.

### 5.1 It arrives in two waves, not one

The two DC files this migration touches belong to **different apps with different
pipelines**:

| DC file | Owning app | Delivers |
|---|---|---|
| `konk-operator-version.txt`, `konk-operator-values.yaml` | **konk-operator** | new operator image → new **chart defaults** |
| `bulk-values.yaml` (`konk.custom.etcd`) | **bulk** | the **DC overrides** that drive the migration |

On us-dev-2 they landed roughly three minutes apart. Wave 1 brought etcd `3.7.1`,
`requests: 200m/128Mi`, tolerations, affinity and both PodMonitors — all chart
defaults baked into the operator image. Wave 2 brought `claimName: data-v2`,
`replicaCount: 3`, `initialClusterState: "new"` and `recreateStatefulSet: true`,
and only then was the StatefulSet recreated.

**Between the waves the cluster sits in a state that looks broken but is not:**
etcd restarts onto 3.7.1 at the new `/var/lib/etcd` mount path while still bound to
the old `data` PVC at `replicaCount: 1`, with the StatefulSet un-recreated and
`ETCD_INITIAL_CLUSTER_STATE` not emitted at all (Part 1.5 — it is gated on
`replicaCount > 1`).

The operational handling of this is in
[the deployment checklist, Step 3](phase-1-deployment-checklist.md).

### 5.2 The data-path change, confirmed in the logs

Part 1.4 predicted the old Bitnami bytes would be invisible at the new mount path.
The etcd log says so explicitly:

```
"found invalid file under data directory","filename":"data","data-dir":"/var/lib/etcd"
"found invalid file under data directory","filename":"lost+found","data-dir":"/var/lib/etcd"
"found invalid file under data directory","filename":"member_removal.log","data-dir":"/var/lib/etcd"
```

`data/` is where Bitnami kept the member directory. etcd 3.7.1 reads the volume
root, sees `data/` as a stray file, and ignores it.

### 5.3 A previously-migrated cluster can carry a stale `member/` directory

us-dev-2 had been through an upgrade-and-downgrade cycle before
(`us-dev-2-downgrade_to_prd1.md`). Its old `data` PVC therefore already contained a
`/var/lib/etcd/member` directory left behind by that attempt — so during wave 1
etcd did **not** bootstrap truly fresh, it *recovered* a stale, near-empty member:

```
"server has already been initialized","data-dir":"/var/lib/etcd","dir-type":"member"
"member-initialized":true
"recovered v3 backend","backend-size-bytes":20480,"backend-size":"20 kB"
"restarting local member","cluster-id":"e9e217a51a7c2cee","local-member-id":"132d3f2b2031a7d7","commit-index":4
```

This also explains a detail that is otherwise alarming: the member ID
`132d3f2b2031a7d7` is **identical** to the pre-upgrade baseline.

**This applies only to the wave-1 transient on the *old* `data` PVC.** The final
cluster on the fresh `data-v2` volumes bootstrapped cleanly — `member-initialized:
false`, `start mode: bootstrapping cluster`, a new `cluster-id`
(`a1f00c6916643ffa`), and only `lost+found` reported as an orphaned file.

### 5.4 Key counts measure repopulation, not preservation

| | Keys | DB size | etcd |
|---|---|---|---|
| Pre-upgrade baseline | 213 | 889 kB | 3.4.14 |
| Post-migration | 212 | 520 kB | 3.7.1 |

The counts land within one of each other, which is easy to misread as "the data
survived". It did not — these are different data directories entirely. The konk
apiserver rewrites the same `/registry/apiregistration.k8s.io/...` entries on
startup, so the logical key count reconstructs to roughly the same number every
time.

**Do not treat key-count parity as evidence of data preservation.** Judge
repopulation by the KonkService count and `/registry` readability instead.

---

## Appendix A — us-dev-2 before and after (2026-09-01)

### A.1 Pre-migration baseline

Captured with `tests/pre-upgrade.sh`. **13/13 checks passed — safe to upgrade.**
Recorded here as the reference "pre-migration" state to compare against later.

```
Cluster : teleport.services.sdp.infoblox.com-us-dev-2
NS      : aggregate
STS     : bulk-konk-etcd
```

| Item | Value |
|---|---|
| konk-operator image | `infoblox/konk:v0.2.1-138-g8b64bf7-j170` |
| konk-operator pod | Running |
| Konk CR `bulk-konk` | `Deployed=True`, reason `UpgradeSuccessful`, no `ReleaseFailed` |
| Etcd CR `bulk-konk-etcd` | `Deployed=True`, reason `UpgradeSuccessful`, no `ReleaseFailed` |
| `recreateStatefulSet.enabled` | **(not set)** |
| STS `volumeClaimTemplate` | **`data`** |
| `data-*` PVCs | `data-bulk-konk-etcd-0` — Bound, 8Gi, RWO, gp3 |
| `data-v2-*` PVCs | **none** |
| STS replicas | **1/1 ready** |
| etcd image | `docker.io/bitnami/etcd:3.4.14-debian-10-r0` |
| Helm release | `rev=6 status=deployed` → next deploy is an **in-place upgrade** ([checklist Step 2](phase-1-deployment-checklist.md)) |
| etcd endpoint | healthy (`took = 8.849607ms`) |
| etcd members | 1 — `132d3f2b2031a7d7` `bulk-konk-etcd-0` started, not learner |
| **etcd key count** | **213** ← data baseline |
| etcd DB size | 889 kB |
| etcd version reported | `3.4.14` |
| Raft term / index | 6 / 5511 (applied 5511) |
| Stale hook resources | none |

Notes for the comparison later:

- The single member is the **box-dev lifecycle default** (`replicaCount: 1`), not a
  fault. Prod runs 3 by inheriting the konk chart default — see Part 4.3.
- `rev=6` means the `bulk-konk-etcd` release exists, so `initialClusterState` must
  be set **explicitly** or the release uninstalled first ([checklist Step 2](phase-1-deployment-checklist.md)).
- 213 keys / 889 kB is the pre-migration data baseline. After a `data-v2` bootstrap
  the new cluster starts empty and repopulates.

---


### A.2 Post-migration result

Captured with `post-upgrade.sh` after both waves landed. **38/39 assertions passed** — the
one failure is unrelated to etcd (see the note below Appendix A.2).

| Item | Value |
|---|---|
| konk-operator image | `infoblox/konk:v0.2.1-162-gbeea16d-j33` |
| etcd image | `cgr.dev/infoblox.com/etcd:3.7.1` |
| STS `volumeClaimTemplate` | **`data-v2`** |
| STS `creationTimestamp` | **`2026-09-01T09:55:11Z`** — genuinely recreated |
| STS replicas | **3/3 ready**, 0 restarts |
| `ETCD_INITIAL_CLUSTER_STATE` | `new` |
| `recreateStatefulSet.enabled` | `true` — still armed, awaiting the steady-state flip |
| `data-v2-*` PVCs | 3 Bound, 8Gi gp3 |
| `data-*` PVCs | `data-bulk-konk-etcd-0` retained |
| etcd members | 3 — `132d3f2b2031a7d7`, `932935662d82d16a`, `9fbfa0b83e694be`, all started, none learner |
| etcd key count | **212** (see 5.4 — repopulated, not preserved) |
| etcd DB size | 520 kB |
| Helm release | `rev=11 status=deployed` |
| PDB | `bulk-konk-etcd`, minAvailable 2, **allowed disruptions 1** |
| requests | `cpu 200m` / `memory 128Mi` |
| tolerations | `infoblox.com/do-not-disrupt:NoSchedule` |
| PodMonitors | `aggregate/bulk-konk-etcd`, `konk/konk-operator` |
| Hook resources | none — cleaned up |
| KonkServices | 17 registered |
| Konk CR / Etcd CR | `Deployed=True`, reason `UpgradeSuccessful` |

Still outstanding: the **steady-state flip PR**
([checklist Step 7](phase-1-deployment-checklist.md)) — `initialClusterState` →
`existing`, `recreateStatefulSet` → `false`.

---

## Appendix B — Cross-references

Base path: `~/Documents/Issues/konk/issues/etcd issues/`

| File | What it covers |
|---|---|
| `etcd-konk-migration.md` | Image-by-image comparison, `ETCD_INITIAL_CLUSTER_STATE` logic, Bitnami-vs-upstream data-path diff, the install-vs-upgrade decision table, and the post-migration flag flip |
| `etcd-upgrade-issues.md` | Issues actually hit: operator rollback not restarting pods, HelmRelease re-applying HA values, the immutable-STS upgrade loop, mixed pod state, stale `ReleaseFailed`, and the `replicaCount` regression (§6) |
| `etcd-rollback.md` | Rollback procedure and its constraints |
| `tests/us-stg-1-etcd-upgrade-error.md` | The us-stg-1 upgrade failure in detail |
| `us-stage-etcd-upgrade-issue.md` | us-stage upgrade issue write-up |
| `eu-stg-etcd-upgrade-issue.md` | eu-stg-1 upgrade issue write-up |
| `prod-etcd-migration-options.md` | Options considered for the production migration |
| `etcd_approach_b_claimname.md` | The `claimName` approach (Option B) in depth |
| `etcd-upgrade-approach-final.md` | Final agreed approach |
| `new files/etcd-migration-debugging.md` | Debugging notes |
| `new files/etcd-rollback-issues-cgr-to-bitnami-us-stg.md` | Rollback from Chainguard back to Bitnami on us-stg |
| `tests/pre-upgrade.sh` / `tests/pre-upgrade.md` | Pre-upgrade check script and notes |
| `tests/post-upgrade.sh` / `tests/post-upgrade.md` | Post-upgrade check script and notes |
| `tests/pre-etcd-upgrade-test-results.md` | Recorded pre-upgrade results |

Sibling directory: `~/Documents/Issues/konk/etcd upgrade final/`

| File | What it covers |
|---|---|
| [`phase-1-deployment-checklist.md`](phase-1-deployment-checklist.md) | **The deployment runbook for this migration** — pre-checks, install-vs-upgrade gate, hook watching, post-checks, E2E, rollback |
| `us-dev-2-downgrade_to_prd1.md` | Downgrading us-dev-2 to the prd-1 baseline |

**Repos**
- konk — `github.com/infobloxopen/konk`; branches `main`, `release/upgrade-etcd`, `etcd-upgrade-tests`
- DC — `github.com/Infoblox-CTO/deployment-configurations`; `envs/<lifecycle>/<cluster>/konk-operator-{version.txt,values.yaml}` and `bulk-values.yaml`
