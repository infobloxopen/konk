---
name: go-vuln-remediate
description: 'Run Wiz-based vulnerability scan and automatic Go module remediation for containerized Go services in the konk repository. Use when you need to build images, scan CVEs, patch vulnerable dependencies in go.mod/go.sum across konk-service and konk-provision modules, validate builds, and prepare a PR summary.'
argument-hint: 'Provide image targets (name|dockerfile|build_path|image_tag|module_dir), base image, and registry/auth constraints.'
user-invocable: true
---

# Go Wiz Auto Vulnerability Fix (konk)

## Purpose
This skill converts the GitHub Actions workflow behavior into an agent-driven runbook for local or CI-assisted execution.
It helps you:
- Build Go binaries and Docker images for scan.
- Run Wiz scanner against the built images.
- Parse Wiz output into structured findings.
- Recommend the safest compatible fix version for each package.
- Score exploit urgency versus fix risk and allowlist low-risk fixes.
- Apply only allowlisted dependency updates, per Go module.
- Rebuild to validate no regressions.
- Produce PR-ready markdown summaries for fixes, skipped items, and manual follow-ups.

## Repository Layout (multi-module)
konk has **no root `go.mod`**. Each scanned image is built from its own Go module:

| Target | Module dir | Dockerfile | Image tag |
|---|---|---|---|
| `konk-service` | `cmd/konk-service` | `Dockerfile.konk-service` | `konk-service` |
| `konk-provision` | `cmd/provision` | `Dockerfile.provision` | `konk-provision` |

Out of scope for auto-fix (must be remediated manually):
- The konk operator image (root `Dockerfile`) builds `operator-sdk` `helm-operator` from upstream source — CVEs require bumping the pinned `operator-sdk` tag in the Dockerfile.
- The konk-app image (`build/kubernetes/Dockerfile`) is a patched kube-apiserver fork — CVEs require bumping `K8S_RELEASE` in the Makefile.

## When to Use
Use this skill when one or more konk Go services have vulnerability findings and you want repeatable, semi-automated remediation with guardrails.

## Required Inputs
Collect these before execution:
- Service config values (all sourced from `.github/skills/go-vuln-remediate/konk/service-config.env`):
  - `IMAGE_NAME`, `DOCKERFILE_PATH`, `SERVER_BUILD_PATH` — defaults that describe the first target
  - `SCAN_TARGETS` — `;`-separated list of images to build and scan; each entry is `name|dockerfile|build_path|image_tag|module_dir`. konk scans two images (`konk-service`, `konk-provision`); findings from all images are merged before risk scoring, and the resulting allowlist is applied per-module.
  - `BUILD_TAGS`, `BUILD_LDFLAGS`, `DOCKER_BUILD_EXTRA_ARGS`
  - `BASE_IMAGE`
  - `GO_PRIVATE`
  - `MODE` — risk scoring mode (heuristic only)
  - `RISK_THRESHOLD_AUTO` — score below this can be auto-applied
  - `RISK_THRESHOLD_REVIEW` — score below this requires review instead of skip
  - `MIN_CONFIDENCE` — minimum confidence required for `auto_apply`
  - `EXPLOIT_WEIGHT` — weight for severity/exploit score
  - `VERSION_WEIGHT` — weight for version safety score
  - `CYCLE_WEIGHT` — weight for urgency / time-to-fix score
  - The bundled `konk/service-config.env` is a template with repo-specific defaults. Copy it locally or override values in your environment before running the skill outside CI.
- Credentials/tokens (if scanning private images or repos):
  - Wiz client id/secret (`WIZ_CLIENT_ID` / `WIZ_CLIENT_SECRET`)
  - Registry username/password (`HARBOR_SERVICES_PROD_USERNAME` / `HARBOR_SERVICES_PROD_PASSWORD`)
  - Git token with private module access (`GITPAT`)

Use [workflow mapping](./references/workflow-mapping.md) as the canonical behavior reference.

