---
name: afk-decompose
description: Convert one PRD issue into vertical-slice child issues using the tracer-bullet pattern. Use only inside the decompose phase prompt of the AFK orchestrator.
---

# Skill: afk-decompose

Break one PRD into N vertical-slice child issues, each one
independently implementable end-to-end. The runner parses your
`<children>` payload and creates the issues on the tracker; you do
**not** call the tracker CLI yourself in this phase.

## Vertical-slice rules

- A slice **cuts through every layer** of the change — schema, API,
  UI, tests — for one narrow capability.
- A slice is **demoable on its own**: shipping just this PR moves the
  product forward observably.
- Prefer many thin slices over few thick ones. A child should fit in
  ≤ ~300 LOC of diff and one PR review.
- A slice is **AFK-implementable** by default. Use `needs-human` only
  when the slice genuinely needs a human (visual approval of a
  generated mockup, license decision, secret rotation, infra change
  that requires admin credentials).

## Process

### 1. Read the parent PRD

Use the `afk-tracker-issue` skill to fetch the PRD by `ISSUE_ID`.
Read its body and any clarifying comments. Read referenced ADRs and
`CONTEXT.md` from the package the PRD touches (`Package path:` field
in the PRD).

### 2. Draft slices

For each slice, decide:

| Field        | Constraint                                                           |
|--------------|----------------------------------------------------------------------|
| Title        | Imperative, one line, ≤ 80 chars. Includes package / module.         |
| Body         | What to build, acceptance criteria, blocked-by, parent.              |
| Type         | `afk` (default) or `needs-human`.                                    |
| Blocked by   | Other slice indices in this decomposition OR existing issue numbers. |

### 3. Order

Order slices in **dependency order** (zero-dependency slices first).
The runner creates them in order so later slices can reference real
issue numbers in their `Blocked by:` bullets.

### 4. Emit the children block

The runner parses this exact shape — JSON, no trailing commas, one
top-level array:

```
<children>
[
  {
    "title": "<package>: extract CatalogStore deep module",
    "type":  "afk",
    "blocked_by_indices": [],
    "blocked_by_issues":  [],
    "body": "...full child issue body, see template..."
  },
  {
    "title": "<package>: wire CatalogStore into the editor bootstrap",
    "type":  "afk",
    "blocked_by_indices": [0],
    "blocked_by_issues":  [],
    "body": "..."
  }
]
</children>
<promise>COMPLETE</promise>
```

- `blocked_by_indices` references **other entries in this same array**
  (0-based). The runner resolves these to real issue numbers after
  each issue is created and rewrites `Blocked by:` in dependent
  bodies before publishing.
- `blocked_by_issues` references **already-existing tracker issues**
  (e.g. a previously-decomposed sibling). **Never** list the parent
  PRD as a blocker — every child is implicitly downstream of its PRD.

### 5. Body template

Each child body is rendered from `.afk/templates/child-issue.md`. The
agent fills the placeholders; the runner only touches
`{{BLOCKED_BY_LIST}}`.

| Placeholder              | Meaning                                                       |
|--------------------------|---------------------------------------------------------------|
| `{{PARENT}}`             | `#<PRD-issue-number>`                                         |
| `{{WHAT}}`               | 1–3 paragraph description of the slice                        |
| `{{ACCEPTANCE_CRITERIA}}`| Bullet list of testable criteria                              |
| `{{BLOCKED_BY_LIST}}`    | **Leave this exact token.** The runner substitutes it.        |
| `{{TEST_NOTES}}`         | Module + test pattern reminder (see `afk-tdd`)                |

The runner does **not** mutate the body beyond resolving
`{{BLOCKED_BY_LIST}}`.

## Quality gates

Before emitting, verify each slice independently:

- [ ] Has a clear, demoable acceptance criterion.
- [ ] Touches the smallest possible surface to deliver that criterion.
- [ ] Blocked-by graph is a DAG (no cycles).
- [ ] Doesn't duplicate or partially overlap a sibling.
- [ ] Uses vocabulary from `CONTEXT.md`.

If any of these fails on a draft, fix it before emitting `<children>`.
The runner cannot undo a bad decomposition without manual cleanup.

## Anti-patterns

- **Horizontal slicing** — "write all the schemas", "write all the
  tests", "stub all the endpoints". Each slice must demo something on
  its own.
- **Premature optimization slicing** — splitting a 50-LOC change into
  3 PRs because "more PRs = better". The reviewer overhead dominates.
- **PRD restatement** — child bodies that read like a smaller PRD.
  Children are tickets for one PR, not docs.
- **Hidden dependencies** — slice A "doesn't depend on" slice B, but
  silently assumes B's schema exists. Make every dep explicit in
  `blocked_by_indices`.
