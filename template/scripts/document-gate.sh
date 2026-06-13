#!/usr/bin/env bash
# Auto-trigger the `document` phase for every PRD whose children are all
# closed. Idempotent — skips PRDs already labelled afk-done, already
# blocked, or with a *live* docs runner currently on them.
#
# This script runs:
#   • Manually via `.afk/scripts/afk document` (handy for one-off forces).
#   • Automatically on every idle pass of `orchestrate.sh`.
#
# Crash / resume model (mirrors run-issue.sh for child issues):
#   The docs phase stamps the PRD with afk-in-progress and takes a per-PRD
#   lock (lib/lock.sh) recording its pid. If the runner crashes or is killed
#   (e.g. cursor-agent loses its connection, or the operator kills the
#   orchestrator), the label and lock are left behind.
#
#   On the next pass we must NOT treat that stale label as "still running"
#   and skip the PRD forever. Instead we probe the lock for liveness:
#     • lock owned by a running pid  → a docs runner is genuinely active → skip.
#     • lock missing / pid dead      → stale → RESUME the interrupted docs run.
#   Resume is per-phase: each docs phase (document, pr, merge) records itself
#   in the issue state's completed_phases, so we re-run only what didn't
#   finish (e.g. re-run `document` if the agent never committed) and reuse the
#   existing branch/worktree/PR for everything that did.
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
. "$SCRIPT_DIR/lib/lock.sh"

AFK_SCOPE="docs-gate"

DONE_LBL="$(afk::config_nested labels done            afk-done)"
INPROG_LBL="$(afk::config_nested labels in_progress   afk-in-progress)"
BLOCKED_LBL="$(afk::config_nested labels blocked      afk-blocked)"

