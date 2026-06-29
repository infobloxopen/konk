#!/usr/bin/env bash
# Compatible with bash and zsh. When invoked via `zsh script.sh`, emulate bash
# to normalise array indexing, word splitting, and option behaviour.
[ -n "$ZSH_VERSION" ] && emulate bash
set -euo pipefail

# Risk scoring with exploit urgency (Jobs #3 + #4)
# Input: parsed-vulns.txt, version-recommendations.jsonl
# Output: risk-decisions.jsonl with decision (auto_apply|review_required|skip_auto)

INPUT="parsed-vulns.txt"
RECOMMENDATIONS="version-recommendations.jsonl"
OUTPUT="risk-decisions.jsonl"
MODE="heuristic"
AUTO_THR="0.50"
REVIEW_THR="0.70"
MIN_CONF="0.60"
CONFIDENCE="0.80"
EXPLOIT_WEIGHT="0.4"
VERSION_WEIGHT="0.3"
CYCLE_WEIGHT="0.3"
METRICS_FILE="${CI_METRICS_FILE:-ci-metrics.tsv}"
RECOMMENDATIONS_INDEX=""

usage() {
  cat <<'EOF'
Usage:
  risk-score.sh [options]
Options:
  --input <file>                  Parsed vulns (default: parsed-vulns.txt)
  --recommendations <file>        Version recommendations (default: version-recommendations.jsonl)
  --output <file>                 Output decisions (default: risk-decisions.jsonl)
  --mode <heuristic>              Scoring mode (default: heuristic)
  --auto-threshold <float>        Auto-apply threshold (default: 0.50)
  --review-threshold <float>      Review-required threshold (default: 0.70)
  --min-confidence <float>        Min confidence for decision (default: 0.60)
  --confidence <float>            Confidence score (default: 0.80)
  --exploit-weight <float>        Weight for exploit score (default: 0.4)
  --version-weight <float>        Weight for version safety (default: 0.3)
  --cycle-weight <float>          Weight for cycle time (default: 0.3)
  --metrics-file <file>           Historical CI metrics file (default: CI_METRICS_FILE or ci-metrics.tsv)
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT="${2:-}"; shift 2 ;;
    --recommendations) RECOMMENDATIONS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --auto-threshold) AUTO_THR="${2:-}"; shift 2 ;;
    --review-threshold) REVIEW_THR="${2:-}"; shift 2 ;;
    --min-confidence) MIN_CONF="${2:-}"; shift 2 ;;
    --confidence) CONFIDENCE="${2:-}"; shift 2 ;;
    --exploit-weight) EXPLOIT_WEIGHT="${2:-}"; shift 2 ;;
    --version-weight) VERSION_WEIGHT="${2:-}"; shift 2 ;;
    --cycle-weight) CYCLE_WEIGHT="${2:-}"; shift 2 ;;
    --metrics-file) METRICS_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$MODE" != "heuristic" ]]; then
  echo "Invalid --mode: $MODE (supported: heuristic)" >&2
  usage
  exit 2
fi

[[ -f "$INPUT" ]] || { echo "Missing input: $INPUT" >&2; exit 1; }
: > "$OUTPUT"

if [[ -f "$RECOMMENDATIONS" ]]; then
  RECOMMENDATIONS_INDEX=$(mktemp)
  trap '[[ -n "$RECOMMENDATIONS_INDEX" && -f "$RECOMMENDATIONS_INDEX" ]] && rm -f "$RECOMMENDATIONS_INDEX"' EXIT
  jq -r 'select(.package != null and .recommended_version != null) | [.package, .recommended_version, (.safety_score // 0.50)] | @tsv' \
    "$RECOMMENDATIONS" 2>/dev/null > "$RECOMMENDATIONS_INDEX" || true
fi

rank_sev() {
  case "$1" in
    CRITICAL) echo 5 ;;
    HIGH) echo 4 ;;
    MEDIUM) echo 3 ;;
    LOW) echo 2 ;;
    INFO) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Estimate cycle time from historical data or heuristic
estimate_cycle_time() {
  local pkg="$1"
  local cur_ver="$2"
  local fix_ver="$3"
  
  # Check if we have historical data in the configured metrics file.
  if [[ -f "$METRICS_FILE" ]]; then
    local hist
    hist=$(awk -F'\t' -v p="$pkg" '$1==p {print $4; exit}' "$METRICS_FILE" 2>/dev/null || true)
    # Validate: must be a positive integer/float; clamp to minimum 1 to prevent division by zero.
    if [[ -n "$hist" ]] && awk -v v="$hist" 'BEGIN{exit !(v+0 == v && v+0 > 0)}' 2>/dev/null; then
      awk -v v="$hist" 'BEGIN{printf "%s", (v < 1 ? 1 : v)}' && return
    fi
  fi
  
  # Fallback heuristic: major/minor bumps are slower than patch bumps.
  local cur_norm="${cur_ver#v}"
  local fix_norm="${fix_ver#v}"
  local cur_major=0 cur_minor=0 fix_major=0 fix_minor=0
  IFS='.' read -r cur_major cur_minor _ <<< "$cur_norm"
  IFS='.' read -r fix_major fix_minor _ <<< "$fix_norm"
  cur_major=${cur_major:-0}
  cur_minor=${cur_minor:-0}
  fix_major=${fix_major:-0}
  fix_minor=${fix_minor:-0}

  if [[ "$fix_major" != "$cur_major" || "$fix_minor" != "$cur_minor" ]]; then
    echo "7"
  else
    echo "1"
  fi
}

