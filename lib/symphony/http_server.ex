defmodule Symphony.HTTPServer do
  @moduledoc false

  alias Symphony.Error
  alias Symphony.Orchestrator
  alias Symphony.Utils

  @agent_read_timeout_ms 250
  @fallback_state_path ".symphony-workspaces/.symphony-state.json"

  defstruct orchestrator: nil,
            host: "127.0.0.1",
            port: 0,
            listen_socket: nil,
            bound_port: nil,
            acceptor: nil

  def start(orchestrator, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 0)
    ip = parse_bind_host!(host)

    socket =
      case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, ip: ip]) do
        {:ok, socket} ->
          socket

        {:error, reason} ->
          raise Error,
            code: :http_server_bind_failed,
            message:
              "failed to bind Symphony HTTP server on #{host}:#{port}: #{format_inet_error(reason)}",
            cause: reason
      end

    bound_port =
      case :inet.port(socket) do
        {:ok, bound_port} ->
          bound_port

        {:error, reason} ->
          :gen_tcp.close(socket)

          raise Error,
            code: :http_server_bind_failed,
            message:
              "failed to read Symphony HTTP server port for #{host}:#{port}: #{format_inet_error(reason)}",
            cause: reason
      end

    server = %__MODULE__{
      orchestrator: orchestrator,
      host: host,
      port: port,
      listen_socket: socket,
      bound_port: bound_port
    }

    acceptor = spawn_link(fn -> accept_loop(server) end)
    %{server | acceptor: acceptor}
  end

  defp parse_bind_host!(host) do
    case host |> to_charlist() |> :inet.parse_address() do
      {:ok, ip} ->
        ip

      {:error, reason} ->
        raise Error,
          code: :http_server_bind_failed,
          message:
            "failed to parse Symphony HTTP bind host #{inspect(host)}: #{format_inet_error(reason)}",
          cause: reason
    end
  end

  defp format_inet_error(reason) when is_atom(reason), do: ":#{reason}"
  defp format_inet_error(reason), do: inspect(reason)

  def stop(%__MODULE__{} = server) do
    if server.acceptor, do: Process.exit(server.acceptor, :normal)
    if server.listen_socket, do: :gen_tcp.close(server.listen_socket)
    :ok
  end

  defp accept_loop(server) do
    case :gen_tcp.accept(server.listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, server.orchestrator) end)
        accept_loop(server)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(socket, orchestrator) do
    with {:ok, request_line} <- :gen_tcp.recv(socket, 0, 5_000),
         [method, target | _] <-
           request_line |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ", parts: 3) do
      drain_headers(socket)
      route(socket, method, URI.parse(target).path || "/", orchestrator)
    else
      _ ->
        send_json(socket, 500, %{
          "error" => %{"code" => "internal_error", "message" => "invalid request"}
        })
    end
  after
    :gen_tcp.close(socket)
  end

  defp drain_headers(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        unless String.contains?(data, "\r\n\r\n"), do: drain_headers(socket)

      _ ->
        :ok
    end
  end

  defp route(socket, "GET", "/", orchestrator) do
    snapshot = snapshot(orchestrator)
    send_html(socket, 200, dashboard_html(snapshot))
  end

  defp route(socket, "GET", "/api/v1/state", orchestrator),
    do: send_json(socket, 200, snapshot(orchestrator))

  defp route(socket, "POST", "/api/v1/refresh", orchestrator) do
    coalesced =
      if is_pid(orchestrator) do
        Orchestrator.request_refresh(orchestrator, @agent_read_timeout_ms)
      else
        false
      end

    send_json(socket, 202, %{
      "queued" => true,
      "coalesced" => coalesced,
      "requested_at" => Utils.isoformat_z(Utils.now_utc()),
      "operations" => ["poll", "reconcile"]
    })
  catch
    :exit, _ ->
      send_json(socket, 202, %{
        "queued" => true,
        "coalesced" => true,
        "requested_at" => Utils.isoformat_z(Utils.now_utc()),
        "operations" => ["poll", "reconcile"]
      })
  end

  defp route(socket, "GET", "/api/v1/" <> issue_identifier, orchestrator) do
    case issue_snapshot(orchestrator, URI.decode(issue_identifier)) do
      nil ->
        send_json(socket, 404, %{
          "error" => %{
            "code" => "issue_not_found",
            "message" => "issue is not known: #{issue_identifier}"
          }
        })

      detail ->
        send_json(socket, 200, detail)
    end
  end

  defp route(socket, _method, _path, _orchestrator),
    do:
      send_json(socket, 404, %{
        "error" => %{"code" => "not_found", "message" => "route not found"}
      })

  defp snapshot(source) when is_pid(source) do
    Orchestrator.cached_snapshot(source) ||
      Orchestrator.snapshot(source, @agent_read_timeout_ms)
  catch
    :exit, _ -> persisted_snapshot()
  end

  defp snapshot(source), do: Orchestrator.snapshot(source)

  defp issue_snapshot(source, issue_identifier) when is_pid(source) do
    Orchestrator.cached_issue_snapshot(source, issue_identifier) ||
      Orchestrator.issue_snapshot(source, issue_identifier, @agent_read_timeout_ms)
  catch
    :exit, _ -> persisted_issue_snapshot(issue_identifier)
  end

  defp issue_snapshot(source, issue_identifier),
    do: Orchestrator.issue_snapshot(source, issue_identifier)

  defp send_json(socket, status, payload),
    do: send_response(socket, status, "application/json; charset=utf-8", Jason.encode!(payload))

  defp send_html(socket, status, body),
    do: send_response(socket, status, "text/html; charset=utf-8", body)

  defp send_response(socket, status, content_type, body) do
    reason =
      %{200 => "OK", 202 => "Accepted", 404 => "Not Found", 500 => "Internal Server Error"}[
        status
      ] || "OK"

    response = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp persisted_snapshot do
    case persisted_payload() do
      {:ok, payload} -> fallback_snapshot(payload)
      :error -> empty_snapshot()
    end
  end

  defp persisted_issue_snapshot(issue_identifier) do
    case persisted_payload() do
      {:ok, payload} ->
        issue_identifier = to_string(issue_identifier)

        Enum.find_value(payload["completed"] || [], fn entry ->
          issue = if is_map(entry), do: entry["issue"] || %{}, else: %{}

          if issue["identifier"] == issue_identifier do
            fallback_completed_entry(entry)
          end
        end)

      :error ->
        nil
    end
  end

  defp persisted_payload do
    with {:ok, body} <- @fallback_state_path |> Path.expand(File.cwd!()) |> File.read(),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp fallback_snapshot(payload) do
    retrying = Enum.map(payload["retry_attempts"] || [], &fallback_retry_entry/1)
    continuing_count = Enum.count(retrying, &(&1["kind"] == "continuation"))
    retrying_count = length(retrying) - continuing_count
    blocked = Enum.map(payload["blocked"] || [], &fallback_blocked_entry/1)
    completed = Enum.map(payload["completed"] || [], &fallback_completed_entry/1)
    service = if is_map(payload["service"]), do: payload["service"], else: %{}

    %{
      "generated_at" => Utils.isoformat_z(Utils.now_utc()),
      "service" => %{
        "status" => "busy",
        "startup_completed_at" => service["startup_completed_at"],
        "last_poll_started_at" => service["last_poll_started_at"],
        "last_poll_completed_at" => service["last_poll_completed_at"],
        "last_poll_error" => service["last_poll_error"],
        "last_candidate_count" => service["last_candidate_count"],
        "poll_interval_ms" => service["poll_interval_ms"],
        "max_concurrent_agents" => service["max_concurrent_agents"],
        "snapshot_source" => "persisted_state"
      },
      "counts" => %{
        "running" => 0,
        "continuing" => continuing_count,
        "retrying" => retrying_count,
        "queued" => length(retrying),
        "blocked" => length(blocked),
        "completed" => length(completed)
      },
      "running" => [],
      "retrying" => retrying,
      "blocked" => blocked,
      "completed" => completed,
      "codex_totals" => payload["codex_totals"] || %{},
      "rate_limits" => payload["rate_limits"]
    }
  end

  defp empty_snapshot do
    %{
      "generated_at" => Utils.isoformat_z(Utils.now_utc()),
      "service" => %{"status" => "starting", "snapshot_source" => "empty"},
      "counts" => %{
        "running" => 0,
        "continuing" => 0,
        "retrying" => 0,
        "queued" => 0,
        "blocked" => 0,
        "completed" => 0
      },
      "running" => [],
      "retrying" => [],
      "blocked" => [],
      "completed" => [],
      "codex_totals" => %{},
      "rate_limits" => nil
    }
  end

  defp fallback_retry_entry(entry) when is_map(entry) do
    kind = if entry["error"], do: "retry", else: "continuation"

    %{
      "issue_id" => entry["issue_id"],
      "issue_identifier" => entry["issue_identifier"] || entry["identifier"],
      "kind" => kind,
      "status" => if(kind == "continuation", do: "continuing", else: "retrying"),
      "attempt" => entry["attempt"],
      "due_at" => entry["due_at"] || entry["due_at_wall"],
      "due_in_seconds" => due_in_seconds(entry["due_at"] || entry["due_at_wall"]),
      "error" => entry["error"]
    }
  end

  defp fallback_retry_entry(_entry), do: %{}

  defp fallback_blocked_entry(entry) when is_map(entry) do
    issue = entry["issue"] || %{}

    %{
      "issue_id" => issue["id"],
      "issue_identifier" => issue["identifier"],
      "title" => issue["title"],
      "url" => issue["url"],
      "state" => issue["state"],
      "labels" => issue["labels"] || [],
      "blocked_at" => entry["blocked_at"],
      "reason" => entry["reason"],
      "workspace" => %{"path" => entry["workspace_path"]},
      "repo_plan" => entry["repo_plan"]
    }
  end

  defp fallback_blocked_entry(_entry), do: %{}

  defp fallback_completed_entry(entry) when is_map(entry) do
    issue = entry["issue"] || %{}

    %{
      "issue_id" => issue["id"],
      "issue_identifier" => issue["identifier"],
      "title" => issue["title"],
      "url" => issue["url"],
      "state" => issue["state"],
      "labels" => issue["labels"] || [],
      "completed_at" => entry["completed_at"],
      "reason" => entry["reason"],
      "workspace" => %{"path" => entry["workspace_path"]},
      "repo_plan" => entry["repo_plan"],
      "summary" => entry["summary"] || %{},
      "tokens" => entry["tokens"] || %{},
      "activity" => entry["recent_activity"] || entry["activity"] || []
    }
  end

  defp fallback_completed_entry(_entry), do: %{}

  defp due_in_seconds(nil), do: nil

  defp due_in_seconds(value) do
    case Utils.parse_datetime(value) do
      %DateTime{} = due_at -> max(DateTime.diff(due_at, Utils.now_utc(), :second), 0)
      _ -> nil
    end
  end

  defp dashboard_html(snapshot) do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Symphony</title>
      <style>
        :root {
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
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--bg);
          color: var(--text);
          font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          font-size: 14px;
          line-height: 1.45;
        }
        header {
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
        }
        h1 { margin: 0; font-size: 1.15rem; letter-spacing: 0; }
        h2 { margin: 0 0 .75rem; font-size: .9rem; letter-spacing: 0; color: var(--muted); font-weight: 700; }
        main { padding: 1rem 1.5rem 1.5rem; }
        a { color: var(--blue); }
        button {
          border: 1px solid var(--border);
          border-radius: 6px;
          background: #fff;
          color: var(--text);
          padding: .45rem .7rem;
          font: inherit;
          cursor: pointer;
        }
        button:hover { border-color: #a8b2c1; }
        .meta { color: var(--muted); font-size: .82rem; margin-top: .2rem; }
        .actions { display: flex; align-items: center; gap: .5rem; flex-wrap: wrap; justify-content: flex-end; }
        .stats {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
          gap: .75rem;
          margin-bottom: 1rem;
        }
        .stat {
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          box-shadow: var(--shadow);
          padding: .8rem .9rem;
          min-width: 0;
        }
        .stat-value { display: block; font-size: 1.35rem; font-weight: 750; line-height: 1.2; }
        .stat-label { color: var(--muted); font-size: .78rem; }
        .issue-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: .85rem; margin-bottom: 1.25rem; }
        .issue {
          background: var(--panel);
          border: 1px solid var(--border);
          border-radius: 8px;
          box-shadow: var(--shadow);
          padding: .95rem;
          min-width: 0;
        }
        .issue-head { display: flex; align-items: flex-start; justify-content: space-between; gap: .75rem; margin-bottom: .75rem; }
        .issue-title { min-width: 0; }
        .issue-title a { color: var(--text); text-decoration: none; font-weight: 750; }
        .issue-title a:hover { color: var(--blue); text-decoration: underline; }
        .badges { display: flex; gap: .35rem; flex-wrap: wrap; justify-content: flex-end; }
        .badge {
          display: inline-flex;
          align-items: center;
          border-radius: 999px;
          border: 1px solid var(--border);
          padding: .12rem .45rem;
          font-size: .72rem;
          white-space: nowrap;
          color: var(--muted);
          background: #fff;
        }
        .badge.ok { color: var(--green); border-color: #a9d7bf; background: #f2fbf6; }
        .badge.warn { color: var(--amber); border-color: #e5ca91; background: #fff8e8; }
        .badge.bad { color: var(--red); border-color: #f0b4ad; background: #fff3f1; }
        .summary {
          border-left: 3px solid var(--blue);
          padding-left: .75rem;
          margin: .65rem 0 .75rem;
          min-height: 3rem;
        }
        .summary.attention { border-left-color: var(--red); }
        .summary-text { margin: 0 0 .45rem; font-size: .95rem; }
        .step { color: var(--muted); font-size: .82rem; }
        .attention-reason { color: var(--red); margin-top: .45rem; font-size: .82rem; }
        .activity { margin: .75rem 0 0; padding: 0; list-style: none; max-height: 10rem; overflow: auto; border-top: 1px solid var(--border); }
        .activity li { padding: .42rem 0; border-bottom: 1px solid #edf0f4; overflow-wrap: anywhere; }
        .activity-time { color: var(--muted); font-size: .74rem; margin-right: .35rem; }
        .details { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: .5rem; margin-top: .75rem; }
        .detail { min-width: 0; }
        .detail-label { color: var(--muted); font-size: .72rem; }
        .detail-value { overflow-wrap: anywhere; font-weight: 650; }
        .repo-plan {
          margin-top: .75rem;
          padding-top: .65rem;
          border-top: 1px solid var(--border);
        }
        .repo-title { color: var(--muted); font-size: .72rem; font-weight: 700; margin-bottom: .35rem; }
        .repo-list { display: flex; gap: .35rem; flex-wrap: wrap; }
        .repo-chip {
          display: inline-flex;
          align-items: center;
          max-width: 100%;
          border: 1px solid var(--border);
          border-radius: 6px;
          padding: .18rem .4rem;
          font-size: .74rem;
          background: #fbfcfd;
          overflow-wrap: anywhere;
        }
        .repo-chip.primary { border-color: #a9c2ef; color: var(--blue); background: #f3f7ff; }
        .repo-chip.readonly { color: var(--muted); background: #f7f8fa; }
        table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }
        th, td { border-bottom: 1px solid #edf0f4; padding: .6rem; text-align: left; vertical-align: top; }
        th { color: var(--muted); font-size: .78rem; font-weight: 700; background: #fbfcfd; }
        .empty { color: var(--muted); background: #fff; border: 1px dashed var(--border); border-radius: 8px; padding: 1rem; }
        @media (max-width: 760px) {
          header { position: static; flex-direction: column; }
          main { padding: 1rem; }
          .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
          .issue-grid { grid-template-columns: 1fr; }
          .details { grid-template-columns: 1fr; }
          .actions { justify-content: flex-start; }
        }
      </style>
    </head>
    <body>
      <header>
        <div>
          <h1>Symphony</h1>
          <div class="meta" id="generated">Generated at #{html_escape(snapshot["generated_at"])}</div>
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
        const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) => ({"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}[ch]));
        const duration = (seconds) => {
          const value = Number(seconds || 0);
          if (value < 60) return `${value.toFixed(0)}s`;
          if (value < 3600) return `${Math.floor(value / 60)}m ${Math.floor(value % 60)}s`;
          return `${Math.floor(value / 3600)}h ${Math.floor((value % 3600) / 60)}m`;
        };
        const shortTime = (iso) => {
          if (!iso) return "unknown";
          const date = new Date(iso);
          return Number.isNaN(date.getTime()) ? iso : date.toLocaleTimeString();
        };
        const riskClass = (risk, needsHuman) => needsHuman ? "bad" : risk === "high" ? "bad" : risk === "medium" ? "warn" : "ok";

        function renderStats(state) {
          const totals = state.codex_totals || {};
          const service = state.service || {};
          document.getElementById("stats").innerHTML = [
            ["Service", service.status || "unknown"],
            ["Running", state.counts?.running ?? 0],
            ["Continuing", state.counts?.continuing ?? 0],
            ["Retrying", state.counts?.retrying ?? 0],
            ["Needs attention", (state.running || []).filter((row) => row.summary?.needs_human).length],
            ["Blocked", state.counts?.blocked ?? 0],
            ["Completed", state.counts?.completed ?? 0],
            ["Tokens", totals.total_tokens ?? 0],
          ].map(([label, value]) => `<div class="stat"><span class="stat-value">${esc(value)}</span><span class="stat-label">${esc(label)}</span></div>`).join("");
        }

        function renderRepoPlan(plan) {
          if (!plan || !plan.coding_task) return "";
          const chips = [];
          if (plan.primary_repo) chips.push(`<span class="repo-chip primary">Primary: ${esc(plan.primary_repo.slug)}</span>`);
          for (const repo of plan.secondary_repos || []) {
            chips.push(`<span class="repo-chip">Secondary: ${esc(repo.slug)}${repo.edit_allowed ? "" : " (read-only)"}</span>`);
          }
          for (const repo of plan.read_only_context_repos || []) {
            chips.push(`<span class="repo-chip readonly">Context: ${esc(repo.slug)}</span>`);
          }
          if (!chips.length) return "";
          return `<div class="repo-plan"><div class="repo-title">Repo plan</div><div class="repo-list">${chips.join("")}</div></div>`;
        }

        function renderIssue(row) {
          const summary = row.summary || {};
          const needsHuman = Boolean(summary.needs_human);
          const risk = summary.risk || "unknown";
          const summaryText = summary.text || (summary.pending ? "LLM summary is updating." : "Waiting for the first LLM summary.");
          const currentStep = summary.current_step || row.last_event || "Starting.";
          const title = row.title ? `${row.issue_identifier} · ${row.title}` : row.issue_identifier;
          const issueLink = row.url ? `<a href="${esc(row.url)}" target="_blank" rel="noreferrer">${esc(title)}</a>` : esc(title);
          const activity = (row.activity || []).slice(-6).reverse().map((item) => (
            `<li><span class="activity-time">${esc(shortTime(item.at))}</span>${esc(item.message)}</li>`
          )).join("");
          const attentionReason = needsHuman && summary.human_reason ? `<div class="attention-reason">${esc(summary.human_reason)}</div>` : "";
          return `
            <article class="issue">
              <div class="issue-head">
                <div class="issue-title">${issueLink}<div class="meta">${esc(row.state || "unknown")} · turn ${esc(row.turn_count || 0)}</div></div>
                <div class="badges">
                  <span class="badge ${needsHuman ? "bad" : "ok"}">${needsHuman ? "Needs human" : "No intervention"}</span>
                  <span class="badge ${riskClass(risk, needsHuman)}">Risk: ${esc(risk)}</span>
                  ${summary.pending ? '<span class="badge warn">Summarizing</span>' : ""}
                  ${summary.stale && !summary.pending ? '<span class="badge warn">New activity</span>' : ""}
                </div>
              </div>
              <div class="summary ${needsHuman ? "attention" : ""}">
                <p class="summary-text">${esc(summaryText)}</p>
                <div class="step">Current step: ${esc(currentStep)}</div>
                ${attentionReason}
              </div>
              <div class="details">
                <div class="detail"><div class="detail-label">Elapsed</div><div class="detail-value">${duration(row.elapsed_seconds)}</div></div>
                <div class="detail"><div class="detail-label">Tokens</div><div class="detail-value">${esc(row.tokens?.total_tokens ?? 0)}</div></div>
                <div class="detail"><div class="detail-label">Summary</div><div class="detail-value">${summary.updated_at ? shortTime(summary.updated_at) : "pending"}</div></div>
              </div>
              ${renderRepoPlan(row.repo_plan)}
              ${activity ? `<ul class="activity">${activity}</ul>` : '<div class="meta">No activity captured yet.</div>'}
            </article>
          `;
        }

        function renderBlocked(state) {
          const blocked = state.blocked || [];
          if (!blocked.length) {
            document.getElementById("blocked").innerHTML = '<div class="empty">No blocked issues.</div>';
            return;
          }
          document.getElementById("blocked").innerHTML = `
            <table><thead><tr><th>Issue</th><th>Reason</th><th>Repo plan</th><th>Blocked</th></tr></thead><tbody>
              ${blocked.map((row) => {
                const title = row.title ? `${row.issue_identifier} · ${row.title}` : row.issue_identifier;
                const issue = row.url ? `<a href="${esc(row.url)}" target="_blank" rel="noreferrer">${esc(title)}</a>` : esc(title);
                return `<tr><td>${issue}</td><td>${esc(row.reason || "")}</td><td>${renderRepoPlan(row.repo_plan)}</td><td>${esc(row.blocked_at || "")}</td></tr>`;
              }).join("")}
            </tbody></table>
          `;
        }

        function renderRetrying(state) {
          const retrying = state.retrying || [];
          if (!retrying.length) {
            document.getElementById("retrying").innerHTML = '<div class="empty">No queued continuation or failure retry.</div>';
            return;
          }
          document.getElementById("retrying").innerHTML = `
            <table><thead><tr><th>Issue</th><th>Status</th><th>Attempt</th><th>Due</th><th>Reason</th></tr></thead><tbody>
              ${retrying.map((row) => {
                const status = row.kind === "continuation" ? "Continuing" : "Retrying";
                const badge = row.kind === "continuation" ? "ok" : "warn";
                const reason = row.kind === "continuation" ? "Clean worker exit; rechecking whether issue is still active." : (row.error || "");
                return `<tr><td>${esc(row.issue_identifier)}</td><td><span class="badge ${badge}">${status}</span></td><td>${esc(row.attempt)}</td><td>${esc(row.due_at)}</td><td>${esc(reason)}</td></tr>`;
              }).join("")}
            </tbody></table>
          `;
        }

        function renderCompleted(state) {
          const completed = state.completed || [];
          if (!completed.length) {
            document.getElementById("completed").innerHTML = '<div class="empty">No completed runs recorded yet.</div>';
            return;
          }
          document.getElementById("completed").innerHTML = `
            <table><thead><tr><th>Issue</th><th>Completed</th><th>Reason</th><th>Turns</th><th>Tokens</th></tr></thead><tbody>
              ${completed.slice(0, 25).map((row) => {
                const title = row.title ? `${row.issue_identifier} · ${row.title}` : row.issue_identifier;
                const issue = row.url ? `<a href="${esc(row.url)}" target="_blank" rel="noreferrer">${esc(title)}</a>` : esc(title);
                return `<tr><td>${issue}</td><td>${esc(row.completed_at || "")}</td><td>${esc(row.reason || "")}</td><td>${esc(row.turn_count ?? 0)}</td><td>${esc(row.tokens?.total_tokens ?? 0)}</td></tr>`;
              }).join("")}
            </tbody></table>
          `;
        }

        function render(state) {
          document.getElementById("generated").textContent = `Generated at ${state.generated_at || "unknown"}`;
          renderStats(state);
          const running = state.running || [];
          const service = state.service || {};
          const emptyRunning = service.status === "starting"
            ? "Symphony is starting; startup cleanup or the first tracker poll has not finished yet."
            : service.status === "polling"
              ? "Symphony is polling the tracker now."
              : "No running agents.";
          document.getElementById("running").innerHTML = running.length ? running.map(renderIssue).join("") : `<div class="empty">${esc(emptyRunning)}</div>`;
          renderRetrying(state);
          renderBlocked(state);
          renderCompleted(state);
        }

        async function loadState() {
          const response = await fetch(stateUrl, { cache: "no-store" });
          if (!response.ok) throw new Error(`State request failed: ${response.status}`);
          render(await response.json());
        }

        document.getElementById("refresh").addEventListener("click", async () => {
          await fetch("/api/v1/refresh", { method: "POST" });
          await loadState();
        });
        loadState().catch((error) => {
          document.getElementById("running").innerHTML = `<div class="empty">${esc(error.message)}</div>`;
        });
        setInterval(() => loadState().catch(() => {}), 5000);
      </script>
    </body>
    </html>
    """
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
