---
name: afk-setup
description: Scaffold the per-repo .afk/ orchestrator (config, labels, prompts, scripts, templates) and wire it into the repo's agent rules file. Use after installing the afk-agent skill bundle, when the user says "set up afk", "install afk in this repo", "/afk-setup", or wants to start using the AFK orchestrator on a new project.
---

# Skill: afk-setup

Scaffold the AFK orchestrator into the **current repository** by:

1. Detecting the repo's tracker, default branch, and existing agent rules
   file.
2. Walking three guided decisions one at a time.
3. Running `install.sh` (or copying `template/` by hand if you don't have
   it on disk) to create `.afk/` with the right config baked in.
4. Appending an `## AFK orchestrator` section to the repo's
   `AGENTS.md` (or `CLAUDE.md` / `.cursorrules` / `GEMINI.md`, whichever
   exists) so future agents pick it up.

This is **prompt-driven**, not a silent script. Explore, present what you
found, confirm one decision at a time, then write.

## Process

### 1. Explore the current repo

Read whatever exists; don't assume. In parallel:

- `git config --get remote.origin.url` — extract host (`github.com` /
  `gitlab.com` / self-hosted) and `<owner>/<repo>` slug.
- `git symbolic-ref refs/remotes/origin/HEAD` — derive default branch
  (fall back to `main` if absent).
- Check for an existing agent rules file in this order: `AGENTS.md`,
  `CLAUDE.md`, `.cursor/rules/` directory, `.cursorrules`, `GEMINI.md`,
  `.github/copilot-instructions.md`. The first one that exists is the
  primary; if none exist, default to `AGENTS.md`.
- Check whether `.afk/` already exists. If it does, **stop** and ask
  the user whether to overwrite, abort, or only refresh a subset
  (config / scripts / prompts).

Present a one-screen summary of what you found before asking anything.

### 2. Three guided decisions (one at a time)

Ask each, propose a recommended answer based on what you discovered, wait
for confirmation, then move on.

**Decision 1 — Tracker.**

> "I see a `git@github.com:acme/widget.git` remote. Recommend tracker:
> **GitHub** via `gh`. Confirm, or pick GitLab / other?"

Accepted values: `github`, `gitlab`.

If `gitlab`, also confirm whether they're on `gitlab.com` or a
self-hosted instance (the slug format is the same; only the CLI host
config differs).

**Decision 2 — Agent runner binary.**

> "Which CLI should the orchestrator shell out to for each phase?
> Recommend: **`cursor-agent`** (detected in `$PATH`). Other common
> options: `claude`, `codex`, `gh copilot`, `gemini`."

Validate by `command -v <bin>`. If the user picks one that isn't on
`$PATH`, warn but still write it — they may install it later.

**Decision 3 — Merge mode.**

> "When CI is green and self-review passes, should the AFK orchestrator
> squash-merge automatically (`auto`), or pause and ping you to confirm
> with `/merge <PR#>` (`gated`)? Recommend `auto` for greenfield
> repos, `gated` for production code."

Accepted values: `auto`, `gated`.

Stop here. Do **not** ask about parallelism, timeouts, or notification
policy. Those have sensible defaults; advanced users can edit
`.afk/config.yml` after install.

### 3. Show the draft, then write

Show the resolved values back as a YAML block:

```yaml
tracker: github
repo: acme/widget
default_branch: main
agent_bin: cursor-agent
merge_mode: auto
```

Ask "write this to `.afk/config.yml` and scaffold the rest? (y/n)".

On `y`:

1. Run `install.sh` from this bundle if available:

   ```bash
   ./install.sh \
     --tracker "$TRACKER" \
     --repo    "$REPO" \
     --default-branch "$DEFAULT_BRANCH" \
     --runner  "$AGENT_BIN" \
     --merge-mode "$MERGE_MODE" \
     --target  "$(pwd)"
   ```

   If `install.sh` is not on disk (e.g. the skill was installed without
   the template), copy `template/` from the skill bundle's directory
   into `<repo>/.afk/` manually and write `.afk/config.yml` with the
   resolved values.

2. Append (or create) the agent rules file. The block to write is in
   `template/AGENTS.md.snippet`. Render `{{TRACKER_CLI}}` and
   `{{REPO}}` placeholders before appending.

3. Run the one-time tracker setup:

   ```bash
   .afk/scripts/afk setup
   ```

   This creates the AFK labels (`afk-prd`, `afk-child`,
   `ready-for-agent`, `afk-in-progress`, `afk-blocked`, `needs-human`,
   `afk-done`, `afk-docs`) on the remote tracker.

4. Print a 5-line "what to do next" pointing the user at:
   - `/afk-grill` for stress-testing a new design into ADRs
   - `/afk-prd` for turning a sketched solution into a tracker PRD
   - `.afk/scripts/afk decompose <PRD#>` for kicking off a run
   - `.afk/scripts/afk dashboard --background` (optional) for a
     live web view of orchestrator progress
   - `docs/INSTALLATION.md` for the full reference

### 4. Idempotency

Re-running `afk-setup` on a repo that already has `.afk/`:

- If the user says "refresh", overwrite only `prompts/`, `templates/`,
  `scripts/` and **leave** `config.yml`, `labels.yml`, and any state.
- If the user says "switch tracker", rewrite `config.yml` and re-run
  the tracker setup. Warn that any in-flight issues on the old tracker
  will be orphaned.
- Never silently overwrite `config.yml` — it has the user's choices.

## Failure modes

- **Not in a git repo** → ask the user to `git init` or `cd` into one;
  do not proceed.
- **No remote configured** → ask for the `<owner>/<repo>` slug and the
  tracker explicitly; skip auto-detection.
- **CLI not installed** (`gh` / `glab`) → write the config anyway, but
  print the install command for the chosen tracker and warn that
  `afk setup` will fail until it's available.
- **Agent rules file conflict** — multiple rules files exist
  (`AGENTS.md` AND `CLAUDE.md`): ask the user which is canonical;
  append only to that one.
