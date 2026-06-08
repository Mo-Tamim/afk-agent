#!/usr/bin/env bash
# `afk dashboard` — launch the live progress dashboard for this repo.
#
# Reads .afk/state, .afk/logs, `git worktree list`, and (optionally)
# glab/gh to render a single-pane HTML view. Pure stdlib Python; no
# install. Safe to run against a live AFK session — read-only.
#
# Usage:
#   afk dashboard                                 # bind 127.0.0.1:8765
#   afk dashboard --port 9000                     # custom port
#   afk dashboard --bind 0.0.0.0                  # expose on the network
#   afk dashboard --no-tracker                    # skip glab/gh (offline)
#   afk dashboard --no-browser                    # don't try to open one
#   afk dashboard --background                    # daemonise (logs to .afk/logs/dashboard.log)
#   afk dashboard --stop                          # stop the backgrounded one
#
# Env overrides:
#   AFK_DASHBOARD_PORT, AFK_DASHBOARD_BIND, AFK_DASHBOARD_PYTHON

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

AFK_SCOPE="dashboard"

# Locate the server.py. We support two layouts so a global `afk dashboard`
# also works:
#   1) <repo>/.afk/dashboard/server.py        (per-repo install)
#   2) <orchestrator install root>/dashboard/server.py
#      (e.g. ~/.afk-agent/dashboard/server.py via the global scope)
DASHBOARD_DIR=""
for cand in \
  "$AFK_DIR/dashboard" \
  "$SCRIPT_DIR/../dashboard" \
  "$(dirname "$SCRIPT_DIR")/dashboard"; do
  if [[ -f "$cand/server.py" ]]; then
    DASHBOARD_DIR="$(cd "$cand" && pwd)"
    break
  fi
done
[[ -n "$DASHBOARD_DIR" ]] || afk::die "cannot find dashboard/server.py (expected at .afk/dashboard/server.py)"

# Pick a Python interpreter. Prefer AFK_DASHBOARD_PYTHON, else python3.
PYTHON_BIN="${AFK_DASHBOARD_PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then PYTHON_BIN="$cand"; break; fi
  done
fi
[[ -n "$PYTHON_BIN" ]] || afk::die "no python interpreter found (set AFK_DASHBOARD_PYTHON)"

PORT="${AFK_DASHBOARD_PORT:-8765}"
BIND="${AFK_DASHBOARD_BIND:-127.0.0.1}"
NO_TRACKER=0
OPEN_BROWSER=1
BACKGROUND=0
STOP=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)         PORT="$2"; shift 2 ;;
    --bind)         BIND="$2"; shift 2 ;;
    --no-tracker)   NO_TRACKER=1; shift ;;
    --no-browser)   OPEN_BROWSER=0; shift ;;
    --background|-d) BACKGROUND=1; OPEN_BROWSER=0; shift ;;
    --stop)         STOP=1; shift ;;
    --help|-h)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

PID_FILE="$AFK_LOGS/dashboard.pid"
LOG_FILE="$AFK_LOGS/dashboard.log"

if (( STOP )); then
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.3
      kill -9 "$pid" 2>/dev/null || true
      echo "stopped dashboard (pid $pid)"
    else
      echo "dashboard not running"
    fi
    rm -f "$PID_FILE"
  else
    echo "no pid file at $PID_FILE; nothing to stop"
  fi
  exit 0
fi

# Refuse to double-launch in background mode.
if (( BACKGROUND )) && [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    afk::die "dashboard already running (pid $pid). Stop with: afk dashboard --stop"
  fi
fi

ARGS=(--root "$AFK_ROOT" --port "$PORT" --bind "$BIND")
(( NO_TRACKER )) && ARGS+=(--no-tracker)
ARGS+=("${EXTRA_ARGS[@]}")

URL="http://${BIND}:${PORT}/"

maybe_open_browser() {
  (( OPEN_BROWSER )) || return 0
  if command -v wslview >/dev/null 2>&1; then
    wslview "$URL" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "$URL" >/dev/null 2>&1 &
  fi
}

if (( BACKGROUND )); then
  afk::log "starting dashboard at $URL (background; log → $LOG_FILE)"
  setsid nohup "$PYTHON_BIN" "$DASHBOARD_DIR/server.py" "${ARGS[@]}" \
    >"$LOG_FILE" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
  sleep 0.5
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    afk::error "dashboard failed to start; tail of $LOG_FILE:"
    tail -n 20 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "dashboard pid $(cat "$PID_FILE") · $URL · log $LOG_FILE"
  maybe_open_browser
  exit 0
fi

afk::log "starting dashboard at $URL  (Ctrl-C to stop)"
maybe_open_browser
exec "$PYTHON_BIN" "$DASHBOARD_DIR/server.py" "${ARGS[@]}"
