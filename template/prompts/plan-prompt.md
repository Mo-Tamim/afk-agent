# PLAN PHASE — One child issue

You are the **planner**. Read one child issue and decide if and how it
should be implemented in a single branch / single PR.

Read the following before acting:

- `.afk/skills/afk-tracker-issue/SKILL.md`
- `.afk/skills/afk-workflow/SKILL.md`

## Inputs

- `ISSUE_ID = {{ISSUE_ID}}`
- `REPO     = {{REPO}}`

## Context

Default branch:

<default-branch>
!`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main`
</default-branch>

Recent commits (for tone / convention):

<recent-commits>
!`git log -n 10 --format="%h %s" 2>/dev/null || echo "no git history"`
</recent-commits>

## Task

1. Fetch issue `{{ISSUE_ID}}` via the `afk-tracker-issue` skill.
2. If it references a parent / PRD, fetch the parent **once** for
   context — do not re-fetch in later phases.
3. Verify it is implementable as-is:
   - Acceptance criteria are concrete and testable.
   - All `Blocked by:` issues are closed.
   - Scope is one branch / one PR.
4. Decide a branch name:
   `afk/issue-{{ISSUE_ID}}-<kebab-slug>` (≤ 60 chars).
5. Identify the touched package(s) from the issue title / body. If the
   issue spans more than one package, BLOCK — it should have been
   sliced thinner.

## Output

If implementable, emit exactly:

```
<plan>
{
  "issue":   {"id": {{ISSUE_ID}}, "title": "<issue title>"},
  "branch":  "afk/issue-{{ISSUE_ID}}-<slug>",
  "package": "<single package path, or 'multi' if cross-cutting>",
  "approach": "<one-paragraph description>",
  "test_surface": ["<deep module to test>", ...]
}
</plan>
<promise>COMPLETE</promise>
```

If not implementable:

```
<promise>BLOCKED</promise>
<one-line reason>
```

Do not output anything after the sentinel.