# === Per-PRD pipeline =========================================================
# Factored into a function so the loop can wrap every exit path (the many
# early `return`s below) in a single lock acquire/release. `return 0` here
# means "done with this PRD for now"; it is never fatal to the scan.
#
# Args: <prd-number> <resuming:0|1>
afk::docs_run_prd() {
  local PRD="$1" RESUMING="${2:-0}"

  # === 1. Find children referencing this PRD as their parent ===============
  # Children link via `Parent: #N` or `## Parent\n#N` in their bodies. The
  # regex tolerates both forms.

  local CHILDREN_JSON
  CHILDREN_JSON="$(case "$TRACKER" in
    github)
      gh issue list -R "$REPO" --state all --label "$(afk::config_nested labels child afk-child)" \
        --limit 200 --json number,state,body \
        --jq "[.[] | select(.body | test(\"(?ms)^##[ \\t]*Parent[ \\t]*\\\\n\\\\s*#${PRD}\\\\b|Parent:[ \\t]*#${PRD}\\\\b\"))]"
      ;;
    gitlab)
      glab issue list -R "$REPO" --all --label "$(afk::config_nested labels child afk-child)" \
        --per-page 200 --output json \
        | jq "[.[] | select(.description // .body // \"\" | test(\"(?ms)^##[ \\t]*Parent[ \\t]*\\\\n\\\\s*#${PRD}\\\\b|Parent:[ \\t]*#${PRD}\\\\b\")) | {number: (.iid // .number), state, body: (.description // .body)}]"
      ;;
  esac)"
  local COUNT
  COUNT="$(jq 'length' <<<"$CHILDREN_JSON")"
  (( COUNT == 0 )) && return 0

  local CLOSED_COUNT
  CLOSED_COUNT="$(jq '[.[] | select(.state=="CLOSED" or .state=="closed")] | length' <<<"$CHILDREN_JSON")"
  if (( CLOSED_COUNT < COUNT )); then
    afk::log "PRD #$PRD: $CLOSED_COUNT/$COUNT children closed; not yet documenting"
    return 0
  fi

  if (( RESUMING )); then
    afk::log "PRD #$PRD: resuming interrupted docs phase (all $COUNT children closed)"
  else
    afk::log "PRD #$PRD: all $COUNT children closed → triggering docs phase"
  fi

  # === 2. Gather inputs for the documenter agent ===========================

  local PRD_TITLE PRD_SLUG CHILD_NUMS
  PRD_TITLE="$(afk::tracker::issue_view_json "$PRD" | jq -r '.title')"
  PRD_SLUG="$(afk::slug "$PRD_TITLE")"
  CHILD_NUMS="$(jq -r '[.[].number] | join(" ")' <<<"$CHILDREN_JSON")"

  # Map each child to the PR that closed it. The tracker abstraction
  # returns empty on issues with no associated PR — we just skip those.
  local CHILD_PRS="" c pr
  for c in $CHILD_NUMS; do
    pr="$(afk::tracker::pr_merged_for_issue "$c" 2>/dev/null || true)"
    [[ -n "$pr" ]] && CHILD_PRS+="$pr "
  done
  CHILD_PRS="$(echo "$CHILD_PRS" | xargs || true)"

  # Same `## Package path` parser as decompose.sh — single source of truth
  # for "where in the repo does this PRD touch?".
  local PRD_BODY PACKAGE_PATH
  PRD_BODY="$(afk::tracker::issue_view_json "$PRD" | jq -r '.body // .description // ""')"
  PACKAGE_PATH="$(awk '
    /^##[ \t]+Package path/ { in_section=1; next }
    /^##[ \t]/ && in_section { exit }
    in_section && NF { gsub(/^[[:space:]`]+|[[:space:]`]+$/, ""); print; exit }
  ' <<<"$PRD_BODY")"
  [[ -z "$PACKAGE_PATH" ]] && PACKAGE_PATH="."

  # On resume, prefer the branch recorded in state so we re-attach to the
  # exact worktree/branch the interrupted run created (the slug could in
  # principle change if the PRD title was edited mid-flight).
  local BRANCH
  BRANCH="$(afk::state_get "$PRD" branch 2>/dev/null || true)"
  [[ -z "$BRANCH" ]] && BRANCH="afk/docs-prd-${PRD}-${PRD_SLUG}"

  afk::worktree_create "$PRD" "$BRANCH"
  afk::state_init "$PRD" "$BRANCH"
  afk::state_set  "$PRD" branch "$BRANCH"
  afk::tracker::issue_add_label "$PRD" "$INPROG_LBL"

  # === 3. Run the document agent ==========================================
  # Resumable: skip if a prior run already completed it (agent committed the
  # docs but the run died before merging).

  if afk::state_phase_completed "$PRD" document; then
    afk::log "PRD #$PRD: skipping document (already completed)"
  else
    local rc=0
    "$SCRIPT_DIR/run-phase.sh" document "$PRD" \
      "PRD_ISSUE=$PRD" "PRD_TITLE=$PRD_TITLE" "PRD_SLUG=$PRD_SLUG" \
      "PACKAGE_PATH=$PACKAGE_PATH" "CHILD_ISSUES=$CHILD_NUMS" "CHILD_PRS=$CHILD_PRS" || rc=$?
    if (( rc != 0 )); then
      afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"
      return 0
    fi
    afk::state_phase_mark_completed "$PRD" document
  fi

  # === 4. Ship the docs PR through the same pr→ci→review→merge flow ========
  # We reuse the per-issue phases instead of duplicating logic, with a docs-
  # flavored PR body.

  local PR_NUMBER
  PR_NUMBER="$(afk::state_get "$PRD" pr 2>/dev/null || echo "")"

  # Idempotency: adopt an already-open PR for this branch (handles a crash
  # between `gh pr create` and the state write).
  if [[ -z "$PR_NUMBER" ]]; then
    PR_NUMBER="$(afk::tracker::pr_list_for_branch "$BRANCH" 2>/dev/null || echo "")"
    if [[ -n "$PR_NUMBER" ]]; then
      afk::log "PRD #$PRD: found existing open PR #$PR_NUMBER for $BRANCH; reusing"
      afk::state_set "$PRD" pr "$PR_NUMBER"
      afk::state_phase_mark_completed "$PRD" pr
    fi
  fi

  if afk::state_phase_completed "$PRD" pr; then
    afk::log "PRD #$PRD: skipping pr (already completed; PR #$PR_NUMBER)"
  else
    local PR_BODY_FILE rc=0
    PR_BODY_FILE="$(mktemp)"
    afk::render "$AFK_DIR/templates/pr-body.md" \
      TITLE          "Docs: $PRD_TITLE" \
      BRANCH         "$BRANCH" \
      ISSUE_ID       "$PRD" \
      SUMMARY        "AFK-generated developer + user documentation for PRD #$PRD." \
      TEST_PLAN      "Manual: open the new docs and confirm mermaid renders + links resolve." \
      SMOKE_TEST     "$(printf '1. Open the changed files under \`docs/dev/\` and \`docs/user/\`.\n2. Confirm every mermaid block renders (paste into a mermaid live editor or view on the tracker).\n3. Click each link in the docs index and confirm it resolves.')" \
      REVIEWER_NOTES "Self-review by AFK pr_review phase against the docs PR diff." \
      > "$PR_BODY_FILE"

    "$SCRIPT_DIR/run-phase.sh" pr "$PRD" "PR_BODY_FILE=$PR_BODY_FILE" || rc=$?
    rm -f "$PR_BODY_FILE"
    (( rc == 0 )) || { afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"; return 0; }

    PR_NUMBER="$(jq -r '.number' "$AFK_LOGS/issue-${PRD}-pr-latest/pr.json")"
    afk::state_set "$PRD" pr "$PR_NUMBER"
    afk::state_phase_mark_completed "$PRD" pr
  fi

  # Tiny CI wait — docs PRs rarely trigger heavy pipelines. Always re-checked
  # on resume (live CI state must not be cached as "completed").
  local POLL MAX elapsed s
  POLL="$(afk::config ci_poll_interval_seconds 30)"
  MAX="$(afk::config ci_max_wait_seconds 1800)"
  elapsed=0
  while (( elapsed < MAX )); do
    s="$(afk::tracker::ci_status "$PR_NUMBER")"
    [[ "$s" == "GREEN" ]] && break
    [[ "$s" == "RED"   ]] && { afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"; return 0; }
    sleep "$POLL"; elapsed=$((elapsed+POLL))
  done

  "$SCRIPT_DIR/run-phase.sh" pr-review "$PRD" "PR_NUMBER=$PR_NUMBER" || true

  if afk::state_phase_completed "$PRD" merge; then
    afk::log "PRD #$PRD: skipping merge (already completed)"
  else
    local rc=0
    "$SCRIPT_DIR/run-phase.sh" merge "$PRD" "PR_NUMBER=$PR_NUMBER" || rc=$?
    if (( rc != 0 )); then
      afk::tracker::issue_add_label "$PRD" "$BLOCKED_LBL"
      return 0
    fi
    afk::state_phase_mark_completed "$PRD" merge
  fi

  # === 5. Close the PRD ===================================================

  afk::tracker::issue_remove_label "$PRD" "$INPROG_LBL"
  afk::tracker::issue_add_label    "$PRD" "$DONE_LBL"
  afk::tracker::issue_close        "$PRD" "AFK docs merged in #$PR_NUMBER. Closing PRD."
  afk::worktree_remove "$PRD"
  afk::log "PRD #$PRD documented and closed."
  return 0
}

# === Scan loop ================================================================

mapfile -t PRDS < <(afk::tracker::open_afk_prds)

for PRD in "${PRDS[@]}"; do
  [[ -z "$PRD" ]] && continue
  LABELS="$(afk::tracker::issue_labels "$PRD")"
  [[ "$LABELS" == *"$DONE_LBL"* ]]    && continue
  [[ "$LABELS" == *"$BLOCKED_LBL"* ]] && continue   # needs a human; don't auto-retry

  # A PRD labelled afk-in-progress is only "running" if a live runner owns
  # its lock. A stale label (crash / killed orchestrator) must be resumed,
  # not skipped forever — that was the bug this gate used to have.
  RESUMING=0
  if [[ "$LABELS" == *"$INPROG_LBL"* ]]; then
    if afk::lock_alive "$PRD"; then
      afk::log "PRD #$PRD: docs phase already running (live lock); skipping"
      continue
    fi
    afk::warn "PRD #$PRD: stale $INPROG_LBL with no live runner → resuming interrupted docs phase"
    RESUMING=1
  fi

  # Take the per-PRD lock for the duration of this PRD's pipeline.
  # lock_acquire transparently reclaims a lock left by a dead pid, so the
  # stale-label resume above always gets the lock. A failure here means a
  # live runner grabbed it between our liveness probe and now → skip.
  if ! afk::lock_acquire "$PRD"; then
    afk::log "PRD #$PRD: could not acquire lock (another runner active); skipping"
    continue
  fi

  rc=0
  afk::docs_run_prd "$PRD" "$RESUMING" || rc=$?
  afk::lock_release "$PRD"
  (( rc == 0 )) || afk::warn "PRD #$PRD: docs pipeline returned rc=$rc"
done
