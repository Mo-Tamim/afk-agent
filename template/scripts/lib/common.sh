#!/usr/bin/env bash
# Shared bash helpers for the AFK orchestrator.
# Sourced by every other script in .afk/scripts/.

set -euo pipefail

# Resolve repo root (the directory containing .afk/) regardless of cwd.
# This file lives at .afk/scripts/lib/common.sh, so the repo root is three
# levels up: lib → scripts → .afk → <repo>.
AFK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AFK_DIR="$AFK_ROOT/.afk"
AFK_LOGS="$AFK_DIR/logs"
AFK_STATE="$AFK_DIR/state"
AFK_WORKTREES="$AFK_DIR/worktrees"

mkdir -p "$AFK_LOGS" "$AFK_STATE" "$AFK_WORKTREES"

# Read a scalar from config.yml. Tiny grep-based parser; no dep on yq.
# Supports top-level scalar keys (e.g. `repo: foo/bar`), not nested maps.
afk::config() {
  local key="$1"
  local default="${2:-}"
  local val
  val="$(grep -E "^${key}:" "$AFK_DIR/config.yml" 2>/dev/null \
          | head -n1 | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^['\"]//; s/['\"]$//" || true)"
  if [[ -z "$val" ]]; then val="$default"; fi
  printf '%s' "$val"
}

# Read a nested scalar like `labels.in_progress` from config.yml.
# Walks `<parent>:` then `  <child>:` (2-space indent).
afk::config_nested() {
  local parent="$1" child="$2" default="${3:-}"
  local val
  val="$(awk -v p="$parent:" -v c="$child:" '
    $0 ~ "^"p"$" { in_parent=1; next }
    in_parent && /^[^[:space:]]/ { in_parent=0 }
    in_parent && $1 == c { sub(/^[[:space:]]+[^:]+:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); print; exit }
  ' "$AFK_DIR/config.yml" 2>/dev/null || true)"
  if [[ -z "$val" ]]; then val="$default"; fi
  printf '%s' "$val"
}

# Logging helpers — every line gets a UTC timestamp + level + scope.
afk::log()   { printf '%s [INFO ] [%s] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AFK_SCOPE:-afk}" "$*" >&2; }
afk::warn()  { printf '%s [WARN ] [%s] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AFK_SCOPE:-afk}" "$*" >&2; }
afk::error() { printf '%s [ERROR] [%s] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AFK_SCOPE:-afk}" "$*" >&2; }
afk::die()   { afk::error "$*"; exit 1; }

# Verify required tools exist on PATH.
afk::require() {
  local missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    afk::die "missing required tool(s): ${missing[*]}"
  fi
}

# Render a {{KEY}} template file to stdout.
# Args: <template-path> <key> <val> [<key> <val>]...
afk::render() {
  local tpl="$1"; shift
  local content
  content="$(cat "$tpl")"
  while (( "$#" >= 2 )); do
    local k="$1" v="$2"; shift 2
    content="${content//\{\{$k\}\}/$v}"
  done
  printf '%s' "$content"
}

# Notify-developer wrapper. Stays a no-op if the skill isn't installed.
# Looks in two standard locations; users can override AFK_NOTIFY_START.
afk::notify() {
  local kind="${1:-attention}" reason="${2:-}"
  local script="${AFK_NOTIFY_START:-}"
  if [[ -z "$script" ]]; then
    for cand in \
      "$HOME/.cursor/skills/notify-developer/scripts/start.sh" \
      "$HOME/.claude/skills/notify-developer/scripts/start.sh" \
      "$HOME/.agents/skills/notify-developer/scripts/start.sh"; do
      [[ -x "$cand" ]] && { script="$cand"; break; }
    done
  fi
  if [[ -n "$script" && -x "$script" ]]; then
    "$script" "$kind" >/dev/null 2>&1 || true
    afk::warn "notify-developer ($kind) started: $reason"
  else
    afk::warn "notify-developer not installed; would have alerted: $kind — $reason"
  fi
}

afk::notify_stop() {
  local script="${AFK_NOTIFY_STOP:-}"
  if [[ -z "$script" ]]; then
    for cand in \
      "$HOME/.cursor/skills/notify-developer/scripts/stop.sh" \
      "$HOME/.claude/skills/notify-developer/scripts/stop.sh" \
      "$HOME/.agents/skills/notify-developer/scripts/stop.sh"; do
      [[ -x "$cand" ]] && { script="$cand"; break; }
    done
  fi
  if [[ -n "$script" && -x "$script" ]]; then
    "$script" >/dev/null 2>&1 || true
  fi
}

# Append a structured event to .afk/logs/events.ndjson.
#
# This is the on-disk telemetry stream the dashboard consumes. The format
# is one JSON object per line, opt-in for the dashboard but tolerated by
# every other script (we never read this file from bash).
#
# Args: <kind> [k1 v1] [k2 v2] ...
#
# Reserved fields injected automatically:
#   ts       — UTC ISO 8601 with millis
#   ts_epoch — float seconds since epoch (cheap to filter on)
#   kind     — first argument
#   scope    — $AFK_SCOPE if set (otherwise "afk")
#   pid      — emitting bash PID
#
# Best-effort: any failure (jq missing, disk full, file locked, …) is
# silenced. Telemetry MUST NOT change script behavior.
afk::telemetry::emit() {
  local kind="${1:-event}"; shift || true
  local file="$AFK_LOGS/events.ndjson"
  [[ -d "$AFK_LOGS" ]] || return 0

  local ts ts_epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  ts_epoch="$(date +%s.%N 2>/dev/null || date +%s)"

  # Prefer jq for safety (proper escaping), fall back to hand-rolled JSON.
  if command -v jq >/dev/null 2>&1; then
    local -a jq_args=(-n -c
      --arg ts "$ts" --arg ts_epoch "$ts_epoch"
      --arg kind "$kind" --arg scope "${AFK_SCOPE:-afk}" --arg pid "$$")
    local jq_obj='{ts:$ts, ts_epoch:($ts_epoch|tonumber? // null), kind:$kind, scope:$scope, pid:($pid|tonumber)}'
    while (( $# >= 2 )); do
      local k="$1" v="$2"; shift 2
      jq_args+=(--arg "kv_$k" "$v")
      jq_obj+=" | .[\"$k\"] = \$kv_$k"
    done
    jq "${jq_args[@]}" "$jq_obj" >> "$file" 2>/dev/null || true
  else
    # Hand-rolled fallback. Only handles simple scalars; complex strings
    # may produce invalid JSON, which the dashboard parses leniently
    # (drops bad lines).
    local kvs=""
    while (( $# >= 2 )); do
      local k="$1" v="$2"; shift 2
      v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
      v="${v//$'\n'/\\n}"; v="${v//$'\t'/\\t}"
      kvs+=",\"$k\":\"$v\""
    done
    printf '{"ts":"%s","ts_epoch":%s,"kind":"%s","scope":"%s","pid":%s%s}\n' \
      "$ts" "$ts_epoch" "$kind" "${AFK_SCOPE:-afk}" "$$" "$kvs" \
      >> "$file" 2>/dev/null || true
  fi
}

# Slug helper: title → kebab, lowercase, ascii, ≤ 50 chars.
afk::slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-50 \
    | sed 's/-$//'
}
