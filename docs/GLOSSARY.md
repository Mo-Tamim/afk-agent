# Glossary

Every term, abbreviation, and bit of jargon used anywhere in this
repo — defined plainly and pointed at the place it's used.

Alphabetised. Cross-references in `backticks` link to other entries.

---

## A

### ADR — Architecture Decision Record
A short markdown file capturing **one decision** that is hard to
reverse, surprising without context, and was a real trade-off. Lives
under `docs/adr/NNNN-kebab-title.md`. Written by `afk-grill` during
the design phase. See [skills/afk-grill/SKILL.md](../skills/afk-grill/SKILL.md).

### AFK — Away From Keyboard
The whole point. You hand work to the orchestrator, walk away, and
trust the alarm to call you back only when a human is genuinely
required.

### Agent
Two meanings, context-dependent:
1. **IDE agent** — your interactive Cursor / Claude Code / Copilot
   Chat / Windsurf session. The thing you `/`-talk to.
2. **Phase agent** — a fresh process the orchestrator spawns for
   one phase of one issue. Set by `agent_bin` in `config.yml`.
   The two are usually the same binary but different invocations.

### `agent_bin`
The config key in `.afk/config.yml` that names the binary the
orchestrator shells out to per phase (`cursor-agent`, `claude`,
`codex`, `gh copilot`, `gemini`, …). Swap binaries to swap agent
runtimes — no script edits needed.

### `AGENTS.md`
The conventional file most modern agents read on startup to learn
the repo's rules. `afk-setup` appends an `## AFK orchestrator`
section to whichever rules file your repo uses (`AGENTS.md`,
`CLAUDE.md`, `.cursorrules`, `GEMINI.md`, …).

### `afk` (the script)
The single CLI entrypoint at `.afk/scripts/afk`. Dispatches to
`setup`, `decompose`, `run`, `issue`, `document`, `status`,
`stop-notify`.

### `afk-blocked`
A `label` the orchestrator applies to any issue whose phase
emitted `BLOCKED`. Tells the orchestrator (and you) "skip this until
fixed".

### `afk-child`
A `label` applied to every child issue produced by the
`decompose` phase. The orchestrator's pool only pulls from this
label.

### `afk-done`
A `label` applied to issues that have been merged via the AFK
pipeline. Use it to count throughput.

### `afk-in-progress`
A `label` applied while the orchestrator holds an issue. Combined
with the per-issue `lock file` to prevent double-processing.

### `afk-prd`
A `label` applied to PRD issues. The `docs-gate` scans for these
to know when to trigger the `document` phase.

---

## B

### Background mode
Running the orchestrator detached from chat or terminal, typically
via `setsid nohup … &`. See [MODES.md](./MODES.md).

### `Blocked by:`
A markdown section convention in child issue bodies that lists
prerequisite issues, e.g. `Blocked by: #43, #44`. The orchestrator
parses this section and refuses to pick up an issue whose blockers
aren't all closed.

### `BLOCKED` (sentinel)
The `<promise>BLOCKED</promise>` tag a phase agent emits when it
cannot proceed without human input. The orchestrator stops the
phase, applies `afk-blocked`, and (per `config.yml`) triggers
`notify-developer`.

---

## C

