from __future__ import annotations

import asyncio
import html
import json
import logging
from http import HTTPStatus
from typing import Any
from urllib.parse import unquote, urlparse

from .logging import log_event
from .orchestrator import Orchestrator
from .utils import now_utc, isoformat_z

LOGGER = logging.getLogger(__name__)


class StatusHTTPServer:
    def __init__(self, orchestrator: Orchestrator, *, host: str = "127.0.0.1", port: int = 0):
        self.orchestrator = orchestrator
        self.host = host
        self.port = port
        self.server: asyncio.AbstractServer | None = None
        self.bound_port: int | None = None

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle, self.host, self.port)
        socket = self.server.sockets[0] if self.server.sockets else None
        self.bound_port = socket.getsockname()[1] if socket else self.port
        log_event(LOGGER, logging.INFO, "http_server_started", host=self.host, port=self.bound_port)

    async def stop(self) -> None:
        if self.server is None:
            return
        self.server.close()
        await self.server.wait_closed()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            request_line = await reader.readline()
            if not request_line:
                return
            method, target, _version = request_line.decode("iso-8859-1").strip().split(" ", 2)
            headers: dict[str, str] = {}
            while True:
                line = await reader.readline()
                if line in {b"\r\n", b"\n", b""}:
                    break
                key, _, value = line.decode("iso-8859-1").partition(":")
                headers[key.lower()] = value.strip()
            length = int(headers.get("content-length", "0") or 0)
            if length:
                await reader.readexactly(length)
            parsed = urlparse(target)
            await self._route(method.upper(), parsed.path, writer)
        except Exception as exc:
            await self._send_json(writer, HTTPStatus.INTERNAL_SERVER_ERROR, {"error": {"code": "internal_error", "message": str(exc)}})
        finally:
            writer.close()
            await writer.wait_closed()

    async def _route(self, method: str, path: str, writer: asyncio.StreamWriter) -> None:
        if path == "/":
            if method != "GET":
                await self._method_not_allowed(writer)
                return
            await self._send_html(writer, HTTPStatus.OK, self._dashboard_html(await self.orchestrator.snapshot()))
            return
        if path == "/api/v1/state":
            if method != "GET":
                await self._method_not_allowed(writer)
                return
            await self._send_json(writer, HTTPStatus.OK, await self.orchestrator.snapshot())
            return
        if path == "/api/v1/refresh":
            if method != "POST":
                await self._method_not_allowed(writer)
                return
            coalesced = await self.orchestrator.request_refresh()
            await self._send_json(
                writer,
                HTTPStatus.ACCEPTED,
                {
                    "queued": True,
                    "coalesced": coalesced,
                    "requested_at": isoformat_z(now_utc()),
                    "operations": ["poll", "reconcile"],
                },
            )
            return
        if path.startswith("/api/v1/"):
            if method != "GET":
                await self._method_not_allowed(writer)
                return
            issue_identifier = unquote(path.removeprefix("/api/v1/"))
            detail = await self.orchestrator.issue_snapshot(issue_identifier)
            if detail is None:
                await self._send_json(
                    writer,
                    HTTPStatus.NOT_FOUND,
                    {"error": {"code": "issue_not_found", "message": f"issue is not known: {issue_identifier}"}},
                )
                return
            await self._send_json(writer, HTTPStatus.OK, detail)
            return
        await self._send_json(writer, HTTPStatus.NOT_FOUND, {"error": {"code": "not_found", "message": "route not found"}})

    async def _method_not_allowed(self, writer: asyncio.StreamWriter) -> None:
        await self._send_json(writer, HTTPStatus.METHOD_NOT_ALLOWED, {"error": {"code": "method_not_allowed", "message": "method not allowed"}})

    async def _send_json(self, writer: asyncio.StreamWriter, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True, default=str).encode("utf-8")
        await self._send(writer, status, "application/json; charset=utf-8", body)

    async def _send_html(self, writer: asyncio.StreamWriter, status: HTTPStatus, text: str) -> None:
        await self._send(writer, status, "text/html; charset=utf-8", text.encode("utf-8"))

    async def _send(self, writer: asyncio.StreamWriter, status: HTTPStatus, content_type: str, body: bytes) -> None:
        writer.write(
            (
                f"HTTP/1.1 {status.value} {status.phrase}\r\n"
                f"Content-Type: {content_type}\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode("ascii")
            + body
        )
        await writer.drain()

    def _dashboard_html(self, snapshot: dict[str, Any]) -> str:
        return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Symphony</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f7f8fa;
      --panel: #ffffff;
      --text: #17202a;
      --muted: #637083;
      --border: #d9dee7;
      --blue: #1b5fcc;
      --green: #1f7a4d;
      --amber: #9a6200;
      --red: #b42318;
      --shadow: 0 1px 2px rgba(16, 24, 40, .06);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 14px;
      line-height: 1.45;
    }}
    header {{
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 1rem;
      padding: 1.25rem 1.5rem .75rem;
      border-bottom: 1px solid var(--border);
      background: #fff;
      position: sticky;
      top: 0;
      z-index: 5;
    }}
    h1 {{ margin: 0; font-size: 1.15rem; letter-spacing: 0; }}
    h2 {{ margin: 0 0 .75rem; font-size: .9rem; letter-spacing: 0; color: var(--muted); font-weight: 700; }}
    main {{ padding: 1rem 1.5rem 1.5rem; }}
    button {{
      border: 1px solid var(--border);
      border-radius: 6px;
      background: #fff;
      color: var(--text);
      padding: .45rem .7rem;
      font: inherit;
      cursor: pointer;
    }}
    button:hover {{ border-color: #a8b2c1; }}
    .meta {{ color: var(--muted); font-size: .82rem; margin-top: .2rem; }}
    .actions {{ display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; justify-content: flex-end; }}
    .stats {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: .75rem;
      margin-bottom: 1rem;
    }}
    .stat {{
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: .8rem .9rem;
      min-width: 0;
    }}
    .stat-value {{ display: block; font-size: 1.35rem; font-weight: 750; line-height: 1.2; }}
    .stat-label {{ color: var(--muted); font-size: .78rem; }}
    .issue-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: .85rem; margin-bottom: 1.25rem; }}
    .issue {{
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: .95rem;
      min-width: 0;
    }}
    .issue-head {{ display: flex; align-items: flex-start; justify-content: space-between; gap: .75rem; margin-bottom: .75rem; }}
    .issue-title {{ min-width: 0; }}
    .issue-title a {{ color: var(--text); text-decoration: none; font-weight: 750; }}
    .issue-title a:hover {{ color: var(--blue); text-decoration: underline; }}
    .badges {{ display: flex; gap: .35rem; flex-wrap: wrap; justify-content: flex-end; }}
    .badge {{
      display: inline-flex;
      align-items: center;
      border-radius: 999px;
      border: 1px solid var(--border);
      padding: .12rem .45rem;
      font-size: .72rem;
      white-space: nowrap;
      color: var(--muted);
      background: #fff;
    }}
    .badge.ok {{ color: var(--green); border-color: #a9d7bf; background: #f2fbf6; }}
    .badge.warn {{ color: var(--amber); border-color: #e5ca91; background: #fff8e8; }}
    .badge.bad {{ color: var(--red); border-color: #f0b4ad; background: #fff3f1; }}
    .summary {{
      border-left: 3px solid var(--blue);
      padding-left: .75rem;
      margin: .65rem 0 .75rem;
      min-height: 3rem;
    }}
    .summary.attention {{ border-left-color: var(--red); }}
    .summary-text {{ margin: 0 0 .45rem; font-size: .95rem; }}
    .step {{ color: var(--muted); font-size: .82rem; }}
    .attention-reason {{ color: var(--red); margin-top: .45rem; font-size: .82rem; }}
    .activity {{ margin: .75rem 0 0; padding: 0; list-style: none; max-height: 10rem; overflow: auto; border-top: 1px solid var(--border); }}
    .activity li {{ padding: .42rem 0; border-bottom: 1px solid #edf0f4; overflow-wrap: anywhere; }}
    .activity-time {{ color: var(--muted); font-size: .74rem; margin-right: .35rem; }}
    .details {{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: .5rem; margin-top: .75rem; }}
    .detail {{ min-width: 0; }}
    .detail-label {{ color: var(--muted); font-size: .72rem; }}
    .detail-value {{ overflow-wrap: anywhere; font-weight: 650; }}
    .repo-plan {{
      margin-top: .75rem;
      padding-top: .65rem;
      border-top: 1px solid var(--border);
    }}
    .repo-title {{ color: var(--muted); font-size: .72rem; font-weight: 700; margin-bottom: .35rem; }}
    .repo-list {{ display: flex; gap: .35rem; flex-wrap: wrap; }}
    .repo-chip {{
      display: inline-flex;
      align-items: center;
      max-width: 100%;
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: .18rem .4rem;
      font-size: .74rem;
      background: #fbfcfd;
      overflow-wrap: anywhere;
    }}
    .repo-chip.primary {{ border-color: #a9c2ef; color: var(--blue); background: #f3f7ff; }}
    .repo-chip.readonly {{ color: var(--muted); background: #f7f8fa; }}
    table {{ border-collapse: collapse; width: 100%; background: #fff; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }}
    th, td {{ border-bottom: 1px solid #edf0f4; padding: .6rem; text-align: left; vertical-align: top; }}
    th {{ color: var(--muted); font-size: .78rem; font-weight: 700; background: #fbfcfd; }}
    .empty {{ color: var(--muted); background: #fff; border: 1px dashed var(--border); border-radius: 8px; padding: 1rem; }}
    @media (max-width: 760px) {{
      header {{ position: static; flex-direction: column; }}
      main {{ padding: 1rem; }}
      .stats {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
      .issue-grid {{ grid-template-columns: 1fr; }}
      .details {{ grid-template-columns: 1fr; }}
      .actions {{ justify-content: flex-start; }}
    }}
  </style>
</head>
<body>
  <header>
    <div>
      <h1>Symphony</h1>
      <div class="meta" id="generated">Generated at {html.escape(str(snapshot.get('generated_at')))}</div>
    </div>
    <div class="actions">
      <button id="refresh" type="button">Refresh</button>
      <a href="/api/v1/state">State JSON</a>
    </div>
  </header>
  <main>
    <section class="stats" id="stats"></section>
    <section>
      <h2>Running Agents</h2>
      <div class="issue-grid" id="running"></div>
    </section>
    <section>
      <h2>Continuing / Retrying</h2>
      <div id="retrying"></div>
    </section>
    <section>
      <h2>Blocked</h2>
      <div id="blocked"></div>
    </section>
    <section>
      <h2>Completed</h2>
      <div id="completed"></div>
    </section>
  </main>
  <script>
    const stateUrl = "/api/v1/state";
    const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) => ({{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}}[ch]));
    const duration = (seconds) => {{
      const value = Number(seconds || 0);
      if (value < 60) return `${{value.toFixed(0)}}s`;
      if (value < 3600) return `${{Math.floor(value / 60)}}m ${{Math.floor(value % 60)}}s`;
      return `${{Math.floor(value / 3600)}}h ${{Math.floor((value % 3600) / 60)}}m`;
    }};
    const shortTime = (iso) => {{
      if (!iso) return "unknown";
      const date = new Date(iso);
      return Number.isNaN(date.getTime()) ? iso : date.toLocaleTimeString();
    }};
    const riskClass = (risk, needsHuman) => needsHuman ? "bad" : risk === "high" ? "bad" : risk === "medium" ? "warn" : "ok";

    function renderStats(state) {{
      const totals = state.codex_totals || {{}};
      const service = state.service || {{}};
      document.getElementById("stats").innerHTML = [
        ["Service", service.status || "unknown"],
        ["Running", state.counts?.running ?? 0],
        ["Continuing", state.counts?.continuing ?? 0],
        ["Retrying", state.counts?.retrying ?? 0],
        ["Needs attention", (state.running || []).filter((row) => row.summary?.needs_human).length],
        ["Blocked", state.counts?.blocked ?? 0],
        ["Completed", state.counts?.completed ?? 0],
        ["Tokens", totals.total_tokens ?? 0],
      ].map(([label, value]) => `<div class="stat"><span class="stat-value">${{esc(value)}}</span><span class="stat-label">${{esc(label)}}</span></div>`).join("");
    }}

    function renderRepoPlan(plan) {{
      if (!plan || !plan.coding_task) return "";
      const chips = [];
      if (plan.primary_repo) chips.push(`<span class="repo-chip primary">Primary: ${{esc(plan.primary_repo.slug)}}</span>`);
      for (const repo of plan.secondary_repos || []) {{
        chips.push(`<span class="repo-chip">Secondary: ${{esc(repo.slug)}}${{repo.edit_allowed ? "" : " (read-only)"}}</span>`);
      }}
      for (const repo of plan.read_only_context_repos || []) {{
        chips.push(`<span class="repo-chip readonly">Context: ${{esc(repo.slug)}}</span>`);
      }}
      if (!chips.length) return "";
      return `<div class="repo-plan"><div class="repo-title">Repo plan</div><div class="repo-list">${{chips.join("")}}</div></div>`;
    }}

    function renderIssue(row) {{
      const summary = row.summary || {{}};
      const needsHuman = Boolean(summary.needs_human);
      const risk = summary.risk || "unknown";
      const summaryText = summary.text || (summary.pending ? "LLM summary is updating." : "Waiting for the first LLM summary.");
      const currentStep = summary.current_step || row.last_event || "Starting.";
      const title = row.title ? `${{row.issue_identifier}} · ${{row.title}}` : row.issue_identifier;
      const issueLink = row.url ? `<a href="${{esc(row.url)}}" target="_blank" rel="noreferrer">${{esc(title)}}</a>` : esc(title);
      const activity = (row.activity || []).slice(-6).reverse().map((item) => (
        `<li><span class="activity-time">${{esc(shortTime(item.at))}}</span>${{esc(item.message)}}</li>`
      )).join("");
      const attentionReason = needsHuman && summary.human_reason ? `<div class="attention-reason">${{esc(summary.human_reason)}}</div>` : "";
      return `
        <article class="issue">
          <div class="issue-head">
            <div class="issue-title">${{issueLink}}<div class="meta">${{esc(row.state || "unknown")}} · turn ${{esc(row.turn_count || 0)}}</div></div>
            <div class="badges">
              <span class="badge ${{needsHuman ? "bad" : "ok"}}">${{needsHuman ? "Needs human" : "No intervention"}}</span>
              <span class="badge ${{riskClass(risk, needsHuman)}}">Risk: ${{esc(risk)}}</span>
              ${{summary.pending ? '<span class="badge warn">Summarizing</span>' : ""}}
              ${{summary.stale && !summary.pending ? '<span class="badge warn">New activity</span>' : ""}}
            </div>
          </div>
          <div class="summary ${{needsHuman ? "attention" : ""}}">
            <p class="summary-text">${{esc(summaryText)}}</p>
            <div class="step">Current step: ${{esc(currentStep)}}</div>
            ${{attentionReason}}
          </div>
          <div class="details">
            <div class="detail"><div class="detail-label">Elapsed</div><div class="detail-value">${{duration(row.elapsed_seconds)}}</div></div>
            <div class="detail"><div class="detail-label">Tokens</div><div class="detail-value">${{esc(row.tokens?.total_tokens ?? 0)}}</div></div>
            <div class="detail"><div class="detail-label">Summary</div><div class="detail-value">${{summary.updated_at ? shortTime(summary.updated_at) : "pending"}}</div></div>
          </div>
          ${{renderRepoPlan(row.repo_plan)}}
          ${{activity ? `<ul class="activity">${{activity}}</ul>` : '<div class="meta">No activity captured yet.</div>'}}
        </article>
      `;
    }}

    function renderBlocked(state) {{
      const blocked = state.blocked || [];
      if (!blocked.length) {{
        document.getElementById("blocked").innerHTML = '<div class="empty">No blocked issues.</div>';
        return;
      }}
      document.getElementById("blocked").innerHTML = `
        <table><thead><tr><th>Issue</th><th>Reason</th><th>Repo plan</th><th>Blocked</th></tr></thead><tbody>
          ${{blocked.map((row) => {{
            const title = row.title ? `${{row.issue_identifier}} · ${{row.title}}` : row.issue_identifier;
            const issue = row.url ? `<a href="${{esc(row.url)}}" target="_blank" rel="noreferrer">${{esc(title)}}</a>` : esc(title);
            return `<tr><td>${{issue}}</td><td>${{esc(row.reason || "")}}</td><td>${{renderRepoPlan(row.repo_plan)}}</td><td>${{esc(row.blocked_at || "")}}</td></tr>`;
          }}).join("")}}
        </tbody></table>
      `;
    }}

    function renderRetrying(state) {{
      const retrying = state.retrying || [];
      if (!retrying.length) {{
        document.getElementById("retrying").innerHTML = '<div class="empty">No queued continuation or failure retry.</div>';
        return;
      }}
      document.getElementById("retrying").innerHTML = `
        <table><thead><tr><th>Issue</th><th>Status</th><th>Attempt</th><th>Due</th><th>Reason</th></tr></thead><tbody>
          ${{retrying.map((row) => {{
            const status = row.kind === "continuation" ? "Continuing" : "Retrying";
            const badge = row.kind === "continuation" ? "ok" : "warn";
            const reason = row.kind === "continuation" ? "Clean worker exit; rechecking whether issue is still active." : (row.error || "");
            return `<tr><td>${{esc(row.issue_identifier)}}</td><td><span class="badge ${{badge}}">${{status}}</span></td><td>${{esc(row.attempt)}}</td><td>${{esc(row.due_at)}}</td><td>${{esc(reason)}}</td></tr>`;
          }}).join("")}}
        </tbody></table>
      `;
    }}

    function renderCompleted(state) {{
      const completed = state.completed || [];
      if (!completed.length) {{
        document.getElementById("completed").innerHTML = '<div class="empty">No completed runs recorded yet.</div>';
        return;
      }}
      document.getElementById("completed").innerHTML = `
        <table><thead><tr><th>Issue</th><th>Completed</th><th>Reason</th><th>Turns</th><th>Tokens</th></tr></thead><tbody>
          ${{completed.slice(0, 25).map((row) => {{
            const title = row.title ? `${{row.issue_identifier}} · ${{row.title}}` : row.issue_identifier;
            const issue = row.url ? `<a href="${{esc(row.url)}}" target="_blank" rel="noreferrer">${{esc(title)}}</a>` : esc(title);
            return `<tr><td>${{issue}}</td><td>${{esc(row.completed_at || "")}}</td><td>${{esc(row.reason || "")}}</td><td>${{esc(row.turn_count ?? 0)}}</td><td>${{esc(row.tokens?.total_tokens ?? 0)}}</td></tr>`;
          }}).join("")}}
        </tbody></table>
      `;
    }}

    function render(state) {{
      document.getElementById("generated").textContent = `Generated at ${{state.generated_at || "unknown"}}`;
      renderStats(state);
      const running = state.running || [];
      const service = state.service || {{}};
      const emptyRunning = service.status === "starting"
        ? "Symphony is starting; startup cleanup or the first tracker poll has not finished yet."
        : service.status === "polling"
          ? "Symphony is polling the tracker now."
          : "No running agents.";
      document.getElementById("running").innerHTML = running.length ? running.map(renderIssue).join("") : `<div class="empty">${{esc(emptyRunning)}}</div>`;
      renderRetrying(state);
      renderBlocked(state);
      renderCompleted(state);
    }}

    async function loadState() {{
      const response = await fetch(stateUrl, {{ cache: "no-store" }});
      if (!response.ok) throw new Error(`State request failed: ${{response.status}}`);
      render(await response.json());
    }}

    document.getElementById("refresh").addEventListener("click", async () => {{
      await fetch("/api/v1/refresh", {{ method: "POST" }});
      await loadState();
    }});
    loadState().catch((error) => {{
      document.getElementById("running").innerHTML = `<div class="empty">${{esc(error.message)}}</div>`;
    }});
    setInterval(() => loadState().catch(() => {{}}), 5000);
  </script>
</body>
</html>"""
