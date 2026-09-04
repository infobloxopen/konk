#!/usr/bin/env bash
#
# rollback-recreate-sts.sh — perform the one manual step an etcd rollback needs,
# automatically and at the only moment it is safe.
#
# WHY THIS EXISTS
#   A StatefulSet's volumeClaimTemplate name is immutable. Rolling back from the
#   release line (vct "data-v2") to the prod baseline chart (vct "data", hardcoded)
#   is therefore rejected by the API server, and the Helm operator loops
#   failed-upgrade / rollback forever. The forward path self-heals via the etcd
#   chart's pre-upgrade recreate hook (konk #634/#636) -- but a Helm pre-upgrade
#   hook ships in the INCOMING chart, and the rollback target predates the hook
#   (and predates persistence.claimName entirely). So on the way back, nothing in
#   the cluster can delete the StatefulSet. Something outside it must.
#
# WHY IT WAITS INSTEAD OF JUST DELETING
#   In DC, `bulk` depends on `konk-operator`, so the operator image flips FIRST
#   and the bulk values (replicaCount 3 -> 1, claimName removed) land SECOND.
#   In that gap the Etcd CR still says replicaCount 3 / claimName data-v2. Delete
#   the StatefulSet there and the operator recreates it as THREE bitnami pods on
#   data-{0,1,2} -- three volumes with unrelated etcd state, each recovering its
#   own cluster ID. This script refuses to act until the desired state has fully
#   settled, so the recreate happens exactly once, into the final shape.
#
# USAGE
#   ./rollback-recreate-sts.sh inspect      # read-only: what is on the old PVCs?
#   ./rollback-recreate-sts.sh baseline     # read-only: capture pre-rollback state
#   ./rollback-recreate-sts.sh preflight    # read-only: Helm ownership audit (run BEFORE merge)
#   ./rollback-recreate-sts.sh watch        # arm BEFORE merging the DC PR
#   ./rollback-recreate-sts.sh verify       # read-only: check the end state
#
# AFTER THE DELETE, etcd is DOWN until the operator recreates the StatefulSet.
# "Not recreated yet" has two causes that look identical: reconcile latency, and a
# release that is hard-blocked and never will succeed. The script watches the
# operator log for a sync error on this release and fails loudly with the message
# and a classification, instead of sitting out the RECREATE_TIMEOUT clock. On
# eu-stg-1 the Issue 4 block was fixed by hand with ~110s left on a 600s timer.
#
# TUNABLES (env)
#   TARGET_OP_TAG TARGET_REPLICAS TARGET_VCT TARGET_IMAGE_SUBSTR
#   NS OP_NS OP_DEPLOY STS ETCD_CR
#   TIMEOUT (gate wait)  RECREATE_TIMEOUT (post-delete wait)  POLL  BLOCK_GRACE
#   KONK_REPO TARGET_REF CHART_SUBDIR CHART_DIR   -- preflight chart source
#   DRY_RUN=true         gate + preflight, never delete
#   SKIP_PREFLIGHT=true  arm even with ownership blockers (not advised)
#
# PREFLIGHT exists because of Issue 4 (eu-stg-1, 2026-09-04). The rollback chart
# renders a scripts ConfigMap the release-line chart does not. The object was left
# on the cluster by the forward migration WITHOUT Helm ownership annotations, so
# Helm refused to adopt it and the release failed while computing the candidate
# release -- BEFORE it ever reached the StatefulSet. Signature is a FROZEN helm
# revision + Irreconcilable=True, not the climbing revisions + ReleaseFailed=True
# of the immutable-vct wall. It must be fixed before the StatefulSet is deleted,
# or the delete strands etcd with nothing able to recreate it.
#
#   DRY_RUN=true ./rollback-recreate-sts.sh watch   # gate + preflight, never delete
#
set -uo pipefail

NS=${NS:-aggregate}
OP_NS=${OP_NS:-konk}
OP_DEPLOY=${OP_DEPLOY:-konk-operator}
STS=${STS:-bulk-konk-etcd}
ETCD_CR=${ETCD_CR:-bulk-konk-etcd}

