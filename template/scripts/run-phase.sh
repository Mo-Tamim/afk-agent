#!/usr/bin/env bash
# Run a single phase of an issue's lifecycle.
#
# Contract:
#   stdin to the spawned agent  = rendered phase prompt
#   stdout/stderr of the agent  = streamed to a timestamped log file
#   agent's last sentinel       = the only thing this script trusts
#
# Exit codes (run-issue.sh keys off these):
#   0   COMPLETE     — phase did its job, advance
#   10  NO_CHANGES   — phase had nothing to do (e.g. clean review pass)
#   20  BLOCKED      — phase cannot proceed; needs a human
#   30  (no sentinel)— agent crashed or stalled
#
# Usage:
#   run-phase.sh <phase> <issue> [K=V ...]
#
# The K=V tail is passed through to the prompt renderer as extra
# {{KEY}} substitutions on top of the standard set (ISSUE_ID, BRANCH, …).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/sentinel.sh"
. "$SCRIPT_DIR/lib/state.sh"
. "$SCRIPT_DIR/lib/tracker.sh"
. "$SCRIPT_DIR/lib/worktree.sh"

PHASE="${1:?phase required}"
ISSUE="${2:?issue required}"
shift 2 || true

AFK_SCOPE="phase:${PHASE}:#${ISSUE}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$AFK_LOGS/issue-${ISSUE}-${PHASE}-${RUN_ID}"
mkdir -p "$LOG_DIR"

# === 1. Locate the prompt template ===========================================
# Every phase has exactly one prompt at .afk/prompts/<phase>-prompt.md. The
# filename is the contract; adding a new phase = adding a new prompt file.

PROMPT_TPL="$AFK_DIR/prompts/${PHASE}-prompt.md"
[[ -f "$PROMPT_TPL" ]] || afk::die "no prompt template for phase '$PHASE' at $PROMPT_TPL"

PROMPT_OUT="$LOG_DIR/${PHASE}.prompt.md"

# === 2. Resolve standard variables ===========================================
# These are always injected. Phase-specific extras come in via the K=V tail.
# The agent reads these as inline header values inside the prompt body.

WORKTREE="$(afk::worktree_path "$ISSUE")"
BRANCH="$(afk::state_get "$ISSUE" branch 2>/dev/null || echo "")"
ISSUE_TITLE="$(afk::tracker::issue_view_json "$ISSUE" | jq -r '.title')"

declare -a EXTRA_ARGS=()
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  EXTRA_ARGS+=("$k" "$v")
done

# === 3. Render the prompt ====================================================

afk::render "$PROMPT_TPL" \
  ISSUE_ID         "$ISSUE" \
  ISSUE_TITLE      "$ISSUE_TITLE" \
  BRANCH           "$BRANCH" \
  REPO             "$REPO" \
  DEFAULT_BRANCH   "$DEFAULT_BRANCH" \
  WORKTREE         "$WORKTREE" \
  TRACKER          "$TRACKER" \
  "${EXTRA_ARGS[@]}" \
  > "$PROMPT_OUT"

# === 4. Pick the working directory ===========================================
# decompose / plan happen before a branch exists, so they run at repo root.
# Every other phase runs inside the issue's worktree so the agent's git
# commands target the right ref by default.

case "$PHASE" in
  decompose|plan) CWD="$AFK_ROOT" ;;
  *)              CWD="$WORKTREE" ;;
esac
[[ -d "$CWD" ]] || afk::die "cwd does not exist: $CWD"

# === 5. Resolve the agent runner =============================================
# agent_bin / agent_flags are config so users can swap cursor-agent for
# claude / codex / gh copilot / gemini without touching scripts.

AGENT_BIN="$(afk::config agent_bin cursor-agent)"
AGENT_FLAGS="$(afk::config agent_flags '--print --force')"
afk::require "$AGENT_BIN" jq git "$AFK_TRACKER_CLI"

LOG="$LOG_DIR/${PHASE}.log"
afk::log "spawning $AGENT_BIN in $CWD; log: $LOG"
PHASE_START_EPOCH="$(date +%s)"
afk::telemetry::emit phase_start \
  issue "$ISSUE" phase "$PHASE" branch "${BRANCH:-}" \
  cwd "$CWD" log "$LOG" run_id "$RUN_ID"

# PIDs registered in .afk/logs/subprocess-registry.ndjson for the dashboard.
# EXIT trap guarantees we never leave a timeout sentry or agent wrapper alive
# if this script is killed mid-wait (Cursor crash, orchestrator SIGTERM, …).
AGENT_PID=""
TIMEOUT_PID=""
AGENT_REG_DONE=0
TIMEOUT_REG_DONE=0

phase_registry_reap_agent() {
  (( AGENT_REG_DONE )) && return 0
  [[ -z "${AGENT_PID:-}" ]] && return 0
  AGENT_REG_DONE=1
  afk::registry::emit reap role phase_agent_wrapper pid "$AGENT_PID" issue "$ISSUE" \
    phase "$PHASE" run_id "$RUN_ID" || true
}

phase_registry_reap_timeout() {
  (( TIMEOUT_REG_DONE )) && return 0
  [[ -z "${TIMEOUT_PID:-}" ]] && return 0
  TIMEOUT_REG_DONE=1
  afk::registry::emit reap role phase_timeout_sentry pid "$TIMEOUT_PID" issue "$ISSUE" \
    phase "$PHASE" run_id "$RUN_ID" || true
}

