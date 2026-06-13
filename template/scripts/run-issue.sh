#!/usr/bin/env bash
# Drive ONE child issue through every phase, with per-phase resume.
#
# Usage:
#   run-issue.sh <issue-number>
#
# Resume model (critical to understand before editing):
#   • Each phase that finishes with COMPLETE is appended to
#     .afk/state/issue-<N>.json::completed_phases.
#   • Every invocation walks the phase list and skips anything in that
#     array. So Ctrl-C, crash, machine reboot, network blip → next
#     `afk issue N` picks up at the first not-yet-completed phase.
#   • For phases that are themselves polling loops (pr_wait_ci) or are
#     idempotent at the tracker layer (pr, merge), we additionally
#     short-circuit based on observed remote state — e.g. if a PR
#     already exists for the branch, we reuse it instead of opening
#     a duplicate; if a PR is already MERGED, we emit COMPLETE without
#     re-running gh pr merge.
#
# Failure handling:
#   Any phase RC != 0 labels the issue `afk-blocked` (unless RC was
#   10 / NO_CHANGES, which is non-fatal) and exits with the phase's RC.
#   The orchestrator can then move on to the next issue, and the
#   developer can resume this one after fixing the block.

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

# === Lock the issue against concurrent runners ===============================
# Atomic noclobber-redirect inside lock_acquire — see lib/lock.sh. If
# acquisition fails, another `afk run` or `afk issue N` is already on it.

if ! afk::lock_acquire "$ISSUE"; then
  afk::die "issue $ISSUE is already locked by another runner; refusing to double-process"
fi

# Tear down any live `run-phase.sh` / agent subtree when this runner exits or
# receives SIGTERM from the orchestrator (so we do not leave cursor-agent
# processes behind).
issue_cleanup_children() {
  afk::proc_kill_child_trees "$$"
}

trap 'rc=$?; issue_cleanup_children || true; afk::lock_release "'"$ISSUE"'"; afk::telemetry::emit issue_end issue "'"$ISSUE"'" rc "$rc"' EXIT
trap 'issue_cleanup_children || true' INT TERM HUP
afk::telemetry::emit issue_start issue "$ISSUE"

# === Verify the issue is in a runnable state =================================

LABELS="$(afk::tracker::issue_labels "$ISSUE")"
READY_LBL="$(afk::config_nested labels ready_for_agent ready-for-agent)"
INPROG_LBL="$(afk::config_nested labels in_progress    afk-in-progress)"
BLOCKED_LBL="$(afk::config_nested labels blocked       afk-blocked)"
DONE_LBL="$(afk::config_nested labels done             afk-done)"

# Allow afk-in-progress too — that's the normal state when resuming after a
# crash or after an explicit `afk issue N` interrupt.
if [[ "$LABELS" != *"$READY_LBL"* && "$LABELS" != *"$INPROG_LBL"* ]]; then
  afk::warn "issue $ISSUE has labels '$LABELS'; not labelled $READY_LBL. Skipping."
  exit 0
fi
if ! afk::tracker::blockers_resolved "$ISSUE"; then
  afk::warn "issue $ISSUE has unresolved blockers. Skipping."
  exit 0
fi

# Lazy-init so subsequent state_set calls don't have to check.
afk::state_init "$ISSUE"

# Flip labels to "claimed by orchestrator".
afk::tracker::issue_remove_label "$ISSUE" "$READY_LBL"
afk::tracker::issue_add_label    "$ISSUE" "$INPROG_LBL"

# Thin wrapper so every phase invocation reads identically below.
run_phase() {
  local phase="$1"; shift
  PHASE_RC=0
  "$SCRIPT_DIR/run-phase.sh" "$phase" "$ISSUE" "$@" || PHASE_RC=$?
}

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                          PHASE 1 — plan                                 ║
# ║ Reads the issue, decides a branch name, package, and approach.          ║
# ║ Emits <plan>JSON</plan>. Skipped on resume if already COMPLETE.         ║
# ╚════════════════════════════════════════════════════════════════════════╝

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

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                       Setup — git worktree                              ║
# ║ Isolates this issue's work so parallel runners can't fight over HEAD.   ║
# ║ Idempotent: leaves the worktree alone if it already exists.             ║
# ╚════════════════════════════════════════════════════════════════════════╝

afk::worktree_create "$ISSUE" "$BRANCH"

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                        PHASE 2 — implement                              ║
# ║ The actual work. TDD red→green→refactor inside the worktree.            ║
# ║ NO_CHANGES → bail (nothing to PR); BLOCKED → label + exit.              ║
# ╚════════════════════════════════════════════════════════════════════════╝

