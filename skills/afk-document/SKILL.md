---
name: afk-document
description: Write developer-facing and user-facing documentation for a completed PRD, with mandatory mermaid diagrams. Use only inside the document phase prompt, after every child issue of a PRD has been merged.
---

# Skill: afk-document

The final phase of a PRD's lifecycle. After every child issue has
merged, the orchestrator spawns a fresh agent that produces two
documents and ships them via a docs PR.

## Inputs (passed by the runner)

| Variable        | Meaning                                                   |
|-----------------|-----------------------------------------------------------|
| `PRD_ISSUE`     | The parent PRD issue number.                              |
| `PRD_TITLE`     | The PRD's title.                                          |
| `PRD_SLUG`      | Kebab-slug used in filenames.                             |
| `PACKAGE_PATH`  | The repo path the PRD primarily touched (from the PRD).   |
| `CHILD_ISSUES`  | Space-separated list of merged child issue numbers.       |
| `CHILD_PRS`     | Space-separated list of merged PR numbers.                |
| `BRANCH`        | `afk/docs-prd-<N>-<slug>`.                                |
| `WORKTREE`      | Per-issue worktree path (cwd is set to this).             |
| `REPO`          | Tracker repo slug.                                        |

## Outputs

Two markdown files under the package:

```
<PACKAGE_PATH>/docs/dev/<prd-slug>.md
<PACKAGE_PATH>/docs/user/<prd-slug>.md
```

Plus a small index entry in `<PACKAGE_PATH>/docs/README.md` (create if
absent) linking to both.

## What to write

### Developer doc (`docs/dev/<prd-slug>.md`)

Audience: a future contributor who will modify or extend this code.

1. **Overview** — one paragraph: what shipped and why. Cite the PRD
   and any ADRs by number.
2. **Architecture diagram** (mandatory, mermaid):
   - For module decompositions: `graph TD` showing module boundaries
     and data flow.
   - For state machines: `stateDiagram-v2`.
   - For request / response flows: `sequenceDiagram`.
3. **Module reference** — for each deep module shipped: typed surface
   signature, invariants, where it lives, what it owns, what it does
   *not* own.
4. **Extension points** — how to add a new field type / element kind
   / format / etc., concretely. Include a checklist.
5. **Test strategy** — what's covered, what's deliberately not, where
   the goldens live, how to update them.
6. **Gotchas** — at least 3 non-obvious things that will trip up the
   next contributor. If you can't think of any, you didn't read the
   diff carefully enough.

### User doc (`docs/user/<prd-slug>.md`)

Audience: an operator using the feature.

1. **What you can do** — one sentence.
2. **A walk-through diagram** (mandatory, mermaid `flowchart` or
   `sequenceDiagram`) showing the operator workflow.
3. **Step-by-step** — numbered steps. Use screenshot placeholders for
   visuals: `![Step 1: …](./screenshots/<slug>-step-1.png)` with a
   `<!-- TODO: real screenshot -->` comment.
4. **Common tasks** — at least 3 representative tasks worked
   end-to-end.
5. **Troubleshooting** — at least 3 failure modes the operator might
   hit, with resolution steps. **Not** "contact support".
6. **What's *not* in this release** — explicit out-of-scope list,
   matching the PRD's `## Out of scope` section.

## Mermaid rules (mandatory)

Every doc has at least one mermaid diagram. Diagrams must:

- Use the simplest type that fits (`graph` / `flowchart` /
  `sequenceDiagram` / `stateDiagram-v2` / `erDiagram`). Don't reach
  for `gantt` unless it's actually a schedule.
- Use the project's domain vocabulary from `CONTEXT.md`. No generic
  *"Service A → Service B"*.
- Be syntactically valid: GitHub renders mermaid; if it doesn't
  render, it's broken.
- Stay under ~30 nodes per diagram. Split large flows into two
  diagrams with named anchors instead of one mega-graph.

## Process

1. Read the parent PRD, every child issue title, every merged PR
   title.
2. Read the **diffs** of merged PRs via the `afk-tracker-pr` skill
   (`tracker-pr get-diff <N>`). You are documenting *the code that
   landed*, not the PRD's intentions.
3. Read `CONTEXT.md` and any ADRs in the package — use their
   vocabulary.
4. Draft both documents in `BRANCH` inside `WORKTREE`.
5. Commit each doc separately:
   - `AFK: dev docs for PRD #N`
   - `AFK: user docs for PRD #N`
   - `AFK: docs index entry for PRD #N` (if README updated)
6. The orchestrator's PR / merge phases handle pushing and shipping.
   Do **not** push from this phase.
7. Comment on the parent PRD with links to both docs.
8. Emit `<promise>COMPLETE</promise>`.

## Quality gates

- [ ] Both files exist and are non-empty.
- [ ] At least one mermaid block in each, and it parses.
- [ ] No broken markdown links.
- [ ] Vocabulary matches `CONTEXT.md`.
- [ ] User doc's troubleshooting section has at least 3 concrete
      entries.
- [ ] Dev doc's gotchas section has at least 3 entries.
