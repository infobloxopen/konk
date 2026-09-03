# Phase 1 — etcd 3.4.14 → 3.7.1 Deployment Checklist

**Companion document:** [What changed and why](etcd-3.4.14-to-3.7.1-migration-changes.md) — image lineage, chart
diffs, the Grafana work, the Karpenter mitigation, and the per-cluster state
matrix. This document is **only the runbook**.

**Target build:** konk-operator `v0.2.1-162-gbeea16d-j33` (etcd `cgr.dev/infoblox.com/etcd:3.7.1`)
**Last updated:** 2026-09-01 — validated end-to-end on us-dev-2

---

## Order of operations

| Step | What | Blocking? |
|---|---|---|
| 0 | Pick the right `podAnnotations` form for this cluster | **yes — gets silently wrong** |
| 1 | Match the prod baseline (`pre-upgrade.sh`) | yes — 13/13 must pass |
| 2 | ⭐ Decide fresh install vs in-place upgrade | **yes — do not skip** |
| 3 | Expect a two-wave rollout | no — but do not intervene mid-wave |
| 4 | Watch the hook and the StatefulSet recreate | yes |
| 5 | Post-deployment checks (`post-upgrade.sh`) | yes — 33 sections / 39 assertions must pass |
| 6 | E2E validation (`e2e-konk-test.sh`) | yes |
| 7 | Raise the steady-state flip PR | **yes — the migration is not done without it** |

Scripts referenced throughout live in
`~/Documents/Issues/konk/issues/etcd issues/tests/`.

---

## Step 0 — Pick the right `podAnnotations` form for this cluster

**Do this before writing the DC PR.** Enabling the konk-operator PodMonitor
requires suppressing annotation discovery, and there are two mutually exclusive
ways to do it. Choosing wrong either **doubles every series** or **silently pulls
konk-operator out of the service mesh** — neither fails loudly.

```bash
# 1. does this cluster carry podAnnotations that must survive?
git show origin/master:envs/<lifecycle>/<cluster>/konk-operator-values.yaml | grep -A6 podAnnotations

# 2. ground truth — is konk-operator actually meshed?
kubectl --context <ctx> -n konk get pods \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

| Finding | Use |
|---|---|
| no cluster-level `podAnnotations`, no `linkerd-proxy` sidecar | `podAnnotations: null` |
| carries `podAnnotations` (e.g. `linkerd.io/inject`) **or** a `linkerd-proxy` sidecar | explicit keys + `prometheus.io/scrape: "false"` (quoted) |

As of 2026-09-02 only **us-stg-1** needs the second form. Every other cluster —
including us-com-1, eu-com-1 and prd-1 — takes `podAnnotations: null`. Full
reasoning, the `deep_merge` constraint, and why `"false"` works rather than
deleting the key: [changes doc Part 2.4](etcd-3.4.14-to-3.7.1-migration-changes.md).

> ⚠️ **When the k8s.manifests preview PR appears, expect a one-line diff** — just
> `prometheus.io/scrape: "true"` → `"false"`. Both PodMonitor templates are gated
> on `.Capabilities.APIVersions.Has "monitoring.coreos.com/v1"`, which offline
> rendering can never satisfy, so the PodMonitor is **always** absent from the
> preview on every cluster. That is not a failure. Check the annotations block
> instead, and verify the PodMonitor on-cluster after Flux reconciles. Full
> detail: [changes doc Part 2.4](etcd-3.4.14-to-3.7.1-migration-changes.md).

Also confirm the PodMonitor has a consumer before enabling it at all:

```bash
kubectl --context <ctx> -n infra-monitoring get cm infra-monitoring-alloy \
  -o jsonpath='{.data.config\.alloy}' | grep -A6 'prometheus.operator.podmonitors'
  # must exist AND carry no selector