# --- rollback target: eu-stg-1 -> pre-migration baseline -----------------------
TARGET_OP_TAG=${TARGET_OP_TAG:-v0.2.1-138-g8b64bf7-j170}
TARGET_REPLICAS=${TARGET_REPLICAS:-1}
TARGET_VCT=${TARGET_VCT:-data}
TARGET_IMAGE_SUBSTR=${TARGET_IMAGE_SUBSTR:-bitnami/etcd:3.4.14}

TIMEOUT=${TIMEOUT:-2400}
POLL=${POLL:-10}
DRY_RUN=${DRY_RUN:-false}
KUBECTL=${KUBECTL:-kubectl}

# preflight: where to get the TARGET chart from
KONK_REPO=${KONK_REPO:-$HOME/Library/CloudStorage/OneDrive-InfobloxInc/Documents/repos/konk}
TARGET_REF=${TARGET_REF:-8b64bf7}
CHART_SUBDIR=${CHART_SUBDIR:-helm-charts/etcd}
CHART_DIR=${CHART_DIR:-}          # set to skip the git extraction entirely
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-false}
RECREATE_TIMEOUT=${RECREATE_TIMEOUT:-600}
BLOCK_GRACE=${BLOCK_GRACE:-40}   # wait one reconcile interval before trusting an error

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf '%s[%s]%s %s\n' "$BLD" "$(date -u +%H:%M:%S)" "$RST" "$*"; }
ok()   { printf '  %s+%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YLW" "$RST" "$*"; }
bad()  { printf '  %sx%s %s\n' "$RED" "$RST" "$*"; }
die()  { bad "$*"; exit 1; }

k() { $KUBECTL "$@"; }
jp() { k -n "$NS" get "$1" "$2" -o jsonpath="$3" 2>/dev/null; }

# ------------------------------------------------------------------ observations
op_image()      { k -n "$OP_NS" get pods -l app.kubernetes.io/name="$OP_DEPLOY" \
                    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null; }
cr_replicas()   { jp etcds.konk.infoblox.com "$ETCD_CR" '{.spec.statefulset.replicaCount}'; }
cr_claimname()  { jp etcds.konk.infoblox.com "$ETCD_CR" '{.spec.persistence.claimName}'; }
cr_image()      { jp etcds.konk.infoblox.com "$ETCD_CR" '{.spec.image.repository}'; }
sts_vct()       { jp sts "$STS" '{.spec.volumeClaimTemplates[0].metadata.name}'; }
sts_replicas()  { jp sts "$STS" '{.spec.replicas}'; }
sts_ready()     { jp sts "$STS" '{.status.readyReplicas}'; }
sts_image()     { jp sts "$STS" '{.spec.template.spec.containers[0].image}'; }
sts_retention() { jp sts "$STS" '{.spec.persistentVolumeClaimRetentionPolicy.whenDeleted}/{.spec.persistentVolumeClaimRetentionPolicy.whenScaled}'; }

# All operator pods must be on the target tag -- a Deployment mid-rollout still
# has an old ReplicaSet pod serving reconciles, and that pod would immediately
# recreate the StatefulSet we just deleted using the OLD chart.
operator_settled() {
  local imgs; imgs=$(op_image)
  [ -n "$imgs" ] || return 1
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    case "$i" in *"$TARGET_OP_TAG"*) ;; *) return 1;; esac
  done <<< "$imgs"
  return 0
}

