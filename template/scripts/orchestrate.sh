#!/usr/bin/env bash
# Parallel orchestrator. Picks unblocked AFK child issues from the tracker
# and runs them concurrently up to `max_parallel`.
#
# Design notes:
#   • The pool is just a `&` job set guarded by a bash associative array
#     (PID → issue#). No external coordinator. No daemon.
#   • Picking is *pull-based*: every time a slot opens we re-query the
#     tracker for the next ready+unblocked child. This means picks reflect
#     fresh tracker state (e.g. a blocker just closed) on every cycle.
#   • Per-issue locking lives in lib/lock.sh, not here. Multiple `afk run`
#     processes can race on the same issue and the noclobber-redirect
#     lock guarantees only one wins.
#
# Usage:
#   orchestrate.sh                # process every ready child issue, forever
#   orchestrate.sh --once         # one batch then exit (CI-friendly)
#   orchestrate.sh --prd <N>      # only children of PRD #N

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/tracker.sh"
. "$SCRIPT_DIR/lib/lock.sh"

AFK_SCOPE="orchestrate"
afk::require jq git "$AFK_TRACKER_CLI"

# Pre-flight the agent runner — every spawned issue runner would otherwise
# crash with a less helpful error mid-phase.
AGENT_BIN="$(afk::config agent_bin cursor-agent)"
afk::require "$AGENT_BIN"

afk::telemetry::emit orchestrator_start \
  max_parallel "$(afk::config max_parallel 3)" \
  tracker "${TRACKER:-?}" repo "${REPO:-?}"
trap 'afk::telemetry::emit orchestrator_exit reason=trap; exit' INT TERM

# === Args ====================================================================

ONCE=0
PRD_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)  ONCE=1; shift ;;
    --prd)   PRD_FILTER="$2"; shift 2 ;;
    *)       afk::die "unknown arg: $1" ;;
  esac
done

MAX_PARALLEL="$(afk::config max_parallel 3)"
afk::log "max parallel = $MAX_PARALLEL; once=$ONCE; prd-filter=${PRD_FILTER:-(none)}"

READY_LBL="$(afk::config_nested labels ready_for_agent ready-for-agent)"
BLOCKED_LBL="$(afk::config_nested labels blocked       afk-blocked)"
HUMAN_LBL="$(afk::config_nested labels needs_human     needs-human)"

# === Batch picker ============================================================
# Returns the unblocked, ready, non-human-required, non-locked issues, in
# tracker order. We then take the first one (the next slot's pick).

afk::pick_batch() {
  local -a candidates=()
  while IFS=$'\t' read -r n title; do
    [[ -z "$n" ]] && continue
    afk::lock_held "$n" && continue
    local labels
    labels="$(afk::tracker::issue_labels "$n")"
    [[ "$labels" == *"$READY_LBL"* ]] || continue
    [[ "$labels" == *"$BLOCKED_LBL"* ]] && continue
    [[ "$labels" == *"$HUMAN_LBL"* ]] && continue
    if [[ -n "$PRD_FILTER" ]]; then
      # Body grep is approximate; the orchestrator only uses this for
      # filtering — the per-issue `Blocked by:` parser is precise.
      local body
      case "$TRACKER" in
        github) body="$(gh   issue view "$n" -R "$REPO" --json body --jq '.body')" ;;
        gitlab) body="$(glab issue view "$n" -R "$REPO" --output json | jq -r '.description // .body // ""')" ;;
      esac
      grep -qE "(Parent:[[:space:]]*#${PRD_FILTER}\b|#${PRD_FILTER}\b)" <<<"$body" || continue
    fi
    afk::tracker::blockers_resolved "$n" || continue
    candidates+=("$n")
  done < <(afk::tracker::open_afk_children)
  printf '%s\n' "${candidates[@]}"
}

# === Pool bookkeeping ========================================================
# Bash associative array of PID → issue#. `declare -A x=()` is intentional —
# without an explicit assignment, `${#x[@]}` is unsafe under `set -u` on
# some bash builds.

declare -A INFLIGHT=()

reap_one() {
  local pid="$1" rc=0 issue="${INFLIGHT[$pid]}"
  if wait "$pid"; then
    afk::log "issue ${issue} finished cleanly"
  else
    rc=$?
    afk::warn "issue ${issue} exited non-zero (rc=$rc)"
  fi
  afk::telemetry::emit runner_reap issue "$issue" runner_pid "$pid" rc "$rc"
  unset 'INFLIGHT[$pid]'
}

reap_any() {
  # Sweep all known PIDs; remove the dead ones. Lighter-weight than `wait -n`
  # for the "check before starting new work" path.
  local pid
  for pid in "${!INFLIGHT[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      reap_one "$pid"
    fi
  done
}

# === Main loop ===============================================================
# Fill the pool → wait for something to finish → repeat.
# Empty queue + empty pool → run the docs-gate scan, then sleep (or exit
# if --once).

while :; do
  reap_any
  while (( ${#INFLIGHT[@]} < MAX_PARALLEL )); do
    BATCH="$(afk::pick_batch)"
    [[ -z "$BATCH" ]] && break
    NEXT="$(echo "$BATCH" | head -n1)"
    afk::log "spawning runner for issue #$NEXT"
    "$SCRIPT_DIR/run-issue.sh" "$NEXT" >"$AFK_LOGS/issue-${NEXT}-runner.log" 2>&1 &
    INFLIGHT[$!]="$NEXT"
    afk::telemetry::emit runner_spawn issue "$NEXT" runner_pid "$!"
  done

  if (( ${#INFLIGHT[@]} == 0 )); then
    afk::log "no work in flight and queue empty"
    if (( ONCE )); then break; fi
    # Opportunistic: every idle pass, check if any PRD is ready to document.
    "$SCRIPT_DIR/document-gate.sh" || afk::warn "docs gate scan failed"
    sleep 60
    continue
  fi

  # Block until at least one runner finishes, then loop and refill.
  # `wait -n` waits for any background job; rc is ignored — we read it
  # per-PID in reap_any/reap_one.
  wait -n 2>/dev/null || true
  reap_any
done

afk::log "orchestrator exiting; in-flight runners drained."
afk::telemetry::emit orchestrator_exit reason=normal