phase_exit_cleanup() {
  if [[ -n "${TIMEOUT_PID:-}" ]]; then
    kill "$TIMEOUT_PID" 2>/dev/null || true
    phase_registry_reap_timeout
  fi
  if [[ -n "${AGENT_PID:-}" ]]; then
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      afk::warn "issue $ISSUE phase $PHASE: tearing down agent wrapper pid $AGENT_PID (+ subtree)"
      afk::proc_kill_descendants_of "$AGENT_PID"
      kill -TERM "$AGENT_PID" 2>/dev/null || true
    fi
    phase_registry_reap_agent
  fi
}

trap 'phase_exit_cleanup' EXIT

# === 6. Spawn the agent with a wall-clock watchdog ===========================
# The agent reads the prompt on stdin and streams to the log. We background
# it so we can attach a timeout sentry as a sibling process — bash's
# built-in `timeout` is not portable to every container.

# shellcheck disable=SC2086
( cd "$CWD" && $AGENT_BIN $AGENT_FLAGS < "$PROMPT_OUT" ) > "$LOG" 2>&1 &
AGENT_PID=$!
afk::registry::emit spawn role phase_agent_wrapper pid "$AGENT_PID" parent_pid "$$" \
  issue "$ISSUE" phase "$PHASE" run_id "$RUN_ID" agent_bin "$AGENT_BIN" || true
afk::telemetry::emit agent_spawn \
  issue "$ISSUE" phase "$PHASE" agent_pid "$AGENT_PID" \
  agent_bin "$AGENT_BIN"

TIMEOUT="$(afk::config issue_timeout_seconds 7200)"
if [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && (( TIMEOUT > 0 )); then
  # Sentry: if the agent is still alive when the timer expires, kill it.
  # If the agent finishes first, the sentry is harmless and gets reaped below.
  ( sleep "$TIMEOUT" && kill -0 "$AGENT_PID" 2>/dev/null && kill "$AGENT_PID" 2>/dev/null && \
      afk::warn "agent killed after ${TIMEOUT}s timeout" ) &
  TIMEOUT_PID=$!
  afk::registry::emit spawn role phase_timeout_sentry pid "$TIMEOUT_PID" parent_pid "$$" \
    issue "$ISSUE" phase "$PHASE" run_id "$RUN_ID" || true
fi

wait "$AGENT_PID" || true
if [[ -n "${TIMEOUT_PID:-}" ]]; then
  kill "$TIMEOUT_PID" 2>/dev/null || true
  phase_registry_reap_timeout
fi

# === 7. Classify the outcome from the sentinel ===============================
# We never parse prose. We grep for the three known <promise>X</promise>
# tags; missing sentinel == crashed agent (rc=30).

OUTCOME="$(afk::sentinel "$LOG")"
case "$OUTCOME" in
  COMPLETE)   afk::log "phase $PHASE → COMPLETE";   RC=0  ;;
  NO_CHANGES) afk::log "phase $PHASE → NO_CHANGES"; RC=10 ;;
  BLOCKED)
    REASON="$(afk::blocked_reason "$LOG")"
    afk::warn "phase $PHASE → BLOCKED: ${REASON:-(no reason)}"
    # State history is best-effort; never let a logging failure trump
    # the actual phase outcome.
    afk::state_history_append "$ISSUE" "$PHASE" "BLOCKED" "$REASON" || \
      afk::warn "could not record BLOCKED state for issue $ISSUE (continuing)"
    if [[ "$(afk::config notify_on_blocked true)" == "true" ]]; then
      afk::notify error "issue #$ISSUE blocked in $PHASE: ${REASON:-?}"
    fi
    RC=20
    ;;
  *)
    afk::error "phase $PHASE → no sentinel found (agent crashed?)"
    afk::notify error "issue #$ISSUE phase $PHASE crashed; check $LOG"
    RC=30
    ;;
esac

# === 8. Persist payload blocks for downstream phases =========================
# Some phases emit <tag>JSON</tag> alongside their sentinel. The next phase
# reads the extracted JSON from .../latest/<tag>.json — never from the log.

case "$PHASE" in
  plan)       afk::payload "$LOG" plan      > "$LOG_DIR/plan.json"     2>/dev/null || true ;;
  decompose)  afk::payload "$LOG" children  > "$LOG_DIR/children.json" 2>/dev/null || true ;;
  implement)  afk::payload "$LOG" handoff   > "$LOG_DIR/handoff.json"  2>/dev/null || true ;;
  pr)         afk::payload "$LOG" pr        > "$LOG_DIR/pr.json"       2>/dev/null || true ;;
esac

# === 9. Refresh the "latest" symlink =========================================
# `ln -sfn` replaces the link target instead of creating the new link inside
# an existing symlink-to-directory. Critical: without `-n`, the second run
# of any phase silently writes into the first run's log dir.

LATEST_LINK="$AFK_LOGS/issue-${ISSUE}-${PHASE}-latest"
ln -sfn "$LOG_DIR" "$LATEST_LINK"

afk::state_history_append "$ISSUE" "$PHASE" "$OUTCOME" "" || \
  afk::warn "could not record $OUTCOME state for issue $ISSUE (continuing)"
PHASE_END_EPOCH="$(date +%s)"
PHASE_DURATION=$(( PHASE_END_EPOCH - PHASE_START_EPOCH ))
afk::telemetry::emit phase_end \
  issue "$ISSUE" phase "$PHASE" outcome "$OUTCOME" rc "$RC" \
  duration_s "$PHASE_DURATION" log "$LOG" run_id "$RUN_ID"
exit "$RC"