### Chat-detached mode
`afk-run` style where the agent spawns the orchestrator into the
background so chat closing doesn't kill the run. See
[MODES.md § Mode 2](./MODES.md#mode-2--chat-detached).

### Chat-inline mode
`afk-run` style where everything runs as foreground shell tool
calls inside the IDE chat. See
[MODES.md § Mode 1](./MODES.md#mode-1--chat-inline-the-default-chat-experience).

### Child issue
A vertical-slice issue created by the `decompose` phase from a
PRD. Labelled `afk-child, ready-for-agent`. Each child = one
branch = one PR.

### CI — Continuous Integration
The test / build pipeline that runs automatically on every PR
(GitHub Actions, GitLab CI, …). The `pr_wait_ci` phase polls
until CI is `GREEN` / `RED` / timeout.

### CLI — Command-Line Interface
The shell, basically. `.afk/scripts/afk` is the AFK CLI.

### `CLAUDE.md`
Anthropic's convention for repo-level agent rules. Equivalent to
`AGENTS.md`.

### `completed_phases`
An array in `.afk/state/issue-N.json` listing every phase that
finished with `COMPLETE`. The runner skips phases already in this
list — the basis of the resume model.

### `COMPLETE` (sentinel)
The `<promise>COMPLETE</promise>` tag a phase agent emits when it
finished successfully. The runner advances to the next phase.

### `config.yml`
`.afk/config.yml`. Per-repo tunables: tracker, repo slug, default
branch, agent runner, parallelism cap, timeouts, merge mode,
notification policy. The runner reads it on every invocation.

### `CONTEXT.md`
A glossary of domain terms maintained by the user (with help from
`afk-grill`). Lives at the repo root or per-package. Not a spec —
just a glossary. The decomposer and documenter pull vocabulary
from it so PRs and docs use consistent terminology.

### `CONTEXT-MAP.md`
For multi-context repos: a root-level pointer to where each
context's `CONTEXT.md` lives.

### `cursor-agent`
Cursor's CLI agent. The default `agent_bin` because it has the
broadest tool support out of the box.

---

## D

### `decompose` (phase)
The phase that turns one PRD into N child issues. Reads the PRD
body, emits a `<children>JSON</children>` payload that the bash
runner uses to open the child issues on the tracker. See
[skills/afk-decompose/SKILL.md](../skills/afk-decompose/SKILL.md).

### Deep module
A module that exposes a small, stable interface over a large amount
of functionality. Opposite of a shallow module. The `afk-prd` and
`afk-decompose` skills push you toward deep modules because they
test well and slice well.

### Default branch
The branch new PRs target — usually `main`. Set in `config.yml`'s
`default_branch:`. Detected automatically from
`origin/HEAD` by the installer.

### Detached
Running outside chat / terminal control. `setsid nohup … < /dev/null &`
is the canonical detach incantation.

### `document` (phase)
The auto-documentation phase. Triggered by the `docs-gate` when
every child of a PRD is closed. Writes `docs/dev/<slug>.md` and
`docs/user/<slug>.md` (with mandatory mermaid diagrams), opens a
docs PR, merges it. See
[skills/afk-document/SKILL.md](../skills/afk-document/SKILL.md).

### `docs-gate`
The orchestrator's scanner (`document-gate.sh`) that checks every
open `afk-prd` issue to see if all its children are closed. If so,
it kicks the `document` phase. Runs after every idle pass of the
parallel orchestrator.

---

## F

### Foreground mode
Running the orchestrator as a blocking command in chat or terminal.
See [MODES.md](./MODES.md).

---

## G

### `gh`
GitHub's CLI: <https://cli.github.com/>. The orchestrator shells out
to it when `tracker: github` in `config.yml`.

### `glab`
GitLab's CLI: <https://gitlab.com/gitlab-org/cli>. Used when
`tracker: gitlab`.

### Global scope
An install option (`./install.sh --scope global`) that puts the
orchestrator scripts under `~/.afk-agent/` and symlinks
`<repo>/.afk/scripts` to them. Updates flow through one
`git pull` of the toolkit. Compare to `local scope`.

### `GREEN` / `RED` / `PENDING`
The three CI status buckets the orchestrator cares about. Mapped
from `gh pr checks` or `glab ci status` by `lib/tracker.sh`.

### Grilling
The interactive design-stress-test interview from `/afk-grill`.
Adapted from
[`mattpocock/grill-with-docs`](https://www.skills.sh/mattpocock/skills/grill-with-docs).

---

## H

### Hybrid mode
Chat for design phases (`/afk-grill`, `/afk-prd`,
`/afk-run decompose`) and terminal-background for the long run
(`afk run`). See [MODES.md § Mode 5](./MODES.md#mode-5--hybrid-recommended-once-youre-comfortable).

---

## I

### IDE — Integrated Development Environment
Cursor, VS Code, JetBrains, etc. The thing whose chat panel runs
your agent.

### `implement` (phase)
The TDD red→green→refactor phase where the agent writes the
actual code. Spawns inside the issue's `worktree`. See
[skills/afk-tdd/SKILL.md](../skills/afk-tdd/SKILL.md).

### `install.sh`
The non-interactive scaffolder at the repo root. Used both by the
`afk-setup` skill and directly by users who prefer a shell.

### Issue
A unit of work tracked on the `tracker`. PRDs are issues, children
are issues. The orchestrator never invents issues — it always
operates on tracker-side reality.

---

## L

### Label
A short string attached to a tracker issue (`afk-prd`,
`ready-for-agent`, etc.). Used by the orchestrator's batch selector
and by humans for filtering.

### Local scope
The default install scope: scripts copied into `<repo>/.afk/scripts`.
Committed alongside `config.yml`. Compare to `global scope`.

### Lock file
A per-issue file at `.afk/state/issue-N.lock` created atomically
via `set -C` redirection. Prevents two orchestrator runs from
processing the same issue.

---

## M

### `max_parallel`
The orchestrator's pool size. Defaults to 3. Set in `config.yml`.
Bigger = more concurrent agent processes = more API quota burned;
smaller = safer but slower.

### Merge mode
`auto` (squash-merge on green CI + approved self-review) or
`gated` (pause on green CI and wait for a human `/merge` command).
Set in `config.yml`.

### Mermaid
The diagram syntax embedded in markdown via ```` ```mermaid ```` ````
fences. GitHub and most other Markdown renderers display them
inline. The `document` phase requires at least one mermaid diagram
per doc.

### MR — Merge Request
GitLab's name for what GitHub calls a Pull Request. The
`afk-tracker-pr` skill collapses both to "PR".

---

## N

### `NO_CHANGES` (sentinel)
The `<promise>NO_CHANGES</promise>` tag a phase emits when it had
nothing to do (e.g. the reviewer found nothing to refine, or the
implementer found the work was already in a prior commit). The
runner records it and advances — except for `implement`, where
`NO_CHANGES` causes the runner to bail before opening a PR.

### `notify-developer`
A separate skill that plays an audible alarm until the next agent
turn. The orchestrator invokes it on `BLOCKED`, CI red, merge gate,
and timeout. Install it once from
<https://www.skills.sh/> if you want sound; the orchestrator
no-ops without it.

---

## O

### Orchestrator
The bash machine in `.afk/scripts/` that owns the lifecycle. Owns
the pool, the locks, the state files, the tracker calls. Does not
think. See [ARCHITECTURE.md](./ARCHITECTURE.md).

### `origin`
The git remote convention for "the upstream you push to". The
orchestrator always derives the default branch from
`origin/HEAD`.

---

## P

### Phase
One step in a child issue's lifecycle. There are eight:
`decompose`, `plan`, `implement`, `review`, `pr`, `pr_wait_ci`,
`pr_review`, `pr_merge`, plus `document` for PRDs. Each has a
prompt under `.afk/prompts/`.

### `pick_batch`
The orchestrator function that picks the next set of unblocked
ready-for-agent children. The pool fills from its output.

### `plan` (phase)
The phase that reads one child issue and emits a `<plan>JSON</plan>`
payload with the branch name, package path, and approach summary.
Cheap, fast, runs at repo root (not in a worktree).

### Pool
The orchestrator's set of in-flight runners, bounded by
`max_parallel`.

### PR — Pull Request
GitHub's name for a proposed merge. The `pr` phase opens one; the
`pr_review` phase self-reviews it; the `pr_merge` phase merges
it. GitLab calls these MRs; the abstraction layer collapses both.

### PRD — Product Requirements Document
A spec-shaped issue with `## Problem statement`, `## Solution`,
`## User stories`, etc. Produced by `/afk-prd`. Decomposed into
children by the `decompose` phase. See
[skills/afk-prd/SKILL.md](../skills/afk-prd/SKILL.md).

### Prompt
A `.afk/prompts/<phase>-prompt.md` file. Rendered with `{{VAR}}`
substitution and piped to `$AGENT_BIN` on stdin by `run-phase.sh`.

---

## R

### `ready-for-agent`
The `label` that opts an issue in to the orchestrator's pool.
Removed when the orchestrator claims the issue; re-added by you (or
by `decompose`) when an issue is ready.

### Resume
The orchestrator's ability to pick up where it left off after a
crash, reboot, or `Ctrl-C`. Backed by `completed_phases` in
`.afk/state/issue-N.json` plus idempotent tracker-side checks
(reuse open PR, detect already-merged, …).

### `review` (phase)
The local pre-PR pass over the implementer's commits. Clarity only;
must not change behavior. Separate from `pr_review` which runs on
the open PR.

### Runner
Two meanings:
1. **The orchestrator** loosely (`run-issue.sh`, `run-phase.sh`).
2. **The agent runner binary** named by `agent_bin` in
   `config.yml`.

---

## S

### Sentinel
A `<promise>...</promise>` tag the phase agent emits at the very
end of its turn. One of `COMPLETE`, `NO_CHANGES`, or `BLOCKED`.
The orchestrator's only contract with the agent — it never reads
prose.

### `setsid nohup`
The standard Linux/macOS incantation for "detach this process
completely, no controlling terminal, ignore SIGHUP". Used to spawn
a true-background `afk run`.

### Shallow module
A module whose interface mirrors its implementation, so changing
the implementation forces interface changes. Avoid these — they
test poorly and slice poorly. Compare to `deep module`.

### Skill
A `SKILL.md` file with YAML frontmatter that an agent loads on
demand. This repo ships ten of them under `skills/`. Discovered by
[skills.sh](https://www.skills.sh/) via `package.json`'s
`skills.directory` field.

### Slice
Short for `vertical slice`.

### Slug
A kebab-case ASCII identifier derived from a title.
`afk::slug "Add User Auth"` → `add-user-auth`. Used in branch
names and doc filenames.

### State file
`.afk/state/issue-N.json`. Per-issue JSON with the resume cursor
(`completed_phases`), the branch, the PR number, and a history
log. Updated atomically via `jq`-into-tempfile-then-`mv`.

---

## T

### TDD — Test-Driven Development
Red → green → refactor, one behavior at a time. Enforced (loosely)
by the `afk-tdd` skill during the `implement` phase.

### Test surface
The set of behaviors a phase plans to test. Emitted in the `plan`
payload's `test_surface` field. Keeps the implementer honest about
what they're verifying.

### `tracker`
The umbrella term for GitHub or GitLab in this repo. Set by
`tracker:` in `config.yml`. Abstracted by `lib/tracker.sh` so
prompts and skills are tracker-agnostic.

### Tracer bullet
A first end-to-end change that proves the wiring works before
adding feature volume. The TDD skill recommends opening with one
red→green pair to fire the tracer bullet.

---

## V

### Vertical slice
A change that cuts through every layer (schema, API, UI, tests) for
**one narrow capability**. Opposite of horizontal slicing
("write all the tests first, then all the code"). Every AFK child
issue must be a vertical slice. See
[skills/afk-decompose/SKILL.md](../skills/afk-decompose/SKILL.md).

---

## W

### Wake-up
The orchestrator's escalation event: it triggers
`notify-developer` and labels the relevant issue `afk-blocked`
(or its PR `afk-blocked` proxy). The alarm stops on the next
agent turn.

### Worktree
A git worktree at `.afk/worktrees/issue-N/` — a separate working
directory checked out on the issue's branch. Lets multiple
parallel agents work without fighting over `HEAD`. Created by
`worktree.sh::worktree_create`, removed after merge.

### WSL — Windows Subsystem for Linux
Microsoft's Linux-on-Windows runtime. `afk-agent` was developed on
WSL2 Ubuntu and works there identically to native Linux.

---

## Cross-reference: emojis on the labels

The colors used by `labels.yml`:

| Label              | Hex     | Vibe                  |
|--------------------|---------|-----------------------|
| `ready-for-agent`  | 0E8A16  | green — "go"          |
| `afk-in-progress`  | FBCA04  | yellow — "working"    |
| `afk-blocked`      | B60205  | red — "stuck"         |
| `needs-human`      | D93F0B  | orange — "your turn"  |
| `afk-done`         | 5319E7  | purple — "shipped"    |
| `afk-prd`          | 1D76DB  | blue — "spec"         |
| `afk-child`        | BFD4F2  | pale blue — "slice"   |
| `afk-docs`         | 0075CA  | medium blue — "docs"  |

---

If a term in the codebase isn't here, that's a doc bug — open an
issue or just add it yourself in alphabetical position.