## Procedure
1. Ensure you are at the root of the repo. konk has no root `go.mod`; each module lives under `cmd/<target>/`.
2. Build Docker image(s) for scanning. Iterate every entry in `SCAN_TARGETS` and build each image as `<image_tag>:scan`:
   - `bash -lc 'set -euo pipefail; source .github/skills/go-vuln-remediate/konk/service-config.env; IFS=";" read -r -a TARGETS <<< "$SCAN_TARGETS"; for e in "${TARGETS[@]}"; do IFS="|" read -r n d b img m <<< "$e"; echo "Building $img:scan from $d"; docker build --progress=plain -f "$d" --build-arg BASE_IMAGE="$BASE_IMAGE" $DOCKER_BUILD_EXTRA_ARGS -t "$img:scan" .; done'`
   - Note: wrapping in `bash -lc` prevents zsh strict-mode/RPROMPT hook errors when `DOCKER_BUILD_EXTRA_ARGS` contains multiple `--build-arg` flags.
3. Select scanner and scan each target image — choose the first available path:
    - **Wiz (primary, workflow parity)** — if `WIZ_CLIENT_ID` and `WIZ_CLIENT_SECRET` are both set:
       - Install `wizcli` (workflow behavior): `curl -sL --fail -o wizcli "https://downloads.wiz.io/v1/wizcli/${WIZ_CLI_VERSION}/wizcli-linux-amd64" && chmod +x wizcli && sudo mv wizcli /usr/local/bin/wizcli`
     - Authenticate: `wizcli auth --id "$WIZ_CLIENT_ID" --secret "$WIZ_CLIENT_SECRET"`
     - Scan each target to a per-image JSON file `wiz-scan-results-<name>.json`: `wizcli docker scan -i "<image_tag>:scan" -p "PSE: Vulnerability - Critical - Audit/Warn - All Projects" -p "PSE: Vulnerability - High - Audit/Warn - All Projects" --json-output-file "wiz-scan-results-<name>.json" --file-hashes-scan`
       - Parse all JSON files together with [Wiz JSON parser](./scripts/wiz-json-parse.sh) (it accepts multiple inputs and unions findings): `.github/skills/go-vuln-remediate/scripts/wiz-json-parse.sh wiz-scan-results-*.json --parsed parsed-vulns.txt --cve-map cve-map.txt --cve-version-map cve-version-map.txt`.
    - **Grype (fallback)** — if Wiz credentials are absent or Wiz scan cannot run, and `command -v grype` succeeds:
       - Run [grype parser](./scripts/grype-parse.sh) per image and merge outputs.
   - **No scanner available** — if no valid scanner path above can run:
     - Print: `"No scanner available: wizcli is not installed or Wiz credentials are missing, and grype is not installed. Stopping."` and exit.
4. Recommend the safest compatible fix version for each package:
   - `bash .github/skills/go-vuln-remediate/scripts/version-selector.sh parsed-vulns.txt version-recommendations.jsonl`
5. Score exploit urgency versus time-to-fix and build the auto-apply allowlist:
   - `bash -lc 'set -euo pipefail; source .github/skills/go-vuln-remediate/konk/service-config.env; bash .github/skills/go-vuln-remediate/scripts/risk-score.sh --input parsed-vulns.txt --recommendations version-recommendations.jsonl --output risk-decisions.jsonl --mode "$MODE" --auto-threshold "$RISK_THRESHOLD_AUTO" --review-threshold "$RISK_THRESHOLD_REVIEW" --min-confidence "$MIN_CONFIDENCE" --confidence "$CONFIDENCE" --exploit-weight "$EXPLOIT_WEIGHT" --version-weight "$VERSION_WEIGHT" --cycle-weight "$CYCLE_WEIGHT"'`
   - `jq -r 'select(.decision=="auto_apply") | "\(.package)\t\(.fixed_version)"' risk-decisions.jsonl > allowlist.txt`
6. Apply only allowlisted fixes **per module**. The shared allowlist is replayed against every module that has the affected package as a direct or indirect requirement:
   - `WORK="$PWD"`
   - For each `SCAN_TARGETS` entry, capture `module_dir`, then run inside that directory with absolute artifact paths:
     - `cd "$module_dir" && "${WORK}/.github/skills/go-vuln-remediate/scripts/parse-fix.sh" --mode apply --parsed "${WORK}/parsed-vulns.txt" --recommendations "${WORK}/version-recommendations.jsonl" --allowlist "${WORK}/allowlist.txt" --summary "${WORK}/vuln-fix-summary-<name>.md"`
   - Concatenate per-module summaries into `vuln-fix-summary.md`, prefixing each section with a `### Module: <module_dir>` heading.
