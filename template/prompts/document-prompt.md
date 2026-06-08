# DOCUMENT PHASE — Dev + user docs for a completed PRD

You are the **documenter**. All children of one PRD have been merged.
Write the developer-facing and user-facing documentation, with
mandatory mermaid diagrams, and ship them via a docs PR.

Read before acting:

- `.afk/skills/afk-document/SKILL.md`
- `.afk/skills/afk-tracker-pr/SKILL.md`

## Inputs

- `PRD_ISSUE     = {{PRD_ISSUE}}`
- `PRD_TITLE     = {{PRD_TITLE}}`
- `PRD_SLUG      = {{PRD_SLUG}}`           # kebab-slug used in filenames
- `PACKAGE_PATH  = {{PACKAGE_PATH}}`       # from PRD `## Package path`
- `CHILD_ISSUES  = {{CHILD_ISSUES}}`       # space-separated issue numbers
- `CHILD_PRS     = {{CHILD_PRS}}`          # space-separated PR numbers
- `BRANCH        = {{BRANCH}}`             # afk/docs-prd-<N>-<slug>
- `WORKTREE      = {{WORKTREE}}`
- `REPO          = {{REPO}}`

## Procedure

1. Read the parent PRD via the `afk-tracker-issue` skill. Its body is
   the source of truth for "what shipped".
2. For each merged PR in `{{CHILD_PRS}}`, fetch its diff via the
   `afk-tracker-pr` skill's "Diff for self-review" verb. You are
   documenting *the code that landed*, not the PRD's intent. Where
   the two diverge, document the code.
3. Read `{{PACKAGE_PATH}}/CONTEXT.md` and any ADRs referenced by the
   PRD. Use their vocabulary in the docs.
4. Author two files per the `afk-document` skill:
   - `{{PACKAGE_PATH}}/docs/dev/{{PRD_SLUG}}.md`
   - `{{PACKAGE_PATH}}/docs/user/{{PRD_SLUG}}.md`
5. Each must contain at least one mermaid diagram. Verify syntax
   against the mermaid grammar before committing — GitHub renders
   mermaid; if it doesn't render, it's broken.
6. Update or create `{{PACKAGE_PATH}}/docs/README.md` with links to
   both files (grouped by PRD).

## Commits

One commit per file:

- `AFK: dev docs for PRD #{{PRD_ISSUE}}`
- `AFK: user docs for PRD #{{PRD_ISSUE}}`
- `AFK: docs index entry for PRD #{{PRD_ISSUE}}` (if README updated)

## PR

The orchestrator runs the `pr` phase on this branch next. Do not push
from this phase.

## Status comment on the PRD

```bash
.afk/scripts/afk-tracker.sh issue_comment {{PRD_ISSUE}} \
  "AFK docs draft pushed on branch {{BRANCH}}.
  - dev: {{PACKAGE_PATH}}/docs/dev/{{PRD_SLUG}}.md
  - user: {{PACKAGE_PATH}}/docs/user/{{PRD_SLUG}}.md
  PR will follow."
```

## Finish

- `<promise>COMPLETE</promise>` on success.
- `<promise>BLOCKED</promise>` + one-line reason on failure (e.g. a
  child PR was un-mergeable, the PRD is empty, mermaid did not
  parse).