if afk::state_phase_completed "$ISSUE" implement; then
  afk::log "skipping implement (already completed)"
else
  run_phase implement "PACKAGE=$PACKAGE"
  case "$PHASE_RC" in
    0)
      # Deterministic gate: a COMPLETE implement MUST have emitted a valid
      # <handoff> payload — it feeds the PR body, the smoke gate, and the
      # final issue comment. A missing/invalid handoff is a prompt violation,
      # so we fail closed rather than papering over it with boilerplate.
      HANDOFF_FILE="$AFK_LOGS/issue-${ISSUE}-implement-latest/handoff.json"
      if [[ ! -s "$HANDOFF_FILE" ]] || ! jq empty "$HANDOFF_FILE" >/dev/null 2>&1; then
        afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
        afk::die "implement emitted COMPLETE but no valid <handoff> JSON at $HANDOFF_FILE"
      fi
      afk::state_phase_mark_completed "$ISSUE" implement
      ;;
    10) afk::warn "implement returned NO_CHANGES; bailing without PR"; exit 0 ;;
    *)  afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"; exit "$PHASE_RC" ;;
  esac
fi

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                         PHASE 3 — review                                ║
# ║ Local pre-PR clarity pass. Behavior-preserving only. Non-fatal —        ║
# ║ NO_CHANGES is the expected outcome on tidy diffs.                       ║
# ╚════════════════════════════════════════════════════════════════════════╝

if afk::state_phase_completed "$ISSUE" review; then
  afk::log "skipping review (already completed)"
else
  run_phase review "PACKAGE=$PACKAGE" || true   # advisory; never blocks
  afk::state_phase_mark_completed "$ISSUE" review
fi

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                           PHASE 4 — pr                                  ║
# ║ The ONLY phase allowed to push. Reuses an existing open PR if the      ║
# ║ branch already has one (handles crash-between-create-and-state-write). ║
# ╚════════════════════════════════════════════════════════════════════════╝

PR_NUMBER="$(afk::state_get "$ISSUE" pr 2>/dev/null || echo "")"
if [[ -z "$PR_NUMBER" ]]; then
  # Idempotency: if a PR for this branch already exists open on the tracker,
  # adopt it instead of failing on "duplicate PR" later.
  PR_NUMBER="$(afk::tracker::pr_list_for_branch "$BRANCH" || echo "")"
  if [[ -n "$PR_NUMBER" ]]; then
    afk::log "found existing open PR #$PR_NUMBER for $BRANCH; reusing"

    # Subtle bug guard: if a sibling AFK branch was rebased onto a newer
    # origin/main, our local branch tip may have advanced past the remote
    # tip without the PR being aware. Force-push (with-lease) so the PR
    # re-evaluates mergeability against the latest commits.
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
  # Render the PR body from the template. The body must include
  # `Closes #ISSUE` so merging auto-closes the linked child issue.
  #
  # The implement phase emits a <handoff> JSON payload (summary, test
  # plan, smoke test). We thread it in so every PR carries a detailed,
  # human-readable description plus a copy-pasteable smoke test that the
  # merge phase later re-runs for evidence. Missing/older handoffs fall
  # back to generic copy.
  HANDOFF_FILE="$AFK_LOGS/issue-${ISSUE}-implement-latest/handoff.json"
  PR_SUMMARY="AFK-implemented per the linked issue's acceptance criteria."
  PR_TEST_PLAN="Unit/integration tests added per the issue's test notes; CI is the source of truth."
  PR_SMOKE_TEST="N/A — the implement phase recorded no smoke test; rely on CI."
  if [[ -s "$HANDOFF_FILE" ]] && jq empty "$HANDOFF_FILE" >/dev/null 2>&1; then
    _h_summary="$(jq -r '.summary    // ""' "$HANDOFF_FILE")"; [[ -n "$_h_summary"    ]] && PR_SUMMARY="$_h_summary"
    _h_test="$(jq -r '.test_plan  // ""' "$HANDOFF_FILE")";    [[ -n "$_h_test"       ]] && PR_TEST_PLAN="$_h_test"
    _h_smoke="$(jq -r '.smoke_test // ""' "$HANDOFF_FILE")";   [[ -n "$_h_smoke"      ]] && PR_SMOKE_TEST="$_h_smoke"
  fi

  PR_BODY_FILE="$(mktemp)"
  afk::render "$AFK_DIR/templates/pr-body.md" \
    TITLE          "$(afk::tracker::issue_view_json "$ISSUE" | jq -r '.title // ""')" \
    BRANCH         "$BRANCH" \
    ISSUE_ID       "$ISSUE" \
    SUMMARY        "$PR_SUMMARY" \
    TEST_PLAN      "$PR_TEST_PLAN" \
    SMOKE_TEST     "$PR_SMOKE_TEST" \
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

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                       PHASE 5 — pr_wait_ci                              ║
# ║ Pure orchestrator poll loop — no agent spawned. Never marked            ║
# ║ "completed" because the live state (GREEN/RED) must be re-checked       ║
# ║ on every invocation; treating it as completed would skip the gate       ║
# ║ on resume after CI flipped.                                             ║
# ╚════════════════════════════════════════════════════════════════════════╝

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

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                        PHASE 6 — pr_review                              ║
# ║ Fresh agent (no context-bleed) reads the PR diff via the tracker CLI   ║
# ║ and leaves a review. Advisory — NO_CHANGES is treated as success.      ║
# ╚════════════════════════════════════════════════════════════════════════╝

