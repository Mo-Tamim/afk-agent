# MERGE PHASE — Squash-merge the PR / MR

You are the **merger**. Squash-merge the PR if and only if all gates
pass. By the time this phase runs, the orchestrator has already
verified CI is green, the runner has executed the smoke gate and posted
the **Smoke test evidence** comment, and the final wrap-up comment is on
the linked issue. Your job is the mergeability check and the final merge
call — nothing else.

Read before acting:

- `.afk/skills/afk-tracker-pr/SKILL.md`
- `.afk/skills/afk-workflow/SKILL.md`

## Inputs

- `PR_NUMBER    = {{PR_NUMBER}}`
- `ISSUE_ID     = {{ISSUE_ID}}`
- `ISSUE_TITLE  = {{ISSUE_TITLE}}`
- `REPO         = {{REPO}}`

## Pre-flight

1. Check whether the PR is already merged (this phase may be
   **resuming** after a prior run that succeeded but didn't record
   state). Use the tracker CLI's view-state verb.

   - On GitHub: `gh pr view {{PR_NUMBER}} -R {{REPO}} --json state,mergedAt`
   - On GitLab: `glab mr view {{PR_NUMBER}} -R {{REPO}} --output json`

   If state is `MERGED` (GitHub) or `merged` (GitLab), emit
   `<promise>COMPLETE</promise>` and stop. Do not attempt to re-merge.

2. Confirm the PR is mergeable. On GitHub:

   ```bash
   gh pr view {{PR_NUMBER}} -R {{REPO}} \
     --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
   ```

   - `mergeable` must be `MERGEABLE`.
   - `mergeStateStatus` must be `CLEAN` or `HAS_HOOKS`.
   - `statusCheckRollup` must show all required checks succeeded.

   On GitLab, check `mergeable` is `true` and the pipeline succeeded.

3. If any gate fails, BLOCK with reason
   `merge gate failed: <which one>`.

Do **not** re-run the smoke test or re-post evidence/the final issue
comment — the runner already did that deterministically before invoking
you. Re-running would only post duplicates.

## Merge

Use the `afk-tracker-pr` skill's "Merge" operation. The skill routes
to `gh pr merge --squash` or `glab mr merge --squash` depending on the
configured tracker.

If the merge returns `branch protection requires …` or similar, BLOCK
with reason `branch protection: <message>`.

## Finish

- Merged: `<promise>COMPLETE</promise>`
- Otherwise: `<promise>BLOCKED</promise>` + one-line reason.

The orchestrator handles label transitions and any post-merge state.