# ------------------------------------------------------------------------ modes
mode_inspect() {
  say "Read-only inspection of the rollback-target PVCs"
  echo
  echo "  The rollback chart mounts the claim at /bitnami/etcd and sets"
  echo "  ETCD_DATA_DIR=/bitnami/etcd/data, so it reads <root>/data/member."
  echo "  The release-line chart mounts at /var/lib/etcd and reads <root>/member."
  echo
  echo "  Layout            Written by       Target chart sees        Action"
  echo "  <root>/data/...   rollback chart   recovers that cluster    reuse IF membership == replicaCount"
  echo "  <root>/member/... release chart    nothing -> bootstrap     reuse (clean start, data discarded)"
  echo "  empty/lost+found  fresh            nothing -> bootstrap     reuse"
  echo
  local n=0
  for pvc in $(k -n "$NS" get pvc -o name 2>/dev/null | grep -oE "${TARGET_VCT}-${STS}-[0-9]+$"); do
    n=$((n+1)); local pod="pvc-inspect-${RANDOM}"
    say "inspecting $pvc"
    k -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    app.kubernetes.io/component: pvc-inspect
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    runAsGroup: 1001
  containers:
  - name: x
    image: busybox:1.36
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo '# root'; ls -la /mnt
      echo '# data/ (what the rollback chart reads)'; ls -la /mnt/data/member 2>&1
      echo '# data/member/snap (newest 4)'; ls -lat /mnt/data/member/snap 2>&1 | head -5
      echo '# member/ (release-line leftovers, ignored by target)'; ls -la /mnt/member 2>&1 | head -4
      echo '# sizes'; du -sh /mnt/data /mnt/member 2>&1
    volumeMounts:
    - name: v
      mountPath: /mnt
      readOnly: true
  volumes:
  - name: v
    persistentVolumeClaim:
      claimName: $pvc
      readOnly: true
YAML
    k -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$pod" --timeout=180s >/dev/null 2>&1 \
      || warn "pod did not reach Succeeded; output may be partial"
    k -n "$NS" logs "$pod" 2>&1 | sed 's/^/    /'
    k -n "$NS" delete pod "$pod" --wait=false >/dev/null 2>&1
    echo
  done
  [ "$n" -gt 0 ] || warn "no ${TARGET_VCT}-${STS}-* PVCs found -- target chart will bootstrap clean"
  echo
  warn "Only ${TARGET_VCT}-${STS}-0 .. -$((TARGET_REPLICAS-1)) get mounted at replicaCount=$TARGET_REPLICAS."
  warn "Higher-ordinal PVCs are inert now but WILL be recovered if anyone scales up later."
}

mode_baseline() {
  say "Pre-rollback baseline (read-only)"
  printf '  %-22s %s\n' "operator image"  "$(op_image | tr '\n' ' ')"
  printf '  %-22s %s\n' "Etcd CR replicas" "$(cr_replicas)"
  printf '  %-22s %s\n' "Etcd CR claimName" "$(cr_claimname)"
  printf '  %-22s %s\n' "Etcd CR image"    "$(cr_image)"
  printf '  %-22s %s\n' "STS vct"          "$(sts_vct)"
  printf '  %-22s %s\n' "STS replicas"     "$(sts_replicas)/$(sts_ready) ready"
  printf '  %-22s %s\n' "STS image"        "$(sts_image)"
  printf '  %-22s %s\n' "PVC retention"    "$(sts_retention)"
  printf '  %-22s %s\n' "KonkServices"     "$(k get konkservices -A --no-headers 2>/dev/null | grep -c .)"
  echo "  Etcd CR conditions:"
  k -n "$NS" get etcds.konk.infoblox.com "$ETCD_CR" \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.reason}{"\n"}{end}' 2>/dev/null
  echo "  PVCs:"
  k -n "$NS" get pvc --no-headers 2>/dev/null | grep -E "^(data|${TARGET_VCT})" | sed 's/^/    /'
  echo "  Helm history (tail):"
  helm -n "$NS" history "$STS" 2>/dev/null | tail -4 | sed 's/^/    /'
}

