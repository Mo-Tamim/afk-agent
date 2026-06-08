#!/usr/bin/env bash
# After every child of a PRD has been merged, kick the document phase for
# that PRD. Idempotent: skips PRDs that already have afk-done.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/tracker.sh"
. "$SCRIPT_DIR/lib/worktree.sh"
. "$SCRIPT_DIR/lib/state.sh"

AFK_SCOPE="docs-gate"

DONE_LBL="$(afk::config_nested labels done            afk-done)"
INPROG_LBL="$(afk::config_nested labels in_progress   afk-in-progress)"
BLOCKED_LBL="$(afk::config_nested labels blocked      afk-blocked)"

mapfile -t PRDS < <(afk::tracker::open_afk_prds)

for PRD in "${PRDS[@]}"; do
  [[ -z "$PRD" ]] && continue
  LABELS="$(afk::tracker::issue_labels "$PRD")"
  [[ "$LABELS" == *"$DONE_LBL"* ]] && continue
  [[ "$LABELS" == *"$INPROG_LBL"* ]] && continue   # docs phase already running

  # Find children whose body references this PRD via `Parent: #N`.
  CHILDREN_JSON="$(case "$TRACKER" in
    github)
      gh issue list -R "$REPO" --state all --label "$(afk::config_nested labels child afk-child)" \
        --limit 200 --json number,state,body \
        --jq "[.[] | select(.body | test(\"(?ms)^##[ \\t]*Parent[ \\t]*\\\\n\\\\s*#${PRD}\\\\b|Parent:[ \\t]*#${PRD}\\\\b\"))]"
      ;;
    gitlab)
      glab issue list -R "$REPO" --state all --label "$(afk::config_nested labels child afk-child)" \
        --per-page 200 --output json \
        | jq "[.[] | select(.description // .body // \"\" | test(\"(?ms)^##[ \\t]*Parent[ \\t]*\\\\n\\\\s*#${PRD}\\\\b|Parent:[ \\t]*#${PRD}\\\\b\")) | {number: (.iid // .number), state, body: (.description // .body)}]"
      ;;
  esac)"
  COUNT="$(jq 'length' <<<"$CHILDREN_JSON")"
  (( COUNT == 0 )) && continue

  CLOSED_COUNT="$(jq '[.[] | select(.state=="CLOSED" or .state=="closed")] | length' <<<"$CHILDREN_JSON")"
  if (( CLOSED_COUNT < COUNT )); then
    afk::log "PRD #$PRD: $CLOSED_COUNT/$COUNT children closed; not yet documenting"
    continue
  fi

  afk::log "PRD #$PRD: all $COUNT children closed → triggering docs phase"

  PRD_TITLE="$(afk::tracker::issue_view_json "$PRD" | jq -r '.title')"
  PRD_SLUG="$(afk::slug "$PRD_TITLE")"
  CHILD_NUMS="$(jq -r '[.[].number] | join(" ")' <<<"$CHILDREN_JSON")"

  # Find merged PRs for these children.
  CHILD_PRS=""
  for c in $CHILD_NUMS; do
    pr="$(afk::tracker::pr_merged_for_issue "$c" 2>/dev/null || true)"
    [[ -n "$pr" ]] && CHILD_PRS+="$pr "
  done
  CHILD_PRS="$(echo "$CHILD_PRS" | xargs || true)"

  # Detect the package the PRD primarily touched (from `## Package path`).
  PRD_BODY="$(afk::tracker::issue_view_json "$PRD" | jq -r '.body // .description // ""')"
  PACKAGE_PATH="$(awk '
    /^##[ \t]+Package path/ { in_section=1; next }
    /^##[ \t]/ && in_section { exit }
    in_section && NF { gsub(/^[[:space:]`]+|[[:space:]`]+$/, ""); print; exit }
  ' <<<"$PRD_BODY")"
  [[ -z "$PACKAGE_PATH" ]] && PACKAGE_PATH="."

  BRANCH="afk/docs-prd-${PRD}-${PRD_SLUG}"
  afk::worktree_create "$PRD" "$BRANCH"
  afk::state_init "$PRD" "$BRANCH"
  afk::state_set  "$PRD" branch "$BRANCH"
  afk::tracker::issue_add_label "$PRD" "$INPROG_LBL"

  rc=0
  "$SCRIPT_DIR/run-phase.sh" document "$PRD" \
    "PRD_ISSUE=$PRD" "PRD_TITLE=$PRD_TITLE" "PRD_SLUG=$PRD_SLUG" \
    "PACKAGE_PATH=$PACKAGE_PATH" "CHILD_ISSUES=$CHILD_NUMS" "CHILD_PRS=$CHILD_PRS" || rc=$?
  if (( rc != 0 )); then
    afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"
    continue
  fi

  # Open + self-review + merge the docs PR through the same flow as a child.
  PR_BODY_FILE="$(mktemp)"
  afk::render "$AFK_DIR/templates/pr-body.md" \
    TITLE          "Docs: $PRD_TITLE" \
    BRANCH         "$BRANCH" \
    ISSUE_ID       "$PRD" \
    SUMMARY        "AFK-generated developer + user documentation for PRD #$PRD." \
    TEST_PLAN      "Manual: open the new docs and confirm mermaid renders + links resolve." \
    REVIEWER_NOTES "Self-review by AFK pr_review phase against the docs PR diff." \
    > "$PR_BODY_FILE"

  rc=0
  "$SCRIPT_DIR/run-phase.sh" pr "$PRD" "PR_BODY_FILE=$PR_BODY_FILE" || rc=$?
  rm -f "$PR_BODY_FILE"
  (( rc == 0 )) || { afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"; continue; }

  PR_NUMBER="$(jq -r '.number' "$AFK_LOGS/issue-${PRD}-pr-latest/pr.json")"
  afk::state_set "$PRD" pr "$PR_NUMBER"

  # Wait for CI on docs PR (usually trivial).
  POLL="$(afk::config ci_poll_interval_seconds 30)"
  MAX="$(afk::config ci_max_wait_seconds 1800)"
  elapsed=0
  while (( elapsed < MAX )); do
    s="$(afk::tracker::ci_status "$PR_NUMBER")"
    [[ "$s" == "GREEN" ]] && break
    [[ "$s" == "RED"   ]] && { afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"; break; }
    sleep "$POLL"; elapsed=$((elapsed+POLL))
  done

  "$SCRIPT_DIR/run-phase.sh" pr-review "$PRD" "PR_NUMBER=$PR_NUMBER" || true
  rc=0
  "$SCRIPT_DIR/run-phase.sh" merge "$PRD" "PR_NUMBER=$PR_NUMBER" || rc=$?
  if (( rc != 0 )); then
    afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"
    continue
  fi

  afk::tracker::issue_remove_label "$PRD" "$INPROG_LBL"
  afk::tracker::issue_add_label    "$PRD" "$DONE_LBL"
  afk::tracker::issue_close        "$PRD" "AFK docs merged in #$PR_NUMBER. Closing PRD."
  afk::worktree_remove "$PRD"
  afk::log "PRD #$PRD documented and closed."
done
