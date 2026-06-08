#!/usr/bin/env bash
# install.sh — scaffold the AFK orchestrator into a target repo.
#
# Two modes:
#   1. Interactive  — `./install.sh` with no flags walks you through the
#                     same three decisions the `afk-setup` skill asks
#                     about, then writes the scaffold.
#   2. Non-interactive — pass every value via flags; useful for CI,
#                        Docker, and dotfile bootstraps.
#
# Usage:
#   ./install.sh [--tracker github|gitlab] [--repo <owner>/<repo>]
#                [--default-branch <name>] [--runner <agent-bin>]
#                [--merge-mode auto|gated] [--target <dir>]
#                [--scope local|global] [--force] [--no-rules-edit]
#
# Scope:
#   local  (default) — scaffold .afk/ inside <target> (the repo root).
#   global           — install the orchestrator under ~/.afk-agent and
#                      symlink ~/.afk-agent/bin/afk on $PATH; per-repo
#                      .afk/config.yml is still required.
#
# Defaults:
#   --target          $(pwd)
#   --tracker         auto-detected from <target>/.git
#   --repo            auto-detected from <target>/.git
#   --default-branch  auto-detected from origin/HEAD, fall back to "main"
#   --runner          first of: cursor-agent, claude, codex, gh
#   --merge-mode      auto
#   --scope           local

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/template"

[[ -d "$TEMPLATE_DIR" ]] || {
  echo "install.sh: cannot find template/ next to install.sh" >&2
  exit 1
}

# --- defaults --------------------------------------------------------------

TRACKER=""
REPO=""
DEFAULT_BRANCH=""
RUNNER=""
MERGE_MODE="auto"
TARGET="$(pwd)"
SCOPE="local"
FORCE=0
EDIT_RULES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tracker)         TRACKER="$2";        shift 2 ;;
    --repo)            REPO="$2";           shift 2 ;;
    --default-branch)  DEFAULT_BRANCH="$2"; shift 2 ;;
    --runner)          RUNNER="$2";         shift 2 ;;
    --merge-mode)      MERGE_MODE="$2";     shift 2 ;;
    --target)          TARGET="$(cd "$2" && pwd)"; shift 2 ;;
    --scope)           SCOPE="$2";          shift 2 ;;
    --force)           FORCE=1;             shift   ;;
    --no-rules-edit)   EDIT_RULES=0;        shift   ;;
    -h|--help)         sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

INTERACTIVE=0
if [[ -z "$TRACKER" && -z "$REPO" && -z "$RUNNER" ]]; then
  INTERACTIVE=1
fi

# --- helpers ---------------------------------------------------------------

detect_remote_url() {
  ( cd "$TARGET" && git config --get remote.origin.url 2>/dev/null ) || true
}

detect_tracker_from_url() {
  case "$1" in
    *gitlab*) echo gitlab ;;
    *github*) echo github ;;
    *)        echo "" ;;
  esac
}

detect_repo_slug() {
  local url="$1" slug
  # Strip protocol + host.
  slug="${url#git@*:}"
  slug="${slug#http*://*/}"
  slug="${slug%.git}"
  printf '%s' "$slug"
}

detect_default_branch() {
  ( cd "$TARGET" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
      | sed 's@^refs/remotes/origin/@@' ) || true
}

detect_runner() {
  for cand in cursor-agent claude codex gh gemini; do
    if command -v "$cand" >/dev/null 2>&1; then
      [[ "$cand" == "gh" ]] && echo "gh copilot" && return
      echo "$cand"; return
    fi
  done
  echo "cursor-agent"   # best-guess default; user can change later
}

detect_rules_file() {
  for f in AGENTS.md CLAUDE.md GEMINI.md .cursorrules .github/copilot-instructions.md; do
    [[ -f "$TARGET/$f" ]] && { echo "$f"; return; }
  done
  echo "AGENTS.md"   # default if none exist; will be created
}

ask() {
  local prompt="$1" default="$2" var="$3" reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply
  fi
  printf -v "$var" '%s' "$reply"
}

# --- auto-detect -----------------------------------------------------------

