#!/usr/bin/env bash
# One-time setup for an AFK-enabled repo.
#
# Three jobs, in order:
#   1. Verify the tracker CLI is installed and authenticated.
#   2. Create every label in .afk/labels.yml that doesn't already exist
#      on the tracker. Idempotent — safe to re-run after editing
#      labels.yml.
#   3. Fetch the default branch so subsequent worktree creation has
#      `origin/<default>` available.
#
# Run via: `.afk/scripts/afk setup`

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/tracker.sh"

AFK_SCOPE="setup"

afk::require git jq "$AFK_TRACKER_CLI"

afk::log "tracker = $TRACKER ($AFK_TRACKER_CLI)"
afk::log "target repo: $REPO"

# === 1. Tracker auth =========================================================
# We don't try to log in for the user — device flow is interactive and the
# orchestrator is supposed to run unattended. Just fail loudly with the
# fix the user needs.

case "$TRACKER" in
  github) gh   auth status >/dev/null 2>&1 || afk::die "gh is not authenticated; run: gh auth login" ;;
  gitlab) glab auth status >/dev/null 2>&1 || afk::die "glab is not authenticated; run: glab auth login" ;;
esac

# === 2. Labels ===============================================================
# Tiny awk parser instead of `yq` to keep zero non-jq deps. Walks
# labels.yml looking for the `- name:` / `color:` / `description:` triple,
# then pipes "<name>|<color>|<desc>" lines into the create loop.

afk::log "ensuring labels…"
awk '
  /^[[:space:]]*-[[:space:]]*name:/ { sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, ""); name=$0; next }
  /color:/                          { sub(/^[[:space:]]*color:[[:space:]]*/, ""); color=$0; next }
  /description:/                    { sub(/^[[:space:]]*description:[[:space:]]*/, ""); desc=$0; print name "|" color "|" desc; next }
' "$AFK_DIR/labels.yml" | while IFS='|' read -r name color desc; do
  [[ -z "$name" ]] && continue
  case "$TRACKER" in
    github)
      if gh label list -R "$REPO" --json name --jq '.[].name' | grep -qx "$name"; then
        afk::log "label '$name' already exists"
      else
        gh label create "$name" -R "$REPO" --color "$color" --description "$desc" >/dev/null && \
          afk::log "label '$name' created"
      fi
      ;;
    gitlab)
      # `glab label list` output is line-based with leading whitespace; the
      # `^\s*name(\s|$)` anchor avoids false matches on substrings.
      if glab label list -R "$REPO" 2>/dev/null | grep -qE "^\s*$name(\s|$)"; then
        afk::log "label '$name' already exists"
      else
        # glab wants `#RRGGBB`; gh wants `RRGGBB`. Match each CLI's syntax.
        glab label create -R "$REPO" -n "$name" -c "#$color" -d "$desc" >/dev/null 2>&1 && \
          afk::log "label '$name' created"
      fi
      ;;
  esac
done

# === 3. Working-tree sanity ==================================================
# Loud warning, not a hard fail: a dirty working tree means the next
# worktree creation might pick up an unintended baseline, but it's the
# user's call whether to proceed.

if [[ -n "$(git -C "$AFK_ROOT" status --porcelain)" ]]; then
  afk::warn "working tree has uncommitted changes; AFK runs may pick the wrong baseline"
fi

# === 4. Fetch default branch =================================================
# Required for `git worktree add … origin/<default>` later.

DEF="$(afk::config default_branch main)"
git -C "$AFK_ROOT" fetch origin "$DEF" --quiet || afk::warn "could not fetch origin/$DEF"

afk::log "setup complete."
