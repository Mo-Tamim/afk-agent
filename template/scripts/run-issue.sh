#!/usr/bin/env bash
# Drive ONE child issue through all its phases, with per-phase resume.
# Usage: run-issue.sh <issue-number>
#
# Resume model:
#   - Each phase that finishes with COMPLETE is recorded in
#     .afk/state/issue-<N>.json under .completed_phases.
#   - On every invocation we walk the phase list and skip any phase already
#     marked completed. So if the runner crashes between phases (or the
#     machine reboots, or the developer Ctrl-Cs it), the next `afk run`
#     for this issue picks up at the first not-yet-completed phase.
#   - For phases that are themselves polling loops (pr_wait_ci) or are
#     idempotent at the tracker layer (pr, merge), we additionally
#     short-circuit based on observed remote state.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/sentinel.sh"
. "$SCRIPT_DIR/lib/state.sh"
. "$SCRIPT_DIR/lib/lock.sh"
. "$SCRIPT_DIR/lib/tracker.sh"
. "$SCRIPT_DIR/lib/worktree.sh"

ISSUE="${1:?issue number required}"
AFK_SCOPE="run-issue:#${ISSUE}"

afk::require jq git "$AFK_TRACKER_CLI"

if ! afk::lock_acquire "$ISSUE"; then
  afk::die "issue $ISSUE is already locked by another runner; refusing to double-process"
fi
trap 'afk::lock_release "'"$ISSUE"'"' EXIT

# Verify the issue is in a runnable state.
LABELS="$(afk::tracker::issue_labels "$ISSUE")"
READY_LBL="$(afk::config_nested labels ready_for_agent ready-for-agent)"
INPROG_LBL="$(afk::config_nested labels in_progress    afk-in-progress)"
BLOCKED_LBL="$(afk::config_nested labels blocked       afk-blocked)"
DONE_LBL="$(afk::config_nested labels done             afk-done)"
if [[ "$LABELS" != *"$READY_LBL"* && "$LABELS" != *"$INPROG_LBL"* ]]; then
  afk::warn "issue $ISSUE has labels '$LABELS'; not labelled $READY_LBL. Skipping."
  exit 0
fi
if ! afk::tracker::blockers_resolved "$ISSUE"; then
  afk::warn "issue $ISSUE has unresolved blockers. Skipping."
  exit 0
fi

afk::state_init "$ISSUE"

afk::tracker::issue_remove_label "$ISSUE" "$READY_LBL"
afk::tracker::issue_add_label    "$ISSUE" "$INPROG_LBL"

run_phase() {
  local phase="$1"; shift
  PHASE_RC=0
  "$SCRIPT_DIR/run-phase.sh" "$phase" "$ISSUE" "$@" || PHASE_RC=$?
}

# === plan ===
if afk::state_phase_completed "$ISSUE" plan; then
  afk::log "skipping plan (already completed)"
  BRANCH="$(afk::state_get "$ISSUE" branch)"
  PACKAGE="$(afk::state_get "$ISSUE" package)"
  if [[ -z "$BRANCH" ]]; then
    afk::die "plan was marked completed but state has no branch; clear with afk reset"
  fi
else
  run_phase plan
  if (( PHASE_RC != 0 )); then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    exit "$PHASE_RC"
  fi
  PLAN_FILE="$AFK_LOGS/issue-${ISSUE}-plan-latest/plan.json"
  if [[ ! -s "$PLAN_FILE" ]]; then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    afk::die "plan phase emitted COMPLETE but no <plan> JSON payload at $PLAN_FILE"
  fi
  if ! jq empty "$PLAN_FILE" >/dev/null 2>&1; then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    afk::die "plan payload is not valid JSON: $PLAN_FILE"
  fi
  BRANCH="$(jq -r '.branch  // empty' "$PLAN_FILE")"
  PACKAGE="$(jq -r '.package // empty' "$PLAN_FILE")"
  if [[ -z "$BRANCH" ]]; then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    afk::die "plan payload missing required 'branch' field: $PLAN_FILE"
  fi
  afk::state_set "$ISSUE" branch  "$BRANCH"
  afk::state_set "$ISSUE" package "$PACKAGE"
  afk::state_phase_mark_completed "$ISSUE" plan
fi

# === worktree ===
afk::worktree_create "$ISSUE" "$BRANCH"

# === implement ===
if afk::state_phase_completed "$ISSUE" implement; then
  afk::log "skipping implement (already completed)"
else
  run_phase implement "PACKAGE=$PACKAGE"
  case "$PHASE_RC" in
    0)  afk::state_phase_mark_completed "$ISSUE" implement ;;
    10) afk::warn "implement returned NO_CHANGES; bailing without PR"; exit 0 ;;
    *)  afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"; exit "$PHASE_RC" ;;
  esac
fi

# === review === (NO_CHANGES / minor issues are non-fatal)
if afk::state_phase_completed "$ISSUE" review; then
  afk::log "skipping review (already completed)"
else
  run_phase review "PACKAGE=$PACKAGE" || true
  afk::state_phase_mark_completed "$ISSUE" review
fi