# ---------------------------------------------------------------- ownership audit
# Render the chart the operator is ABOUT to run, using the live Etcd CR's own
# values, and audit every object it wants. Anything that already exists must carry
# Helm ownership metadata or Helm will refuse to adopt it.
mode_preflight() {
  say "Helm ownership audit of the target chart rendered objects"

  local chart="$CHART_DIR" tmp=""
  if [ -z "$chart" ]; then
    [ -d "$KONK_REPO/.git" ] || { bad "KONK_REPO is not a git repo: $KONK_REPO"; return 2; }
    tmp=$(mktemp -d) || return 2
    if ! git -C "$KONK_REPO" archive "$TARGET_REF" "$CHART_SUBDIR" 2>/dev/null | tar -x -C "$tmp"; then
      bad "could not extract $CHART_SUBDIR at ref $TARGET_REF from $KONK_REPO"
      rm -rf "$tmp"; return 2
    fi
    chart="$tmp/$CHART_SUBDIR"
  fi
  [ -f "$chart/Chart.yaml" ] || { bad "no Chart.yaml under $chart"; [ -n "$tmp" ] && rm -rf "$tmp"; return 2; }
  local cname cver csrc
  cname=$(sed -n 's/^name: *//p' "$chart/Chart.yaml" | head -1)
  cver=$(sed -n 's/^version: *//p' "$chart/Chart.yaml" | head -1)
  if [ -n "$CHART_DIR" ]; then csrc="dir $CHART_DIR"; else csrc="ref $TARGET_REF"; fi
  ok "chart: ${cname}-${cver} ($csrc)"

  # The live Etcd CR spec IS the values file the operator will use.
  local vals; vals=$(mktemp)
  k -n "$NS" get etcds.konk.infoblox.com "$ETCD_CR" -o yaml 2>/dev/null \
    | awk '/^spec:/{f=1;next} /^status:/{f=0} f' | sed 's/^  //' > "$vals"
  if ! [ -s "$vals" ]; then
    bad "could not read Etcd CR $ETCD_CR spec in $NS"
    rm -f "$vals"; [ -n "$tmp" ] && rm -rf "$tmp"; return 2
  fi
  ok "values: live Etcd CR spec ($(grep -c . "$vals") lines)"

  local rendered; rendered=$(mktemp)
  if ! helm template "$ETCD_CR" "$chart" -n "$NS" -f "$vals" > "$rendered" 2>"$rendered.err"; then
    bad "helm template failed:"; sed 's/^/      /' "$rendered.err" | head -8
    rm -f "$vals" "$rendered" "$rendered.err"; [ -n "$tmp" ] && rm -rf "$tmp"; return 2
  fi

  # Parse kind/name per document without a yaml module.
  local objs; objs=$(python3 - "$rendered" <<'PYEOF'
import re, sys
docs = re.split(r'(?m)^---\s*$', open(sys.argv[1]).read())
for d in docs:
    if not d.strip(): continue
    k = re.search(r'(?m)^kind:\s*(\S+)', d)
    n = re.search(r'(?ms)^metadata:\s*\n(?:[ \t]+\S.*\n|[ \t]*\n)*?[ \t]+name:\s*(\S+)', d)
    if k and n:
        print(k.group(1), re.sub(r'^[\x22\x27]|[\x22\x27]$', '', n.group(1)))
PYEOF
)
  rm -f "$vals" "$rendered" "$rendered.err"; [ -n "$tmp" ] && rm -rf "$tmp"

  [ -n "$objs" ] || { bad "chart rendered no objects -- check the values"; return 2; }
  echo

  local rc=0 n=0
  while read -r kind name; do
    [ -n "$kind" ] || continue
    n=$((n+1))
    # StatefulSet PVCs are created by the statefulset controller and are never part
    # of a Helm manifest. They always look unannotated. Never "fix" them.
    if [ "$kind" = "PersistentVolumeClaim" ]; then
      warn "$(printf '%-22s %-34s' "$kind" "$name") skipped (controller-created, never Helm-owned)"
      continue
    fi
    if ! k -n "$NS" get "$kind" "$name" >/dev/null 2>&1; then
      ok "$(printf '%-22s %-34s' "$kind" "$name") absent -> Helm CREATEs it, no adoption needed"
      continue
    fi
    local rn rns mb
    rn=$(k -n "$NS" get "$kind" "$name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
    rns=$(k -n "$NS" get "$kind" "$name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)
    mb=$(k -n "$NS" get "$kind" "$name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)
    if [ "$rn" = "$ETCD_CR" ] && [ "$rns" = "$NS" ] && [ "$mb" = "Helm" ]; then
      ok "$(printf '%-22s %-34s' "$kind" "$name") ownership OK"
    else
      bad "$(printf '%-22s %-34s' "$kind" "$name") BLOCKER"
      printf '      have: managed-by=%s release-name=%s release-namespace=%s\n' \
        "${mb:-<none>}" "${rn:-<none>}" "${rns:-<none>}"
      printf '      want: managed-by=Helm release-name=%s release-namespace=%s\n' "$ETCD_CR" "$NS"
      echo "      fix:"
      [ "$mb" = "Helm" ] || echo "        $KUBECTL -n $NS label $kind $name app.kubernetes.io/managed-by=Helm --overwrite"
      echo "        $KUBECTL -n $NS annotate $kind $name \\"
      echo "          meta.helm.sh/release-name=$ETCD_CR \\"
      echo "          meta.helm.sh/release-namespace=$NS --overwrite"
      rc=1
    fi
  done <<< "$objs"

  echo
  if [ "$rc" = 0 ]; then
    ok "$n object(s) audited -- no ownership blockers"
  else
    bad "ownership blockers present. Helm will fail computing the candidate release,"
    bad "BEFORE it touches the StatefulSet: frozen helm revision + Irreconcilable=True."
    bad "Fix these BEFORE merging. Do NOT use fix-konk-annotations.sh --sweep:"
    bad "  it stamps release-name=bulk-konk (wrong release here) and would mark the"
    bad "  data-*/data-v2-* PVCs Helm-owned, inviting a later upgrade to prune them."
  fi
  return $rc
}

mode_watch() {
  if [ "$SKIP_PREFLIGHT" != true ]; then
    mode_preflight; local pfrc=$?
    echo
    if [ "$pfrc" != 0 ]; then
      die "refusing to arm: fix the ownership blockers first, or SKIP_PREFLIGHT=true to override"
    fi
  fi
  say "Armed. Gating the StatefulSet recreate on the rollback fully settling."
  echo "  want: operator=$TARGET_OP_TAG  Etcd CR replicas=$TARGET_REPLICAS  claimName=<unset>  live vct != $TARGET_VCT"
  [ "$DRY_RUN" = true ] && warn "DRY_RUN=true -- will gate and preflight, but never delete"
  echo

  local start; start=$(date +%s) last=""
  while :; do
    (( $(date +%s) - start > TIMEOUT )) && die "timed out after ${TIMEOUT}s without all gates satisfied"

    local vct rep claim g1 g2 g3
    vct=$(sts_vct); rep=$(cr_replicas); claim=$(cr_claimname)
    operator_settled && g1=y || g1=n
    [ "$rep" = "$TARGET_REPLICAS" ] && g2=y || g2=n
    [ -z "$claim" ] || [ "$claim" = "$TARGET_VCT" ] && g3=y || g3=n

    local line="op=$g1 replicas=$rep($g2) claimName='${claim:-<unset>}'($g3) live_vct=${vct:-<none>}"
    [ "$line" != "$last" ] && { say "$line"; last="$line"; }

    if [ -z "$vct" ]; then
      warn "no StatefulSet present -- operator will CREATE it (no immutable wall). Nothing to do."
      break
    fi
    if [ "$vct" = "$TARGET_VCT" ]; then
      ok "live vct is already '$TARGET_VCT' -- no delete needed"
      break
    fi
    if [ "$g1$g2$g3" = "yyy" ]; then
      say "all gates satisfied"
      preflight || die "preflight failed -- refusing to delete the StatefulSet"
      if [ "$DRY_RUN" = true ]; then
        warn "DRY_RUN: would now run: kubectl -n $NS delete sts $STS --wait=true"
        break
      fi
      say "deleting StatefulSet $STS (plain delete -- NOT --cascade=orphan)"
      k -n "$NS" delete sts "$STS" --wait=true || die "delete failed"
      ok "deleted; waiting for the operator to recreate it (etcd is DOWN from here)"
      if ! wait_recreate; then
        echo
        die "recreate did not complete -- see above. etcd is still DOWN."
      fi
      break
    fi
    sleep "$POLL"
  done
  echo; mode_verify
}

# Deleting a StatefulSet is reversible; destroying its volumes is not. Refuse
# unless the volumes are provably safe from the delete.
preflight() {
  local rc=0 ret; ret=$(sts_retention)
  if [ "$ret" = "Retain/Retain" ]; then ok "PVC retention policy $ret"
  else bad "PVC retention policy is '$ret', expected Retain/Retain"; rc=1; fi

  local owned; owned=$(k -n "$NS" get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences}{"\n"}{end}' 2>/dev/null \
    | awk 'NF>1' | grep -E "^(data|${TARGET_VCT})" || true)
  if [ -z "$owned" ]; then ok "no PVC carries ownerReferences (none garbage-collected)"
  else bad "PVCs with ownerReferences: $owned"; rc=1; fi

  local i target
  for i in $(seq 0 $((TARGET_REPLICAS-1))); do
    target="${TARGET_VCT}-${STS}-${i}"
    local phase; phase=$(jp pvc "$target" '{.status.phase}')
    if [ "$phase" = Bound ]; then ok "$target Bound (will be recovered, not recreated)"
    elif [ -z "$phase" ]; then warn "$target absent -- etcd will bootstrap a NEW empty cluster"
    else bad "$target is '$phase'"; rc=1; fi
  done
  return $rc
}

# Last sync error the operator logged for OUR release within the last N seconds.
# The operator emits JSON with the full error in .error -- parse it rather than
# sed, because the message embeds escaped quotes (ConfigMap \"name\") that a
# [^"]* pattern truncates.
operator_block_msg() {
  k -n "$OP_NS" logs "deploy/$OP_DEPLOY" --since="${1}s" 2>/dev/null \
    | python3 -c "
import sys, json
last = ''
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get('name') != sys.argv[1] or d.get('level') != 'error':
        continue
    if d.get('error'):
        last = d['error']
print(last)
" "$ETCD_CR"
}

# Between the delete and the recreate, etcd is DOWN and only the operator can
# bring it back. So "no StatefulSet yet" has two very different causes:
#   - the operator has not reconciled yet          -> waiting is correct
#   - the release is blocked and never will        -> waiting is useless
# The original version could not tell them apart and sat silent on a 600s timer.
# On eu-stg-1 that nearly cost the cluster: the Helm ownership block (Issue 4) was
# fixed by hand with ~110s left on the clock. Now we watch the operator, not the
# clock, and fail loudly the moment a real block appears.
wait_recreate() {
  local start; start=$(date +%s)
  local checked_audit=0

  while (( $(date +%s) - start < RECREATE_TIMEOUT )); do
    if [ "$(sts_vct)" = "$TARGET_VCT" ]; then
      ok "StatefulSet recreated with vct=$TARGET_VCT"
      k -n "$NS" rollout status "sts/$STS" --timeout=600s || warn "rollout not complete -- check pod logs"
      return 0
    fi

    local elapsed=$(( $(date +%s) - start ))
    # One reconcile interval is ~35s; wait BLOCK_GRACE before believing an error.
    if [ "$elapsed" -ge "$BLOCK_GRACE" ]; then
      local msg; msg=$(operator_block_msg $((elapsed + 20)))
      if [ -n "$msg" ]; then
        echo
        bad "The release is BLOCKED, not merely slow. etcd is DOWN and will NOT"
        bad "recover on its own. Waiting out the ${RECREATE_TIMEOUT}s timer will not help."
        echo
        echo "  operator error:"
        printf '%s\n' "$msg" | fold -s -w 76 | sed 's/^/    /'
        echo

        case "$msg" in
          *"invalid ownership metadata"*)
            bad "This is Issue 4 -- a Helm ownership orphan. Signature: helm revision"
            bad "FROZEN and Irreconcilable=True (not the climbing revisions of Issue 1)."
            if [ "$checked_audit" = 0 ]; then
              checked_audit=1
              echo; say "re-running the ownership audit to name the object(s)"
              mode_preflight || true
            fi
            ;;
          *"updates to statefulset spec"*|*Forbidden*)
            bad "An immutable StatefulSet field is still being patched -- the recreated"
            bad "object does not match the chart. Compare selector.matchLabels,"
            bad "serviceName, podManagementPolicy and the volumeClaimTemplate name."
            ;;
          *"cannot be imported into the current release"*)
            bad "Helm refuses to adopt a pre-existing object. Run: $0 preflight"
            ;;
          *)
            bad "Unrecognised failure -- read the operator log directly:"
            bad "  kubectl -n $OP_NS logs deploy/$OP_DEPLOY --tail=50 | grep $ETCD_CR"
            ;;
        esac
        echo
        bad "Fix the above, then the operator recreates the StatefulSet on its own"
        bad "(~35s). Re-run '$0 verify' once it does. No second delete is needed."
        return 1
      fi
    fi
    sleep 5
  done

  bad "StatefulSet not recreated with vct=$TARGET_VCT within ${RECREATE_TIMEOUT}s,"
  bad "and no operator error was logged for $ETCD_CR. Check the operator is running:"
  bad "  kubectl -n $OP_NS get pods -l app.kubernetes.io/name=$OP_DEPLOY"
  return 1
}

