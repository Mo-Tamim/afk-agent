#!/usr/bin/env bash
# Per-issue state JSON, atomically updated.
# Schema:
#   { "issue": N, "branch": "...", "phase": "implement",
#     "status": "running"|"done"|"blocked", "pr": null|N,
#     "started_at": "...", "updated_at": "...", "history": [...],
#     "completed_phases": [...] }

afk::state_path() { printf '%s/issue-%s.json' "$AFK_STATE" "$1"; }

# Idempotent initializer. Safe to call repeatedly — only writes when missing.
afk::state_init() {
  local issue="$1" branch="${2:-}"
  local p; p="$(afk::state_path "$issue")"
  if [[ -f "$p" ]]; then return 0; fi
  jq -n --arg branch "$branch" --argjson issue "$issue" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {issue:$issue, branch:$branch, phase:null, status:"pending", pr:null,
     started_at:$now, updated_at:$now, history:[], completed_phases:[]}
  ' > "$p"
}

# True (rc=0) if the named phase is recorded as completed for this issue.
afk::state_phase_completed() {
  local issue="$1" phase="$2"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || return 1
  jq -e --arg phase "$phase" '.completed_phases // [] | index($phase) != null' "$p" >/dev/null 2>&1
}

# Mark a phase as completed. Idempotent — phase only added once.
afk::state_phase_mark_completed() {
  local issue="$1" phase="$2"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || afk::state_init "$issue"
  local tmp; tmp="$(mktemp)"
  jq --arg phase "$phase" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .completed_phases = ((.completed_phases // []) | (. + [$phase]) | unique_by(.))
    | .updated_at = $now
  ' "$p" > "$tmp"
  mv "$tmp" "$p"
}

# Reset a phase's completion flag (operator decided to redo).
afk::state_phase_clear_completed() {
  local issue="$1" phase="$2"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq --arg phase "$phase" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .completed_phases = ((.completed_phases // []) | map(select(. != $phase)))
    | .updated_at = $now
  ' "$p" > "$tmp"
  mv "$tmp" "$p"
}

# afk::state_set <issue> <key> <value>
afk::state_set() {
  local issue="$1" key="$2" value="$3"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || afk::state_init "$issue"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .[$k] = (try ($v|fromjson) catch $v) | .updated_at = $now
  ' "$p" > "$tmp"
  mv "$tmp" "$p"
}

# Returns empty string for missing file or missing key — no error.
afk::state_get() {
  local issue="$1" key="$2"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || { printf ''; return 0; }
  jq -r --arg k "$key" '.[$k] // empty' "$p"
}

afk::state_history_append() {
  local issue="$1" phase="$2" outcome="$3" note="${4:-}"
  local p; p="$(afk::state_path "$issue")"
  [[ -f "$p" ]] || afk::state_init "$issue"
  local tmp; tmp="$(mktemp)"
  jq --arg phase "$phase" --arg outcome "$outcome" --arg note "$note" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .history += [{phase:$phase, outcome:$outcome, note:$note, at:$now}]
    | .phase = $phase | .updated_at = $now
  ' "$p" > "$tmp"
  mv "$tmp" "$p"
}
