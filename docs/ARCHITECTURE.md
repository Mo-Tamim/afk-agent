# Architecture

This document explains how `afk-agent` is put together: the pieces, how
they talk to each other, and why each one exists.

## 30-second mental model

```mermaid
flowchart LR
  subgraph You["You (developer)"]
    G[/afk-grill/]:::skill
    P[/afk-prd/]:::skill
    S[/afk-setup/]:::skill
    CLI([.afk/scripts/afk]):::cli
  end

  subgraph Agent["IDE Agent (Cursor / Claude / Codex / Copilot / …)"]
    Skills[afk-* SKILL.md files]:::skill
    Runner[$AGENT_BIN spawned by orchestrator]:::cli
  end

  subgraph Repo[".afk/ inside your repo"]
    Cfg[config.yml + labels.yml]:::data
    Prompts[prompts/]:::data
    Scripts[scripts/]:::cli
    State[state/ + worktrees/ + logs/]:::data
  end

  subgraph Remote[Outside world]
    Tracker[(Tracker:\nGitHub or GitLab)]:::ext
    NotifyDev{{notify-developer\naudible alarm}}:::ext
    Dash{{afk dashboard\nlocal web view}}:::ext
  end

  G --> Repo
  P --> Tracker
  S -.scaffolds.-> Repo
  CLI --> Scripts
  Scripts -->|spawn per-phase| Runner
  Runner --> Skills
  Runner --> Tracker
  Runner --> Repo
  Scripts -->|on blocker| NotifyDev
  Scripts -.emit state + events.-> Dash
  Dash -.reads only.-> Repo

  classDef skill fill:#dff,stroke:#0369a1,color:#0f172a,stroke-width:1.5px;
  classDef cli   fill:#ffd,stroke:#92400e,color:#0f172a,stroke-width:1.5px;
  classDef data  fill:#eee,stroke:#475569,color:#0f172a,stroke-width:1.5px;
  classDef ext   fill:#fdd,stroke:#991b1b,color:#0f172a,stroke-width:1.5px;
```

Three actors:

- **You** drive the system with three skills (`/afk-grill`, `/afk-prd`,
  `/afk-setup`) and one CLI (`.afk/scripts/afk`).
- **The IDE agent** runs each phase as a fresh, short prompt with the
  skills it needs loaded on demand.
- **The orchestrator** is plain bash. It owns the lifecycle, the
  parallelism, the locks, the state, and the tracker calls — the
  agent does not own those.

## Why the orchestrator is bash, not the agent

The agent is **stateless and fallible**. It crashes, gets rate-limited,
runs out of tokens, hallucinates an extra phase, or simply stops
producing output. If the lifecycle lived inside the agent, every one of
those would corrupt the whole PRD.

The bash orchestrator gives us:

- **Deterministic resume.** State is JSON on disk; a crash mid-phase is
  resumed by re-reading `.completed_phases` and skipping ahead.
- **Bounded parallelism.** A simple `max_parallel` pool of `&` jobs
  plus a per-issue lock file. No coordination service.
- **Sentinel-only contract.** The agent's job is to end its turn with
  exactly one of `<promise>COMPLETE</promise>`,
  `<promise>NO_CHANGES</promise>`, `<promise>BLOCKED</promise>`. Bash
  never reads agent prose.
