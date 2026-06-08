---
name: afk-tdd
description: Vertical-slice red→green→refactor for AFK implementation phases. Use whenever the implement prompt is active and the touched code has a test runner.
---

# Skill: afk-tdd

Test-driven development tuned for unattended AFK runs.

## Philosophy

Tests verify **behavior through public interfaces**, not
implementation. A good test reads like a specification. A test that
breaks on internal refactors is testing the wrong thing — fix the
test, not the code.

## Anti-pattern: horizontal slicing

**Do not** write all tests first then all implementation. That
produces tests written against imagined behavior. Instead, **vertical
slice**:

```
WRONG (horizontal):
  RED:   t1, t2, t3, t4, t5
  GREEN: i1, i2, i3, i4, i5

RIGHT (vertical):
  RED→GREEN: t1 → i1
  RED→GREEN: t2 → i2
  …
```

## Workflow

### 1. Plan the test surface (≤ 5 minutes of thinking)

Before writing any code, list 3–7 behaviors that matter for the
issue's acceptance criteria. Think *behaviors*, not implementation
steps. Identify which deserve tests vs. which are visual-only smoke.

You may **not** interrupt the developer mid-AFK-run to confirm. Pick
sensibly; the reviewer agent and the human PR reviewer will catch
overreach. If you find yourself unsure between two materially
different test surfaces, emit `<promise>BLOCKED</promise>` and let the
developer resolve it.

### 2. Tracer bullet

Write **one** test that confirms one behavior:

```
RED:   write test → run it → must fail for the right reason
GREEN: write minimal code → run test → passes
```

This proves the path is wired. Commit
(`AFK: red→green: <behavior> (issue #N)`).

### 3. Incremental loop

For each remaining behavior:

```
RED:   next test → fails
GREEN: minimal code → passes
```

Rules:

- One test at a time.
- Only enough code to pass the current test.
- Don't anticipate future tests.
- Don't refactor while RED. Get to GREEN first.

### 4. Refactor

After all tests pass:

- Extract duplication.
- Deepen modules — move complexity behind a simple interface.
- Apply SOLID where natural; don't force it.
- Run tests after each refactor step.

Refactor commits: `AFK: refactor — <summary> (issue #N)`.

## Per-cycle checklist

```
[ ] Test describes behavior, not implementation.
[ ] Test uses the public interface only.
[ ] Test would survive an internal refactor.
[ ] Code is minimal for this test.
[ ] No speculative features added.
```

## When tests aren't possible

If the project has no test runner for the relevant area (e.g. UI glue
covered by manual smoke), skip the tests and:

1. Write the smallest demonstrable change.
2. Document the test gap in the commit body's `Follow-ups:` line.
3. Note it in the issue progress comment.

Do **not** fabricate tests for the sake of TDD ritual.

## Feedback loops

Before each commit, run whichever of these exist in the project:

- `<package-manager> lint`
- `<package-manager> test`
- `<package-manager> typecheck`

A non-zero exit from a check that **exists** must be fixed before
committing. Missing checks are fine — note it in the commit body.

If you discover the test runner is configured but globally broken
(e.g. config-load error not caused by this branch), emit
`<promise>BLOCKED</promise>` with reason `test runner broken on default branch: <one-line>`.
