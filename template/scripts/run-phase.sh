#!/usr/bin/env bash
# Run a single phase of an issue's lifecycle.
# Usage: run-phase.sh <phase> <issue> [extra-vars...]
#
# Returns:
#   0  COMPLETE
#  10  NO_CHANGES
#  20  BLOCKED
#  30  agent crashed (no sentinel)

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

PROMPT_TPL="$AFK_DIR/prompts/${PHASE}-prompt.md"
[[ -f "$PROMPT_TPL" ]] || afk::die "no prompt template for phase '$PHASE' at $PROMPT_TPL"

PROMPT_OUT="$LOG_DIR/${PHASE}.prompt.md"

WORKTREE="$(afk::worktree_path "$ISSUE")"
BRANCH="$(afk::state_get "$ISSUE" branch 2>/dev/null || echo "")"
ISSUE_TITLE="$(afk::tracker::issue_view_json "$ISSUE" | jq -r '.title')"

# Pass-through extra vars: each "K=V" pair becomes a render arg.
declare -a EXTRA_ARGS=()
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  EXTRA_ARGS+=("$k" "$v")
done

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

# Decide cwd for the agent process: most phases run inside the worktree,
# decompose/plan run at repo root because there is no branch yet.
case "$PHASE" in
  decompose|plan) CWD="$AFK_ROOT" ;;
  *)              CWD="$WORKTREE" ;;
esac
[[ -d "$CWD" ]] || afk::die "cwd does not exist: $CWD"

AGENT_BIN="$(afk::config agent_bin cursor-agent)"
AGENT_FLAGS="$(afk::config agent_flags '--print --force')"
afk::require "$AGENT_BIN" jq git "$AFK_TRACKER_CLI"

LOG="$LOG_DIR/${PHASE}.log"
afk::log "spawning $AGENT_BIN in $CWD; log: $LOG"

# shellcheck disable=SC2086
( cd "$CWD" && $AGENT_BIN $AGENT_FLAGS < "$PROMPT_OUT" ) > "$LOG" 2>&1 &
AGENT_PID=$!

# Wall-clock timeout: kill the agent if it stalls.
TIMEOUT="$(afk::config issue_timeout_seconds 7200)"
if [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && (( TIMEOUT > 0 )); then
  ( sleep "$TIMEOUT" && kill -0 "$AGENT_PID" 2>/dev/null && kill "$AGENT_PID" 2>/dev/null && \
      afk::warn "agent killed after ${TIMEOUT}s timeout" ) &
  TIMEOUT_PID=$!
fi

wait "$AGENT_PID" || true
[[ -n "${TIMEOUT_PID:-}" ]] && kill "$TIMEOUT_PID" 2>/dev/null || true

OUTCOME="$(afk::sentinel "$LOG")"
case "$OUTCOME" in
  COMPLETE)   afk::log "phase $PHASE → COMPLETE";   RC=0  ;;
  NO_CHANGES) afk::log "phase $PHASE → NO_CHANGES"; RC=10 ;;
  BLOCKED)
    REASON="$(afk::blocked_reason "$LOG")"
    afk::warn "phase $PHASE → BLOCKED: ${REASON:-(no reason)}"
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

# Persist payload blocks for downstream phases.
case "$PHASE" in
  plan)       afk::payload "$LOG" plan      > "$LOG_DIR/plan.json"     2>/dev/null || true ;;
  decompose)  afk::payload "$LOG" children  > "$LOG_DIR/children.json" 2>/dev/null || true ;;
  pr)         afk::payload "$LOG" pr        > "$LOG_DIR/pr.json"       2>/dev/null || true ;;
esac

# Stamp the "latest" pointer for the orchestrator. `-n` (no-dereference)
# replaces an existing symlink rather than creating one inside it.
LATEST_LINK="$AFK_LOGS/issue-${ISSUE}-${PHASE}-latest"
ln -sfn "$LOG_DIR" "$LATEST_LINK"

afk::state_history_append "$ISSUE" "$PHASE" "$OUTCOME" "" || \
  afk::warn "could not record $OUTCOME state for issue $ISSUE (continuing)"
exit "$RC"
