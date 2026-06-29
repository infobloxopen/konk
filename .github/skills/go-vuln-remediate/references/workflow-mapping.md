# Workflow Mapping: GitHub Action -> Skill (konk)

This document maps the konk CI workflow behavior to the skill-run procedure.

## Step Mapping

1. Resolve trigger and target branch
- Workflow:
  - Triggers on `schedule` and `workflow_dispatch`.
  - Resolves target branch from repository variable `vars.TARGET_BRANCH`, defaulting to `main`.
  - Runs remediation against the resolved target branch.
- Skill:
  - For local/manual runs, use the intended default branch (`main`) as remediation base.
  - For CI parity, treat target branch as workflow-owned configuration (repository variable), not service-config-owned.

2. Checkout and strict config loading
- Workflow:
  - Checks out the resolved target branch.
  - Loads `.github/skills/go-vuln-remediate/konk/service-config.env` with strict `KEY=VALUE` parsing (no shell `source`).
  - Exports defaults for build, scan, and risk-scoring variables.
  - Exposes artifact retention as `artifact_retention_days` output (`ARTIFACT_RETENTION_DAYS`, default `30`).
- Skill:
  - Load equivalent variables with strict parsing behavior.
  - Keep defaults aligned with workflow exports.

3. Private module and Go environment bootstrap
- Workflow:
  - Configures optional private Git auth via `GITPAT` URL rewrite.
  - Sets `GOPRIVATE` and `GONOSUMDB` when `GO_PRIVATE` is set.
  - Sets `GOPROXY=https://proxy.golang.org,direct`.
  - Uses `actions/setup-go@v5` with `go-version-file: cmd/konk-service/go.mod` (konk has no root `go.mod`).
- Skill:
  - Ensure equivalent auth/proxy setup before dependency or build steps.

4. Build scan images (no pre-build Go binary)
- Workflow:
  - Iterates each entry in `SCAN_TARGETS` (`name|dockerfile|build_path|image_tag|module_dir`).
  - For each entry: `docker build --progress=plain -f "$dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" $DOCKER_BUILD_EXTRA_ARGS -t "$image_tag:scan" .`
  - Each konk Dockerfile internally runs `go build` against its own module, so no separate pre-build is required.
- Skill:
  - Run the same docker build command per target with values from service config.

5. Wiz guard, auth, and scan
- Workflow:
  - Installs CLI from `https://downloads.wiz.io/v1/wizcli/${WIZ_CLI_VERSION}/wizcli-linux-amd64` (version defaults to `latest` from `service-config.env`).
  - Runs `wiz_guard`: if `WIZ_CLIENT_ID`/`WIZ_CLIENT_SECRET` are missing, skips auth+scan and reports reason in the step summary.
  - If ready, authenticates and runs scan with Critical+High policies and `--file-hashes-scan` for each target.
  - Writes results to `wiz-scan-results-<name>.json` and raw CLI output to `wiz-scan-raw-<name>.txt` (one pair per scan target).
- Skill:
  - Preserve guard behavior and reporting.
  - Produce and retain per-target `wiz-scan-results-*.json` as parser input, and retain `wiz-scan-raw-*.txt` for scan evidence.

6. Parse, recommend, score, and queue review
- Workflow:
  - Parses findings from all `wiz-scan-results-*.json` files together using [wiz-json-parse.sh](../scripts/wiz-json-parse.sh); findings are unioned across images.
  - Recommends compatible fix versions using [version-selector.sh](../scripts/version-selector.sh).
  - Scores risk using [risk-score.sh](../scripts/risk-score.sh) and writes `risk-decisions.jsonl`.
  - Builds `review-queue.md` from `review_required` and `skip_auto` decisions.
  - Builds `allowlist.txt` from `decision=="auto_apply"`.
- Skill:
  - Preserve the same file formats and decision flow before apply.

7. Apply fixes per module and detect dependency diffs
- Workflow:
  - For each `SCAN_TARGETS` entry, `cd "$module_dir"` and call [parse-fix.sh](../scripts/parse-fix.sh) with `--mode apply` using absolute paths to the shared `parsed-vulns.txt`, `version-recommendations.jsonl`, and `allowlist.txt`, writing a per-module summary `vuln-fix-summary-<name>.md`.
  - Concatenates per-module summaries into a single `vuln-fix-summary.md`, prefixing each section with the module name.
  - Detects changes across all module dirs' `go.mod` and `go.sum`.
- Skill:
  - Keep identical per-module apply and diff-detection behavior.

8. No-change reporting and build validation
- Workflow:
  - If no dependency changes: writes a workflow summary.
  - If dependency changes: rebuilds each affected module with `cd "$module_dir" && CGO_ENABLED=0 go build ...` using the same flags, then records pass/fail status overall.
- Skill:
  - Provide explicit no-change messaging and per-module rebuild validation parity.

9. Artifacts and PR automation
- Workflow:
  - Always uploads scan/decision artifacts and uses configurable retention days.
  - Creates PR body from build status, remediation summary, and optional review queue.
  - Cleans stale `auto-fix-vulns-daily` branch when no open PR exists.
  - Creates/updates PR via `peter-evans/create-pull-request@v7`.
  - Uses resolved target branch as PR base.
  - `add-paths` includes `cmd/konk-service/go.mod`, `cmd/konk-service/go.sum`, `cmd/provision/go.mod`, `cmd/provision/go.sum`. Vendor directories are **not** committed (konk modules do not vendor dependencies).
- Skill:
  - Preserve equivalent artifacts and PR-ready summary content for manual or automated PR creation.

## Behavior Preserved
- Handles CVE and EOL-TECHNOLOGY severities.
- Parses package records safely when package names contain spaces.
- Tracks CVEs per package and per package+fixed-version.
- Scores version safety before selecting a fix target.
- Uses risk gating to build an allowlist of `auto_apply` package/version pairs.
- Reports all candidate fixed versions and applies one allowlisted target.
- Skips large/risky jumps per apply-time guards.
- Marks stdlib findings for toolchain updates.
- Includes manual-remediation findings in summary output.
- Detects and annotates transitive dependency context for manual remediation.
- Restores `go.mod` and `go.sum` (in the per-module dir) when package download fails.
- Reverts dependency edits (`go.mod`, `go.sum`, `vendor/`) within a module when tidy/vendor fails for that module.
- Skips Wiz scan gracefully when credentials are unavailable.

## konk-specific notes
- No root `go.mod`: every Go command lives under `cmd/<name>/` with its own module. The workflow always operates on per-target module directories declared in `SCAN_TARGETS`.
- The konk operator image (root `Dockerfile`) is **not** included in `SCAN_TARGETS`. It builds operator-sdk's `helm-operator` from upstream source; CVEs require bumping the pinned operator-sdk tag.
- The konk-app image (`build/kubernetes/Dockerfile`) is also **not** included. It packages a patched kube-apiserver fork; CVEs require bumping `K8S_RELEASE` in the Makefile and refreshing patches in `build/kubernetes/patches/`.
