#!/usr/bin/env python3
"""AFK live dashboard — stdlib-only HTTP server.

Reads .afk/state, .afk/logs, `git worktree list`, and (optionally) glab/gh
to render a single-pane view of the orchestrator's progress. Designed to
run safely against a live AFK session: no writes outside its own cache,
no script modifications, every external call wrapped in a short timeout.

Usage:
    python3 server.py [--root <repo>] [--port 8765] [--bind 127.0.0.1]
                      [--no-tracker] [--poll-tracker <sec>]

The dashboard discovers the AFK repo by walking up from `--root` looking
for `.afk/`. If `--root` is omitted, the cwd is used.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

# --- Phase ordering ----------------------------------------------------------
# Matches .afk/config.yml::phases. We also accept the "pr-review" hyphen
# variant some prompts use; the dashboard normalises both to "pr_review".
DEFAULT_PHASES = ["plan", "implement", "review", "pr", "pr_wait_ci", "pr_review", "pr_merge"]
# Reconcile the historical naming drift between config.yml and the scripts:
#   - config.yml lists `pr_merge`
#   - run-issue.sh records the final phase as `merge` in completed_phases
#     and run-phase.sh writes log dirs `issue-<N>-merge-<run>/`
#   - pr-review log dirs use hyphens; everything else uses underscores
# Canonical name in the dashboard = the config name.
PHASE_ALIASES = {"pr-review": "pr_review", "merge": "pr_merge"}


def normalise_phase(p: str) -> str:
    return PHASE_ALIASES.get(p, p)


def denormalise_phase(p: str) -> list[str]:
    """Names this phase might appear under on disk (log dirs, completed_phases)."""
    seeds = {p}
    for src, dst in PHASE_ALIASES.items():
        if dst == p:
            seeds.add(src)
    # Also try the hyphen variant for compound names.
    if "_" in p:
        seeds.add(p.replace("_", "-"))
    return list(seeds)


# --- AFK repo discovery ------------------------------------------------------


def find_afk_root(start: Path) -> Path:
    """Walk up from `start` until we find a directory containing `.afk/`."""
    cur = start.resolve()
    while True:
        if (cur / ".afk").is_dir():
            return cur
        if cur.parent == cur:
            raise SystemExit(f"no .afk/ directory found at or above {start}")
        cur = cur.parent


# --- Tiny config reader ------------------------------------------------------
# We mirror lib/common.sh's grep-based parser; no yq dependency. Only
# top-level scalars and one level of nesting (`phases:` list).


def read_config(afk_dir: Path) -> dict[str, Any]:
    cfg: dict[str, Any] = {}
    path = afk_dir / "config.yml"
    if not path.is_file():
        return cfg
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    phases: list[str] = []
    in_phases = False
    for raw in lines:
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            if in_phases and (line.startswith(" ") or line.startswith("\t")):
                continue
            in_phases = False
            continue
        if line.startswith("phases:"):
            in_phases = True
            continue
        if in_phases:
            m = re.match(r"^\s+-\s+(.+?)\s*(#.*)?$", line)
            if m:
                phases.append(m.group(1).strip().strip('"').strip("'"))
                continue
            else:
                in_phases = False
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*?)\s*(#.*)?$", line)
        if m:
            key, val = m.group(1), m.group(2)
            val = val.strip().strip('"').strip("'")
            if val:
                cfg[key] = val
    if phases:
        cfg["phases"] = phases
    return cfg


# --- Process introspection ---------------------------------------------------


@dataclass
class Proc:
    pid: int
    ppid: int
    cmdline: str
    started_at: float
    runtime_s: float


def read_proc(pid: int) -> Proc | None:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace").strip()
        stat_path = f"/proc/{pid}/stat"
        with open(stat_path, encoding="utf-8") as f:
            stat = f.read()
        # /proc/<pid>/stat is space-separated, but comm (field 2) may contain
        # spaces or parens. Find the closing ')' to anchor.
        rparen = stat.rfind(")")
        fields = stat[rparen + 2 :].split()
        ppid = int(fields[1])
        starttime_ticks = int(fields[19])
        clk_tck = os.sysconf("SC_CLK_TCK") or 100
        with open("/proc/uptime", encoding="utf-8") as f:
            uptime_s = float(f.read().split()[0])
        boot = time.time() - uptime_s
        started_at = boot + (starttime_ticks / clk_tck)
        return Proc(
            pid=pid,
            ppid=ppid,
            cmdline=cmd,
            started_at=started_at,
            runtime_s=time.time() - started_at,
        )
    except (FileNotFoundError, PermissionError, ValueError, IndexError):
        return None


def scan_afk_processes(afk_root: Path) -> dict[str, Any]:
    """Return live orchestrator + per-issue runner + agent process tree."""
    root_marker = str(afk_root)
    orchestrators: list[dict[str, Any]] = []
    runners: list[dict[str, Any]] = []
    phases: list[dict[str, Any]] = []
    agents: list[dict[str, Any]] = []
    try:
        pids = [int(d) for d in os.listdir("/proc") if d.isdigit()]
    except OSError:
        pids = []
    for pid in pids:
        p = read_proc(pid)
        if not p or root_marker not in p.cmdline and ".afk/scripts" not in p.cmdline:
            continue
        if root_marker not in p.cmdline:
            continue
        entry = {
            "pid": p.pid,
            "ppid": p.ppid,
            "cmd": p.cmdline,
            "started_at_iso": datetime.fromtimestamp(p.started_at, tz=timezone.utc).isoformat(),
            "runtime_s": int(p.runtime_s),
        }
        if "orchestrate.sh" in p.cmdline:
            orchestrators.append(entry)
        elif "run-issue.sh" in p.cmdline:
            m = re.search(r"run-issue\.sh\s+(\d+)", p.cmdline)
            entry["issue"] = int(m.group(1)) if m else None
            runners.append(entry)
        elif "run-phase.sh" in p.cmdline:
            m = re.search(r"run-phase\.sh\s+(\S+)\s+(\d+)", p.cmdline)
            if m:
                entry["phase"] = normalise_phase(m.group(1))
                entry["issue"] = int(m.group(2))
            phases.append(entry)
        elif "cursor-agent" in p.cmdline or "/bin/agent" in p.cmdline or "claude" in p.cmdline.lower():
            agents.append(entry)
    # Deduplicate phases: each phase has 3 bash processes (one parent + two
    # children for piping). Keep only the parent (lowest pid sharing
    # issue+phase).
    by_key: dict[tuple[int, str], dict[str, Any]] = {}
    for e in phases:
        k = (e.get("issue") or 0, e.get("phase") or "")
        if k not in by_key or e["pid"] < by_key[k]["pid"]:
            by_key[k] = e
    phases = list(by_key.values())
    return {
        "orchestrators": orchestrators,
        "runners": runners,
        "phases": phases,
        "agents": agents,
    }


# --- State + logs ------------------------------------------------------------


def load_state(afk_root: Path) -> list[dict[str, Any]]:
    state_dir = afk_root / ".afk" / "state"
    issues: list[dict[str, Any]] = []
    if not state_dir.is_dir():
        return issues
    for p in sorted(state_dir.glob("issue-*.json")):
        try:
            issues.append(json.loads(p.read_text(encoding="utf-8")))
        except (json.JSONDecodeError, OSError):
            continue
    return issues


def list_phase_logs(afk_root: Path, issue: int) -> list[dict[str, Any]]:
    """Every phase run for an issue, newest first, with mtime + size + outcome."""
    logs_dir = afk_root / ".afk" / "logs"
    if not logs_dir.is_dir():
        return []
    entries: list[dict[str, Any]] = []
    prefix = f"issue-{issue}-"
    for d in logs_dir.iterdir():
        if not d.is_dir() or not d.name.startswith(prefix) or d.is_symlink():
            continue
        m = re.match(rf"^issue-{issue}-(.+)-(\d{{8}}-\d{{6}})$", d.name)
        if not m:
            continue
        phase = normalise_phase(m.group(1))
        run_id = m.group(2)
        log_file = d / f"{m.group(1)}.log"
        if not log_file.is_file():
            log_file = next(d.glob("*.log"), None)
        size = log_file.stat().st_size if log_file and log_file.is_file() else 0
        mtime = log_file.stat().st_mtime if log_file and log_file.is_file() else d.stat().st_mtime
        outcome = sniff_outcome(log_file) if log_file else None
        entries.append({
            "phase": phase,
            "run_id": run_id,
            "dir": str(d.relative_to(afk_root)),
            "log": str(log_file.relative_to(afk_root)) if log_file else None,
            "size": size,
            "mtime": mtime,
            "mtime_iso": datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat(),
            "outcome": outcome,
        })
    entries.sort(key=lambda e: e["mtime"], reverse=True)
    return entries


SENTINEL_RE = re.compile(r"<promise>(COMPLETE|NO_CHANGES|BLOCKED)</promise>")


def sniff_outcome(log_file: Path | None) -> str | None:
    if not log_file or not log_file.is_file():
        return None
    try:
        with open(log_file, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            chunk = max(size - 8192, 0)
            f.seek(chunk)
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    m = SENTINEL_RE.search(tail)
    return m.group(1) if m else None


def tail_file(path: Path, lines: int) -> str:
    """Read approximately the last `lines` lines from a file, in O(lines)."""
    if not path.is_file():
        return ""
    block = 8192
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            if size == 0:
                return ""
            data = b""
            seen = 0
            pos = size
            while seen <= lines and pos > 0:
                read_size = min(block, pos)
                pos -= read_size
                f.seek(pos)
                chunk = f.read(read_size)
                data = chunk + data
                seen = data.count(b"\n")
            text = data.decode("utf-8", "replace")
            return "\n".join(text.splitlines()[-lines:])
    except OSError as e:
        return f"<dashboard: cannot read {path}: {e}>"


def read_events(afk_root: Path, since_ts: float | None, limit: int) -> list[dict[str, Any]]:
    f = afk_root / ".afk" / "logs" / "events.ndjson"
    if not f.is_file():
        return []
    out: list[dict[str, Any]] = []
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if since_ts and ev.get("ts_epoch", 0) <= since_ts:
                    continue
                out.append(ev)
    except OSError:
        return out
    return out[-limit:]


# --- External commands (worktree, tracker) -----------------------------------


def run_cmd(cmd: list[str], cwd: Path | None = None, timeout: float = 10.0) -> tuple[int, str, str]:
    try:
        r = subprocess.run(
            cmd, cwd=str(cwd) if cwd else None, capture_output=True,
            text=True, timeout=timeout,
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except FileNotFoundError:
        return 127, "", f"command not found: {cmd[0]}"
    except OSError as e:
        return 1, "", str(e)


def list_worktrees(afk_root: Path) -> list[dict[str, Any]]:
    rc, out, _ = run_cmd(["git", "worktree", "list", "--porcelain"], cwd=afk_root)
    if rc != 0:
        return []
    items: list[dict[str, Any]] = []
    cur: dict[str, Any] = {}
    for line in out.splitlines():
        if not line.strip():
            if cur:
                items.append(cur)
                cur = {}
            continue
        if line.startswith("worktree "):
            cur["path"] = line[len("worktree "):]
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):]
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].replace("refs/heads/", "")
        elif line == "detached":
            cur["detached"] = True
    if cur:
        items.append(cur)
    return items


# --- Tracker cache -----------------------------------------------------------


class TrackerCache:
    """30-second TTL cache for glab/gh calls. Keyed by command tuple."""

    def __init__(self, ttl: float = 30.0, enabled: bool = True):
        self.ttl = ttl
        self.enabled = enabled
        self._cache: dict[tuple[str, ...], tuple[float, Any]] = {}
        self._lock = threading.Lock()

    def get(self, key: tuple[str, ...], fetch):
        if not self.enabled:
            return None
        now = time.time()
        with self._lock:
            cached = self._cache.get(key)
            if cached and now - cached[0] < self.ttl:
                return cached[1]
        try:
            value = fetch()
        except Exception as e:  # noqa: BLE001 — never let tracker break the UI
            value = {"error": str(e)}
        with self._lock:
            self._cache[key] = (time.time(), value)
        return value


def tracker_pr_for_branch(repo: str, tracker: str, branch: str) -> dict[str, Any] | None:
    if tracker == "gitlab":
        rc, out, err = run_cmd(
            ["glab", "mr", "list", "-R", repo, "--source-branch", branch,
             "--output", "json"], timeout=15.0,
        )
    else:
        rc, out, err = run_cmd(
            ["gh", "pr", "list", "-R", repo, "--head", branch,
             "--state", "open", "--json",
             "number,title,url,state,mergeable,statusCheckRollup,headRefName,baseRefName"],
            timeout=15.0,
        )
    if rc != 0 or not out.strip():
        return None
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return None
    if not data:
        return None
    item = data[0]
    if tracker == "gitlab":
        return {
            "number": item.get("iid"),
            "title": item.get("title"),
            "url": item.get("web_url"),
            "state": item.get("state"),
            "head_pipeline_status": (item.get("head_pipeline") or {}).get("status"),
            "merge_status": item.get("merge_status"),
            "head": item.get("source_branch"),
            "base": item.get("target_branch"),
        }
    return item


def ci_status_from_pr(pr: dict[str, Any] | None, tracker: str) -> str:
    if not pr:
        return "NONE"
    if tracker == "gitlab":
        s = (pr.get("head_pipeline_status") or "").lower()
        if s in ("success", "manual"):
            return "GREEN"
        if s in ("failed", "canceled"):
            return "RED"
        if s in ("running", "pending", "created", "preparing", "scheduled", "waiting_for_resource"):
            return "PENDING"
        if s in ("", "none", "null"):
            return "GREEN"
        return "UNKNOWN"
    # github statusCheckRollup is a list of check objects with .conclusion / .status
    rollup = pr.get("statusCheckRollup") or []
    if not rollup:
        return "GREEN"
    concs = {(c.get("conclusion") or c.get("state") or "").upper() for c in rollup}
    if any(c in {"FAILURE", "TIMED_OUT", "CANCELLED", "ERROR"} for c in concs):
        return "RED"
    if any(c in {"", "PENDING", "IN_PROGRESS", "QUEUED"} for c in concs):
        return "PENDING"
    if any(c in {"SUCCESS", "NEUTRAL", "SKIPPED"} for c in concs):
        return "GREEN"
    return "UNKNOWN"


# --- Aggregator --------------------------------------------------------------


@dataclass
class Dashboard:
    afk_root: Path
    cfg: dict[str, Any] = field(default_factory=dict)
    tracker_cache: TrackerCache = field(default_factory=TrackerCache)

    @property
    def afk_dir(self) -> Path:
        return self.afk_root / ".afk"

    @property
    def phases(self) -> list[str]:
        ps = self.cfg.get("phases") or DEFAULT_PHASES
        return [normalise_phase(p) for p in ps]

    def summary(self) -> dict[str, Any]:
        procs = scan_afk_processes(self.afk_root)
        orch_log = self.afk_dir / "logs" / "orchestrator.log"
        return {
            "afk_root": str(self.afk_root),
            "tracker": self.cfg.get("tracker"),
            "repo": self.cfg.get("repo"),
            "default_branch": self.cfg.get("default_branch"),
            "max_parallel": self.cfg.get("max_parallel"),
            "merge_mode": self.cfg.get("merge_mode"),
            "phases": self.phases,
            "now": datetime.now(tz=timezone.utc).isoformat(),
            "processes": procs,
            "orchestrator_alive": bool(procs["orchestrators"]),
            "orchestrator_log_size": orch_log.stat().st_size if orch_log.is_file() else 0,
        }

    def issue_view(self, state: dict[str, Any], procs: dict[str, Any]) -> dict[str, Any]:
        issue = int(state.get("issue") or 0)
        completed = [normalise_phase(p) for p in (state.get("completed_phases") or [])]
        phase_runs = list_phase_logs(self.afk_root, issue)
        latest_per_phase: dict[str, dict[str, Any]] = {}
        for r in phase_runs:
            latest_per_phase.setdefault(r["phase"], r)
        active_phase = None
        for ph in procs.get("phases", []):
            if ph.get("issue") == issue:
                active_phase = ph.get("phase")
                break
        # Build pipeline. Look up each canonical phase under any of its
        # historical disk spellings (e.g. "merge" log dirs map to phase
        # "pr_merge"). Duration is computed from the run_id timestamp
        # (when run-phase.sh created the log dir) to the log file's
        # mtime (last write). This is the most accurate signal we have
        # without telemetry events present.
        pipeline = []
        for ph in self.phases:
            run = None
            for variant in denormalise_phase(ph):
                run = latest_per_phase.get(variant)
                if run:
                    break
            done = ph in completed or (run and run.get("outcome") in ("COMPLETE", "NO_CHANGES"))
            status = "completed" if done else ("running" if ph == active_phase else "pending")
            duration_s = None
            if run and run.get("run_id"):
                try:
                    # run-phase.sh writes RUN_ID via `date +%Y%m%d-%H%M%S` (no
                    # -u), so it's local time. mktime() interprets a struct_time
                    # in local time, which is exactly what we want.
                    naive = datetime.strptime(run["run_id"], "%Y%m%d-%H%M%S")
                    start_epoch = time.mktime(naive.timetuple())
                    duration_s = max(0, int(run["mtime"] - start_epoch))
                except (ValueError, OverflowError):
                    pass
            entry = {
                "phase": ph,
                "status": status,
                "outcome": (run or {}).get("outcome"),
                "log": (run or {}).get("log"),
                "mtime_iso": (run or {}).get("mtime_iso"),
                "duration_s": duration_s,
                "run_id": (run or {}).get("run_id"),
            }
            pipeline.append(entry)
        history = state.get("history") or []
        pr_num = state.get("pr")
        pr_info: dict[str, Any] | None = None
        ci = None
        if pr_num and self.cfg.get("repo"):
            tr = (self.cfg.get("tracker") or "github").lower()
            key = ("pr", tr, self.cfg["repo"], state.get("branch") or "")
            pr_info = self.tracker_cache.get(
                key, lambda: tracker_pr_for_branch(self.cfg["repo"], tr, state.get("branch") or "")
            )
            ci = ci_status_from_pr(pr_info if isinstance(pr_info, dict) else None, tr)
        return {
            "issue": issue,
            "branch": state.get("branch"),
            "package": state.get("package"),
            "status": state.get("status"),
            "phase": state.get("phase"),
            "active_phase": active_phase,
            "started_at": state.get("started_at"),
            "updated_at": state.get("updated_at"),
            "completed_phases": completed,
            "pipeline": pipeline,
            "history": history,
            "pr": pr_num,
            "pr_info": pr_info if isinstance(pr_info, dict) else None,
            "ci": ci,
        }

    def issues(self) -> list[dict[str, Any]]:
        states = load_state(self.afk_root)
        procs = scan_afk_processes(self.afk_root)
        return [self.issue_view(s, procs) for s in states]

    def worktrees(self) -> list[dict[str, Any]]:
        return list_worktrees(self.afk_root)

    def events(self, since_ts: float | None, limit: int) -> list[dict[str, Any]]:
        return read_events(self.afk_root, since_ts, limit)


# --- HTTP routing ------------------------------------------------------------


STATIC_DIR = Path(__file__).resolve().parent / "static"


class Handler(BaseHTTPRequestHandler):
    dashboard: Dashboard = None  # type: ignore[assignment]

    server_version = "afk-dashboard/1"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Quiet by default; uncomment for debugging.
        # sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))
        return

    def _send_json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload, default=str, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text: str, status: int = 200, ctype: str = "text/plain; charset=utf-8") -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path) -> None:
        if not path.is_file():
            self._send_text("not found", 404)
            return
        ext = path.suffix.lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
            ".ico": "image/x-icon",
            ".json": "application/json; charset=utf-8",
        }.get(ext, "application/octet-stream")
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                self._send_file(STATIC_DIR / "index.html")
            elif path.startswith("/static/"):
                sub = path[len("/static/"):]
                target = (STATIC_DIR / sub).resolve()
                # path-traversal guard
                if STATIC_DIR.resolve() not in target.parents and target != STATIC_DIR.resolve():
                    self._send_text("forbidden", 403)
                    return
                self._send_file(target)
            elif path == "/healthz":
                self._send_text("ok")
            elif path == "/api/summary":
                self._send_json(self.dashboard.summary())
            elif path == "/api/issues":
                self._send_json({"issues": self.dashboard.issues()})
            elif m := re.match(r"^/api/issues/(\d+)$", path):
                issue = int(m.group(1))
                states = {s.get("issue"): s for s in load_state(self.dashboard.afk_root)}
                state = states.get(issue)
                if not state:
                    self._send_json({"error": "no such issue"}, 404)
                    return
                procs = scan_afk_processes(self.dashboard.afk_root)
                view = self.dashboard.issue_view(state, procs)
                view["phase_runs"] = list_phase_logs(self.dashboard.afk_root, issue)
                self._send_json(view)
            elif m := re.match(r"^/api/issues/(\d+)/log$", path):
                issue = int(m.group(1))
                phase = normalise_phase((q.get("phase") or [""])[0])
                tail = int((q.get("tail") or ["200"])[0])
                tail = max(1, min(tail, 5000))
                log_file = None
                # Try every on-disk spelling of this canonical phase name.
                for variant in denormalise_phase(phase):
                    link = self.dashboard.afk_dir / "logs" / f"issue-{issue}-{variant}-latest"
                    if link.exists():
                        target = link.resolve()
                        candidates = list(target.glob("*.log"))
                        if candidates:
                            log_file = candidates[0]
                            break
                if not log_file:
                    self._send_text("(no log yet)")
                    return
                self._send_text(tail_file(log_file, tail))
            elif path == "/api/orchestrator/log":
                tail = int((q.get("tail") or ["200"])[0])
                tail = max(1, min(tail, 5000))
                f = self.dashboard.afk_dir / "logs" / "orchestrator.log"
                self._send_text(tail_file(f, tail))
            elif m := re.match(r"^/api/issues/(\d+)/runner-log$", path):
                issue = int(m.group(1))
                tail = int((q.get("tail") or ["200"])[0])
                f = self.dashboard.afk_dir / "logs" / f"issue-{issue}-runner.log"
                self._send_text(tail_file(f, max(1, min(tail, 5000))))
            elif path == "/api/worktrees":
                self._send_json({"worktrees": self.dashboard.worktrees()})
            elif path == "/api/events":
                since = q.get("since", [None])[0]
                limit = int((q.get("limit") or ["200"])[0])
                since_ts: float | None = None
                if since:
                    try:
                        since_ts = float(since)
                    except ValueError:
                        since_ts = None
                self._send_json({"events": self.dashboard.events(since_ts, limit)})
            else:
                self._send_text("not found", 404)
        except Exception as e:  # noqa: BLE001 — last-resort: never crash the server thread
            sys.stderr.write(f"[dashboard] error handling {path}: {e}\n")
            self._send_json({"error": str(e)}, 500)


# --- Entrypoint --------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="AFK live dashboard")
    p.add_argument("--root", default=os.environ.get("AFK_ROOT", os.getcwd()),
                   help="Repo path (must contain .afk/). Default: cwd or $AFK_ROOT.")
    p.add_argument("--port", type=int, default=int(os.environ.get("AFK_DASHBOARD_PORT", "8765")))
    p.add_argument("--bind", default=os.environ.get("AFK_DASHBOARD_BIND", "127.0.0.1"))
    p.add_argument("--no-tracker", action="store_true",
                   help="Disable glab/gh calls (use when offline or rate-limited).")
    p.add_argument("--poll-tracker", type=float, default=30.0,
                   help="Cache TTL for tracker calls, seconds (default: 30).")
    args = p.parse_args(argv)

    root = find_afk_root(Path(args.root))
    cfg = read_config(root / ".afk")
    cache = TrackerCache(ttl=args.poll_tracker, enabled=not args.no_tracker)
    dash = Dashboard(afk_root=root, cfg=cfg, tracker_cache=cache)

    # Pre-flight: warn loudly if tracker is enabled but the CLI is missing.
    if not args.no_tracker:
        tracker = (cfg.get("tracker") or "github").lower()
        cli = "glab" if tracker == "gitlab" else "gh"
        if shutil.which(cli) is None:
            sys.stderr.write(f"[dashboard] WARNING: tracker={tracker} but '{cli}' is not on PATH; "
                             f"PR/CI data will be unavailable. Re-run with --no-tracker to silence.\n")

    Handler.dashboard = dash

    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    url = f"http://{args.bind}:{args.port}/"
    sys.stderr.write(f"[dashboard] serving {root} at {url}\n")
    sys.stderr.write(f"[dashboard] config: tracker={cfg.get('tracker')} repo={cfg.get('repo')} "
                     f"max_parallel={cfg.get('max_parallel')}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\n[dashboard] shutting down\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
