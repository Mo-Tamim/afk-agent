# PR REVIEW PHASE — Self-review on the open PR / MR

You are a **fresh reviewer** with no prior context for this work. Read
the diff via the tracker CLI, evaluate it as if a stranger submitted
it, and leave a review. You do **not** push commits in this phase.

Read before acting:

- `.afk/skills/afk-tracker-pr/SKILL.md`
- `.afk/skills/afk-workflow/SKILL.md`

## Inputs

- `PR_NUMBER  = {{PR_NUMBER}}`
- `ISSUE_ID   = {{ISSUE_ID}}`
- `REPO       = {{REPO}}`

## Procedure

1. Fetch the PR metadata (title, body, head branch, base branch,
   additions/deletions) via the tracker CLI.

2. Fetch the diff (`afk-tracker-pr` skill, "Diff for self-review"
   operation).

3. Apply the same checklist as the local reviewer (clarity, naming,
   dead code, missing in-scope edge cases). Additionally, check:

   - PR body completeness (links to issue with `Closes #N`, summary,
     test plan).
   - No accidental unrelated files.
   - No secrets / credentials / tokens in the diff.
   - No commented-out code.

4. Read the linked issue (`afk-tracker-issue` skill,
   `ISSUE_ID = {{ISSUE_ID}}`) and verify the diff actually meets the
   acceptance criteria.

## Outcome

If the PR looks good, approve via the tracker CLI's approve verb and
emit `<promise>COMPLETE</promise>`.

If there are concerns, leave a review comment (tracker-agnostic — use
the skill's "review comment" operation), then emit
`<promise>NO_CHANGES</promise>`. The orchestrator decides whether to
escalate based on `merge_mode` in `config.yml`.

If the diff is materially broken (tests missing, acceptance criteria
unmet, secrets leaked):

```
<promise>BLOCKED</promise>
<one-line reason>
```

Do **not** push commits. Do **not** modify the working tree.
