#!/usr/bin/env bash
# Compatible with bash and zsh. When invoked via `zsh script.sh`, emulate bash
# to normalise array indexing, word splitting, and option behaviour.
[ -n "$ZSH_VERSION" ] && emulate bash
set -euo pipefail

# Usage:
#   ./parse-fix.sh [--mode full|parse|apply] [options]
# Options:
#   --mode MODE                  full (default), parse, or apply
#   --input FILE                 Wiz output file (default: wiz-scan-output.txt)
#   --parsed FILE                Parsed vulns output (default: parsed-vulns.txt)
#   --cve-map FILE               CVE map output (default: cve-map.txt)
#   --cve-version-map FILE       CVE-per-version output (default: cve-version-map.txt)
#   --allowlist FILE             Allowlist of package+version to apply (for apply mode)
#   --recommendations FILE       Recommendations (optional, for apply mode)
#   --summary FILE               Summary markdown output (default: vuln-fix-summary.md)

MODE="full"
WIZ_OUTPUT_FILE="wiz-scan-output.txt"
SUMMARY_FILE="vuln-fix-summary.md"
PARSED_FILE="parsed-vulns.txt"
CVE_MAP_FILE="cve-map.txt"
CVE_VERSION_MAP_FILE="cve-version-map.txt"
ALLOWLIST_FILE=""
RECOMMENDATIONS_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-full}"; shift 2 ;;
    --input) WIZ_OUTPUT_FILE="${2:-}"; shift 2 ;;
    --parsed) PARSED_FILE="${2:-}"; shift 2 ;;
    --cve-map) CVE_MAP_FILE="${2:-}"; shift 2 ;;
    --cve-version-map) CVE_VERSION_MAP_FILE="${2:-}"; shift 2 ;;
    --allowlist) ALLOWLIST_FILE="${2:-}"; shift 2 ;;
    --recommendations) RECOMMENDATIONS_FILE="${2:-}"; shift 2 ;;
    --summary) SUMMARY_FILE="${2:-}"; shift 2 ;;
    -h|--help) 
      echo "Usage: $0 [--mode MODE] [options]"
      exit 0
      ;;
    *)
      # Backward compatibility: first positional arg is wiz output file
      if [[ -z "$WIZ_OUTPUT_FILE" ]] || [[ "$WIZ_OUTPUT_FILE" == "wiz-scan-output.txt" ]]; then
        WIZ_OUTPUT_FILE="$1"
      fi
      shift
      ;;
  esac
done

[[ "$MODE" =~ ^(full|parse|apply)$ ]] || { echo "Invalid --mode: $MODE" >&2; exit 2; }

HAS_FIXES=false
GO_MOD_CHANGED=false
STDLIB_UPDATE_NEEDED=""
STDLIB_CURRENT_VERSION=""
STDLIB_FIXED_VERSION=""
UNAVAILABLE=""
MAJOR_JUMPS=""
FIXED_LIST=""

if [[ "$MODE" != "apply" ]] && [[ ! -f "$WIZ_OUTPUT_FILE" ]]; then
  echo "No Wiz scan results found: $WIZ_OUTPUT_FILE"
  exit 0
fi

# For parse/full modes, initialize and parse
if [[ "$MODE" =~ ^(parse|full)$ ]]; then
  : > "$PARSED_FILE"
fi

CURRENT_PKG=""
CURRENT_VER=""
CURRENT_SEV=""
CURRENT_FIX="NONE"
CURRENT_CVE=""

