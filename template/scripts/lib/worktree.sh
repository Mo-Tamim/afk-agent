#!/usr/bin/env bash
# Per-issue git-worktree management.
# Each issue gets .afk/worktrees/issue-<N>/ rooted at the planned branch.

afk::worktree_path() { printf '%s/issue-%s' "$AFK_WORKTREES" "$1"; }

# Create a worktree at the planned branch, derived from origin/<default>.
# Idempotent: if the worktree already exists for this issue, leave it.
#
# After every merged PR, `origin/<default>` advances on the remote but the
# local checkout doesn't automatically follow. If we branched off a stale
# local <default>, sibling AFK branches end up on disjoint histories and
# squash-merging produces add/add conflicts on every shared file. So:
#   1. Always `git fetch origin` first.
#   2. Fast-forward local <default> to match `origin/<default>`.
#   3. If the planned branch exists locally and its base has diverged from
#      `origin/<default>`, rebase it cleanly on top. If the rebase has
#      conflicts, fall back to a hard reset (the implement phase will
#      regenerate the work from scratch).
afk::worktree_create() {
  local issue="$1" branch="$2"
  local default; default="$(afk::config default_branch main)"
  local wt; wt="$(afk::worktree_path "$issue")"

  if [[ -d "$wt" ]]; then
    afk::log "worktree already exists at $wt"
    return 0
  fi

  ( cd "$AFK_ROOT" && git fetch origin --prune --quiet ) || \
    afk::warn "git fetch origin failed (continuing with stale refs)"

  # Fast-forward local <default> so subsequent ops see the same SHA as remote.
  if git -C "$AFK_ROOT" rev-parse --verify -q "refs/remotes/origin/$default" >/dev/null; then
    if git -C "$AFK_ROOT" rev-parse --verify -q "refs/heads/$default" >/dev/null; then
      if [[ "$(git -C "$AFK_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$default" ]]; then
        git -C "$AFK_ROOT" branch -f "$default" "origin/$default" 2>/dev/null || true
      else
        git -C "$AFK_ROOT" merge --ff-only "origin/$default" --quiet 2>/dev/null || \
          afk::warn "could not fast-forward local $default to origin/$default"
      fi
    else
      git -C "$AFK_ROOT" branch "$default" "origin/$default" 2>/dev/null || true
    fi
  fi

  if git -C "$AFK_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    local base; base="$(git -C "$AFK_ROOT" merge-base "$branch" "origin/$default" 2>/dev/null || true)"
    local origin_head; origin_head="$(git -C "$AFK_ROOT" rev-parse "origin/$default" 2>/dev/null)"
    if [[ -n "$base" && "$base" != "$origin_head" ]]; then
      afk::log "branch $branch base ($base) diverges from origin/$default ($origin_head) — rebasing"
      local scratch="${wt}.rebase"
      rm -rf "$scratch"
      if git -C "$AFK_ROOT" worktree add --quiet "$scratch" "$branch" >/dev/null 2>&1; then
        if git -C "$scratch" rebase --quiet "origin/$default" >/dev/null 2>&1; then
          afk::log "rebased $branch onto origin/$default"
        else
          afk::warn "rebase of $branch onto origin/$default had conflicts; resetting hard"
          git -C "$scratch" rebase --abort >/dev/null 2>&1 || true
          git -C "$scratch" reset --hard "origin/$default" >/dev/null 2>&1 || true
        fi
        git -C "$AFK_ROOT" worktree remove --force "$scratch" >/dev/null 2>&1 || rm -rf "$scratch"
      fi
    elif [[ -z "$base" ]]; then
      afk::warn "branch $branch has no common ancestor with origin/$default — recreating"
      git -C "$AFK_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
      git -C "$AFK_ROOT" branch "$branch" "origin/$default" >/dev/null 2>&1 || true
    fi
    git -C "$AFK_ROOT" worktree add "$wt" "$branch" >/dev/null
  else
    git -C "$AFK_ROOT" worktree add -b "$branch" "$wt" "origin/$default" >/dev/null
  fi
  afk::log "worktree created at $wt on $branch (base: $(git -C "$wt" merge-base HEAD "origin/$default" 2>/dev/null | cut -c1-8))"
}

# Remove a worktree (does not delete the branch).
afk::worktree_remove() {
  local issue="$1"
  local wt; wt="$(afk::worktree_path "$issue")"
  if [[ -d "$wt" ]]; then
    git -C "$AFK_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    afk::log "worktree removed: $wt"
  fi
}

afk::worktree_status_clean() {
  local issue="$1"
  local wt; wt="$(afk::worktree_path "$issue")"
  [[ -d "$wt" ]] || return 1
  [[ -z "$(git -C "$wt" status --porcelain)" ]]
}