```

---

## Step 1 — Match the prod baseline

Run `tests/pre-upgrade.sh` against the target cluster. All 13 checks must pass.

| # | Check | Expected |
|---|---|---|
| 1 | konk-operator | Running, image = expected prod baseline |
| 2 | Konk CR (`bulk-konk`) | `Deployed=True`, no `ReleaseFailed` |
| 3 | Etcd CR (`bulk-konk-etcd`) | `Deployed=True`, no `ReleaseFailed` |
| 4 | `recreateStatefulSet` flag | **not set** |
| 5 | STS `volumeClaimTemplate` name | **`data`** (not `data-v2`) |
| 6 | PVC state | `data-*` present; **no `data-v2-*`** |
| 7 | STS replicas | all ready; note the count and image |
| 8 | Helm release stability | `status=deployed`, no failed revisions |
| 9 | etcd endpoint health | healthy |
| 10 | etcd cluster members | member count == STS replicas |
| 11 | etcd baseline (informational) | **record the key count and DB size** |
| 12 | Stale hook resources | none |

Points 4, 5, 6 and 12 are the ones that catch a half-finished previous attempt.
A leftover `data-v2-*` PVC or a stale hook Job means a prior migration did not
complete or was not cleaned up — resolve that before starting.

**Record the section 11 key count.** It is the only baseline you can compare
against after the migration to reason about data.

---

## Step 2 — ⭐ The decisive gate: fresh install vs in-place upgrade

**This is what broke us-stg-1 and eu-stg-1. Check it before every migration.**

`initialClusterState` falls back to `.Release.IsInstall` when not set explicitly.
If the `bulk-konk-etcd` Helm release **already exists**, the operator performs a
`helm upgrade` (revision N → N+1), `IsInstall` is false, and the chart renders
`existing` — against a volume whose data is invisible at the new mount path
([changes doc Part 1.4](etcd-3.4.14-to-3.7.1-migration-changes.md)). The pods crash-loop.

```bash
CTX=teleport.services.sdp.infoblox.com-<cluster>
NS=aggregate

helm --kube-context $CTX list -n $NS | grep bulk-konk-etcd
```

| Release state | Render | Result |
|---|---|---|
| Does not exist / uninstalled first (rev 1 = install) | auto `new` | ✅ clean bootstrap |
| Exists → in-place upgrade (rev N → N+1) | `existing` | ❌ CrashLoopBackOff |

Two ways through:

1. **Set `initialClusterState: "new"` explicitly.** It overrides the fallback —
   but only if `replicaCount > 1`, or the env var is never emitted at all ([changes doc Part 1.5](etcd-3.4.14-to-3.7.1-migration-changes.md)).
2. **Uninstall the release first** so the next deploy is revision 1:

```bash
helm --kube-context $CTX uninstall bulk-konk-etcd -n $NS
# or, if helm CLI scope is a problem:
# kubectl --context $CTX delete secret -n $NS -l owner=helm,name=bulk-konk-etcd

# must return nothing
kubectl --context $CTX get secret -n $NS -l owner=helm,name=bulk-konk-etcd
```

PVCs survive a `helm uninstall` — `volumeClaimTemplate` PVCs are not garbage
collected.

> ⚠️ Uninstalling removes the **running** etcd release. Do this inside the
> migration window, not casually.

---

## Step 3 — Expect a two-wave rollout

**Observed on us-dev-2, 2026-09-01.** The change does not land atomically. The two
DC files are owned by **different apps with different pipelines**:

| DC file | Owning app |
|---|---|
| `konk-operator-version.txt`, `konk-operator-values.yaml` | **konk-operator** |
| `bulk-values.yaml` (the whole `konk.custom.etcd` block) | **bulk** |

They arrived roughly three minutes apart:

| | After wave 1 (konk-operator) | After wave 2 (bulk) |
|---|---|---|
| operator image | `v0.2.1-162-gbeea16d-j33` ✅ | unchanged |
| etcd image | `cgr.dev/infoblox.com/etcd:3.7.1` ✅ | unchanged |
| `requests` | `200m` / `128Mi` ✅ | unchanged |
| tolerations / affinity | present ✅ | unchanged |
| PodMonitors | created ✅ | unchanged |
| STS `volumeClaimTemplate` | **still `data`** ❌ | `data-v2` ✅ |
| STS replicas | **still `1`** ❌ | `3` ✅ |
| STS `creationTimestamp` | **unchanged** ❌ | new ✅ |
| Etcd CR `persistence.claimName` | **absent** ❌ | `data-v2` ✅ |
| Etcd CR `recreateStatefulSet` | **absent** ❌ | `true` ✅ |
| Etcd CR `etcd.initialClusterState` | **absent** ❌ | `"new"` ✅ |
| PDB | **absent** (gated on replicas > 1) ❌ | present ✅ |

Wave 1 delivers the new **chart defaults** — they ship inside the operator image.
Wave 2 delivers the **DC overrides** that actually drive the migration.

> ⚠️ **During wave 1 etcd restarts onto 3.7.1 at the new mount path but still on
> the old `data` PVC, at `replicaCount: 1`.** The StatefulSet has *not* been
> recreated and `ETCD_INITIAL_CLUSTER_STATE` is not even emitted (it is gated on
> `replicaCount > 1`). This looks like a stalled or broken migration. It is not —
> **do not intervene.** Wave 2 does the real work.

How to tell wave 1 from a genuine failure:

```bash
# wave 1 in progress: operator is new, Etcd CR still lacks the migration keys
kubectl -n konk get pods -o jsonpath='{.items[*].spec.containers[0].image}{"\n"}'
kubectl -n aggregate get etcds.konk.infoblox.com bulk-konk-etcd \
  -o jsonpath='{.spec.persistence.claimName}{" "}{.spec.statefulset.replicaCount}{"\n"}'
  # wave 1 -> "<empty> 1"      wave 2 landed -> "data-v2 3"
