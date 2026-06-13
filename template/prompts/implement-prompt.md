# IMPLEMENT PHASE — One child issue

You are the **implementer**. Make real code changes on a dedicated
branch in a dedicated git worktree to resolve one tracker child issue.

Read before acting:

- `.afk/skills/afk-tracker-issue/SKILL.md`
- `.afk/skills/afk-workflow/SKILL.md`
- `.afk/skills/afk-tdd/SKILL.md`

## Inputs

- `ISSUE_ID    = {{ISSUE_ID}}`
- `ISSUE_TITLE = {{ISSUE_TITLE}}`
- `BRANCH      = {{BRANCH}}`
- `PACKAGE     = {{PACKAGE}}`
- `WORKTREE    = {{WORKTREE}}`     # cwd is already this path

## Setup

1. Confirm you are on `{{BRANCH}}`:

   <branch>
   !`git symbolic-ref --short HEAD 2>/dev/null`
   </branch>

   If not, BLOCK. The orchestrator should have set this up.

2. Inspect prior progress (this phase may be **resuming** after a
   crash, reboot, or Ctrl-C):

   <git-log>
   !`git log --oneline origin/{{DEFAULT_BRANCH}}..HEAD 2>/dev/null | head -20`
   </git-log>

   <git-status>
   !`git status --porcelain`
   </git-status>

   - If `git log` shows existing commits attributed to AFK, you are
     resuming a prior attempt. Read those commits, decide whether the
     issue's acceptance criteria are already met, and either continue
     or — only if absolutely necessary — `git reset --hard origin/{{DEFAULT_BRANCH}}`
     and start over (note that decision in the final commit body).
   - If `git status --porcelain` is non-empty, you have uncommitted
     leftovers from a previous run. Either commit them (if they
     belong to this issue) or `git checkout -- .` before starting
     fresh. Never carry an uncommitted partial change forward
     silently.
   - A clean worktree with no AFK commits ahead of
     `origin/{{DEFAULT_BRANCH}}` is the normal "first attempt" case
     — proceed.

## Context-gathering

- Re-read the issue (`afk-tracker-issue` skill, `ISSUE_ID = {{ISSUE_ID}}`).
- Read the package's `CONTEXT.md` and any ADRs the issue references —
  by path, sectionally, not in bulk.
- Read the **specific files** the issue points at. Do not crawl.

## Execution

Apply `afk-tdd`:

1. **RED** — write or extend ONE test that fails for the right reason.
2. **GREEN** — minimal code to pass it.
3. Repeat until acceptance criteria are met.
4. **REFACTOR** without changing behavior.

If the package has no test runner for the area you're touching, write
the smallest demonstrable change and document the test gap in the
commit body.

## Feedback loops

Before each commit, run whichever of these are configured in the
project (skip silently if missing):

- lint
- test
- typecheck

A non-zero exit from a check that **exists** must be fixed before
committing. Missing checks are fine — note in the commit body.

## Out-of-scope defects

If you notice something fishy **outside this issue's scope** — a broken
invariant, a latent bug, a failing edge case in neighboring code — do
**not** fix it here (that breaks the vertical slice). File it via
`.afk/skills/afk-bug/SKILL.md` (capture-and-file path), drop a one-line
pointer in your status comment, and carry on. Only `BLOCKED` if the
defect actually prevents *this* issue's work.

## Commit

```
AFK: <imperative summary> (issue #{{ISSUE_ID}})

Why: <one line>
Files: <comma-separated paths>
Follow-ups: <none | short note>
```

Do **not** `git push`. Do **not** open a PR. Those happen in later
phases.

## Status comment

When you stop (success or partial), post one progress comment on the
issue via the `afk-tracker-issue` skill — under ~10 lines.

## Handoff (drives the PR body and the merge-time smoke test)

On success you **must** emit one `<handoff>` JSON block. The runner
captures it: it renders `summary` / `test_plan` / `smoke_test` into the
PR/MR body, and — when the smoke gate is enabled — **executes your
`smoke_cmd` itself** in this worktree before merging, attaching the
output as evidence. Write it for a human reviewer, not for yourself.

```
<handoff>
{
  "summary":    "<2–5 sentences: WHAT changed and WHY, named by package/file. Detailed, not boilerplate.>",
  "test_plan":  "<the automated tests you added/extended and what they prove; call out any test gaps honestly>",
  "smoke_test": "<human-readable steps anyone can run from a fresh checkout of this branch to verify the change end-to-end: exact commands + the expected observable output. If a meaningful smoke test is genuinely not applicable (pure docs/refactor with no runtime surface), write exactly: 'N/A — <one-line why>'>",
  "smoke_cmd":  "<a SINGLE self-contained shell command (chain with && if needed) that the runner can execute non-interactively to verify the change. It MUST exit 0 on success and non-zero on failure. If no automated smoke test is applicable, set this to exactly 'N/A'.>"
}
</handoff>
```

Rules for the smoke fields:

- `smoke_cmd` is the **machine-verifiable** contract: the runner runs it
  verbatim with `bash -c` from the worktree root and gates the merge on
  its exit code. `smoke_test` is the human-readable companion.
- Prefer **real** commands that already exist in this repo (a test
  target, a CLI invocation, a `curl … && grep`, a script) plus the
  expected result. Escape newlines as `\n` so the block stays valid JSON.
- Make `smoke_cmd` self-contained and non-interactive: assume only that
  the branch is checked out and deps are installed the normal way for
  this repo. Bake the expected-result assertion into the command itself
  (e.g. pipe to `grep -q`, `jq -e`, or a test) so a wrong result is a
  non-zero exit, not just unexpected stdout.
- Never invent commands or flags that do not exist here. If you cannot
  write a reliable one-shot check, set `smoke_cmd` to `N/A` and explain
  in `smoke_test` — do not fabricate a command that will not pass.

## Finish

- On success: emit the `<handoff>{…}</handoff>` block, then
  `<promise>COMPLETE</promise>`.
- Nothing needed: `<promise>NO_CHANGES</promise>`
- Blocked: `<promise>BLOCKED</promise>` + one-line reason

Only work on issue `{{ISSUE_ID}}`. Nothing else.
