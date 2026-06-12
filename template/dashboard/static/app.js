// AFK dashboard — vanilla JS, no dependencies, no build.
//
// Polling model:
//   - /api/summary + /api/issues every `state` tick (default 2s)
//   - /api/worktrees every `slow` tick (default 6s)
//   - selected log every `log` tick (default 2s, paused on hover-scroll)
//   - /api/orchestrator/log every `log` tick (default 4s)

(() => {
  "use strict";

  const $ = (sel) => document.querySelector(sel);
  const el = (tag, attrs = {}, children = []) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") e.className = v;
      else if (k === "html") e.innerHTML = v;
      else if (k.startsWith("on") && typeof v === "function") e.addEventListener(k.slice(2), v);
      else if (v !== undefined && v !== null) e.setAttribute(k, v);
    }
    for (const c of [].concat(children)) {
      if (c == null) continue;
      e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return e;
  };

  const state = {
    summary: null,
    issues: [],
    selectedIssue: null,
    selectedPhase: null,
    logPaused: false,
    logTail: 300,
    refreshRate: 2000,
    timer: null,
    openIssues: new Set(),
  };

  // --- helpers --------------------------------------------------------------

  async function jget(url) {
    const r = await fetch(url, { cache: "no-store" });
    if (!r.ok) throw new Error(`${url} → ${r.status}`);
    const ct = r.headers.get("content-type") || "";
    return ct.includes("json") ? r.json() : r.text();
  }

  function fmtDuration(secs) {
    if (secs == null || isNaN(secs)) return "—";
    if (secs < 60) return `${secs}s`;
    if (secs < 3600) return `${Math.floor(secs / 60)}m${secs % 60}s`;
    return `${Math.floor(secs / 3600)}h${Math.floor((secs % 3600) / 60)}m`;
  }

  function fmtAge(isoStr) {
    if (!isoStr) return "—";
    const t = Date.parse(isoStr);
    if (isNaN(t)) return isoStr;
    const diff = Math.max(0, Math.floor((Date.now() - t) / 1000));
    return fmtDuration(diff) + " ago";
  }

  // --- summary panel --------------------------------------------------------

  function renderSummary(s) {
    state.summary = s;
    const alive = s.orchestrator_alive;
    const reg = s.subprocess_registry || {};
    const unreaped = reg.live_unreaped_spawns || [];
    $("#orch-dot").className = "dot " + (alive ? "alive" : "dead");
    let statusLine = alive
      ? `orchestrator alive · ${s.processes.runners.length} runner${s.processes.runners.length === 1 ? "" : "s"} · ${s.processes.agents.length} agent${s.processes.agents.length === 1 ? "" : "s"}`
      : "orchestrator not running";
    if (unreaped.length) {
      statusLine += ` · registry: ${unreaped.length} live spawn row(s) — see Subprocess registry`;
    }
    $("#orch-status").textContent = statusLine;
    $("#repo-name").textContent = s.repo || "(no repo configured)";
    $("#prd-info").textContent = `${s.tracker || "?"} · max_parallel=${s.max_parallel || "?"} · merge_mode=${s.merge_mode || "auto"}`;

    const panel = $("#orch-panel");
    panel.innerHTML = "";
    const rows = [
      ["root", s.afk_root],
      ["orchestrators", s.processes.orchestrators.map(o => `pid ${o.pid} · up ${fmtDuration(o.runtime_s)}`).join(", ") || "—"],
      ["runners", s.processes.runners.map(r => `#${r.issue} (pid ${r.pid})`).join(", ") || "—"],
      ["phases", s.processes.phases.map(p => `#${p.issue}/${p.phase}`).join(", ") || "—"],
      ["agents", s.processes.agents.length],
      ["phases cfg (child)", (s.phases || []).join(" → ")],
      ["phases cfg (PRD)", (s.prd_phases || []).join(" → ")],
    ];
    for (const [k, v] of rows) {
      panel.appendChild(el("div", { class: "k" }, k));
      panel.appendChild(el("div", { class: "v" }, String(v)));
    }

    const alertBox = $("#subproc-alerts");
    const tailBox = $("#subproc-tail");
    if (alertBox && tailBox) {
      alertBox.innerHTML = "";
      if (unreaped.length) {
        const parts = unreaped.map(
          (u) => `pid ${u.pid} (${u.role || "?"}` + (u.issue != null ? ` · #${u.issue}` : "") + ")"
        );
        alertBox.appendChild(el("div", { class: "subproc-warn" }, [
          "Live processes still marked as spawned in the registry tail: ",
          parts.join("; "),
        ]));
      }
      const recent = reg.recent || [];
      tailBox.textContent = recent.length
        ? recent.map((e) => JSON.stringify(e)).join("\n")
        : "(empty registry tail)";
    }
  }

  // --- issue cards ----------------------------------------------------------

  function renderIssues(list) {
    state.issues = list;
    const container = $("#issues");
    container.innerHTML = "";
    $("#issue-count").textContent = `${list.length} issue${list.length === 1 ? "" : "s"}`;

    // Update log-issue dropdown
    const issueSel = $("#log-issue");
    const prevIssue = state.selectedIssue;
    issueSel.innerHTML = "";
    issueSel.appendChild(el("option", { value: "" }, "— select issue —"));
    for (const i of list) {
      issueSel.appendChild(el("option", { value: String(i.issue) }, `#${i.issue} · ${i.branch || ""}`));
    }
    if (prevIssue) issueSel.value = String(prevIssue);

    for (const issue of list) {
      container.appendChild(renderIssueCard(issue));
    }

    // Default-select the most-recently-updated issue if none chosen
    if (!state.selectedIssue && list.length) {
      const sorted = [...list].sort((a, b) => (b.updated_at || "").localeCompare(a.updated_at || ""));
      const target = sorted.find(i => i.active_phase) || sorted[0];
      if (target) {
        state.selectedIssue = target.issue;
        issueSel.value = String(target.issue);
        rebuildPhaseSelect(target);
        refreshLog();
      }
    }
  }

  function renderIssueCard(issue) {
    const klass = ["issue"];
    if (issue.active_phase) klass.push("is-running");
    else if (issue.status === "done") klass.push("is-done");
    else if ((issue.history || []).some(h => h.outcome === "BLOCKED")) klass.push("is-blocked");
    if (state.openIssues.has(issue.issue)) klass.push("open");

    const head = el("div", { class: "issue-head" }, [
      el("span", { class: "id" }, `#${issue.issue}`),
      el("span", { class: "branch" }, issue.branch || "—"),
      el("span", { class: "spacer" }),
      issue.pr ? el("a", { class: "branch", href: (issue.pr_info && issue.pr_info.url) || "#", target: "_blank", rel: "noopener" }, `PR !${issue.pr}`) : null,
      el("span", { class: `ci ${issue.ci || "NONE"}` }, `CI: ${issue.ci || "—"}`),
      el("span", { class: "muted small" }, fmtAge(issue.updated_at)),
    ]);

    const pipeline = el("div", { class: "pipeline" });
    for (let i = 0; i < issue.pipeline.length; i++) {
      const p = issue.pipeline[i];
      const phaseClasses = ["phase", p.status];
      if (p.outcome) phaseClasses.push("outcome-" + p.outcome);
      const phaseEl = el("span", {
        class: phaseClasses.join(" "),
        title: `${p.phase} · ${p.status}${p.outcome ? " · " + p.outcome : ""}${p.duration_s ? " · " + fmtDuration(p.duration_s) : ""}`,
        onclick: () => {
          state.selectedIssue = issue.issue;
          $("#log-issue").value = String(issue.issue);
          rebuildPhaseSelect(issue);
          $("#log-phase").value = p.phase;
          state.selectedPhase = p.phase;
          refreshLog();
        },
      }, [
        el("span", {}, p.phase),
        p.duration_s ? el("span", { class: "dur" }, "·" + fmtDuration(p.duration_s)) : null,
      ]);
      pipeline.appendChild(phaseEl);
      if (i < issue.pipeline.length - 1) pipeline.appendChild(el("span", { class: "phase arrow" }, "→"));
    }

    const history = el("div", { class: "history" });
    for (const h of (issue.history || []).slice().reverse()) {
      history.appendChild(el("div", { class: "row" }, [
        el("span", { class: "muted" }, h.at || ""),
        el("span", {}, h.phase),
        el("span", { class: "outcome " + (h.outcome || "") }, h.outcome || ""),
        el("span", { class: "muted" }, h.note || ""),
      ]));
    }

    const card = el("div", { class: klass.join(" "), onclick: (e) => {
      if (e.target.closest("a") || e.target.closest(".phase")) return;
      if (state.openIssues.has(issue.issue)) state.openIssues.delete(issue.issue);
      else state.openIssues.add(issue.issue);
      card.classList.toggle("open");
    }}, [head, pipeline, history]);

    return card;
  }

  function rebuildPhaseSelect(issue) {
    const sel = $("#log-phase");
    sel.innerHTML = "";
    sel.appendChild(el("option", { value: "" }, "— phase —"));
    for (const p of issue.pipeline) {
      const tag = p.status === "running" ? " · running" : p.outcome ? " · " + p.outcome : "";
      sel.appendChild(el("option", { value: p.phase }, p.phase + tag));
    }
    // Auto-pick: active phase, else most-recent run
    const auto = issue.active_phase || (issue.pipeline.slice().reverse().find(p => p.mtime_iso) || {}).phase;
    if (auto) {
      sel.value = auto;
      state.selectedPhase = auto;
    }
  }

  // --- worktrees + PRs ------------------------------------------------------

  async function refreshWorktrees() {
    try {
      const data = await jget("/api/worktrees");
      const el1 = $("#worktrees");
      el1.innerHTML = "";
      for (const w of data.worktrees || []) {
        el1.appendChild(el("div", { class: "worktree" }, [
          el("div", { class: "branch" }, w.branch || w.head || "(detached)"),
          el("div", { class: "muted small" }, w.path),
        ]));
      }
      if (!data.worktrees || !data.worktrees.length) el1.appendChild(el("div", { class: "muted small" }, "(none)"));
    } catch (e) {
      $("#worktrees").textContent = String(e);
    }
  }

  function renderPRs() {
    const box = $("#prs");
    box.innerHTML = "";
    const prs = state.issues.filter(i => i.pr).sort((a, b) => Number(b.pr) - Number(a.pr));
    if (!prs.length) {
      box.appendChild(el("div", { class: "muted small" }, "(no open PRs tracked yet)"));
      return;
    }
    for (const i of prs) {
      const url = (i.pr_info && i.pr_info.url) || "#";
      box.appendChild(el("div", { class: "pr" }, [
        el("div", {}, [
          el("a", { href: url, target: "_blank", rel: "noopener" }, `!${i.pr}`),
          el("span", { class: "muted" }, ` · #${i.issue}`),
          el("span", { class: "spacer" }),
          el("span", { class: `ci ${i.ci || "NONE"}`, style: "margin-left:6px" }, i.ci || "—"),
        ]),
        el("div", { class: "branch small" }, i.branch || ""),
      ]));
    }
  }

  // --- log views ------------------------------------------------------------

  async function refreshLog() {
    const issue = state.selectedIssue;
    const phase = state.selectedPhase || $("#log-phase").value;
    const tail = $("#log-tail").value || 300;
    const view = $("#log-view");
    const atBottom = view.scrollTop + view.clientHeight >= view.scrollHeight - 8;
    if (!issue) { view.textContent = "(select an issue)"; return; }
    try {
      const url = phase
        ? `/api/issues/${issue}/log?phase=${encodeURIComponent(phase)}&tail=${tail}`
        : `/api/issues/${issue}/runner-log?tail=${tail}`;
      const text = await jget(url);
      view.textContent = text || "(empty)";
      if (!state.logPaused && atBottom) view.scrollTop = view.scrollHeight;
    } catch (e) {
      view.textContent = `error: ${e}`;
    }
  }

  async function refreshOrchLog() {
    const view = $("#orch-log");
    const atBottom = view.scrollTop + view.clientHeight >= view.scrollHeight - 8;
    try {
      const text = await jget("/api/orchestrator/log?tail=120");
      view.textContent = text || "(empty)";
      if (atBottom) view.scrollTop = view.scrollHeight;
    } catch (e) {
      view.textContent = `error: ${e}`;
    }
  }

  // --- main poll loop -------------------------------------------------------

  let slowTick = 0;
  async function tick() {
    try {
      const [s, i] = await Promise.all([jget("/api/summary"), jget("/api/issues")]);
      renderSummary(s);
      renderIssues(i.issues || []);
      renderPRs();
    } catch (e) {
      $("#orch-status").textContent = "dashboard error: " + e;
      $("#orch-dot").className = "dot dead";
    }
    slowTick++;
    if (slowTick % 3 === 0) refreshWorktrees();
    refreshLog();
    if (slowTick % 2 === 0) refreshOrchLog();
  }

  function startLoop() {
    if (state.timer) clearInterval(state.timer);
    if (!state.refreshRate) return;
    state.timer = setInterval(tick, state.refreshRate);
  }

  // --- wiring ---------------------------------------------------------------

  $("#refresh-rate").addEventListener("change", (e) => {
    state.refreshRate = Number(e.target.value);
    startLoop();
  });

  $("#log-issue").addEventListener("change", (e) => {
    const id = Number(e.target.value) || null;
    state.selectedIssue = id;
    const issue = state.issues.find(i => i.issue === id);
    if (issue) rebuildPhaseSelect(issue);
    refreshLog();
  });
  $("#log-phase").addEventListener("change", (e) => {
    state.selectedPhase = e.target.value || null;
    refreshLog();
  });
  $("#log-tail").addEventListener("change", refreshLog);
  $("#log-pause").addEventListener("click", () => {
    state.logPaused = !state.logPaused;
    $("#log-pause").textContent = state.logPaused ? "▶" : "⏸";
    $("#log-pause").title = state.logPaused ? "Resume auto-scroll" : "Pause auto-scroll";
  });

  $("#theme-toggle").addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    const next = cur === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("afk-theme", next); } catch (_) {}
  });
  try {
    const saved = localStorage.getItem("afk-theme");
    if (saved) document.documentElement.setAttribute("data-theme", saved);
  } catch (_) {}

  tick();
  startLoop();
})();
