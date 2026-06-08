---
name: afk-grill
description: Stress-test a design idea against the existing domain model, sharpen vocabulary, and capture decisions as ADRs and CONTEXT.md entries inline. Use when the user wants to "grill" a plan, design a new feature, or get challenged on a sketch before writing code. The output of this skill is what /afk-prd consumes next.
---

# Skill: afk-grill

Interview the user relentlessly about every branch of their plan until you
share a model of the design. As decisions crystallise, write them into
`CONTEXT.md` (vocabulary) and `docs/adr/` (decisions worth a paper-trail).
The transcript of this session becomes the input for `afk-prd`.

This is the lightly-revised universal version of
[`mattpocock/grill-with-docs`](https://www.skills.sh/mattpocock/skills/grill-with-docs)
— same philosophy, fewer assumptions about your repo layout, and tuned
to dovetail with the rest of the AFK pipeline.

## What to do

Interview the user **one question at a time**. Walk down each branch of
the design tree. For each question:

1. Propose your recommended answer (with a one-line reason).
2. Wait for feedback.
3. Either accept their answer or push back once with a concrete
   alternative — then accept.

If a question can be answered by reading the codebase, **read the
codebase instead** and report what you found.

## Domain awareness

During exploration, also look for existing documentation. Most repos
have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple
contexts. The map points to where each one lives:

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

**Create files lazily** — only when you have something to write. If no
`CONTEXT.md` exists, create one when the first term is resolved. If no
`docs/adr/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in
`CONTEXT.md`, call it out immediately: *"Your glossary defines
'cancellation' as X, but you seem to mean Y — which is it?"*

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise
canonical term: *"You're saying 'account' — do you mean the Customer or
the User? Those are different things."*

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with
specific scenarios. Invent edge cases that force the user to be precise
about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code
agrees. If you find a contradiction, surface it: *"Your code cancels
entire Orders, but you just said partial cancellation is possible —
which is right?"*

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch
these up — capture them as they happen.

A `CONTEXT.md` entry is short:

```markdown
## Customer
The entity that *pays*. One Customer may have many Users. A Customer
without at least one User is considered dormant. See ADR-0003 for the
billing-account distinction.
```

`CONTEXT.md` is a **glossary**. Do not treat it as a spec, a scratch
pad, or a repository for implementation decisions.

### Offer ADRs sparingly

Only offer to create an ADR when **all three** are true:

1. **Hard to reverse** — the cost of changing your mind later is
   meaningful.
2. **Surprising without context** — a future reader will wonder *"why
   did they do it this way?"*
3. **The result of a real trade-off** — there were genuine alternatives
   and you picked one for specific reasons.

If any of the three is missing, skip the ADR.

## ADR format

Numbered, lowercase-kebab filename: `docs/adr/0007-postgres-for-write-model.md`.

```markdown
# 7. Postgres for write model

## Status
Accepted on 2026-06-07.

## Context
<2–4 sentences: what forced the decision now>

## Decision
<one sentence: what we are doing>

## Consequences
- Positive: ...
- Negative: ...
- Neutral: ...

## Alternatives considered
- <option>: why rejected
- <option>: why rejected
```

## Handoff to /afk-prd

When the user signals they are done grilling (or when every open
question has a decision), end with:

> "Design grilled. ADRs written: `0007-postgres-for-write-model.md`,
> `0008-…`. `CONTEXT.md` updated with: Customer, BillingAccount, …
> Run `/afk-prd` to turn this into a tracker PRD."

`/afk-prd` will read the same transcript, so do **not** restate the
plan in a separate doc.
