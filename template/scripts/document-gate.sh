#!/usr/bin/env bash
# Auto-trigger the `document` phase for every PRD whose children are all
# closed. Idempotent — skips PRDs already labelled afk-done or already
# in-progress.
#
# This script runs:
#   • Manually via `.afk/scripts/afk document` (handy for one-off forces).
#   • Automatically on every idle pass of `orchestrate.sh`.
#
# Pipeline (per PRD that's ready):
#   1. Verify all afk-child issues referencing this PRD are closed.
#   2. Collect the merged PR numbers so the documenter can read their diffs.
#   3. Pick a docs branch + create the worktree.
#   4. Run the `document` phase agent.
#   5. Open the docs PR, wait for CI, self-review, squash-merge.
#   6. Label the PRD afk-done and close it.

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
  [[ "$LABELS" == *"$DONE_LBL"* ]]   && continue
  [[ "$LABELS" == *"$INPROG_LBL"* ]] && continue   # docs phase already running

  # === 1. Find children referencing this PRD as their parent ===============
  # Children link via `Parent: #N` or `## Parent\n#N` in their bodies. The
  # regex tolerates both forms.

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

  # === 2. Gather inputs for the documenter agent ===========================

  PRD_TITLE="$(afk::tracker::issue_view_json "$PRD" | jq -r '.title')"
  PRD_SLUG="$(afk::slug "$PRD_TITLE")"
  CHILD_NUMS="$(jq -r '[.[].number] | join(" ")' <<<"$CHILDREN_JSON")"

  # Map each child to the PR that closed it. The tracker abstraction
  # returns empty on issues with no associated PR — we just skip those.
  CHILD_PRS=""
  for c in $CHILD_NUMS; do
    pr="$(afk::tracker::pr_merged_for_issue "$c" 2>/dev/null || true)"
    [[ -n "$pr" ]] && CHILD_PRS+="$pr "
  done
  CHILD_PRS="$(echo "$CHILD_PRS" | xargs || true)"

  # Same `## Package path` parser as decompose.sh — single source of truth
  # for "where in the repo does this PRD touch?".
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

  # === 3. Run the document agent ===========================================

  rc=0
  "$SCRIPT_DIR/run-phase.sh" document "$PRD" \
    "PRD_ISSUE=$PRD" "PRD_TITLE=$PRD_TITLE" "PRD_SLUG=$PRD_SLUG" \
    "PACKAGE_PATH=$PACKAGE_PATH" "CHILD_ISSUES=$CHILD_NUMS" "CHILD_PRS=$CHILD_PRS" || rc=$?
  if (( rc != 0 )); then
    afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"
    continue
  fi

  # === 4. Ship the docs PR through the same pr→ci→review→merge flow ========
  # We reuse the per-issue phases instead of duplicating logic, with a docs-
  # flavored PR body.

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

  # Tiny CI wait — docs PRs rarely trigger heavy pipelines.
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

  # === 5. Close the PRD ====================================================

  afk::tracker::issue_remove_label "$PRD" "$INPROG_LBL"
  afk::tracker::issue_add_label    "$PRD" "$DONE_LBL"
  afk::tracker::issue_close        "$PRD" "AFK docs merged in #$PR_NUMBER. Closing PRD."
  afk::worktree_remove "$PRD"
  afk::log "PRD #$PRD documented and closed."
done
