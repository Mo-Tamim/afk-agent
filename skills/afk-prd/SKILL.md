---
name: afk-prd
description: Take the current conversation context (typically from afk-grill) and synthesize a PRD, then publish it as an issue on the configured tracker (GitHub or GitLab) with the labels the AFK orchestrator expects. Use when the user has finished sketching a feature and says "/afk-prd", "write a PRD", or "publish this as an issue for AFK".
---

# Skill: afk-prd

Take the conversation context — typically the output of `/afk-grill` —
and produce a PRD issue on the project's tracker, labelled so the AFK
orchestrator can pick it up.

Do **not** re-interview the user. Synthesize what you already know.

This skill is the universal counterpart of
[`mattpocock/to-prd`](https://www.skills.sh/mattpocock/skills/to-prd):
same template, tracker-agnostic, and wired into the AFK label
vocabulary.

## Prerequisites

This skill assumes `.afk/config.yml` exists. If it doesn't, ask the user
to run `/afk-setup` first and stop.

Read these values from `.afk/config.yml`:

- `tracker:` — `github` or `gitlab`
- `repo:` — slug (`<owner>/<repo>`)
- `labels.ready_for_agent:` — usually `ready-for-agent`
- (look up the `afk-prd` label name; defaults to `afk-prd`)

Use the `afk-tracker-issue` skill for the actual issue-create call. Do
not invoke `gh` or `glab` yourself.

## Process

### 1. Ground the PRD in the codebase

Explore the repo briefly to understand the current state. Use the
project's domain glossary (`CONTEXT.md` and any `CONTEXT-MAP.md`)
vocabulary throughout. Respect any ADRs in the area you're touching —
if a decision contradicts an ADR, surface that and stop.

### 2. Sketch the major modules

List the modules you'll need to build or modify. Actively look for
opportunities to extract **deep modules** that can be tested in
isolation.

> A deep module encapsulates a lot of functionality behind a simple,
> testable interface that rarely changes. A shallow module wraps a
> tiny amount of logic behind an interface that mirrors its
> implementation — avoid those.

Check with the user one time that these modules match their
expectations. Ask which deserve tests.

### 3. Write the PRD

Use this template, substituting the user's language from the grilling
session. Keep it tight — the AFK decomposer will turn this into
vertical-slice child issues, so over-specification creates dead text
that the decomposer has to ignore.

```markdown
## Problem statement
<The problem the user is facing, from the user's perspective.>

## Solution
<The solution to the problem, from the user's perspective.>

## User stories
A numbered list. Format: `As a <actor>, I want a <feature>, so that <benefit>`.

1. As a mobile bank customer, I want to see balance on my accounts,
   so that I can make better informed decisions about my spending
2. ...

(Aim for ≥ 5 stories. Skip ones that are obvious filler — every story
should suggest at least one acceptance criterion.)

## Implementation decisions
A list of decisions already made. Include:

- The modules that will be built / modified
- The interfaces of those modules (signatures, not file paths)
- Architectural decisions and references to relevant ADRs
- Schema changes
- API contracts
- Specific interactions worth pinning down

Do NOT include specific file paths or code snippets — they go stale
quickly. Exception: if a prototype produced a snippet that encodes a
decision more precisely than prose can (state machine, reducer,
schema, type shape), inline the decision-rich bits and note it came
from a prototype.

## Testing decisions
- What makes a good test in this project (behavior, not
  implementation; survives refactors; reads like a spec).
- Which modules get tests; which are visual-smoke-only.
- Prior art — point at one or two similar tests already in the
  codebase.

## Out of scope
<Bullet list. Be specific — vague "out of scope" leads the decomposer
to invent slices for it.>

## Further notes
<Anything else: dependencies on other PRDs, deployment notes, …>

## Package path
`<path/under/the/repo>` — the AFK decomposer uses this to scope its
exploration and the documenter uses it to locate `docs/dev/` and
`docs/user/`. Use the repo root (`.`) if the work spans the whole
project.
```

### 4. Publish

Open the issue via the `afk-tracker-issue` skill:

- **Title:** the PRD's `## Solution` summarised to one imperative line
  (≤ 80 chars).
- **Body:** the rendered template above.
- **Labels:** `afk-prd` and `ready-for-agent`.

Capture the returned issue number/URL and report it back to the user
with the next-step prompt:

> "PRD #42 opened: <URL>. Run `.afk/scripts/afk decompose 42` to slice
> it into child issues, then `.afk/scripts/afk run` to start the
> orchestrator."

## Quality bar

Before publishing, verify:

- [ ] At least one ADR is cited if the PRD touches a hard-to-reverse
      decision.
- [ ] Vocabulary matches `CONTEXT.md` everywhere.
- [ ] No file paths or code snippets in `## Implementation decisions`
      (except the prototype exception).
- [ ] Each user story implies a concrete acceptance criterion.
- [ ] `## Out of scope` has at least two bullets — explicit boundaries
      prevent slice creep.
- [ ] `## Package path` points at a real directory.

If any of these fails, fix the PRD before publishing. Do not publish a
draft and "polish later" — the decomposer will run against whatever is
in the issue body.