# Get version safety score from recommendations
get_version_safety() {
  local pkg="$1"
  local fix_ver="$2"

  [[ -n "$RECOMMENDATIONS_INDEX" && -s "$RECOMMENDATIONS_INDEX" ]] || { echo "0.50"; return; }

  local score
  score=$(awk -F'\t' -v p="$pkg" -v v="$fix_ver" '$1==p && $2==v {print $3; exit}' "$RECOMMENDATIONS_INDEX" 2>/dev/null || true)
  [[ -z "$score" ]] && score="0.50"
  echo "$score"
}

# Aggregate by package + fixed_version and score each
awk -F'\t' '
  $1!="" && $3!="" && $3!="NONE" {
    key=$1 "\t" $2 "\t" $3
    sev_rank=($4=="CRITICAL"?5:($4=="HIGH"?4:($4=="MEDIUM"?3:($4=="LOW"?2:($4=="INFO"?1:0)))))
    if (sev_rank > max_sev[key]) { 
      max_sev[key]=sev_rank
      max_sev_txt[key]=$4 
    }
    if ($5 != "") {
      cve_key=key SUBSEP $5
      if (!seen_cve[cve_key]++) {
        cve_count[key]++
      }
    }
  }
  END {
    for (k in max_sev) {
      split(k, a, "\t")
      pkg=a[1]; cur=a[2]; fix=a[3]
      c=(k in cve_count ? cve_count[k] : 0)
      print pkg "\t" cur "\t" fix "\t" max_sev_txt[k] "\t" c
    }
  }
' "$INPUT" | sort -u | while IFS=$'\t' read -r pkg cur fix sev cvecount; do
  
  # Exploit score (based on severity + exploitability)
  sev_rank=$(rank_sev "$sev")
  exploit_score=$(awk -v s="$sev_rank" 'BEGIN{printf "%.2f", s/5.0}')
  
  # Version safety score from recommendations
  version_safety=$(get_version_safety "$pkg" "$fix")
  
  # Cycle time and urgency
  cycle_time=$(estimate_cycle_time "$pkg" "$cur" "$fix")
  urgency_score=$(awk -v e="$exploit_score" -v c="$cycle_time" 'BEGIN{printf "%.2f", e/c}')
  
  # Combined risk score: weighted average
  # version_safety is a safety signal (high = safe), so invert it to a risk term.
  risk_score=$(awk \
    -v exploit="$exploit_score" \
    -v version="$version_safety" \
    -v urgency="$urgency_score" \
    -v ew="$EXPLOIT_WEIGHT" \
    -v vw="$VERSION_WEIGHT" \
    -v cw="$CYCLE_WEIGHT" \
    'BEGIN{
      combined=(exploit*ew + (1-version)*vw + urgency*cw)/(ew+vw+cw)
      if(combined<0) combined=0
      if(combined>1) combined=1
      printf "%.2f", combined
    }')
  
  confidence="$CONFIDENCE"
  decision="skip_auto"
  reasons=()
  
  # Decision logic and urgency evaluation in one awk call.
  decision_eval=$(awk -v s="$risk_score" -v a="$AUTO_THR" -v r="$REVIEW_THR" -v c="$confidence" -v m="$MIN_CONF" -v u="$urgency_score" '
    BEGIN {
      d="skip_auto"
      reason="risk_score>=review_threshold"
      if (s < a && c >= m) {
        d="auto_apply"
        reason="risk_score<auto_threshold"
      } else if (s < r) {
        d="review_required"
        reason="risk_score<review_threshold"
      }
      hu=(u>=0.50)?1:0
      printf "%s\t%s\t%d", d, reason, hu
    }
  ')
  IFS=$'\t' read -r decision primary_reason high_urgency_flag <<< "$decision_eval"
  reasons+=("$primary_reason")
  
  # Add context reasons
  [[ "$sev" == "CRITICAL" ]] && reasons+=("severity=CRITICAL")
  if [[ "$cvecount" -ge 3 ]]; then
    reasons+=("cve_count>=3")
    reasons+=("cve_count=${cvecount}")
  fi
  [[ "${high_urgency_flag:-0}" -eq 1 ]] && reasons+=("high_urgency")
  
  reasons_json=$(printf "%s\n" "${reasons[@]}" | awk 'NF{printf "\"%s\",",$0}' | sed 's/,$//')
  [[ -z "$reasons_json" ]] && reasons_json="\"baseline\""
  
  printf '{"package":"%s","current_version":"%s","fixed_version":"%s","severity_max":"%s","cve_count":%s,"exploit_score":%s,"version_safety":%s,"urgency_score":%s,"risk_score":%s,"confidence":%s,"cycle_time_days":%s,"decision":"%s","reasons":[%s]}\n' \
    "$pkg" "$cur" "$fix" "$sev" "${cvecount:-0}" "$exploit_score" "$version_safety" "$urgency_score" "$risk_score" "$confidence" "$cycle_time" "$decision" "$reasons_json" >> "$OUTPUT"
done

echo "Wrote $OUTPUT"
