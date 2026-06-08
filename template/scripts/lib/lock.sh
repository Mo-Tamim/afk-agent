#!/usr/bin/env bash
# Per-issue locking so two concurrent orchestrator runs don't grab the same
# issue.
#
# Acquire a lock for one issue. Returns 0 on success, 1 if already locked.
# Lock file lives at .afk/state/issue-<N>.lock and contains
# "<pid>:<host>:<iso-time>".
#
# Uses noclobber + redirect to create atomically: `set -C; > FILE` returns
# rc=1 without truncating if FILE exists. That removes the TOCTOU race
# between checking existence and writing the lock.

afk::lock_acquire() {
  local issue="$1"
  local lock="$AFK_STATE/issue-${issue}.lock"
  local payload; payload="$(printf '%s:%s:%s\n' "$$" "$(hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"

  if ( set -C; printf '%s\n' "$payload" > "$lock" ) 2>/dev/null; then
    return 0
  fi

  # File already exists — inspect ownership. Nested ifs (rather than `&&`)
  # avoid the `set -e` quirk where a failing command inside an `if` test
  # can still abort the surrounding function in some bash versions.
  local pid; pid="$(cut -d: -f1 "$lock" 2>/dev/null || echo)"
  if [[ -n "$pid" ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      return 1   # held by a live process
    fi
  fi

  afk::warn "stale lock detected on issue $issue (pid $pid not running); reclaiming"
  rm -f "$lock"
  if ( set -C; printf '%s\n' "$payload" > "$lock" ) 2>/dev/null; then
    return 0
  fi
  # Lost a race with another reclaim attempt — refuse rather than overwrite.
  return 1
}

afk::lock_release() {
  local issue="$1"
  rm -f "$AFK_STATE/issue-${issue}.lock"
}

afk::lock_held() {
  local issue="$1"
  [[ -f "$AFK_STATE/issue-${issue}.lock" ]]
}