```

If the Etcd CR still shows `<empty> 1` after ~10 minutes, the **bulk** app has not
reconciled — that is the thing to investigate, not etcd itself.

---

## Step 4 — During deployment: hook and StatefulSet recreate

### 4.1 What should happen

1. The pre-upgrade hook Job is created (gated on
   `recreateStatefulSet.enabled AND persistence.enabled`, `recreate-statefulset-hook.yaml:21`)
2. It compares the **live** `volumeClaimTemplate` name against `persistence.claimName`
   (`:23`). If they already match it is a **no-op** — the hook is idempotent
3. On mismatch it deletes the StatefulSet (orphaning pods/PVCs) so Helm can CREATE
   it with the new claim name — a `volumeClaimTemplate` name is immutable and cannot
   be patched
4. Helm creates the STS with `data-v2`; fresh PVCs are provisioned
5. Pods bootstrap with `ETCD_INITIAL_CLUSTER_STATE=new`

```bash
# hook Job
kubectl -n aggregate get jobs -l app.kubernetes.io/name=etcd
kubectl -n aggregate get jobs -A -o json \
  | jq -r '.items[]|select(.metadata.annotations["helm.sh/hook"])|"\(.metadata.namespace) \(.metadata.name) succeeded=\(.status.succeeded)"'

# hook logs
kubectl -n aggregate logs job/<hook-job-name>

# STS actually recreated?
kubectl -n aggregate get sts bulk-konk-etcd \
  -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}{"\n"}'
kubectl -n aggregate get sts bulk-konk-etcd \
  -o jsonpath='{.metadata.creationTimestamp}{"\n"}'   # should be recent

# watch it come up
kubectl -n aggregate get pods -w | grep etcd
```

`scripts/e2e-konk-test.sh --hook` runs a dedicated hook/init-container section
(section 0) covering `konk-service`, `konk` and `etcd` chart hooks, including
completed hook pods detected via events when the Job has already been reaped.

### 4.2 Failure modes to watch for

| Symptom | Cause | Fix |
|---|---|---|
| `Forbidden: updates to statefulset spec for fields other than 'replicas'...` | `claimName` changed but the hook did not run (or `recreateStatefulSet: false`) | `kubectl -n aggregate delete sts bulk-konk-etcd --cascade=orphan`, let Helm recreate |
| etcd pods CrashLoopBackOff on bootstrap | rendered `existing` — in-place upgrade, or `replicaCount: 1` swallowed the env var | Step 2; verify `ETCD_INITIAL_CLUSTER_STATE` on the pod |
| Helm revision loops / repeated failed revisions | stuck release from the immutable-VCT rejection | remove the stuck release, delete the Etcd CR so the operator reinstalls clean |
| Stale `ReleaseFailed` on the Etcd CR after a successful reinstall | condition not cleared | delete + recreate the Etcd CR |
| Hook Job never created | `persistence.enabled` false, or `recreateStatefulSet.enabled` false | check the rendered Etcd CR spec |
| Hook Job created but never completes | RBAC / SA missing, or kubectl image unpullable | `kubectl logs job/...`; check `recreateStatefulSet.image.*` for air-gapped registries |
| Mixed pod state — some old image, some new | partial rollout | check operator logs and the Etcd CR condition |
| etcd pods evicted repeatedly, EBS Multi-Attach errors on reschedule | Karpenter consolidation loop | see **[changes doc Part 3](etcd-3.4.14-to-3.7.1-migration-changes.md)** — verify CPU request is `200m`, the PDB exists, and the toleration/affinity landed |

Verify the env var actually landed:

```bash
kubectl -n aggregate get sts bulk-konk-etcd -o json \
  | jq -r '.spec.template.spec.containers[0].env[]|select(.name|startswith("ETCD_INITIAL"))|"\(.name)=\(.value)"'