- **Tool isolation.** Each phase is its own subprocess with its own
  cwd (the issue's worktree), its own log file, and its own timeout.

## The five layers

```mermaid
graph TD
  L1[Layer 1: User skills<br/>afk-setup, afk-grill, afk-prd]
  L2[Layer 2: Orchestrator scripts<br/>afk, run-issue.sh, orchestrate.sh, …]
  L3[Layer 3: Phase prompts<br/>plan-prompt.md, implement-prompt.md, …]
  L4[Layer 4: Internal skills<br/>afk-workflow, afk-decompose, afk-tdd, afk-document,<br/>afk-tracker-issue, afk-tracker-pr]
  L5[Layer 5: Adapters<br/>lib/tracker.sh, lib/state.sh, lib/worktree.sh, lib/lock.sh]

  L1 -->|invoke| L2
  L2 -->|spawn agent with| L3
  L3 -->|reference| L4
  L4 -->|via shell| L5
  L2 -->|directly call| L5
```

| Layer | Lives in           | Job                                                  |
|-------|--------------------|------------------------------------------------------|
| 1     | `skills/afk-*/`    | What the **human** invokes                           |
| 2     | `template/scripts/`| Owns the lifecycle; never thinks                     |
| 3     | `template/prompts/`| The instructions handed to one agent for one phase   |
| 4     | `skills/afk-*/`    | What the **agent** loads on demand inside a phase    |
| 5     | `template/scripts/lib/`| Bash adapters: tracker, state, worktrees, locks  |

## Resume semantics

```mermaid
stateDiagram-v2
  [*] --> Pending
  Pending --> Plan: run-issue.sh starts
  Plan --> Implement: COMPLETE recorded in completed_phases
  Plan --> Blocked:   BLOCKED
  Implement --> Review: COMPLETE
  Implement --> Bailed: NO_CHANGES
  Implement --> Blocked: BLOCKED
  Review --> PR: COMPLETE (NO_CHANGES treated as COMPLETE)
  PR --> WaitCI: COMPLETE
  PR --> Blocked: BLOCKED
  WaitCI --> PRReview: ci=GREEN
  WaitCI --> Blocked:  ci=RED or timeout
  PRReview --> Merge: COMPLETE (NO_CHANGES treated as COMPLETE)
  Merge --> Done: COMPLETE
  Merge --> Blocked: BLOCKED
  Done --> [*]
  Blocked --> Plan: (operator resumes after fixing)
  Bailed --> [*]
```

Each `COMPLETE` transition appends the phase to
`.afk/state/issue-<N>.json::completed_phases`. A second invocation of
`afk issue <N>` walks the phase list and skips anything in that array.

Phases that are themselves idempotent at the tracker layer (`pr`,
`merge`) additionally short-circuit on observed remote state — e.g. the
PR phase reuses an open PR for the branch instead of opening a duplicate;
the merge phase emits COMPLETE immediately if the PR is already `MERGED`.

## Sentinel-driven phase handoff

```mermaid
sequenceDiagram
  participant Orch as run-issue.sh
  participant RunP as run-phase.sh
  participant Agent as $AGENT_BIN
  participant Log as logs/<phase>.log
  participant State as state/issue-<N>.json

  Orch->>RunP: phase=implement
  RunP->>Log: open new log file
  RunP->>Agent: stdin=rendered prompt, cwd=worktree
  Agent-->>Log: streamed output
  Agent-->>Log: ...<promise>COMPLETE</promise>
  Agent-->>RunP: exit
  RunP->>Log: grep for sentinel → COMPLETE
  RunP->>State: history += {phase, outcome}
  RunP-->>Orch: rc=0
  Orch->>State: completed_phases += "implement"
  Orch->>Orch: advance to next phase
```

The orchestrator's loop is trivial: render prompt → spawn agent →
grep log → decide rc. Nothing else.

## Locking model

```mermaid
flowchart LR
  R1[Orchestrator #1] -.tries.-> Lock[(issue-42.lock)]
  R2[Orchestrator #2] -.tries.-> Lock
  Lock -->|first to noclobber| R1
  R1 -->|holds while phases run| Done[releases on EXIT]
  R2 -->|blocked| Skip[picks a different issue]
```

`set -C; > lockfile` is atomic at the filesystem layer — only one
process can win. Stale locks (process gone but file remains) are
reclaimed by checking `kill -0 $pid`.

## Tracker abstraction

`lib/tracker.sh` exposes ~20 verbs (`issue_view_json`, `issue_labels`,
`issue_add_label`, `pr_list_for_branch`, `ci_status`, …) and routes
each one to `gh` or `glab` based on `config.yml`'s `tracker:` value.

```mermaid
graph LR
  Prompt[plan-prompt.md]
  Skill[afk-tracker-issue/SKILL.md]
  TrackerSh[lib/tracker.sh]
  GH[gh CLI]
  GL[glab CLI]
  GHAPI[(GitHub API)]
  GLAPI[(GitLab API)]

  Prompt -.references.-> Skill
  Skill -.describes verbs implemented in.-> TrackerSh
  TrackerSh -->|tracker=github| GH --> GHAPI
  TrackerSh -->|tracker=gitlab| GL --> GLAPI
```

Adding a third tracker (Forgejo, Gitea, Linear) is one file: add the
`case "$TRACKER" in <new>) … ;;` arms to `lib/tracker.sh`, plus the
matching authentication step in `ensure-setup.sh`. Prompts and skills
don't change.

## Observability layer

The orchestrator emits two parallel streams that anything else can
read without touching the scripts, plus a **subprocess registry** for
spawn/reap auditing:

```mermaid
flowchart LR
  subgraph Scripts[Orchestrator scripts]
    O[orchestrate.sh]
    RI[run-issue.sh]
    RP[run-phase.sh]
  end
  subgraph Streams[On-disk streams]
    S[(.afk/state/<br/>issue-N.json)]
    E[(.afk/logs/<br/>events.ndjson)]
    R[(.afk/logs/<br/>subprocess-registry.ndjson)]
  end
  subgraph Readers[Read-only consumers]
    Status[afk status<br/>CLI snapshot]
    Dash[afk dashboard<br/>live web view]
    Custom[your own analytics<br/>scripts / Grafana / etc.]
  end

  O & RI & RP -- atomic jq+mv --> S
  O & RI & RP -- append --> E
  O & RI & RP -- append --> R
  S --> Status
  S --> Dash
  E --> Dash
  R --> Dash
  E --> Custom

  classDef script fill:#fff4d6,stroke:#92400e,color:#0f172a,stroke-width:1.5px;
  classDef stream fill:#eee,stroke:#475569,color:#0f172a,stroke-width:1.5px;
  classDef reader fill:#dff,stroke:#0369a1,color:#0f172a,stroke-width:1.5px;
  class O,RI,RP script
  class S,E,R stream
  class Status,Dash,Custom reader
```

- **State files** (`.afk/state/issue-N.json`) are the **resume cursor**.
  Atomically updated via `jq → tempfile → mv`. The single source of
  truth for "is this phase done?".
- **Event stream** (`.afk/logs/events.ndjson`) is the **timeline**.
  Append-only NDJSON, one line per lifecycle transition (see
  [DASHBOARD.md § Telemetry](./DASHBOARD.md#telemetry)). Best-effort —
  scripts continue working even if the file is unwritable.
- **Subprocess registry** (`.afk/logs/subprocess-registry.ndjson`)
  records spawn/reap pairs for issue runners, agent wrappers, and
  timeout sentries so the dashboard can flag unexpected live PIDs and
  operators can audit leaks after crashes.
- All three are **read-only inputs** to downstream tools. Nothing
  in the orchestrator depends on a reader being present. You can
  swap `afk dashboard` for a custom Grafana exporter without
  touching a single phase prompt.

## What ends up where

```
<your-repo>/
├── AGENTS.md                          ← patched with an "AFK orchestrator" section
└── .afk/
    ├── config.yml                     ← tracker, repo, runner, merge mode
    ├── labels.yml                     ← labels to ensure on the tracker
    ├── .gitignore                     ← ignores state/ worktrees/ logs/
    ├── prompts/                       ← 8 phase prompts (committed)
    ├── templates/                     ← child issue / PR / docs templates (committed)
    ├── skills/                        ← copy of afk-* skills (committed; agent loads these)
    ├── scripts/                       ← orchestrator + lib/ + dashboard.sh (committed)
    ├── dashboard/                     ← stdlib HTTP server + HTML/JS UI (committed)
    ├── state/                         ← per-issue JSON state (gitignored)
    ├── worktrees/                     ← per-issue git worktrees (gitignored)
    └── logs/                          ← timestamped phase logs + events.ndjson + dashboard.{log,pid} (gitignored)
```

`.afk/` is fully self-contained: a fresh clone of the repo + a
working `gh`/`glab` + the chosen agent runner is enough to drive AFK
on it. Nothing else needs to be installed globally.

## See also

- [LIFECYCLE.md](./LIFECYCLE.md) — every phase, every sentinel,
  blow-by-blow.
- [DASHBOARD.md](./DASHBOARD.md) — the live web view and telemetry
  stream that ride on top of this architecture.
- [INSTALLATION.md](./INSTALLATION.md) — installer flags, manual
  install, per-agent quirks.
- [EXTENDING.md](./EXTENDING.md) — adding a phase, a tracker, or a new
  agent runner.