# === pr ===
PR_NUMBER="$(afk::state_get "$ISSUE" pr 2>/dev/null || echo "")"
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER="$(afk::tracker::pr_list_for_branch "$BRANCH" || echo "")"
  if [[ -n "$PR_NUMBER" ]]; then
    afk::log "found existing open PR #$PR_NUMBER for $BRANCH; reusing"
    wt="$(afk::worktree_path "$ISSUE")"
    if [[ -d "$wt" ]]; then
      local_tip="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")"
      remote_tip="$(git -C "$wt" ls-remote origin "$BRANCH" 2>/dev/null | awk '{print $1}')"
      if [[ -n "$local_tip" && "$local_tip" != "$remote_tip" ]]; then
        afk::log "local $BRANCH ($local_tip) diverges from remote ($remote_tip); force-pushing"
        git -C "$wt" push --force-with-lease origin "$BRANCH" 2>&1 | sed 's/^/  /' | tail -3
      fi
    fi
    afk::state_set "$ISSUE" pr "$PR_NUMBER"
    afk::state_phase_mark_completed "$ISSUE" pr
  fi
fi

if afk::state_phase_completed "$ISSUE" pr; then
  afk::log "skipping pr (already completed; PR #$PR_NUMBER)"
else
  PR_BODY_FILE="$(mktemp)"
  afk::render "$AFK_DIR/templates/pr-body.md" \
    TITLE          "$(afk::tracker::issue_view_json "$ISSUE" | jq -r '.title // ""')" \
    BRANCH         "$BRANCH" \
    ISSUE_ID       "$ISSUE" \
    SUMMARY        "AFK-implemented per the linked issue's acceptance criteria." \
    TEST_PLAN      "Unit/integration tests added per the issue's test notes; CI is the source of truth." \
    REVIEWER_NOTES "Self-review by AFK pr_review phase. Acceptance criteria checked against the diff." \
    > "$PR_BODY_FILE"

  run_phase pr "PR_BODY_FILE=$PR_BODY_FILE"
  rm -f "$PR_BODY_FILE"
  if (( PHASE_RC != 0 )); then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    exit "$PHASE_RC"
  fi
  PR_FILE="$AFK_LOGS/issue-${ISSUE}-pr-latest/pr.json"
  if [[ ! -s "$PR_FILE" ]] || ! jq empty "$PR_FILE" >/dev/null 2>&1; then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    afk::die "pr phase did not produce a valid <pr> payload at $PR_FILE"
  fi
  PR_NUMBER="$(jq -r '.number // empty' "$PR_FILE")"
  if [[ -z "$PR_NUMBER" ]]; then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    afk::die "pr payload missing 'number' field: $PR_FILE"
  fi
  afk::state_set "$ISSUE" pr "$PR_NUMBER"
  afk::state_phase_mark_completed "$ISSUE" pr
  afk::log "PR opened: #$PR_NUMBER"
fi

# === pr_wait_ci === (poll loop; never marked completed — always re-checks)
POLL="$(afk::config ci_poll_interval_seconds 30)"
MAX="$(afk::config ci_max_wait_seconds 1800)"
elapsed=0
while (( elapsed < MAX )); do
  STATUS="$(afk::tracker::ci_status "$PR_NUMBER")"
  case "$STATUS" in
    GREEN)   afk::log "CI green on PR #$PR_NUMBER"; break ;;
    RED)
      afk::warn "CI red on PR #$PR_NUMBER"
      [[ "$(afk::config notify_on_ci_red true)" == "true" ]] && afk::notify error "PR #$PR_NUMBER CI red"
      afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
      exit 20
      ;;
    PENDING|UNKNOWN) sleep "$POLL"; elapsed=$((elapsed+POLL)) ;;
  esac
done
if (( elapsed >= MAX )); then
  [[ "$(afk::config notify_on_timeout true)" == "true" ]] && afk::notify error "PR #$PR_NUMBER CI timed out"
  afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
  exit 20
fi

# === pr_review === (advisory; non-fatal)
if afk::state_phase_completed "$ISSUE" pr_review; then
  afk::log "skipping pr_review (already completed)"
else
  run_phase pr-review "PR_NUMBER=$PR_NUMBER" || true
  afk::state_phase_mark_completed "$ISSUE" pr_review
fi

# === pr_merge ===
MERGE_MODE="$(afk::config merge_mode auto)"
if [[ "$MERGE_MODE" == "gated" ]]; then
  [[ "$(afk::config notify_on_merge_gate true)" == "true" ]] && \
    afk::notify attention "PR #$PR_NUMBER ready to merge; type '/merge $PR_NUMBER' to proceed"
  afk::log "merge_mode=gated; pausing here. PR #$PR_NUMBER awaits manual merge."
  exit 0
fi

if afk::state_phase_completed "$ISSUE" merge; then
  afk::log "skipping merge (already completed)"
else
  run_phase merge "PR_NUMBER=$PR_NUMBER"
  if (( PHASE_RC != 0 )); then
    afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
    exit "$PHASE_RC"
  fi
  afk::state_phase_mark_completed "$ISSUE" merge
fi

# === post-merge cleanup === (idempotent label edits)
afk::state_set "$ISSUE" status "done"
afk::tracker::issue_remove_label "$ISSUE" "$INPROG_LBL"
afk::tracker::issue_remove_label "$ISSUE" "$BLOCKED_LBL"
afk::tracker::issue_add_label    "$ISSUE" "$DONE_LBL"
afk::worktree_remove "$ISSUE"
afk::log "issue #$ISSUE merged and cleaned up."