```

---

## Step 5 — After deploying: post-upgrade checks

```bash
cd ~/Documents/Issues/konk/issues/etcd\ issues/tests
./post-upgrade.sh
```

Run it **after the DC PR merges and the etcd chart upgrade completes.** Every check
prints `[PASS]` or `[FAIL]`, the run ends with a summary box, and the script
**exits 1 if any check failed** — so it can gate a pipeline.

### 5.1 Configuration

All settings are environment variables with defaults; override inline rather than
editing the script.

| Variable | Default | Notes |
|---|---|---|
| `CTX` | current `kubectl` context | Script aborts if this resolves empty |
| `NS` | `aggregate` | etcd namespace |
| `STS` | `bulk-konk-etcd` | StatefulSet name |
| `OPERATOR_NS` | `konk` | Falls back to `vela-system` when the deploy isn't found |
| `TARGET_VCT` | `data-v2` | Expected `volumeClaimTemplate` after migration |
| `EXPECTED_REPLICAS` | `3` | Drives checks 5, 6, 11, 20, 27, 28 |
| `OPERATOR_VERSION_MIN` | `25` | Lower bound of the accepted `-jN` build number |
| `OPERATOR_VERSION_MAX` | `35` | Upper bound |
| `EXPECTED_ETCD_IMAGE` | `cgr.dev/infoblox.com/etcd` | Match on the **StatefulSet template** image (check 2) |
| `MIGRATION_PHASE` | `migration` | `migration` or `steady` — drives check 4. Script aborts on any other value |
| `ETCD_CERTS_DIR` | `/etc/etcd/certs/client` | **cgr.dev** cert layout |
| `EXPECTED_ETCD_IMAGE_MATCH` | `infoblox.com/etcd` | Match on the **running pod** image (check 30) — registry-agnostic, see 5.4 |
| `EXPECTED_ETCD_CPU_REQUEST` | `200m` | Karpenter fix (check 19) |
| `EXPECTED_ETCD_MEM_REQUEST` | `128Mi` | Karpenter fix (check 19) |
| `EXPECTED_KONK_SERVICE_CPU` | `100m` | Karpenter fix (check 22) |
| `EXPECTED_PDB_MIN_AVAILABLE` | `2` | check 20 |
| `DO_NOT_DISRUPT_TAINT` | `infoblox.com/do-not-disrupt` | check 21 |
| `STABLE_NODE_LABEL` / `STABLE_NODE_VALUE` | `node-group-type` / `stable` | check 21 |
| `MAX_EVICTIONS` | `2` | `Underutilized` eviction threshold (check 23) |
| `ETCD_METRICS_PORT` | `2381` | check 26 |
| `MAX_RAFT_INDEX_DELTA` | `1000` | raft convergence tolerance (check 28) |
| `MAX_APISERVER_RESTARTS` | `5` | check 33 |
| `DASH_CRD` | `grafanadashboards.integreatly.org` | check 18 — **must stay fully qualified**, see 5.4 |
| `DASH_OPERATOR_LABEL` / `DASH_FOLDER` | `appinfra-grafana` / `konk` | check 18 |

```bash
# single-member cluster (box-dev, eu-stg-1)
EXPECTED_REPLICAS=1 ./post-upgrade.sh

# validating a build outside the release/upgrade-etcd j-range
OPERATOR_VERSION_MIN=200 OPERATOR_VERSION_MAX=210 ./post-upgrade.sh

# explicit cluster
CTX=teleport.services.sdp.infoblox.com-us-dev-2 ./post-upgrade.sh

