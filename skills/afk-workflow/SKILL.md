---
name: afk-workflow
description: The shared mental model the AFK orchestrator drives — decompose → plan → implement → review → PR → wait CI → PR-review → merge → document. Use whenever an AFK prompt mentions a phase, branch naming, sentinels, locks, or the lifecycle of a child issue / PRD.
---

# Skill: afk-workflow

This skill is the shared mental model for every phase the AFK
orchestrator runs. Each prompt under `.afk/prompts/` corresponds to
exactly one phase.

## Lifecycle of a PRD

```
PRD issue (label: afk-prd, ready-for-agent)
   └─ decompose ──> N child issues (label: afk-child + ready-for-agent)
                       │
                       │ orchestrator picks unblocked children (resume `afk-in-progress` first, else `ready-for-agent`) up to max_parallel
                       ▼
                    plan → implement → review
                       ▼
                       pr (push branch, open PR/MR, link to child issue)
                       ▼
                    pr_wait_ci  (poll until green / red / timeout)
                       ▼
                    pr_review   (fresh agent, separate context)
                       ▼
                    pr_merge    (squash-merge, close child issue)
                       ▼
                    next child …
                       ▼
   when the last child of a PRD is closed:
       document ──> dev docs + user docs (mermaid required)
                       ▼
                    close PRD issue, label afk-done
```

## Branching rules

- Branch name from the planner:
  `{{branch_prefix}}-{{ISSUE_ID}}-{{kebab-slug}}` (≤ 60 chars).
  Defaults to prefix `afk/issue` from `config.yml`.
- Always derive from the repo's default branch, detected via
  `git symbolic-ref refs/remotes/origin/HEAD`, falling back to the
  value in `config.yml` (`default_branch:`, usually `main`).
- Each in-flight issue gets its own **git worktree** at
  `.afk/worktrees/issue-<ID>/`. The agent never `cd`s out of its
  worktree.
- Never commit directly to the default branch.
- If the planned branch already exists locally with unrelated commits,
  emit `<promise>BLOCKED</promise>` — do not rebase or reset it.

## Commit hygiene

- One logical change per commit where practical.
- All commit messages start with `AFK:` so the orchestrator can grep
  them.
- Body: one-line "why", touched files, follow-up note if any.
- Never commit generated artifacts, `node_modules/`, build output, or
  secrets.
- Never commit `.afk/state/`, `.afk/worktrees/`, or `.afk/logs/` —
  they are gitignored by `afk-setup`.

## PR / MR rules

- The PR opener phase is the **only** phase allowed to `git push`.
- The PR body is rendered from `.afk/templates/pr-body.md`.
- The PR title mirrors the child issue title.
- The PR description always references the child issue with
  `Closes #N` (GitHub) or `Closes #N` (GitLab — same syntax) so
  merging auto-closes it.
- Self-review (`pr_review`) is performed by a **fresh agent** with no
  prior context — it pulls the diff via the tracker CLI, not the
  working tree.
- The merge phase squash-merges and applies `afk-done`.

## Sentinels

The background runner greps the log for these. Emit exactly **one** at
the end of each phase. The orchestrator never parses prose.

| Phase           | On success                                   | Other sentinels         |
|-----------------|----------------------------------------------|-------------------------|
| `decompose`     | `<children>[…]</children>` + COMPLETE        | BLOCKED                 |
| `plan`          | `<plan>{…}</plan>` + COMPLETE                | BLOCKED                 |
| `implement`     | COMPLETE                                     | NO_CHANGES, BLOCKED     |
| `review`        | COMPLETE                                     | NO_CHANGES, BLOCKED     |
| `pr`            | `<pr>{"number":N,"url":"…"}</pr>` + COMPLETE | BLOCKED                 |
| `pr_wait_ci`    | (handled by orchestrator, no agent sentinel) | —                       |
| `pr_review`     | COMPLETE                                     | NO_CHANGES, BLOCKED     |
| `pr_merge`      | COMPLETE                                     | BLOCKED                 |
| `document`      | COMPLETE                                     | BLOCKED                 |

`<promise>BLOCKED</promise>` must always be followed by a one-line
reason on the very next line. The orchestrator routes BLOCKED through
`notify-developer` per `config.yml`.

## Locks and idempotency

- Each issue has a lock file at `.afk/state/issue-<N>.lock`. The
  orchestrator refuses to double-process a locked issue.
- Phase completion is recorded in `.afk/state/issue-<N>.json` under
  `.completed_phases`. A second `afk issue <N>` invocation skips
  completed phases.
- The PR phase reuses an existing open PR for the branch instead of
  trying to open a duplicate.
- The merge phase first checks `state == "MERGED"` and short-circuits
  with COMPLETE if the merge already happened.

## Telemetry

Every lifecycle transition (orchestrator start/exit, runner
spawn/reap, issue start/end, phase start/end, agent spawn) appends
one JSON line to `.afk/logs/events.ndjson` via
`afk::telemetry::emit` in `lib/common.sh`. This is **best-effort**:
write failures are swallowed and never change the orchestrator's
exit code. The `dashboard` and any custom analytics read this
stream — agents do not need to emit anything themselves. See
[DASHBOARD.md § Telemetry](../../docs/DASHBOARD.md#telemetry).

## When to BLOCK vs NO_CHANGES vs COMPLETE

- **COMPLETE** — the phase did its job.
- **NO_CHANGES** — the phase had nothing to do (e.g. reviewer found
  nothing to refine; implementer found the work was already done by a
  prior commit). Non-fatal; orchestrator moves on.
- **BLOCKED** — the phase cannot proceed without human input. Always
  pair with a one-line reason on the next line. The orchestrator
  labels the issue `afk-blocked` and (per `config.yml`) starts the
  notify-developer alarm.
