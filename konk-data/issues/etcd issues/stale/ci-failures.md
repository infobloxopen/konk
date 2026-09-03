# PR #634 — CI Failures Analysis

**PR:** [infobloxopen/konk#634](https://github.com/infobloxopen/konk/pull/634) — `feat(etcd): declarative StatefulSet recreate hook for claimName/PVC migration`
**Branch:** `rsatal/etcd-recreate-sts-hook` → base `release/upgrade-etcd`
**Run:** `28023001459`
**Date:** 2026-06-23

## TL;DR

The only failing CI job is the **`End To End (true, v1.25.11, main)`** leg (the upgrade-from-main E2E test). All failures are **environmental/infra flakes, not caused by this PR**. The change is additive Helm-only (zero Go), and the new hook is gated `enabled: false`, so it does not even execute in the E2E run. Merging is safe — the base branch has no branch protection, so the red leg does not block the merge.

## What this PR changes

Only 2 files, both Helm chart YAML, **zero Go code**:

| File | Change |
|------|--------|
| `helm-charts/etcd/templates/recreate-statefulset-hook.yaml` | New pre-upgrade hook (gated `enabled: false`) |
| `helm-charts/etcd/values.yaml` | New `recreateStatefulSet` block, default disabled |

Because the hook is gated `{{- if and .Values.recreateStatefulSet.enabled .Values.persistence.enabled }}` with `enabled: false` by default, the template renders to nothing under default values — the E2E run never exercises it. The `lookup` call inside the block never runs.

## Failure history (run 28023001459)

| Attempt | Failed step | Root cause | Type |
|---------|-------------|-----------|------|
| 1 | etcd bootstrap | kind DNS race — `no such host` for `runner-konk-etcd-{0,1}…headless…` peers, CoreDNS `server misbehaving` (10.96.0.10:53) during the etcd pod rolling restart on upgrade | DNS race |
| 2 | `Install konk-operator` | 6-minute action timeout while still running `go mod tidy && go build` (downloading modules) | build timeout |
| 3 | `Install konk-operator` | Same — 6-minute timeout downloading Go modules | build timeout |

Two *different* failure modes across the attempts — the signature of flakiness, not a deterministic regression.

### Why the `Install konk-operator` step times out

The step builds the operator image (`go mod tidy && CGO_ENABLED=0 go build`) then helm-installs it, with a hard **6-minute** action timeout. Two infra factors:

1. **Cold/contended docker layer cache** — the 4 parallel E2E legs fight over the same `satackey/action-docker-layer-caching` key (`Unable to reserve cache … another job may be creating this cache`), so caching fails and each leg does a cold build.
2. **The upgrade leg builds the operator image twice** (once from `main`, once from the PR — visible as two `go: downloading …` passes in the log), doubling the module-download work. On a slow-network runner this exceeds 6 minutes.

Neither factor is related to this PR (which adds no Go and does not touch the operator build).

## Evidence it is not caused by the PR

- **Diff is purely additive, zero Go** — only the 2 Helm YAML files above.
- **Hook gated off by default** — default `helm install`/`upgrade` render is byte-identical to base apart from an empty template; the E2E test never enables the hook.
- **3 of 4 E2E legs pass** consistently: `(false, v1.25.11)`, `(false, v1.31.4)`, `(controller-v1.2.1, v1.25.11)`, plus `readme` and `helm lint`.
- **Known-flaky leg historically** — `End To End (true, v1.25.11, main)` failed **6 of 29** recent runs across unrelated branches (`smoke-tests` ×4, `add/sync-agents-workflow` ×1, etc.). ~20% baseline flake rate.

```
upgrade-leg (true, v1.25.11, main): PASS=23  FAIL=6  across last ~30 PR runs (all branches)
```

- **Control run** on the unrelated branch `feature/etcd-claim-name-param-main` (run `27943234504`) re-triggered today to confirm the same infra issue reproduces independently of this PR. _Result: pending (watcher running)._

## Merge safety

- Base branch `release/upgrade-etcd` has **no branch protection** (protection API → 404), so there are **no required status checks**. The red leg does not block merge.
- PR #634 status: `mergeable: MERGEABLE`, `mergeStateStatus: UNSTABLE` (= mergeable with a failing non-required check).
- **No admin override or test-skipping needed.** Do **not** edit the workflow to skip/delete the test — that affects every PR on the repo.

## Caveat (test coverage, not a regression)

CI never exercises the hook with `recreateStatefulSet.enabled: true`, so the hook's actual behavior has **no automated test**. It is covered by:
- Manual validation on us-dev-5 (manual STS delete = fresh `data-v2` cluster, rev 72→73 `deployed`, fail→rollback loop stopped, 3-member healthy etcd, 196 keys reconstructed).
- Code review.

Optional follow-up: add an E2E leg that sets `recreateStatefulSet.enabled: true` with a `claimName` change to get automated coverage of the migration path.

## Recommendation

**Merge.** It is safe (additive, gated-off, no branch protection, lint + 3 other E2E legs green, hook validated live on us-dev-5). Chasing a green upgrade leg is unproductive on a slow-runner/cold-cache day — retries keep trading one infra flake for another. If a clean green history is preferred, re-run until the runner network cooperates, but there is no functional risk to merging now.
