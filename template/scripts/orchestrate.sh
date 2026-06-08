#!/usr/bin/env bash
# Parallel orchestrator. Picks unblocked AFK child issues from the tracker
# and runs them concurrently up to `max_parallel`.
#
# Usage:
#   orchestrate.sh                # process every ready child issue
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

# Verify the agent runner exists; without it the runners would all crash.
AGENT_BIN="$(afk::config agent_bin cursor-agent)"
afk::require "$AGENT_BIN"

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

# Pick the next batch of issues that:
#  - are open
#  - have label afk-child
#  - have label ready-for-agent (not in-progress, not blocked)
#  - have all blockers closed
#  - if PRD_FILTER is set, mention the PRD in their body
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

# Track child PIDs and the issue each one is processing.
declare -A INFLIGHT=()

reap_one() {
  local pid="$1"
  if wait "$pid"; then
    afk::log "issue ${INFLIGHT[$pid]} finished cleanly"
  else
    afk::warn "issue ${INFLIGHT[$pid]} exited non-zero"
  fi
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

while :; do
  reap_any
  while (( ${#INFLIGHT[@]} < MAX_PARALLEL )); do
    BATCH="$(afk::pick_batch)"
    [[ -z "$BATCH" ]] && break
    NEXT="$(echo "$BATCH" | head -n1)"
    afk::log "spawning runner for issue #$NEXT"
    "$SCRIPT_DIR/run-issue.sh" "$NEXT" >"$AFK_LOGS/issue-${NEXT}-runner.log" 2>&1 &
    INFLIGHT[$!]="$NEXT"
  done

  if (( ${#INFLIGHT[@]} == 0 )); then
    afk::log "no work in flight and queue empty"
    if (( ONCE )); then break; fi
    # Check the docs gate before sleeping.
    "$SCRIPT_DIR/document-gate.sh" || afk::warn "docs gate scan failed"
    sleep 60
    continue
  fi

  # Wait for at least one to finish, then loop and refill.
  wait -n 2>/dev/null || true
  reap_any
done

afk::log "orchestrator exiting; in-flight runners drained."