mode_verify() {
  say "Verification"
  local vct rep ready img rc=0
  vct=$(sts_vct); rep=$(sts_replicas); ready=$(sts_ready); img=$(sts_image)

  [ "$vct" = "$TARGET_VCT" ] && ok "vct=$vct" || { bad "vct=$vct, want $TARGET_VCT"; rc=1; }
  [ "$rep" = "$TARGET_REPLICAS" ] && ok "replicas=$rep" || { bad "replicas=$rep, want $TARGET_REPLICAS"; rc=1; }
  [ "$ready" = "$TARGET_REPLICAS" ] && ok "ready=$ready" || { bad "ready=${ready:-0}, want $TARGET_REPLICAS"; rc=1; }
  case "$img" in *"$TARGET_IMAGE_SUBSTR"*) ok "image=$img";; *) bad "image=$img, want *$TARGET_IMAGE_SUBSTR*"; rc=1;; esac

  local cond; cond=$(k -n "$NS" get etcds.konk.infoblox.com "$ETCD_CR" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)
  case "$cond" in
    *"ReleaseFailed=True"*) bad "Etcd CR still has ReleaseFailed=True -- $cond"; rc=1;;
    *) ok "Etcd CR conditions: $cond";;
  esac

  echo
  say "etcd startup mode -- THIS is the load-bearing check"
  echo "  This rollback is meant to RECOVER the pre-migration data, so expect:"
  echo "    ${GRN}restarting member${RST} <id> in cluster <id>   <- data preserved (WANTED)"
  echo "    ${RED}starting member${RST} <id> in cluster <id>     <- volume was empty, data GONE"
  echo "  (Note this is inverted from the us-stg-1 rollback, where the volumes were"
  echo "   deliberately discarded and 'starting member' was the success signal.)"
  echo
  k -n "$NS" logs "${STS}-0" --tail=400 2>/dev/null \
    | grep -E "(re)?starting member|became leader|became candidate|starting a new election|published|set the initial cluster version|publish error" \
    | tail -12 | sed 's/^/    /' || warn "no pod logs yet"

  local terms; terms=$(k -n "$NS" logs "${STS}-0" --tail=400 2>/dev/null | grep -c "became candidate" || true)
  if [ "${terms:-0}" -gt 5 ]; then
    echo
    bad "$terms election attempts -- this is the silent election loop (rollback doc Issue 3)."
    bad "The recovered membership does not match replicaCount=$TARGET_REPLICAS."
    bad "Nothing logs at ERROR and the pod never restarts, so it looks idle rather than broken."
    rc=1
  fi

  echo
  printf '  %-22s %s\n' "KonkServices" "$(k get konkservices -A --no-headers 2>/dev/null | grep -c .)"
  warn "Do NOT use post-upgrade.sh -- its defaults assert the FORWARD end state"
  warn "  (TARGET_VCT=data-v2, cgr.dev image, cgr cert paths) and will report"
  warn "  correct rollback outcomes as failures."
  echo
  echo "  etcdctl in the rollback chart needs the bitnami cert path:"
  echo "    kubectl -n $NS exec ${STS}-0 -- etcdctl \\"
  echo "      --endpoints=https://127.0.0.1:2379 \\"
  echo "      --cacert=/opt/bitnami/etcd/certs/client/ca.crt \\"
  echo "      --cert=/opt/bitnami/etcd/certs/client/server.crt \\"
  echo "      --key=/opt/bitnami/etcd/certs/client/server.key member list -w table"
  return $rc
}

case "${1:-}" in
  inspect)   mode_inspect   ;;
  baseline)  mode_baseline  ;;
  preflight) mode_preflight ;;
  watch)     mode_watch     ;;
  verify)    mode_verify    ;;
  *) sed -n '2,40p' "$0" | sed 's/^#\ \?//'; exit 1 ;;
esac