REMOTE_URL="$(detect_remote_url)"
[[ -z "$TRACKER"        ]] && TRACKER="$(detect_tracker_from_url "$REMOTE_URL")"
[[ -z "$REPO"           ]] && REPO="$(detect_repo_slug "$REMOTE_URL")"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="$(detect_default_branch)"
[[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"
[[ -z "$RUNNER"         ]] && RUNNER="$(detect_runner)"

# --- interactive ----------------------------------------------------------

if (( INTERACTIVE )); then
  echo
  echo "=== AFK orchestrator install ==="
  echo "Target repo:    $TARGET"
  echo "Remote URL:     ${REMOTE_URL:-(none detected)}"
  echo
  ask "Tracker (github | gitlab)"          "${TRACKER:-github}"     TRACKER
  ask "Repo slug (<owner>/<repo>)"         "$REPO"                  REPO
  ask "Default branch"                     "$DEFAULT_BRANCH"        DEFAULT_BRANCH
  ask "Agent runner binary"                "$RUNNER"                RUNNER
  ask "Merge mode (auto | gated)"          "$MERGE_MODE"            MERGE_MODE
  ask "Install scope (local | global)"     "$SCOPE"                 SCOPE
  echo
fi

# --- validate -------------------------------------------------------------

case "$TRACKER" in
  github|gitlab) ;;
  *) echo "install.sh: --tracker must be github or gitlab (got: '$TRACKER')" >&2; exit 1 ;;
esac
case "$MERGE_MODE" in
  auto|gated) ;;
  *) echo "install.sh: --merge-mode must be auto or gated (got: '$MERGE_MODE')" >&2; exit 1 ;;
esac
case "$SCOPE" in
  local|global) ;;
  *) echo "install.sh: --scope must be local or global (got: '$SCOPE')" >&2; exit 1 ;;
esac
[[ -n "$REPO" ]] || { echo "install.sh: --repo not set and could not be auto-detected" >&2; exit 1; }

if [[ "$SCOPE" == "local" ]]; then
  [[ -d "$TARGET/.git" ]] || {
    echo "install.sh: $TARGET is not a git repo (no .git/). Run 'git init' first." >&2
    exit 1
  }
fi

# --- destination layout ---------------------------------------------------

