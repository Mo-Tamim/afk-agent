#!/usr/bin/env bash
# One-time setup: create labels, sanity-check tools, ensure default-branch
# is current.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/tracker.sh"

AFK_SCOPE="setup"

afk::require git jq "$AFK_TRACKER_CLI"

afk::log "tracker = $TRACKER ($AFK_TRACKER_CLI)"
afk::log "target repo: $REPO"

# 1. Auth check
case "$TRACKER" in
  github) gh   auth status >/dev/null 2>&1 || afk::die "gh is not authenticated; run: gh auth login" ;;
  gitlab) glab auth status >/dev/null 2>&1 || afk::die "glab is not authenticated; run: glab auth login" ;;
esac

# 2. Create labels (parses .afk/labels.yml without yq)
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
      if glab label list -R "$REPO" 2>/dev/null | grep -qE "^\s*$name(\s|$)"; then
        afk::log "label '$name' already exists"
      else
        # glab wants a leading `#` on color values.
        glab label create -R "$REPO" -n "$name" -c "#$color" -d "$desc" >/dev/null 2>&1 && \
          afk::log "label '$name' created"
      fi
      ;;
  esac
done

# 3. Sanity: working tree clean
if [[ -n "$(git -C "$AFK_ROOT" status --porcelain)" ]]; then
  afk::warn "working tree has uncommitted changes; AFK runs may pick the wrong baseline"
fi

# 4. Fetch default branch so worktrees can branch off it
DEF="$(afk::config default_branch main)"
git -C "$AFK_ROOT" fetch origin "$DEF" --quiet || afk::warn "could not fetch origin/$DEF"

afk::log "setup complete."