7. If fixes were applied, run build validation per module using the same flags:
   - `cd "$module_dir" && CGO_ENABLED=0 go build -v -tags "$BUILD_TAGS" -trimpath -ldflags "$BUILD_LDFLAGS" -o "${WORK}/bin/<name>" "$build_path"`
8. Generate final artifacts for review. If fixes were applied, commit the changed `go.mod` and `go.sum` files **in each affected module dir** on a new branch and open a PR:
   - `vuln-fix-summary.md`
   - `parsed-vulns.txt`
   - `cve-map.txt`
   - `cve-version-map.txt`
   - `version-recommendations.jsonl`
   - `risk-decisions.jsonl`
   - `allowlist.txt`
   - updated `cmd/konk-service/go.mod`, `cmd/konk-service/go.sum`, `cmd/provision/go.mod`, `cmd/provision/go.sum` when successful

   Note: konk modules do not commit `vendor/`. `parse-fix.sh` will run `go mod tidy && go mod vendor` locally as a validation step but only `go.mod` and `go.sum` are committed to the PR.

## Guardrails Included
- Skips dependency updates with large minor-version jumps (>10).
- Captures packages with no available fixed version (including EOL-TECHNOLOGY findings).
- Preserves full package names (including names with spaces) during parse and summary generation using tab-delimited records.
- Distinguishes stdlib findings from module findings.
- Reverts `go.mod` **and** `go.sum` if `go mod download` fails for a package.
- Reverts all dependency changes (in the current module dir) if `go mod tidy` or `go mod vendor` fails.
- Includes findings requiring manual remediation regardless of domain suffix pattern.
- Detects transitive dependencies via `go mod graph`; transitive packages requiring manual remediation report their importing repos.
- Tracks CVEs per package **and** per fixed version (`cve-map.txt`, `cve-version-map.txt`).
- When multiple fix versions are suggested for a package: all are shown in the summary for visibility, but only the recommended allowlisted target is actually applied.
- Uses risk scoring to separate `auto_apply`, `review_required`, and `skip_auto` candidates before any dependency change.
- Scanner selection: workflow parity installs `wizcli` at runtime when Wiz credentials are present, then scans/parses JSON output. Grype is used as fallback when Wiz cannot run and `grype` is installed; if neither path is available execution stops with an error message. All scanner paths produce identical `parsed-vulns.txt`/`cve-map.txt`/`cve-version-map.txt` output, and downstream recommendation/risk/apply steps are unchanged.
- Multi-module safety: the shared allowlist is applied independently inside each module's directory; modules that don't require an affected package are left untouched by `parse-fix.sh`'s direct/indirect detection.

## Output Contract
The skill writes:
- `vuln-fix-summary.md` — combined markdown summary, with per-module sections containing:
  - **Packages Updated** — pipe-delimited table (`| Package | From | To | Severity | CVEs |`); rows marked `(applied)` or `(reported only)` when multiple fix versions exist for a package
  - **Vulnerabilities Requiring Manual Remediation** — packages with no fix version; transitive ones include their importing repos
  - **Skipped Large Version Jumps** — packages skipped due to >10 minor-version delta
  - **Go Stdlib Update Required** — when `stdlib` findings are detected
- `parsed-vulns.txt` — tab-delimited raw records (`PACKAGE\tVERSION\tFIX_VERSION\tSEVERITY\tCVE_ID`)
- `cve-map.txt` — per-package CVE list (`PACKAGE\tCVE1, CVE2, ...`)
- `cve-version-map.txt` — per-package-per-fixed-version CVE list (`PACKAGE@VERSION\tCVE1, CVE2, ...`)
- `version-recommendations.jsonl` — version safety recommendations per package/version candidate
- `risk-decisions.jsonl` — risk scoring output with `auto_apply`, `review_required`, or `skip_auto`
- `allowlist.txt` — tab-delimited package/version pairs permitted for automatic apply

## Resources
- [parse and fix script](./scripts/parse-fix.sh)
- [version selector](./scripts/version-selector.sh)
- [risk scorer](./scripts/risk-score.sh)
- [grype parser](./scripts/grype-parse.sh)
- [wiz JSON parser](./scripts/wiz-json-parse.sh)
- [workflow mapping](./references/workflow-mapping.md)
- [service env template](./konk/service-config.env)