# after the steady-state flip PR (initialClusterState=existing, recreate=false)
MIGRATION_PHASE=steady ./post-upgrade.sh
```

### 5.2 The checks and what each asserts

**33 sections, 39 assertions** — some sections emit more than one.

| # | Check | PASS when |
|---|---|---|
| 1 | konk-operator version | `-jN` build number parsed from the image is within `[MIN, MAX]` |
| 2 | etcd container image | running image contains `EXPECTED_ETCD_IMAGE` |
| 3 | STS `volumeClaimTemplate` | equals `TARGET_VCT` (`data-v2`) → **the STS really was recreated** |
| 4 | `ETCD_INITIAL_CLUSTER_STATE` | value equals what `MIGRATION_PHASE` demands — `new` for `migration`, `existing` for `steady` |
| 4b | `recreateStatefulSet.enabled` | matches the same phase — `true` for `migration`, `false` for `steady` |
| 5 | PVC state | count of `data-v2-*` PVCs == `EXPECTED_REPLICAS`; old `data-*` listed as retained |
| 6 | STS replicas | `ready == total == EXPECTED_REPLICAS`; also prints STS `creationTimestamp` |
| 7 | KonK CR `bulk-konk` | `Deployed=True`, `ReleaseFailed` empty |
| 8 | Etcd CR | `Deployed=True`, `ReleaseFailed` empty |
| 9 | Helm release stability | last revision `status=deployed`; prints the last 3 revisions |
| 10 | etcd endpoint health | `etcdctl endpoint health` succeeds over TLS |
| 11 | etcd cluster members | member count == `EXPECTED_REPLICAS` |
| 12 | etcd data integrity | key count **> 0**; also prints `endpoint status` (DB size, version, raft) |
| 13 | etcd `/registry` readability | at least one `/registry` key returned |
| 14 | **Hook resource cleanup** | `kubectl get job,sa,role,rolebinding -n $NS \| grep -i recreate` returns nothing |
| 15 | bulk-konk apiserver | pod Running |
| 16 | KonkServices | count registered to `bulk-konk` > 0 |
| 17 | Recent warning events | informational only — prints the last 5 warnings, never fails |
| 18 | **Grafana dashboards** | `aggregate/bulk-konk-etcd`, `konk/konk-operator`, `konk/konk-operator-konk-services` exist on `integreatly.org/v1alpha1` with the `appinfra-grafana` operator label and folder `konk` |
| 19 | **etcd resource requests** | `cpu=200m`, `memory=128Mi` — explicitly names the pre-fix `10m`/`64Mi` if still present |
| 20 | **etcd PDB** | `minAvailable=2` and `disruptionsAllowed>=1`; asserts the PDB is **absent** when `EXPECTED_REPLICAS<=1` |
| 21 | **etcd scheduling** | `infoblox.com/do-not-disrupt` toleration + `node-group-type=stable` affinity, and that the affinity is **soft** not hard |
| 22 | **konk-service CPU** | every `*konk-service*` deployment requests `100m` |
| 23 | **Karpenter evictions** | count of `Evicted: Underutilized` events for etcd/konk within `MAX_EVICTIONS` |
| 24 | **PodMonitors** | `aggregate/bulk-konk-etcd` and `konk/konk-operator` both exist |
| 25 | **Scrape-path hygiene** | neither etcd nor konk-operator has a PodMonitor **and** `prometheus.io/scrape=true` (double-scrape) |
| 26 | **etcd metrics port** | `2381` exposed on the etcd container |
| 27 | **Per-member health** | execs into **each** pod and hits its own `localhost` — see 5.4 |
| 28 | **Leader + raft** | exactly one leader; `raftIndex` spread within `MAX_RAFT_INDEX_DELTA`; all members report the same etcd version |
| 29 | **etcd alarms** | `etcdctl alarm list` empty (no `NOSPACE` / `CORRUPT`) |
| 30 | **Image consistency** | all running pods share one image matching `EXPECTED_ETCD_IMAGE_MATCH`; catches partial rollout that check 2 cannot |
| 31 | **Old PVC retention** | at least one pre-migration `data-*` PVC survives — the rollback path |
| 32 | **Startup provenance** | informational — orphaned files on the volume, `member-initialized`, `cluster-id`, `commit-index`, bootstrap vs recover |
| 33 | **Apiserver readiness** | `bulk-konk` is `Ready` (not merely `Running`) with restarts within `MAX_APISERVER_RESTARTS` |

Check 3 is the direct answer to *"was the StatefulSet actually recreated?"*, and
check 14 to *"did the hook clean up after itself?"* — both are the questions Step 4
tells you to ask, asserted automatically here.

### 5.3 Defaults that will bite you

> ⚠️ **`EXPECTED_REPLICAS` defaults to `3`.** On any single-member cluster — every
> box-dev cluster inheriting the lifecycle default, plus eu-stg-1 ([changes doc Part 4.3](etcd-3.4.14-to-3.7.1-migration-changes.md)) —
> checks **5, 6 and 11 fail spuriously**. Run with `EXPECTED_REPLICAS=1`.

> ⚠️ **The operator version range defaults to `j25`–`j35`**, tuned for the
> `release/upgrade-etcd` builds (`j26`, `j31`, `j32`, `j33`). The prod baseline
> (`j170`) and the gov builds (`j203`) fall outside it and fail check 1. Override
> both bounds when validating anything else.

> ⚠️ **`ETCD_CERTS_DIR` is the cgr.dev layout** (`/etc/etcd/certs/client`). Bitnami
> kept client certs under `/opt/bitnami/etcd/certs/client`, so checks 10–13 cannot
> work against a pre-migration cluster. This script is **post-migration only** — use
> `pre-upgrade.sh` before the change.

> ℹ️ **Check 4 is phase-aware** (updated 2026-09-01). It no longer accepts both
> values blindly. Pass `MIGRATION_PHASE=steady` after the post-migration flip PR;
> the default `migration` expects `new` + `recreateStatefulSet: true`. It also
> cross-checks the two flags against each other, so a half-applied phase change is
> caught, and it explains an absent `ETCD_INITIAL_CLUSTER_STATE` in terms of the
> `replicaCount > 1` gate ([changes doc Part 1.5](etcd-3.4.14-to-3.7.1-migration-changes.md)) rather than just reporting it missing.

> ⚠️ **Check 12 only asserts "more than zero keys".** It is *not* a comparison
> against the pre-upgrade baseline. After a `data-v2` bootstrap the cluster starts
> empty and is repopulated by the owning controllers, so the count legitimately
> differs from the number recorded by `pre-upgrade.sh` §11 (Step 1). Compare the two
> manually and judge whether repopulation looks complete.

### 5.4 Two traps these checks exist to catch

> **Registry mirrors rewrite the pod image.** On us-dev-2 the StatefulSet template
> says `cgr.dev/infoblox.com/etcd:3.7.1` but the pods actually run
> `harbor.services.sdp.infoblox.com/cgr-proxy/infoblox.com/etcd:3.7.1`. Check 2
> reads the template and check 30 reads the pods, so check 30 matches on the repo
> path (`EXPECTED_ETCD_IMAGE_MATCH`) rather than the full ref, and reports the
> difference as INFO. Do not "fix" this by pinning the full mirrored ref.

> **The etcd server cert does not cover per-member FQDNs.** Its SANs are
> `bulk-konk-etcd-headless`, a (possibly stale) init-pod name, `localhost`, and a
> single pod IP. Running `etcdctl` from one pod against
> `bulk-konk-etcd-N.bulk-konk-etcd-headless...` fails TLS verification. That is why
> check 27 execs into every pod and queries its own `localhost` instead of
> addressing members remotely.

Companion notes live alongside the script: `tests/post-upgrade.md`, and
`tests/pre-etcd-upgrade-test-results.md` for a recorded run.

---

## Step 6 — E2E validation

Full stack validation after the deployment settles:

```bash
git show origin/etcd-upgrade-tests:scripts/e2e-konk-test.sh | bash
```

The script lives in the **konk** repo on branch `etcd-upgrade-tests` at
`scripts/e2e-konk-test.sh`. 19 sections:

| § | Covers |
|---|---|
| 1 | konk-operator pod health (`konk` ns) |
| 2 | Core infra: bulk-konk, etcd, init pods (`aggregate` ns) |
| 3 | Image version consistency (expected vs running) |
| 4 | Konk CR + Etcd CR status, `ReleaseFailed` detection |
| 5 | KonkService CR statuses (all namespaces) |
| 6 | konk-service pod health (all namespaces) |
| 7 | CA trust chain (bulk-konk CA vs kubeconfig secrets) |
| 8 | APIServices registered inside konk |
| 9 | Deep test: sample namespace (default `tagging-v2`) |
| 10 | Bulk (atlas.bulk) integration with konk |
| 11 | konk-operator log health |
| 12 | cert-manager CA integration |
| 13 | Konk API deep test (tagging, dnsconfig, …) |
| 14 | External API integration via CSP endpoint |
| 15 | Konk APIService backend health, all konk namespaces |
| 16–19 | Ghost detection: stale containers, stale KonkService deployments, excluded resources |

Useful invocations:

```bash
./e2e-konk-test.sh                    # full run
./e2e-konk-test.sh --hook             # section 0: Helm hook + init container status
./e2e-konk-test.sh --section 4        # Konk CR + Etcd CR only
./e2e-konk-test.sh --section 8-10     # range
./e2e-konk-test.sh --skip-exec        # read-only
./e2e-konk-test.sh --sample-ns atcapi
./e2e-konk-test.sh -v                 # verbose
./e2e-konk-test.sh -d                 # debug: show commands + full output
```

Env vars: `KONK_E2E_TOKEN` (bearer token for §14), `KONK_E2E_CSP_URL`.
Requires `kubectl`, `openssl`, `curl`, `jq` (optional).

---

## Step 7 — Raise the steady-state flip PR

**The migration is not complete until this merges.** Once all members are healthy
on `data-v2`, raise a second DC PR flipping the two migration-only flags:

```yaml
konk:
  custom:
    etcd:
      etcd:
        initialClusterState: "existing"   # was "new"
      recreateStatefulSet:
        enabled: false                    # was true
