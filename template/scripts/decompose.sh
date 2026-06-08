#!/usr/bin/env bash
# Decompose one PRD issue into N child issues on the tracker.
#
# Pipeline (in this script):
#   1. Sniff the PRD's `## Package path` so the decompose agent knows
#      where to focus its codebase reading.
#   2. Spawn the decompose agent via run-phase.sh.
#   3. Parse the <children>JSON</children> payload it emitted.
#   4. For each entry, in dependency order, create the child issue on
#      the tracker and remember the assigned number.
#   5. Rewrite `Blocked by:` references in dependent siblings to use
#      the real numbers we just learned.
#   6. Drop a comment on the PRD listing the created children.
#
# Usage: `.afk/scripts/afk decompose <prd-issue-number> [package-path]`

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

# === 1. Sniff package path ===================================================
# If the caller didn't pass it, parse the PRD body for the `## Package path`
# section. Fall back to `.` (repo root) so the decompose agent at least has
# *something* to anchor on.

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

# === 2. Run the decompose phase ==============================================
# Captured rc so a non-zero from bookkeeping doesn't trump the actual phase
# outcome. If the agent never emits a sentinel, run-phase.sh exits 30.

rc=0
"$SCRIPT_DIR/run-phase.sh" decompose "$PRD_ISSUE" "PACKAGE_PATH=$PACKAGE_PATH" || rc=$?
if (( rc != 0 )); then
  afk::die "decompose phase failed (rc=$rc); see .afk/logs/issue-${PRD_ISSUE}-decompose-latest/decompose.log"
fi

LATEST="$AFK_LOGS/issue-${PRD_ISSUE}-decompose-latest"
CHILDREN_JSON="$LATEST/children.json"
[[ -s "$CHILDREN_JSON" ]] || afk::die "no <children> payload in $LATEST/decompose.log"
jq empty "$CHILDREN_JSON" >/dev/null 2>&1 || afk::die "<children> payload is not valid JSON: $CHILDREN_JSON"

# === 3. Ensure the parent has the afk-prd label ==============================
# Without this, the docs-gate won't pick it up at the end of the PRD.

PRD_LBL="$(afk::config_nested labels prd   afk-prd)"
CHILD_LBL="$(afk::config_nested labels child afk-child)"
READY_LBL="$(afk::config_nested labels ready_for_agent ready-for-agent)"
HUMAN_LBL="$(afk::config_nested labels needs_human needs-human)"
afk::tracker::issue_add_label "$PRD_ISSUE" "$PRD_LBL"

# === 4. Create children in order =============================================
# Iteration order matters: a sibling at index 3 may list `blocked_by_indices:
# [0, 1]`, which we resolve to the real issue numbers stored in CREATED[0]
# and CREATED[1] before publishing #3's body.

LEN="$(jq 'length' "$CHILDREN_JSON")"
declare -a CREATED=()

for ((i=0; i<LEN; i++)); do
  TITLE=$(jq -r ".[$i].title" "$CHILDREN_JSON")
  TYPE=$(jq -r ".[$i].type"  "$CHILDREN_JSON")
  BODY=$(jq -r ".[$i].body"  "$CHILDREN_JSON")
  BIDX=$(jq -r ".[$i].blocked_by_indices | map(tostring) | join(\",\")" "$CHILDREN_JSON")
  BISS=$(jq -r ".[$i].blocked_by_issues  | map(tostring) | join(\",\")" "$CHILDREN_JSON")

  # Resolve sibling indices → real issue numbers from prior iterations.
  RESOLVED=""
  if [[ -n "$BIDX" ]]; then
    IFS=',' read -r -a IDX_ARR <<< "$BIDX"
    for idx in "${IDX_ARR[@]}"; do
      n="${CREATED[$idx]:-}"
      [[ -n "$n" ]] && RESOLVED+="#$n "
    done
  fi
  # Existing tracker issues — already-known numbers; passed through as-is.
  if [[ -n "$BISS" ]]; then
    IFS=',' read -r -a ISS_ARR <<< "$BISS"
    for n in "${ISS_ARR[@]}"; do
      RESOLVED+="#$n "
    done
  fi
  RESOLVED="$(echo "$RESOLVED" | xargs || true)"
  [[ -z "$RESOLVED" ]] && RESOLVED="None - can start immediately"

  # Splice the resolved list into the body's `{{BLOCKED_BY_LIST}}` slot.
  # The decompose-prompt requires the agent to leave this exact token.
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

# === 5. PRD-side breadcrumb ==================================================
# Lets a human glance at the PRD and immediately see what got spawned.

FORMATTED="$(printf '#%s, ' "${CREATED[@]}" | sed 's/, $//')"
afk::tracker::issue_comment "$PRD_ISSUE" "AFK decomposed into ${LEN} children: ${FORMATTED}"
afk::log "decomposition done: ${CREATED[*]}"