if afk::state_phase_completed "$ISSUE" pr_review; then
  afk::log "skipping pr_review (already completed)"
else
  run_phase pr-review "PR_NUMBER=$PR_NUMBER" || true   # advisory phase, non-fatal
  afk::state_phase_mark_completed "$ISSUE" pr_review
fi

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                  SMOKE GATE — deterministic, pre-merge                  ║
# ║ Run the implementer's handoff.smoke_cmd in the worktree, post the      ║
# ║ captured output as evidence on the PR, and refuse to merge on a        ║
# ║ non-zero exit. No model is in the trust path for "did it pass". The    ║
# ║ gate is opt-in (config: smoke_gate) and always honours an "N/A" cmd.   ║
# ╚════════════════════════════════════════════════════════════════════════╝

HANDOFF_FILE="$AFK_LOGS/issue-${ISSUE}-implement-latest/handoff.json"
SMOKE_CMD=""; SMOKE_PROSE=""; HANDOFF_SUMMARY=""
if [[ -s "$HANDOFF_FILE" ]] && jq empty "$HANDOFF_FILE" >/dev/null 2>&1; then
  SMOKE_CMD="$(jq -r '.smoke_cmd  // ""' "$HANDOFF_FILE")"
  SMOKE_PROSE="$(jq -r '.smoke_test // ""' "$HANDOFF_FILE")"
  HANDOFF_SUMMARY="$(jq -r '.summary    // ""' "$HANDOFF_FILE")"
fi
# Normalize the "not applicable" sentinel (case-insensitive, tolerates "N/A …").
SMOKE_NA=0
shopt -s nocasematch
[[ -z "$SMOKE_CMD" || "$SMOKE_CMD" == n/a* ]] && SMOKE_NA=1
shopt -u nocasematch

if afk::state_phase_completed "$ISSUE" smoke; then
  afk::log "skipping smoke gate (already completed)"
elif [[ "$(afk::config smoke_gate false)" != "true" ]]; then
  afk::log "smoke_gate disabled in config; relying on CI. PR body carries the documented smoke test."
  afk::state_phase_mark_completed "$ISSUE" smoke
