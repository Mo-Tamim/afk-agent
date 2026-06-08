---
name: afk-tracker-pr
description: Tracker-agnostic PR/MR operations — push, open, poll checks, diff, review, merge — wrapping `gh` (GitHub) or `glab` (GitLab) behind one set of verbs. Use whenever the active AFK phase pushes a branch, opens a PR/MR, polls CI, performs a self-review, or merges.
---

# Skill: afk-tracker-pr

The **only** sanctioned way to talk to tracker PRs / MRs from an AFK
phase. GitHub calls them *pull requests*; GitLab calls them *merge
requests*; this skill collapses both to the verb **PR**.

## Preconditions

Same as `afk-tracker-issue`. The current branch must be the issue's
planned branch (named `afk/issue-<N>-<slug>` by default).

## Inputs

- `ISSUE_ID`, `BRANCH`, `REPO`, `DEFAULT_BRANCH`.

## Operations

### 1. Push the branch

```bash
git push -u origin "$BRANCH"
```

This is the **only** push the AFK runner ever performs. Never
force-push. If the remote already has the branch with conflicting
commits, emit BLOCKED with reason
`branch exists on remote with conflicting commits`.

### 2. Open the PR

GitHub:

```bash
gh pr create -R "$REPO" \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH" \
  --title "$ISSUE_TITLE" \
  --body-file "$PR_BODY_FILE"
```

GitLab:

```bash
glab mr create -R "$REPO" \
  --target-branch "$DEFAULT_BRANCH" \
  --source-branch "$BRANCH" \
  --title "$ISSUE_TITLE" \
  --description "$(cat "$PR_BODY_FILE")" \
  --yes
```

The body **must** contain `Closes #${ISSUE_ID}` so merging auto-closes
the linked child issue. Capture the returned PR URL and number.

Output for the runner (same shape for both trackers):

```
<pr>{"number": 99, "url": "<URL>"}</pr>
```

### 3. Poll CI

GitHub:

```bash
gh pr checks "$PR_NUMBER" -R "$REPO" --json bucket,name,status,conclusion
```

GitLab:

```bash
glab ci status -p "$PR_NUMBER" -R "$REPO"
```

The orchestrator polls this — agents do not run an open-ended polling
loop. If invoked from inside an agent (rare), read once and report.

### 4. Diff for self-review

The `pr_review` phase fetches the diff via the tracker, **not** by
reading working-tree files (the reviewer runs in a fresh
worktree-less process):

GitHub:

```bash
gh pr diff "$PR_NUMBER" -R "$REPO"
```

GitLab:

```bash
glab mr diff "$PR_NUMBER" -R "$REPO"
```

Reviewer behavior is the same as the local `review` phase: clarity
only, no behavior changes. If the reviewer finds something, it
**does not** edit the PR — it leaves a review comment and emits
`<promise>NO_CHANGES</promise>`.

GitHub review comment:

```bash
gh pr review "$PR_NUMBER" -R "$REPO" \
  --comment --body "$REVIEW_BODY"
```

GitLab review comment:

```bash
glab mr note "$PR_NUMBER" -R "$REPO" --message "$REVIEW_BODY"
```

### 5. Merge

GitHub squash-merge:

```bash
gh pr merge "$PR_NUMBER" -R "$REPO" --squash --delete-branch \
  --subject "$ISSUE_TITLE (#$PR_NUMBER)" \
  --body "Closes #$ISSUE_ID."
```

GitLab squash-merge:

```bash
glab mr merge "$PR_NUMBER" -R "$REPO" --squash --yes --remove-source-branch \
  --message "$ISSUE_TITLE (!$PR_NUMBER)" \
  --squash-message "Closes #$ISSUE_ID."
```

Only the `pr_merge` phase may run this. Label transitions
(`+afk-done -afk-in-progress`) are performed by the orchestrator, not
by the agent.

## Failure modes

- `gh pr create` / `glab mr create` returns "no commits" → emit
  BLOCKED with `nothing to PR`.
- CI red after `ci_max_wait_seconds` → orchestrator escalates via
  `notify-developer`. The agent simply emits BLOCKED with reason
  `CI red: <first failed check name>`.
- Merge returns conflict → emit BLOCKED with `merge conflict`.
- Branch protections require a human review → emit BLOCKED with reason
  `branch protection requires human review`.
