#!/usr/bin/env bash
# Decompose one PRD issue into N child issues on the tracker.
# Usage: decompose.sh <prd-issue-number> [package-path]
#
# `package-path` defaults to the PRD body's `## Package path` value if
# present, then to the repo root (`.`).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/sentinel.sh"
. "$SCRIPT_DIR/lib/tracker.sh"

PRD_ISSUE="${1:?PRD issue number required}"
PACKAGE_PATH="${2:-}"

AFK_SCOPE="decompose:#${PRD_ISSUE}"
afk::require jq git "$AFK_TRACKER_CLI"

# Sniff PACKAGE_PATH from the PRD body if not passed explicitly.
if [[ -z "$PACKAGE_PATH" ]]; then
  PRD_BODY="$(afk::tracker::issue_view_json "$PRD_ISSUE" | jq -r '.body // .description // ""')"
  PACKAGE_PATH="$(awk '
    /^##[ \t]+Package path/ { in_section=1; next }
    /^##[ \t]/ && in_section { exit }
    in_section && NF { gsub(/^[[:space:]`]+|[[:space:]`]+$/, ""); print; exit }
  ' <<<"$PRD_BODY")"
  [[ -z "$PACKAGE_PATH" ]] && PACKAGE_PATH="."
fi
afk::log "PRD #$PRD_ISSUE → decomposing under package: $PACKAGE_PATH"

rc=0
"$SCRIPT_DIR/run-phase.sh" decompose "$PRD_ISSUE" "PACKAGE_PATH=$PACKAGE_PATH" || rc=$?
if (( rc != 0 )); then
  afk::die "decompose phase failed (rc=$rc); see .afk/logs/issue-${PRD_ISSUE}-decompose-latest/decompose.log"
fi

LATEST="$AFK_LOGS/issue-${PRD_ISSUE}-decompose-latest"
CHILDREN_JSON="$LATEST/children.json"
[[ -s "$CHILDREN_JSON" ]] || afk::die "no <children> payload in $LATEST/decompose.log"
jq empty "$CHILDREN_JSON" >/dev/null 2>&1 || afk::die "<children> payload is not valid JSON: $CHILDREN_JSON"

# Make sure the parent has the afk-prd label.
PRD_LBL="$(afk::config_nested labels prd  afk-prd)"
CHILD_LBL="$(afk::config_nested labels child afk-child)"
READY_LBL="$(afk::config_nested labels ready_for_agent ready-for-agent)"
HUMAN_LBL="$(afk::config_nested labels needs_human needs-human)"
afk::tracker::issue_add_label "$PRD_ISSUE" "$PRD_LBL"

LEN="$(jq 'length' "$CHILDREN_JSON")"
declare -a CREATED=()

for ((i=0; i<LEN; i++)); do
  TITLE=$(jq -r ".[$i].title" "$CHILDREN_JSON")
  TYPE=$(jq -r ".[$i].type"  "$CHILDREN_JSON")
  BODY=$(jq -r ".[$i].body"  "$CHILDREN_JSON")
  BIDX=$(jq -r ".[$i].blocked_by_indices | map(tostring) | join(\",\")" "$CHILDREN_JSON")
  BISS=$(jq -r ".[$i].blocked_by_issues  | map(tostring) | join(\",\")" "$CHILDREN_JSON")

  # Resolve indices to real numbers from CREATED.
  RESOLVED=""
  if [[ -n "$BIDX" ]]; then
    IFS=',' read -r -a IDX_ARR <<< "$BIDX"
    for idx in "${IDX_ARR[@]}"; do
      n="${CREATED[$idx]:-}"
      [[ -n "$n" ]] && RESOLVED+="#$n "
    done
  fi
  if [[ -n "$BISS" ]]; then
    IFS=',' read -r -a ISS_ARR <<< "$BISS"
    for n in "${ISS_ARR[@]}"; do
      RESOLVED+="#$n "
    done
  fi
  RESOLVED="$(echo "$RESOLVED" | xargs || true)"
  [[ -z "$RESOLVED" ]] && RESOLVED="None - can start immediately"

  # Splice the resolved blocker list into the body.
  BODY="${BODY//\{\{BLOCKED_BY_LIST\}\}/$RESOLVED}"

  case "$TYPE" in
    afk)         LABELS="$CHILD_LBL,$READY_LBL" ;;
    needs-human) LABELS="$CHILD_LBL,$HUMAN_LBL" ;;
    *)           LABELS="$CHILD_LBL,$READY_LBL" ;;
  esac

  TMP_BODY="$(mktemp)"
  printf '%s\n' "$BODY" > "$TMP_BODY"
  N="$(afk::tracker::issue_create "$TITLE" "$TMP_BODY" "$LABELS")"
  rm -f "$TMP_BODY"
  CREATED+=("$N")
  afk::log "created child #$N: $TITLE"
done

FORMATTED="$(printf '#%s, ' "${CREATED[@]}" | sed 's/, $//')"
afk::tracker::issue_comment "$PRD_ISSUE" "AFK decomposed into ${LEN} children: ${FORMATTED}"
afk::log "decomposition done: ${CREATED[*]}"
