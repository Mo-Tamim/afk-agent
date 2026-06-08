---
name: afk-tracker-issue
description: Tracker-agnostic CRUD on a single issue — fetch, comment, label, close — wrapping `gh` (GitHub) or `glab` (GitLab) behind the same verbs. Use whenever the active AFK phase needs to read or write an issue and you don't want to hardcode the tracker.
---

# Skill: afk-tracker-issue

The **only** sanctioned way to talk to a single tracker issue from an
AFK phase. Routes to `gh` or `glab` based on `.afk/config.yml`'s
`tracker:` value. Behavior is predictable across phases and across
hosts.

## Preconditions (run once per session)

```bash
# Resolve the tracker once per session.
TRACKER="$(grep -E '^tracker:' .afk/config.yml | awk '{print $2}')"   # github | gitlab
REPO="$(grep -E '^repo:'    .afk/config.yml | awk '{print $2}')"

case "$TRACKER" in
  github) CLI=gh   ; AUTH="$($CLI auth status 2>&1)" ;;
  gitlab) CLI=glab ; AUTH="$($CLI auth status 2>&1)" ;;
  *) echo "unknown tracker: $TRACKER" >&2; exit 1 ;;
esac

command -v "$CLI" >/dev/null || { echo "$CLI not installed" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null    # must be inside a repo
```

For `gh`, pass `-R "$REPO"` to every call. For `glab`, pass
`-R "$REPO"` (it accepts the same flag).

## Inputs

Every prompt that uses this skill passes one of:

- `ISSUE_ID` — e.g. `42`
- `ISSUE_URL` — extract the trailing number as `ISSUE_ID`

## Operations

Use exactly these wrappers. Do not invent flags.

### 1. Fetch (always first)

GitHub:

```bash
gh issue view "$ISSUE_ID" -R "$REPO" \
  --json number,title,body,labels,state,assignees,comments
```

GitLab:

```bash
glab issue view "$ISSUE_ID" -R "$REPO" --output json
```

Capture title, body (treat as source of truth), labels, state, and
every comment. Newer comments override older ones on conflict. Do
**not** re-fetch the same issue mid-phase — keep the result in memory.

### 2. Look for parent / blockers

Scan body and comments for:

- `Parent:` / `PRD:` / `Closes #N` (parent linkage)
- `Blocked by:` / `Depends on:` (dependency edges)

The orchestrator's `tracker.sh` library has a strict parser that only
reads the `## Blocked by` markdown section to avoid false positives —
agents do **not** need to re-parse blockers; the orchestrator gates
on them. Agents just need to know they exist.

If a parent is found, fetch it the same way **once** for context.
Never modify the parent issue from a child's phase.

### 3. Progress comment

Use when work is partial, you are blocked, or the prompt asks for a
status update.

GitHub:

```bash
gh issue comment "$ISSUE_ID" -R "$REPO" --body "$(cat <<'EOF'
AFK update:
- <what was done>
- <what is left>
- <blockers, if any>
EOF
)"
```

GitLab:

```bash
glab issue note "$ISSUE_ID" -R "$REPO" --message "$(cat <<'EOF'
AFK update:
- <what was done>
- <what is left>
- <blockers, if any>
EOF
)"
```

Keep status comments under ~10 lines. Never paste full diffs into
issue comments — link to the PR/MR instead.

### 4. Apply / remove labels

GitHub:

```bash
gh issue edit "$ISSUE_ID" -R "$REPO" \
  --add-label "afk-in-progress" --remove-label "ready-for-agent"
```

GitLab:

```bash
glab issue update "$ISSUE_ID" -R "$REPO" \
  --label "afk-in-progress" --unlabel "ready-for-agent"
```

Standard transitions:

- Picked up: `+afk-in-progress  -ready-for-agent`
- Blocked: `+afk-blocked  -afk-in-progress`
- Done (after merge): `+afk-done  -afk-in-progress`
- Needs human: `+needs-human` (does **not** remove `afk-in-progress` —
  the orchestrator escalates on both)

### 5. Close (only when the prompt says so)

The merge phase auto-closes via `Closes #N` in the PR body. Do **not**
manually close from any other phase.

## Failure modes

- CLI returns non-zero → print stderr, emit `<promise>BLOCKED</promise>`
  with reason `<cli> failed: <stderr first line>`, stop.
- Issue is already `closed` / `Closed` → emit BLOCKED with reason
  `already closed`.
- Issue body empty and no comments → emit BLOCKED with reason
  `insufficient spec`.