```

Why each matters:

| Flag | Left as-is | Risk |
|---|---|---|
| `initialClusterState: "new"` | any future pod recreate bootstraps a **fresh cluster** instead of rejoining | data loss |
| `recreateStatefulSet: true` | an STS-deleting pre-upgrade hook stays **armed** on every reconcile | unplanned STS deletion |

Precedent: [#143226](https://github.com/Infoblox-CTO/deployment-configurations/pull/143226)
did exactly this for us-dev-5 and us-stg-1.

Verify afterwards with the phase-aware run:

```bash
MIGRATION_PHASE=steady ./post-upgrade.sh
```

Check 4 then requires `initialClusterState=existing` **and**
`recreateStatefulSet.enabled=false`, and fails if only one of the two was flipped.

---

## Rollback

Rolling **back** across the migration is not symmetric with rolling forward: the
baseline chart hardcodes `volumeClaimTemplates[0].metadata.name: data`
(`statefulset.yaml:301` at `8b64bf7`), `persistence.claimName` does not exist, and
there is no recreate hook. A revert therefore hits the same immutable-VCT wall and
must be paired with a manual STS delete.

The old `data-*` PVCs are orphaned rather than deleted by the forward migration, so
they remain available to reattach.

See the cross-referenced rollback notes in Appendix B before attempting one.

---

---

## Quick reference

```bash
cd ~/Documents/Issues/konk/issues/etcd\ issues/tests

# Step 1 — baseline (13/13)
CTX=teleport.services.sdp.infoblox.com-<cluster> ./pre-upgrade.sh

# Step 2 — install-vs-upgrade gate
helm --kube-context <ctx> list -n aggregate | grep bulk-konk-etcd

# Step 5 — post-deploy (33 sections); add EXPECTED_REPLICAS=1 on single-member clusters
CTX=teleport.services.sdp.infoblox.com-<cluster> ./post-upgrade.sh

# Step 6 — end to end
git show origin/etcd-upgrade-tests:scripts/e2e-konk-test.sh | bash
git show origin/etcd-upgrade-tests:scripts/e2e-konk-test.sh | bash -s -- --hook

# Step 7 — after the flip PR
MIGRATION_PHASE=steady ./post-upgrade.sh
```

See [etcd-3.4.14-to-3.7.1-migration-changes.md](etcd-3.4.14-to-3.7.1-migration-changes.md) for what each change actually does.
