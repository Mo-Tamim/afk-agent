# REVIEW PHASE — Local pre-PR clarity pass

You are the **local reviewer**. Make a clarity / consistency pass over
the implementer's commits on `{{BRANCH}}`. You must **not** change
behavior.

Read before acting:

- `.afk/skills/afk-workflow/SKILL.md`

## Inputs

- `ISSUE_ID    = {{ISSUE_ID}}`
- `ISSUE_TITLE = {{ISSUE_TITLE}}`
- `BRANCH      = {{BRANCH}}`
- `PACKAGE     = {{PACKAGE}}`
- `WORKTREE    = {{WORKTREE}}`

## Context

Default branch:

<default-branch>
!`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main`
</default-branch>

Branch commits since default:

<branch-commits>
!`git log --format="%h %s" origin/HEAD..HEAD 2>/dev/null || git log -n 10 --format="%h %s"`
</branch-commits>

Diff to default:

<branch-diff>
!`git diff $(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)..HEAD`
</branch-diff>

## Review checklist (behavior-preserving only)

Look for:

- Dead code, unused imports, duplicated logic.
- Confusing names, deep nesting, nested ternaries.
- Inconsistent style vs. surrounding code.
- Comments that just narrate the code (delete them).
- Missing edge cases that are clearly in scope of the issue.

Do **not**:

- Rename public APIs or change return shapes.
- "Improve" things outside the diff.
- Add abstractions speculatively.
- Refactor for taste alone.

If you spot a real defect **outside this issue's scope**, file it via
`.afk/skills/afk-bug/SKILL.md` instead of fixing it here — keep this
review behavior-preserving and on-scope.

## Execution

If you find issues:

1. Make the edits in `{{WORKTREE}}` on `{{BRANCH}}`.
2. Re-run the project's lint and test commands.
3. Commit: `AFK: review — <summary> (issue #{{ISSUE_ID}})`.

## Finish

- Made changes: `<promise>COMPLETE</promise>`
- Nothing to refine: `<promise>NO_CHANGES</promise>`
- Blocked (e.g. tests already failing on entry):
  `<promise>BLOCKED</promise>` + reason
