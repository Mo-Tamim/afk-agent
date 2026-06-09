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
#   • **Resume:** issues labelled `afk-in-progress` on the tracker (e.g.
#     after Cursor/terminal died mid-run) are valid picks *before* fresh
#     `ready-for-agent` work, so `afk run` continues the chain without a
#     manual `afk issue <N>`.
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
INPROG_LBL="$(afk::config_nested labels in_progress    afk-in-progress)"
BLOCKED_LBL="$(afk::config_nested labels blocked       afk-blocked)"
HUMAN_LBL="$(afk::config_nested labels needs_human     needs-human)"

# === Pool bookkeeping ========================================================
# Bash associative array of PID → issue#. `declare -A x=()` is intentional —
# without an explicit assignment, `${#x[@]}` is unsafe under `set -u` on
# some bash builds.

declare -A INFLIGHT=()

orch_stop_inflight_runners() {
  local pid issue rc
  local -a pids=()
  for pid in "${!INFLIGHT[@]}"; do
    [[ -z "$pid" ]] && continue
    pids+=("$pid")
  done
  for pid in "${pids[@]}"; do
    issue="${INFLIGHT[$pid]}"
    afk::warn "orchestrator stopping: SIGTERM to runner pid=$pid (issue #$issue)"
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    issue="${INFLIGHT[$pid]}"
    rc=0
    wait "$pid" 2>/dev/null || rc=$?
    afk::registry::emit reap role issue_runner pid "$pid" issue "$issue" rc "$rc" reason orchestrator_signal || true
    afk::telemetry::emit runner_reap issue "$issue" runner_pid "$pid" rc "$rc" reason signal
    unset 'INFLIGHT[$pid]'
  done
}

trap 'orch_stop_inflight_runners; afk::telemetry::emit orchestrator_exit reason=trap; exit' INT TERM

# === Batch picker ============================================================
# Returns unblocked, non-human-required, non-locked issues in tracker order,
# with two priority bands:
#   1) `afk-in-progress` only (or in-progress + ready — treated as resume)
#   2) `ready-for-agent` only (excluding numbers already listed in band 1)

afk::pick_batch() {
  local -a resume=() fresh=()
  declare -A seen=()
  while IFS=$'\t' read -r n title; do
    [[ -z "$n" ]] && continue
    afk::lock_held "$n" && continue
    local labels
    labels="$(afk::tracker::issue_labels "$n")"
    [[ "$labels" == *"$BLOCKED_LBL"* ]] && continue
    [[ "$labels" == *"$HUMAN_LBL"* ]] && continue
    if [[ -n "$PRD_FILTER" ]]; then
      local body
      case "$TRACKER" in
        github) body="$(gh   issue view "$n" -R "$REPO" --json body --jq '.body')" ;;
        gitlab) body="$(glab issue view "$n" -R "$REPO" --output json | jq -r '.description // .body // ""')" ;;
      esac
      grep -qE "(Parent:[[:space:]]*#${PRD_FILTER}\b|#${PRD_FILTER}\b)" <<<"$body" || continue
    fi
    afk::tracker::blockers_resolved "$n" || continue

    local inprog=0 ready=0
    [[ "$labels" == *"$INPROG_LBL"* ]] && inprog=1
    [[ "$labels" == *"$READY_LBL"* ]] && ready=1

    if (( inprog )); then
      resume+=("$n")
      seen["$n"]=1
    elif (( ready )); then
      fresh+=("$n")
    fi
  done < <(afk::tracker::open_afk_children)

  local i
  for i in "${resume[@]}"; do printf '%s\n' "$i"; done
  for i in "${fresh[@]}"; do
    [[ -n "${seen[$i]:-}" ]] && continue
    printf '%s\n' "$i"
  done
}

reap_one() {
  local pid="$1" rc=0 issue="${INFLIGHT[$pid]}"
  if wait "$pid"; then
    afk::log "issue ${issue} finished cleanly"
  else
    rc=$?
    afk::warn "issue ${issue} exited non-zero (rc=$rc)"
  fi
  afk::registry::emit reap role issue_runner pid "$pid" issue "$issue" rc "$rc" || true
  afk::telemetry::emit runner_reap issue "$issue" runner_pid "$pid" rc "$rc"
  unset 'INFLIGHT[$pid]'
}

reap_any() {
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
    labels="$(afk::tracker::issue_labels "$NEXT")"
    resume_flag=0
    if [[ "$labels" == *"$INPROG_LBL"* ]]; then
      resume_flag=1
      afk::log "resuming issue #$NEXT (tracker shows $INPROG_LBL — e.g. after crash or Ctrl-C)"
    else
      afk::log "spawning runner for issue #$NEXT"
    fi
    "$SCRIPT_DIR/run-issue.sh" "$NEXT" >"$AFK_LOGS/issue-${NEXT}-runner.log" 2>&1 &
    runner_pid=$!
    INFLIGHT[$runner_pid]="$NEXT"
    afk::registry::emit spawn role issue_runner pid "$runner_pid" issue "$NEXT" parent_pid "$$" \
      resume "$resume_flag" || true
    afk::telemetry::emit runner_spawn issue "$NEXT" runner_pid "$runner_pid" resume "$resume_flag"
  done

  if (( ${#INFLIGHT[@]} == 0 )); then
    afk::log "no work in flight and queue empty"
    if (( ONCE )); then break; fi
    "$SCRIPT_DIR/document-gate.sh" || afk::warn "docs gate scan failed"
    sleep 60
    continue
  fi

  wait -n 2>/dev/null || true
  reap_any
done

afk::log "orchestrator exiting; in-flight runners drained."
afk::telemetry::emit orchestrator_exit reason=normal
