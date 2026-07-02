#!/usr/bin/env bash
# Compatible with bash and zsh.
[ -n "$ZSH_VERSION" ] && emulate bash
set -euo pipefail

# Wiz JSON parser — converts Wiz JSON scan output to parsed-vulns format.
# Produces the same tab-delimited output as parse-fix.sh parse mode so that
# version-selector.sh, risk-score.sh, and parse-fix.sh apply mode work unchanged.
#
# Accepts one or more Wiz JSON files; findings from all files are unioned and
# de-duplicated, so multiple scanned images can be remediated together.
#
# Usage:
#   ./wiz-json-parse.sh <wiz-json-file> [<wiz-json-file> ...] [options]
#
# Options:
#   --parsed FILE          Output file for parsed vulns  (default: parsed-vulns.txt)
#   --cve-map FILE         Output file for CVE map       (default: cve-map.txt)
#   --cve-version-map FILE Output file for CVE-per-version map (default: cve-version-map.txt)
#
# Output format (matches parse-fix.sh):
#   parsed-vulns.txt     — PACKAGE\tVERSION\tFIX_VERSION\tSEVERITY\tCVE_ID

PARSED_FILE="parsed-vulns.txt"
CVE_MAP_FILE="cve-map.txt"
CVE_VERSION_MAP_FILE="cve-version-map.txt"
INPUT_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parsed)          PARSED_FILE="${2:-}";          shift 2 ;;
    --cve-map)         CVE_MAP_FILE="${2:-}";          shift 2 ;;
    --cve-version-map) CVE_VERSION_MAP_FILE="${2:-}";  shift 2 ;;
    -h|--help)
      echo "Usage: $0 <wiz-json-file> [<wiz-json-file> ...] [options]"
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      INPUT_FILES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
  echo "Usage: $0 <wiz-json-file> [<wiz-json-file> ...] [options]" >&2
  exit 1
fi

for f in "${INPUT_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Input file not found: $f" >&2
    exit 1
  fi
done

: > "$PARSED_FILE"
: > "$CVE_MAP_FILE"
: > "$CVE_VERSION_MAP_FILE"

# ── parsed-vulns.txt ─────────────────────────────────────────────────────────
# Format: PACKAGE\tVERSION\tFIX_VERSION\tSEVERITY\tCVE_ID
# Extract findings from both Libraries and endOfLifeTechnologies arrays.

jq -r '
  [
    (
      .result.libraries[]?
      | select(.vulnerabilities != null and (.vulnerabilities | length) > 0)
      | .name as $pkg
      | .version as $ver
      | .vulnerabilities[]?
      | select(.severity != null and .severity != "")
      | {
          package: $pkg,
          version: ($ver | ltrimstr("v")),
          fixed: (if (.fixedVersion != null and .fixedVersion != "") then (.fixedVersion | ltrimstr("v")) else "NONE" end),
          severity: (.severity | ascii_upcase),
          cve: (.name // "UNKNOWN")
        }
    ),
    (
      .result.endOfLifeTechnologies[]?
      | select(.vulnerabilities != null and (.vulnerabilities | length) > 0)
      | .name as $pkg
      | .version as $ver
      | .vulnerabilities[]?
      | select(.severity != null and .severity != "")
      | {
          package: $pkg,
          version: ($ver | ltrimstr("v")),
          fixed: "NONE",
          severity: (.severity | ascii_upcase),
          cve: (.name // "EOL-TECHNOLOGY")
        }
    )
  ]
  | .[]
  | [.package, .version, .fixed, .severity, .cve]
  | @tsv
' "${INPUT_FILES[@]}" | sort -u > "$PARSED_FILE"

TOTAL=$(wc -l < "$PARSED_FILE" | tr -d ' ')
echo "Parsed $TOTAL vulnerability records from Wiz JSON into $PARSED_FILE"

if [[ "$TOTAL" -eq 0 ]]; then
  echo "No vulnerabilities found in ${INPUT_FILES[*]}"
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
