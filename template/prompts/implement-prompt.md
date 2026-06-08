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

## Finish

- On success: `<promise>COMPLETE</promise>`
- Nothing needed: `<promise>NO_CHANGES</promise>`
- Blocked: `<promise>BLOCKED</promise>` + one-line reason

Only work on issue `{{ISSUE_ID}}`. Nothing else.