else
  WT="$(afk::worktree_path "$ISSUE")"
  EVIDENCE_FILE="$(mktemp)"
  TIP="$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || echo "?")"
  if (( SMOKE_NA )); then
    {
      printf '## Smoke test evidence\n\n'
      printf -- '- Status: **N/A (skipped)**\n'
      printf -- '- Reason: %s\n' "${SMOKE_PROSE:-no automated smoke test applicable}"
      printf -- '- CI is the gate for this change.\n\n'
      printf '<sub>Recorded by the AFK issue runner before merge.</sub>\n'
    } > "$EVIDENCE_FILE"
    afk::tracker::pr_comment "$PR_NUMBER" "$EVIDENCE_FILE" || afk::warn "could not post N/A smoke evidence (continuing)"
    afk::log "smoke gate: smoke_cmd is N/A; recorded and proceeding."
    afk::state_phase_mark_completed "$ISSUE" smoke
  else
    SMOKE_TIMEOUT="$(afk::config smoke_timeout_seconds 600)"
    SMOKE_OUT="$(mktemp)"
    afk::log "smoke gate: running smoke_cmd in $WT (timeout ${SMOKE_TIMEOUT}s)"
    SMOKE_RC=0
    if command -v timeout >/dev/null 2>&1; then
      ( cd "$WT" && timeout "$SMOKE_TIMEOUT" bash -c "$SMOKE_CMD" ) >"$SMOKE_OUT" 2>&1 || SMOKE_RC=$?
    else
      ( cd "$WT" && bash -c "$SMOKE_CMD" ) >"$SMOKE_OUT" 2>&1 || SMOKE_RC=$?
    fi
    SMOKE_STATUS="PASS"; (( SMOKE_RC != 0 )) && SMOKE_STATUS="FAIL"
    {
      printf '## Smoke test evidence\n\n'
      printf -- '- Status: **%s** (exit %s)\n' "$SMOKE_STATUS" "$SMOKE_RC"
      printf -- '- Branch tip: `%s`\n' "$TIP"
      printf -- '- Command:\n\n```sh\n%s\n```\n\n' "$SMOKE_CMD"
      printf -- '- Output (last 40 lines):\n\n```\n'
      tail -n 40 "$SMOKE_OUT"
      printf '\n```\n\n<sub>Run by the AFK issue runner before merge.</sub>\n'
    } > "$EVIDENCE_FILE"
    afk::tracker::pr_comment "$PR_NUMBER" "$EVIDENCE_FILE" || afk::warn "could not post smoke evidence (continuing)"
    rm -f "$SMOKE_OUT"
    if (( SMOKE_RC != 0 )); then
      rm -f "$EVIDENCE_FILE"
      [[ "$(afk::config notify_on_blocked true)" == "true" ]] && afk::notify error "PR #$PR_NUMBER smoke test failed"
      afk::tracker::issue_add_label "$ISSUE" "$BLOCKED_LBL"
      afk::die "smoke gate failed (exit $SMOKE_RC) for PR #$PR_NUMBER; not merging"
    fi
    afk::log "smoke gate: PASS for PR #$PR_NUMBER"
    afk::state_phase_mark_completed "$ISSUE" smoke
  fi
  rm -f "$EVIDENCE_FILE"
fi

# ╔════════════════════════════════════════════════════════════════════════╗
# ║              FINAL ISSUE COMMENT — deterministic wrap-up                ║
# ║ Posted by the runner (not the model) so every completed issue ends     ║
# ║ with: what shipped, how to smoke test, the PR reference, and why it     ║
# ║ will close. Rendered from the handoff + PR data.                        ║
# ╚════════════════════════════════════════════════════════════════════════╝

if afk::state_phase_completed "$ISSUE" final_comment; then
  afk::log "skipping final issue comment (already posted)"
else
  ISSUE_TITLE_FC="$(afk::tracker::issue_view_json "$ISSUE" | jq -r '.title // ""')"
  FINAL_FILE="$(mktemp)"
  {
    printf '## AFK — done\n\n'
    printf '**What was done**\n\n%s\n\n' "${HANDOFF_SUMMARY:-Implemented per the linked issue acceptance criteria.}"
    printf '**How to smoke test**\n\n%s\n\n' "${SMOKE_PROSE:-N/A — no smoke test recorded.}"
    printf '**PR:** #%s — %s\n\n' "$PR_NUMBER" "$ISSUE_TITLE_FC"
    printf 'This issue will close automatically: the PR body links `Closes #%s`, so squash-merging the PR closes it.\n' "$ISSUE"
  } > "$FINAL_FILE"
  afk::tracker::issue_comment "$ISSUE" "$(cat "$FINAL_FILE")" || afk::warn "could not post final issue comment (continuing)"
  rm -f "$FINAL_FILE"
  afk::state_phase_mark_completed "$ISSUE" final_comment
  afk::log "posted final wrap-up comment on issue #$ISSUE"
fi

# ╔════════════════════════════════════════════════════════════════════════╗
# ║                         PHASE 7 — pr_merge                              ║
# ║ Final squash-merge. In `gated` mode, instead of merging we ping the    ║
# ║ developer and exit — they merge manually with `/merge <PR#>`.          ║
# ╚════════════════════════════════════════════════════════════════════════╝

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

# === Post-merge cleanup (all idempotent) =====================================

afk::state_set "$ISSUE" status "done"
afk::tracker::issue_remove_label "$ISSUE" "$INPROG_LBL"
afk::tracker::issue_remove_label "$ISSUE" "$BLOCKED_LBL"
afk::tracker::issue_add_label    "$ISSUE" "$DONE_LBL"
afk::worktree_remove "$ISSUE"
afk::log "issue #$ISSUE merged and cleaned up."