if [[ "$SCOPE" == "global" ]]; then
  GLOBAL_HOME="${AFK_AGENT_HOME:-$HOME/.afk-agent}"
  AFK_DEST="$TARGET/.afk"           # per-repo config still goes here
  mkdir -p "$GLOBAL_HOME"
  cp -R "$TEMPLATE_DIR/scripts" "$GLOBAL_HOME/"
  chmod +x "$GLOBAL_HOME/scripts/afk" "$GLOBAL_HOME/scripts"/*.sh
  # Dashboard ships next to scripts so afk-dashboard.sh resolves to it.
  if [[ -d "$TEMPLATE_DIR/dashboard" ]]; then
    rm -rf "$GLOBAL_HOME/dashboard"
    cp -R "$TEMPLATE_DIR/dashboard" "$GLOBAL_HOME/"
  fi
  mkdir -p "$GLOBAL_HOME/bin"
  ln -sf "$GLOBAL_HOME/scripts/afk" "$GLOBAL_HOME/bin/afk"
  echo "install.sh: global scripts installed at $GLOBAL_HOME"
  echo "             add $GLOBAL_HOME/bin to PATH if not already (export PATH=\"\$PATH:$GLOBAL_HOME/bin\")"
else
  AFK_DEST="$TARGET/.afk"
fi

# --- copy scaffold --------------------------------------------------------

if [[ -d "$AFK_DEST" && $FORCE -eq 0 ]]; then
  read -r -p "install.sh: $AFK_DEST already exists. Refresh prompts/scripts/templates and keep config.yml? (y/N) " ans
  case "$ans" in
    y|Y|yes|YES) REFRESH=1 ;;
    *) echo "install.sh: aborted."; exit 1 ;;
  esac
else
  REFRESH=0
fi

mkdir -p "$AFK_DEST"
cp -R "$TEMPLATE_DIR/prompts"   "$AFK_DEST/"
cp -R "$TEMPLATE_DIR/templates" "$AFK_DEST/"
cp    "$TEMPLATE_DIR/labels.yml" "$AFK_DEST/labels.yml"
# Dashboard (HTML+JS+server). Safe to re-copy on refresh — no user state
# lives in here. Skipped in global scope; afk-dashboard.sh falls back
# to $GLOBAL_HOME/dashboard when this directory is absent.
if [[ "$SCOPE" != "global" && -d "$TEMPLATE_DIR/dashboard" ]]; then
  rm -rf "$AFK_DEST/dashboard"
  cp -R "$TEMPLATE_DIR/dashboard" "$AFK_DEST/"
fi

# Scripts: in local scope we copy in-place; in global scope we symlink to the
# global install so updates flow through `git pull` of the toolkit.
if [[ "$SCOPE" == "global" ]]; then
  ln -sfn "$GLOBAL_HOME/scripts" "$AFK_DEST/scripts"
else
  cp -R "$TEMPLATE_DIR/scripts" "$AFK_DEST/"
  chmod +x "$AFK_DEST/scripts/afk" "$AFK_DEST/scripts"/*.sh
fi

# Skills: copy alongside .afk/ so the bash scripts and the agent see the
# same SKILL.md files even if the user hasn't installed the npx bundle.
mkdir -p "$AFK_DEST/skills"
for s in "$SCRIPT_DIR/skills"/afk-*; do
  [[ -d "$s" ]] && cp -R "$s" "$AFK_DEST/skills/"
done

# config.yml: write only if it doesn't exist or REFRESH=0 (i.e. not refresh-mode).
if [[ -f "$AFK_DEST/config.yml" && $REFRESH -eq 1 ]]; then
  echo "install.sh: keeping existing $AFK_DEST/config.yml"
else
  sed -e "s|__TRACKER__|$TRACKER|" \
      -e "s|__REPO__|$REPO|" \
      -e "s|__DEFAULT_BRANCH__|$DEFAULT_BRANCH|" \
      -e "s|__AGENT_BIN__|$RUNNER|" \
      -e "s|__MERGE_MODE__|$MERGE_MODE|" \
      "$TEMPLATE_DIR/config.yml" > "$AFK_DEST/config.yml"
  echo "install.sh: wrote $AFK_DEST/config.yml"
fi

# .gitignore for the volatile dirs.
mkdir -p "$AFK_DEST"
cat > "$AFK_DEST/.gitignore" <<'EOF'
state/
worktrees/
logs/
EOF

# --- patch agent rules file -----------------------------------------------

if (( EDIT_RULES )); then
  RULES_FILE="$(detect_rules_file)"
  RULES_PATH="$TARGET/$RULES_FILE"
  TRACKER_CLI="$([[ "$TRACKER" == github ]] && echo gh || echo glab)"
  SNIPPET="$(sed -e "s|Mo-Tamim|Mo-Tamim|" \
                 -e "s|{{TRACKER}}|$TRACKER|" \
                 -e "s|{{REPO}}|$REPO|" \
                 -e "s|{{TRACKER_CLI}}|$TRACKER_CLI|" \
                 "$TEMPLATE_DIR/AGENTS.md.snippet")"
  if [[ -f "$RULES_PATH" ]] && grep -q '## AFK orchestrator' "$RULES_PATH"; then
    echo "install.sh: '$RULES_FILE' already mentions AFK orchestrator; skipping rules patch"
  else
    mkdir -p "$(dirname "$RULES_PATH")"
    printf '%s\n' "$SNIPPET" >> "$RULES_PATH"
    echo "install.sh: appended AFK section to $RULES_FILE"
  fi
fi

# --- next-steps banner ----------------------------------------------------

cat <<EOF

✔ AFK orchestrator scaffolded into: $AFK_DEST
  tracker:        $TRACKER ($REPO)
  default branch: $DEFAULT_BRANCH
  agent runner:   $RUNNER
  merge mode:     $MERGE_MODE
  scope:          $SCOPE

Next steps:

  1. Authenticate the tracker CLI if you haven't already:
       $([[ "$TRACKER" == github ]] && echo "→  gh   auth login" || echo "→  glab auth login")

  2. One-time tracker setup (creates AFK labels on the remote):
       .afk/scripts/afk setup

  3. Drive a PRD AFK:
       (in your IDE agent)  /afk-grill <design idea>
       (in your IDE agent)  /afk-prd
       .afk/scripts/afk decompose <PRD#>
       .afk/scripts/afk run

  4. (Optional) Watch progress live in a browser:
       .afk/scripts/afk dashboard --background    # http://127.0.0.1:8765

See docs/INSTALLATION.md for the full reference,
and docs/DASHBOARD.md for the live view.
EOF