# ====== PARSE PHASE (for parse/full modes) ======
if [[ "$MODE" =~ ^(parse|full)$ ]]; then
  while IFS= read -r line; do
    if [[ "$line" == *"Name:"*"Version:"* ]]; then
      if [[ -n "$CURRENT_PKG" && -n "$CURRENT_SEV" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\n" "$CURRENT_PKG" "$CURRENT_VER" "$CURRENT_FIX" "$CURRENT_SEV" "$CURRENT_CVE" >> "$PARSED_FILE"
      fi
      CURRENT_PKG=$(echo "$line" | sed -n 's/.*Name: \([^,]*\), Version: \([^,]*\).*/\1/p')
      CURRENT_VER=$(echo "$line" | sed -n 's/.*Name: \([^,]*\), Version: \([^,]*\).*/\2/p' | sed 's/^v//')
      CURRENT_SEV=""
      CURRENT_FIX="NONE"
      CURRENT_CVE=""
    elif [[ "$line" == *"CVE-"*"Severity:"* ]]; then
      if [[ -n "$CURRENT_PKG" && -n "$CURRENT_SEV" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\n" "$CURRENT_PKG" "$CURRENT_VER" "$CURRENT_FIX" "$CURRENT_SEV" "$CURRENT_CVE" >> "$PARSED_FILE"
      fi
      CURRENT_CVE=$(echo "$line" | grep -oE 'CVE-[0-9]+-[0-9]+' | head -1)
      CURRENT_SEV=$(echo "$line" | sed -n 's/.*Severity: \([A-Z]*\).*/\1/p')
      CURRENT_FIX="NONE"
    elif [[ "$line" == *"EOL-TECHNOLOGY"*"Severity:"* ]]; then
      if [[ -n "$CURRENT_PKG" && -n "$CURRENT_SEV" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\n" "$CURRENT_PKG" "$CURRENT_VER" "$CURRENT_FIX" "$CURRENT_SEV" "$CURRENT_CVE" >> "$PARSED_FILE"
      fi
      CURRENT_CVE="EOL-TECHNOLOGY"
      CURRENT_SEV=$(echo "$line" | sed -n 's/.*Severity: \([A-Z]*\).*/\1/p')
      CURRENT_FIX="NONE"
    elif [[ "$line" == *"Fixed version:"* ]]; then
      CURRENT_FIX=$(echo "$line" | sed -n 's/.*Fixed version: *v*\([^ ]*\).*/\1/p')
    fi
  done < "$WIZ_OUTPUT_FILE"

  if [[ -n "$CURRENT_PKG" && -n "$CURRENT_SEV" ]]; then
    printf "%s\t%s\t%s\t%s\t%s\n" "$CURRENT_PKG" "$CURRENT_VER" "$CURRENT_FIX" "$CURRENT_SEV" "$CURRENT_CVE" >> "$PARSED_FILE"
  fi

  sort -u "$PARSED_FILE" -o "$PARSED_FILE"

  if [[ ! -s "$PARSED_FILE" ]]; then
    echo "No vulnerabilities parsed from $WIZ_OUTPUT_FILE"
    [[ "$MODE" == "parse" ]] && exit 0
  fi
fi

build_cve_maps_from_parsed() {
  : > "$CVE_MAP_FILE"
  : > "$CVE_VERSION_MAP_FILE"

  # Package -> CVE list
  awk -F'\t' '
    NF>=5 {
      pkg=$1
      cve=$5
      if (pkg!="" && cve!="" && !seen[pkg SUBSEP cve]++) {
        if (list[pkg] != "") list[pkg] = list[pkg] ", " cve
        else list[pkg] = cve
      }
    }
    END {
      for (pkg in list) {
        print pkg "\t" list[pkg]
      }
    }
  ' "$PARSED_FILE" | sort > "$CVE_MAP_FILE"

  # Package@fixed_version -> CVE list (fixable only)
  awk -F'\t' '
    NF>=5 && $3!="" && $3!="NONE" {
      key=$1 "@" $3
      cve=$5
      if (key!="" && cve!="" && !seen[key SUBSEP cve]++) {
        if (list[key] != "") list[key] = list[key] ", " cve
        else list[key] = cve
      }
    }
    END {
      for (key in list) {
        print key "\t" list[key]
      }
    }
  ' "$PARSED_FILE" | sort > "$CVE_VERSION_MAP_FILE"
}

# Parse mode should emit parsed output plus populated CVE map artifacts.
if [[ "$MODE" == "parse" ]]; then
  build_cve_maps_from_parsed
  echo "Parse mode complete. Outputs: ${PARSED_FILE}, ${CVE_MAP_FILE}, ${CVE_VERSION_MAP_FILE}"
  exit 0
fi

# For apply mode, parsed file must exist
if [[ "$MODE" == "apply" ]] && [[ ! -s "$PARSED_FILE" ]]; then
  echo "Apply mode requires existing parsed file: $PARSED_FILE" >&2
  exit 1
fi

# Pre-populate CVE maps from the full parsed file so all lookups see complete data.
build_cve_maps_from_parsed
SEEN_NO_FIX_KEYS=""
SEEN_APPLIED_KEYS=""
SEEN_SUMMARY_KEYS=""
# Read-only module introspection avoids go.sum churn when no fixes are applied.
CURRENT_MODULE=$(GOFLAGS='-mod=readonly' go list -m -f '{{.Path}}' 2>/dev/null || true)
ALL_MODULES_SORTED=""
DIRECT_MODULES=""

get_pkg_cves() {
  local pkg="$1"
  awk -F'\t' -v pkg="$pkg" '$1==pkg {print $2; found=1; exit} END {if (!found) print "N/A"}' "$CVE_MAP_FILE"
}

get_pkg_cves_for_version() {
  local pkg="$1"
  local fixed_ver="$2"
  local key="${pkg}@${fixed_ver}"
  awk -F'\t' -v key="$key" '$1==key {print $2; found=1; exit} END {if (!found) print "N/A"}' "$CVE_VERSION_MAP_FILE"
}

get_highest_fixed_version_for_pkg() {
  local pkg="$1"
  awk -F'\t' -v pkg="$pkg" '$1==pkg && $3!="NONE" && $3!="" {print $3}' "$PARSED_FILE" | sort -V | tail -1
}

version_lt() {
  local a="$1"
  local b="$2"
  [[ "$a" == "$b" ]] && return 1
  local first
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)
  [[ "$first" == "$a" ]]
}

# Check if a package+version pair is in the allowlist (for apply mode)
is_allowed() {
  local pkg="$1"
  local ver="$2"
  [[ -z "$ALLOWLIST_FILE" ]] && return 0
  [[ ! -f "$ALLOWLIST_FILE" ]] && return 1
  awk -F'\t' -v p="$pkg" -v v="$ver" '$1==p && $2==v {found=1} END{exit(found?0:1)}' "$ALLOWLIST_FILE"
}

# Get recommended version from recommendations file (for apply mode)
get_recommended_version() {
  local pkg="$1"
  local default_ver="$2"
  [[ -z "$RECOMMENDATIONS_FILE" ]] && echo "$default_ver" && return
  [[ ! -f "$RECOMMENDATIONS_FILE" ]] && echo "$default_ver" && return
  local rec
  rec=$(jq -rs -r --arg pkg "$pkg" '
    def parts(v):
      (v | tostring | ltrimstr("v") | split(".") | map(tonumber? // 0)) as $p
      | [($p[0] // 0), ($p[1] // 0), ($p[2] // 0)];
    [ .[]
      | select(.package==$pkg and .recommended_version != null and .recommended_version != "")
      | {version: .recommended_version, safety: (.safety_score // 0)}
    ]
    | if length == 0 then ""
      else
        (sort_by(.safety, (parts(.version)[0]), (parts(.version)[1]), (parts(.version)[2]), .version)
         | last
         | .version)
      end
  ' "$RECOMMENDATIONS_FILE" 2>/dev/null || true)
  [[ -n "$rec" ]] && echo "$rec" || echo "$default_ver"
}

get_max_severity_for_pkg_version() {
  local pkg="$1"
  local fixed_ver="$2"
  awk -F'\t' -v pkg="$pkg" -v fixed_ver="$fixed_ver" '
    function rank(sev) {
      if (sev=="CRITICAL") return 5
      if (sev=="HIGH") return 4
      if (sev=="MEDIUM") return 3
      if (sev=="LOW") return 2
      if (sev=="INFO") return 1
      return 0
    }
    $1==pkg && $3==fixed_ver {
      r=rank($4)
      if (r > maxr) {
        maxr=r
        maxsev=$4
      }
    }
    END {
      if (maxsev!="") print maxsev
      else print "UNKNOWN"
    }
  ' "$PARSED_FILE"
}

upsert_pkg_cve_for_version() {
  local pkg="$1"
  local fixed_ver="$2"
  local cve="$3"
  local key="${pkg}@${fixed_ver}"
  local existing
  existing=$(awk -F'\t' -v key="$key" '$1==key {print $2; exit}' "$CVE_VERSION_MAP_FILE")

  if [[ -z "$existing" ]]; then
    printf "%s\t%s\n" "$key" "$cve" >> "$CVE_VERSION_MAP_FILE"
    return
  fi

  if echo "$existing" | grep -qF "$cve"; then
    return
  fi

  awk -F'\t' -v OFS='\t' -v key="$key" -v cve="$cve" '
    $1==key { $2=$2 ", " cve }
    { print }
  ' "$CVE_VERSION_MAP_FILE" > "${CVE_VERSION_MAP_FILE}.tmp" && mv "${CVE_VERSION_MAP_FILE}.tmp" "$CVE_VERSION_MAP_FILE"
}

upsert_pkg_cve() {
  local pkg="$1"
  local cve="$2"
  local existing
  existing=$(awk -F'\t' -v pkg="$pkg" '$1==pkg {print $2; exit}' "$CVE_MAP_FILE")

  if [[ -z "$existing" ]]; then
    printf "%s\t%s\n" "$pkg" "$cve" >> "$CVE_MAP_FILE"
    return
  fi

  if echo "$existing" | grep -qF "$cve"; then
    return
  fi

  awk -F'\t' -v OFS='\t' -v pkg="$pkg" -v cve="$cve" '
    $1==pkg { $2=$2 ", " cve }
    { print }
  ' "$CVE_MAP_FILE" > "${CVE_MAP_FILE}.tmp" && mv "${CVE_MAP_FILE}.tmp" "$CVE_MAP_FILE"
}

build_module_cache() {
  [[ -n "$ALL_MODULES_SORTED" ]] && return

  if command -v go &>/dev/null; then
    ALL_MODULES_SORTED=$(GOFLAGS='-mod=readonly' go list -m all 2>/dev/null \
      | awk '{ print length($0) "\t" $0 }' \
      | sort -rn \
      | cut -f2- || true)
  fi

  if [[ -z "$ALL_MODULES_SORTED" ]] && [[ -f go.mod ]]; then
    ALL_MODULES_SORTED=$(awk '/^[[:space:]]+[[:alnum:]][^[:space:]]*/ { print $1 }' go.mod \
      | awk '{ print length($0) "\t" $0 }' \
      | sort -rn \
      | cut -f2- || true)
  fi
}

build_direct_module_cache() {
  [[ -n "$DIRECT_MODULES" ]] && return
  if ! command -v go &>/dev/null; then
    return
  fi

  DIRECT_MODULES=$(GOFLAGS='-mod=readonly' go list -m -f '{{.Path}} {{if .Indirect}}indirect{{else}}direct{{end}}' all 2>/dev/null \
    | awk '$2=="direct" { print $1 }' || true)

  if [[ -z "$DIRECT_MODULES" ]] && [[ -f go.mod ]]; then
    # Fallback: derive direct requirements from go.mod when go list fails.
    DIRECT_MODULES=$(awk '
      /^[[:space:]]*require[[:space:]]*\($/ { in_req=1; next }
      in_req && /^[[:space:]]*\)/ { in_req=0; next }
      in_req {
        if ($1 !~ /^\/\//) {
          line=$0
          if (line !~ /\/\/[[:space:]]*indirect/) print $1
        }
        next
      }
      /^[[:space:]]*require[[:space:]]+/ {
        if ($2 !~ /^\/\//) {
          line=$0
          if (line !~ /\/\/[[:space:]]*indirect/) print $2
        }
      }
    ' go.mod | sort -u || true)
  fi
}

resolve_module_for_path() {
  local pkg_path="$1"
  build_module_cache
  if [[ -z "$ALL_MODULES_SORTED" ]]; then
    echo "$pkg_path"
    return
  fi

  local mod=""
  mod=$(printf '%s\n' "$ALL_MODULES_SORTED" | awk -v p="$pkg_path" '
    p==$0 || index(p, $0"/")==1 { print; exit }
  ' || true)

  if [[ -n "$mod" ]]; then
    echo "$mod"
  else
    echo "$pkg_path"
  fi
}

is_direct_module_dep() {
  local mod="$1"
  [[ -z "$mod" ]] && return 1
  build_direct_module_cache
  [[ -z "$DIRECT_MODULES" ]] && return 1
  printf '%s\n' "$DIRECT_MODULES" | grep -Fxq "$mod"
}

escape_regex() {
  # Escape regex metacharacters so module paths are matched literally in go.mod.
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

# ====== APPLY PHASE (for apply/full modes) ======
if [[ "$MODE" =~ ^(apply|full)$ ]]; then

# Pre-compute go mod graph and go mod why results BEFORE any go.mod edits.
# This is critical: go mod edit (for fixable packages) can modify go.mod/go.sum,
# causing subsequent go mod why calls to fail with checksum mismatches.
_WHY_CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$_WHY_CACHE_DIR"' EXIT
_PRECOMPUTED_GRAPH_OUT=""
if command -v go &>/dev/null; then
  _PRECOMPUTED_GRAPH_OUT=$(GOFLAGS='-mod=readonly' go mod graph 2>/dev/null || true)
fi
while IFS=$'\t' read -r _PC_PKG _PC_VER _PC_FIX _PC_SEV _PC_CVE; do
  [[ -z "$_PC_PKG" ]] && continue
  [[ "$_PC_FIX" != "NONE" && -n "$_PC_FIX" ]] && continue
  _PC_MOD=$(resolve_module_for_path "$_PC_PKG")
  _PC_WHY_FILE="$_WHY_CACHE_DIR/$(printf '%s' "$_PC_PKG" | tr '/' '_' | tr '@' '_')"
  _PC_WHY=""
  if command -v go &>/dev/null; then
    _PC_WHY=$(GOFLAGS='-mod=readonly' go mod why "$_PC_PKG" 2>/dev/null || true)
    if [[ -z "$_PC_WHY" ]] || echo "$_PC_WHY" | grep -qi "main module does not need package"; then
      _PC_WHY=$(GOFLAGS='-mod=readonly' go mod why -m "$_PC_MOD" 2>/dev/null || true)
    fi
  fi
  printf '%s\n' "$_PC_WHY" > "$_PC_WHY_FILE"
done < "$PARSED_FILE"

while IFS=$'\t' read -r PACKAGE CURRENT_VERSION FIXED_VERSION SEVERITY CVE_ID; do

  [[ -z "$PACKAGE" ]] && continue

  # CVE maps are pre-populated from the full parsed file before this loop.

  if [[ "$FIXED_VERSION" == "NONE" || -z "$FIXED_VERSION" ]]; then
    if printf '%s\n' "$SEEN_NO_FIX_KEYS" | grep -Fxq "${PACKAGE}@NO_FIX"; then
      continue
    fi
    SEEN_NO_FIX_KEYS="${SEEN_NO_FIX_KEYS}"$'\n'"${PACKAGE}@NO_FIX"

    PKG_CVES=$(get_pkg_cves "$PACKAGE")
    NO_FIX_MSG=""
    DISPLAY_VERSION="$CURRENT_VERSION"
    if [[ -n "$DISPLAY_VERSION" && "$DISPLAY_VERSION" != v* ]]; then
      DISPLAY_VERSION="v${DISPLAY_VERSION}"
    fi
    PACKAGE_MODULE=$(resolve_module_for_path "$PACKAGE")
    # Transitive detection — three tiers, most reliable first:
    #  1. go.mod contains no direct require for module
    #  2. go.mod has "// indirect": annotation is authoritative, no go list needed
    #  3. go list -m all: fallback for edge cases (may be stale mid-run)
    PACKAGE_MODULE_REGEX=$(escape_regex "$PACKAGE_MODULE")
    DIRECT_REQUIRE_RE="(^[[:space:]]*${PACKAGE_MODULE_REGEX}[[:space:]]|^[[:space:]]*require[[:space:]]+${PACKAGE_MODULE_REGEX}[[:space:]])"
    INDIRECT_REQUIRE_RE="(^[[:space:]]*${PACKAGE_MODULE_REGEX}[[:space:]].*//[[:space:]]*indirect|^[[:space:]]*require[[:space:]]+${PACKAGE_MODULE_REGEX}[[:space:]].*//[[:space:]]*indirect)"
    IS_TRANSITIVE=false
    if [[ -f go.mod ]]; then
      if ! grep -Eq "$DIRECT_REQUIRE_RE" go.mod; then
        IS_TRANSITIVE=true
      elif grep -Eq "$INDIRECT_REQUIRE_RE" go.mod; then
        IS_TRANSITIVE=true
      elif ! is_direct_module_dep "$PACKAGE_MODULE"; then
        IS_TRANSITIVE=true
      fi
    fi
    if [[ "$IS_TRANSITIVE" == "true" ]]; then
      IMPORTING_REPOS=""
      # Use pre-computed graph/why results (collected before any go.mod edits).
      # Direct go mod graph/why calls here would fail after go mod edit modifies go.sum.
      if [[ -n "$_PRECOMPUTED_GRAPH_OUT" ]]; then
        IMPORTING_REPOS=$(printf '%s\n' "$_PRECOMPUTED_GRAPH_OUT" | awk -v mod="$PACKAGE_MODULE" -v current="$CURRENT_MODULE" '
          {
            split($1, p, "@")
            split($2, c, "@")
            parent_mod = p[1]
            child_mod = c[1]
            if (child_mod == mod && parent_mod != "" && parent_mod != current) {
              repos[parent_mod] = 1
            }
          }
          END {
            for (repo in repos) {
              print repo
            }
          }
        ' | sort -u || true)
      fi

      if [[ -z "$IMPORTING_REPOS" ]]; then
        # Read pre-computed go mod why output from cache file.
        _PC_WHY_FILE="$_WHY_CACHE_DIR/$(printf '%s' "$PACKAGE" | tr '/' '_' | tr '@' '_')"
        WHY_OUT=""
        [[ -f "$_PC_WHY_FILE" ]] && WHY_OUT=$(cat "$_PC_WHY_FILE")
        while IFS= read -r pkg_path; do
          [[ -z "$pkg_path" || "$pkg_path" =~ ^# ]] && continue
          [[ "$pkg_path" =~ ^\(main[[:space:]]+module[[:space:]]+does[[:space:]]+not[[:space:]]+need ]] && continue
          [[ "$pkg_path" == "$PACKAGE"* ]] && continue
          [[ "$pkg_path" == "$PACKAGE_MODULE"* ]] && continue
          [[ -n "$CURRENT_MODULE" && "$pkg_path" == "$CURRENT_MODULE"* ]] && continue
          IMPORTER=$(resolve_module_for_path "$pkg_path")
          [[ -z "$IMPORTER" ]] && continue
          [[ "$IMPORTER" == "$PACKAGE"* ]] && continue
          [[ -n "$CURRENT_MODULE" && "$IMPORTER" == "$CURRENT_MODULE"* ]] && continue
          IMPORTING_REPOS="${IMPORTING_REPOS}"$'\n'"${IMPORTER}"
        done <<< "$WHY_OUT"
        IMPORTING_REPOS=$(echo "$IMPORTING_REPOS" | sort -u | grep -v '^$' || true)
      fi
      if [[ -n "$IMPORTING_REPOS" ]]; then
        PARENT_LIST=""
        while IFS= read -r repo; do
          [[ -z "$repo" ]] && continue
          PARENT_LIST="${PARENT_LIST}\n  - ${repo}"
        done <<< "$IMPORTING_REPOS"
        NO_FIX_MSG="${PKG_CVES}\n${PACKAGE} ${DISPLAY_VERSION} [${SEVERITY}] - no fix version available, transitive dependency from:${PARENT_LIST}"
      else
        NO_FIX_MSG="${PKG_CVES}\n${PACKAGE} ${DISPLAY_VERSION} [${SEVERITY}] - no fix version available, transitive dependency"
      fi
    fi
    if [[ -z "$NO_FIX_MSG" ]]; then
      NO_FIX_MSG="${PKG_CVES}\n${PACKAGE} ${DISPLAY_VERSION} [${SEVERITY}] - no fix version available yet"
    fi
    UNAVAILABLE="${UNAVAILABLE}\n\n${NO_FIX_MSG}"
    continue
  fi

  if [[ "$PACKAGE" == "stdlib" ]]; then
    if [[ -z "$STDLIB_CURRENT_VERSION" ]]; then
      STDLIB_CURRENT_VERSION="$CURRENT_VERSION"
    fi
    if [[ -z "$STDLIB_FIXED_VERSION" ]] || version_lt "$STDLIB_FIXED_VERSION" "$FIXED_VERSION"; then
      STDLIB_FIXED_VERSION="$FIXED_VERSION"
      STDLIB_UPDATE_NEEDED="Go ${STDLIB_CURRENT_VERSION} -> ${STDLIB_FIXED_VERSION}"
    fi
    continue
  fi

  # Apply updates for any non-stdlib package reported by Wiz (e.g., gopkg.in/* too).
  if [[ -n "$PACKAGE" ]]; then
    REQUIRED_MIN_VERSION=$(get_highest_fixed_version_for_pkg "$PACKAGE")
    [[ -z "$REQUIRED_MIN_VERSION" ]] && continue
    HIGHEST_FIXED_VERSION="$REQUIRED_MIN_VERSION"

    # Resolve the recommended version first (risk-scorer picks this version, and the
    # allowlist is keyed on it — not on the raw highest CVE fix version).
    RECOMMENDED=$(get_recommended_version "$PACKAGE" "$REQUIRED_MIN_VERSION")
    if [[ -n "$RECOMMENDED" ]] && ! version_lt "$RECOMMENDED" "$REQUIRED_MIN_VERSION"; then
      HIGHEST_FIXED_VERSION="$RECOMMENDED"
    fi

    # Check if this package+version is allowed (for apply mode with allowlist)
    if ! is_allowed "$PACKAGE" "$HIGHEST_FIXED_VERSION"; then
      continue
    fi

      # Use the actual version being applied for accurate CVE/severity metadata
      APPLIED_VERSION="$HIGHEST_FIXED_VERSION"
      PKG_CVES=$(get_pkg_cves_for_version "$PACKAGE" "$APPLIED_VERSION")
      EFFECTIVE_SEVERITY=$(get_max_severity_for_pkg_version "$PACKAGE" "$APPLIED_VERSION")
      SUMMARY_KEY="${PACKAGE}@${APPLIED_VERSION}"

      # Show every suggested version in summary, but only apply the highest one.
      if [[ "$FIXED_VERSION" != "$APPLIED_VERSION" ]]; then
        REPORTED_KEY="${PACKAGE}@${FIXED_VERSION}"
        if ! printf '%s\n' "$SEEN_SUMMARY_KEYS" | grep -Fxq "$REPORTED_KEY"; then
          SEEN_SUMMARY_KEYS="${SEEN_SUMMARY_KEYS}"$'\n'"${REPORTED_KEY}"
          REPORTED_CVES=$(get_pkg_cves_for_version "$PACKAGE" "$FIXED_VERSION")
          REPORTED_SEV=$(get_max_severity_for_pkg_version "$PACKAGE" "$FIXED_VERSION")
          FIXED_LIST="${FIXED_LIST}\n${PACKAGE}\tv${CURRENT_VERSION}\tv${FIXED_VERSION} (reported only)\t${REPORTED_SEV}\t${REPORTED_CVES}"
        fi
        continue
      fi

      if printf '%s\n' "$SEEN_APPLIED_KEYS" | grep -Fxq "${PACKAGE}@${HIGHEST_FIXED_VERSION}"; then
        continue
      fi
      SEEN_APPLIED_KEYS="${SEEN_APPLIED_KEYS}"$'\n'"${PACKAGE}@${HIGHEST_FIXED_VERSION}"

      CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | grep -oE '^[0-9]+' | head -1)
      CURRENT_MINOR=$(echo "$CURRENT_VERSION" | grep -oE '^[0-9]+\.[0-9]+' | head -1 | cut -d. -f2)
      FIXED_MAJOR=$(echo "$HIGHEST_FIXED_VERSION" | grep -oE '^[0-9]+' | head -1)
      FIXED_MINOR=$(echo "$HIGHEST_FIXED_VERSION" | cut -d. -f2)
      if [[ -n "$CURRENT_MAJOR" && -n "$FIXED_MAJOR" && -n "$CURRENT_MINOR" && -n "$FIXED_MINOR" ]]; then
        MAJOR_JUMP=$((FIXED_MAJOR - CURRENT_MAJOR))
        MINOR_JUMP=$((FIXED_MINOR - CURRENT_MINOR))
        if [[ "$MAJOR_JUMP" -gt 0 || "$MINOR_JUMP" -gt 10 ]]; then
          if [[ "$MAJOR_JUMP" -gt 0 ]]; then
            JUMP_DESC="${MAJOR_JUMP} major versions"
          else
            JUMP_DESC="${MINOR_JUMP} minor versions"
          fi
          MAJOR_JUMPS="${MAJOR_JUMPS}\n\n${PKG_CVES}\n${PACKAGE}: v${CURRENT_VERSION} -> v${HIGHEST_FIXED_VERSION} (${JUMP_DESC})"
          continue
        fi
      fi

      if go mod edit -require "${PACKAGE}@v${HIGHEST_FIXED_VERSION}" 2>/dev/null; then
        if go mod download "${PACKAGE}@v${HIGHEST_FIXED_VERSION}" >/dev/null 2>&1; then
          GO_MOD_CHANGED=true
          if ! printf '%s\n' "$SEEN_SUMMARY_KEYS" | grep -Fxq "$SUMMARY_KEY"; then
            SEEN_SUMMARY_KEYS="${SEEN_SUMMARY_KEYS}"$'\n'"${SUMMARY_KEY}"
            FIXED_LIST="${FIXED_LIST}\n${PACKAGE}\tv${CURRENT_VERSION}\tv${HIGHEST_FIXED_VERSION} (applied)\t${EFFECTIVE_SEVERITY}\t${PKG_CVES}"
          fi
        else
          git checkout -- go.mod go.sum 2>/dev/null || true
          UNAVAILABLE="${UNAVAILABLE}\n- ${PACKAGE} v${HIGHEST_FIXED_VERSION} - download failed"
        fi
      else
        UNAVAILABLE="${UNAVAILABLE}\n- ${PACKAGE} v${HIGHEST_FIXED_VERSION} - could not update"
      fi
    fi
done < "$PARSED_FILE"

fi  # End of apply/full mode

# ====== FINALIZATION (for apply/full modes only) ======
if [[ "$MODE" =~ ^(apply|full)$ ]]; then

if [[ "$GO_MOD_CHANGED" == "true" ]]; then
  if go mod tidy >/dev/null 2>&1 && go mod vendor >/dev/null 2>&1; then
    HAS_FIXES=true
  else
    git checkout -- go.mod go.sum vendor/ 2>/dev/null || true
    GO_MOD_CHANGED=false
    HAS_FIXES=false
    # Prevent misleading summary output: updates were attempted but rolled back.
    FIXED_LIST=""
    UNAVAILABLE="${UNAVAILABLE}\n- go mod tidy/vendor failed, all dependency changes were reverted"
  fi
fi

{
  echo "## Vulnerability Fix Summary"
  echo ""

  if [[ -n "$FIXED_LIST" ]]; then
    echo "### Packages Updated"
    echo "Note: If multiple fixed versions are suggested for a package, all are shown for visibility, but only one selected version is applied: the recommended version when it meets the required minimum fix floor, otherwise the required minimum version."
    echo ""
    echo "| Package | From | To | Severity | CVEs |"
    echo "|---------|------|----|----------|------|"
    printf "%b\n" "${FIXED_LIST#\\n}" | awk -F'\t' 'NF>=5 { printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }'
    echo ""
  fi

  if [[ -n "$UNAVAILABLE" ]]; then
    echo "### Vulnerabilities Requiring Manual Remediation"
    printf "%b\n" "${UNAVAILABLE#\\n}"
    echo ""
  fi

  if [[ -n "$MAJOR_JUMPS" ]]; then
    echo "### Skipped Large Version Jumps"
    printf "%b\n" "${MAJOR_JUMPS#\\n}"
    echo ""
  fi

  if [[ -n "$STDLIB_UPDATE_NEEDED" ]]; then
    echo "### Go Stdlib Update Required"
    echo "- ${STDLIB_UPDATE_NEEDED}"
    echo "- Update builder/toolchain definition in your central build repo."
    echo ""
  fi
} > "$SUMMARY_FILE"

echo "Wrote ${PARSED_FILE} and ${SUMMARY_FILE}"

fi  # End of apply/full mode

# Parse mode exits earlier after writing map artifacts.

