#!/usr/bin/env bash
# Compatible with bash and zsh.
[ -n "$ZSH_VERSION" ] && emulate bash
set -euo pipefail

# Grype fallback scanner — scans a container image and produces the same
# tab-delimited artifacts as parse-fix.sh parse mode so that the rest of the
# pipeline (version-selector.sh, risk-score.sh, parse-fix.sh apply mode) works
# unchanged.
#
# Usage:
#   ./grype-parse.sh <image> [options]
#
# Options:
#   --parsed FILE          Output file for parsed vulns  (default: parsed-vulns.txt)
#   --cve-map FILE         Output file for CVE map       (default: cve-map.txt)
#   --cve-version-map FILE Output file for CVE-per-version map (default: cve-version-map.txt)
#   --grype-output FILE    Raw Grype JSON output file    (default: grype-scan-output.json)
#   --severities LIST      Comma-separated severities to include for fixable findings (default: Critical,High,Medium,Low)
#                          Non-fixable findings are always included for manual remediation.
#
# Output format (matches parse-fix.sh):
#   parsed-vulns.txt     — PACKAGE\tVERSION\tFIX_VERSION\tSEVERITY\tCVE_ID
#   cve-map.txt          — PACKAGE\tCVE1, CVE2, ...
#   cve-version-map.txt  — PACKAGE@FIXVERSION\tCVE1, CVE2, ...

IMAGE="${1:-}"
if [[ -z "$IMAGE" ]]; then
  echo "Usage: $0 <image> [options]" >&2
  exit 1
fi
shift

PARSED_FILE="parsed-vulns.txt"
CVE_MAP_FILE="cve-map.txt"
CVE_VERSION_MAP_FILE="cve-version-map.txt"
GRYPE_JSON="grype-scan-output.json"
SEVERITIES="Critical,High,Medium,Low"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parsed)          PARSED_FILE="${2:-}";          shift 2 ;;
    --cve-map)         CVE_MAP_FILE="${2:-}";          shift 2 ;;
    --cve-version-map) CVE_VERSION_MAP_FILE="${2:-}";  shift 2 ;;
    --grype-output)    GRYPE_JSON="${2:-}";            shift 2 ;;
    --severities)      SEVERITIES="${2:-}";            shift 2 ;;
    -h|--help)
      echo "Usage: $0 <image> [options]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Build severity allowlist JSON (uppercased) for jq matching.
SEVERITY_JSON=$(printf '%s' "$SEVERITIES" | tr ',' '\n' | \
  awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)>0) print toupper($0)}' | \
  jq -R . | jq -s .)

echo "Running Grype scan on $IMAGE ..."

# Write scan output to a temp file first so failed scans do not clobber prior JSON.
TMP_GRYPE_JSON=$(mktemp)
if grype "$IMAGE" -o json --file "$TMP_GRYPE_JSON"; then
  mv "$TMP_GRYPE_JSON" "$GRYPE_JSON"
else
  rm -f "$TMP_GRYPE_JSON"
  exit 1
fi

if [[ ! -s "$GRYPE_JSON" ]]; then
  echo "Grype produced empty output for $IMAGE" >&2
  exit 1
fi

echo "Parsing Grype JSON output ..."

: > "$PARSED_FILE"
: > "$CVE_MAP_FILE"
: > "$CVE_VERSION_MAP_FILE"

# ── parsed-vulns.txt ─────────────────────────────────────────────────────────
# Format: PACKAGE\tVERSION\tFIX_VERSION\tSEVERITY\tCVE_ID
# Only go-module artifacts; strip leading 'v' from versions to match Wiz behaviour.
jq -r --argjson severities "$SEVERITY_JSON" '
  .matches[]
  | (.vulnerability.severity | ascii_upcase) as $sev
  | select(
      .artifact.type == "go-module"
      and (
        ($severities | index($sev)) != null
        or .vulnerability.fix.state != "fixed"
      )
    )
  | [
      .artifact.name,
      (.artifact.version | ltrimstr("v")),
      (if (.vulnerability.fix.state == "fixed" and (.vulnerability.fix.versions | length) > 0)
       then (.vulnerability.fix.versions[0] | ltrimstr("v"))
       else "NONE" end),
      $sev,
      .vulnerability.id
    ]
  | @tsv
' "$GRYPE_JSON" | sort -u >> "$PARSED_FILE"

TOTAL=$(wc -l < "$PARSED_FILE" | tr -d ' ')
echo "Parsed $TOTAL vulnerability records into $PARSED_FILE"

if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching vulnerabilities found."
  exit 0
fi

# ── cve-map.txt ───────────────────────────────────────────────────────────────
# Format: PACKAGE\tCVE1, CVE2, ...
awk -F'\t' '
  NF >= 5 && $1 != "" && $5 != "" && !seen[$1 SUBSEP $5]++ {
    if (list[$1] != "") list[$1] = list[$1] ", " $5
    else list[$1] = $5
  }
  END {
    for (pkg in list) print pkg "\t" list[pkg]
  }
' "$PARSED_FILE" | sort > "$CVE_MAP_FILE"

# ── cve-version-map.txt ───────────────────────────────────────────────────────
# Format: PACKAGE@FIXVERSION\tCVE1, CVE2, ...  (fixable entries only)
awk -F'\t' '
  NF >= 5 && $3 != "" && $3 != "NONE" {
    key = $1 "@" $3
    cve = $5
    if (key != "" && cve != "" && !seen[key SUBSEP cve]++) {
      if (list[key] != "") list[key] = list[key] ", " cve
      else list[key] = cve
    }
  }
  END {
    for (key in list) print key "\t" list[key]
  }
' "$PARSED_FILE" | sort > "$CVE_VERSION_MAP_FILE"

echo "CVE maps written: $CVE_MAP_FILE, $CVE_VERSION_MAP_FILE"
