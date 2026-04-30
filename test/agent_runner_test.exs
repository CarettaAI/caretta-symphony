defmodule Symphony.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Symphony.AgentRunner
  alias Symphony.AgentRunner.AgentRunResult
  alias Symphony.Config.ConfigManager
  alias Symphony.Models.Issue

  defmodule StructTracker do
    defstruct parent: nil

    def list_issue_comments(%__MODULE__{parent: parent}, issue_id) do
      send(parent, {:struct_tracker_list_comments, issue_id})
      [%{"id" => "comment-1", "body" => "## Codex Workpad\nold"}]
    end

    def save_issue_comment(%__MODULE__{parent: parent}, issue_id, body, opts) do
      send(parent, {:struct_tracker_save_comment, issue_id, body, opts})
      %{"id" => Keyword.fetch!(opts, :comment_id)}
    end

    def save_issue_state(%__MODULE__{parent: parent}, issue_id, state) do
      send(parent, {:struct_tracker_save_state, issue_id, state})
      %{"id" => issue_id, "state" => state}
    end
  end

  test "agent reported Linear delivery blocker requires completion signal" do
    assert AgentRunner.agent_reported_linear_delivery_blocker?(
             "Completed: implementation is committed and pushed. Validation passed. Blocker: Linear MCP calls were rejected for the workpad and state transition."
           )

    refute AgentRunner.agent_reported_linear_delivery_blocker?(
             "Linear rejected the initial read; continuing repo inspection."
           )

    refute AgentRunner.agent_reported_linear_delivery_blocker?(
             "Blocked; no code changed. The workspace marks `caretta-webapp` as `edit_allowed: false`, and Project-N does not contain the target UI. Linear MCP writes were rejected."
           )
  end

  test "agent reported incomplete or guardrail-blocked work is not delivery-ready" do
    assert AgentRunner.agent_reported_incomplete_or_blocked?(
             "Blocked; no code changed. The workspace still marks `caretta-webapp` as `edit_allowed: false`. No validation was run because no implementation changes were possible."
           )

    assert AgentRunner.agent_reported_incomplete_or_blocked?(
             "Blocked by repo plan guardrail: the selected repo does not contain the target UI."
           )

    refute AgentRunner.agent_reported_incomplete_or_blocked?(
             "Completed: implementation is committed and pushed. Validation passed. Linear MCP writes were rejected."
           )
  end

  test "agent reported unresolved external blocker detects unapplied data operations" do
    assert AgentRunner.agent_reported_unresolved_external_blocker?(
             "Completed: PR is open. Blocker: Linear MCP writes were rejected. Missing Postgres URL; the production data migration was not applied."
           )

    refute AgentRunner.agent_reported_unresolved_external_blocker?(
             "Completed: migration dry-run and apply both succeeded. No known blockers remain."
           )

    refute AgentRunner.agent_reported_unresolved_external_blocker?(
             "Completed the production data operation. Blocker: Linear MCP write calls were rejected for both the workpad update and moving ABC-1 to In Review, and no local Linear API credential was available as a fallback."
           )
  end

  test "existing workpad comment id finds Codex workpad" do
    assert AgentRunner.existing_workpad_comment_id([
             %{"id" => "comment-1", "body" => "ordinary note"},
             %{"id" => "comment-2", "body" => "## Codex Workpad\nstatus"}
           ]) == "comment-2"
  end

  test "delivery fallback dispatches through tracker structs" do
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    assert AgentRunner.try_delivery_fallback(
             %StructTracker{parent: self()},
             issue,
             "Completed: implementation is committed and pushed. Validation passed. Blocker: Linear MCP calls were rejected for the workpad and state transition.",
             handoff_state: "In Review",
             workspace_path: "/tmp/symphony-test-workspace"
           )

    assert_received {:struct_tracker_list_comments, "ABC-1"}
    assert_received {:struct_tracker_save_comment, "ABC-1", body, [comment_id: "comment-1"]}
    assert body =~ "Completed: implementation is committed and pushed."
    assert_received {:struct_tracker_save_state, "ABC-1", "In Review"}
  end

  test "delivery fallback refuses unresolved credentialed data blockers" do
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    refute AgentRunner.try_delivery_fallback(
             %StructTracker{parent: self()},
             issue,
             "Completed: PR is open. Blocker: Linear MCP writes were rejected. Missing Postgres URL; the data migration was not run.",
             handoff_state: "In Review",
             workspace_path: "/tmp/symphony-test-workspace"
           )

    refute_received {:struct_tracker_save_state, "ABC-1", "In Review"}
  end

  test "delivery fallback refuses blocked no-code handoff" do
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    refute AgentRunner.try_delivery_fallback(
             %StructTracker{parent: self()},
             issue,
             "Blocked; no code changed. The target repo is read-only and does not contain the relevant UI. Linear MCP writes were rejected.",
             handoff_state: "In Review",
             workspace_path: "/tmp/symphony-test-workspace"
           )

    refute_received {:struct_tracker_save_state, "ABC-1", "In Review"}
  end

  @tag :tmp_dir
  test "run_issue executes a Codex turn and exits when issue leaves active state", %{
    tmp_dir: tmp_dir
  } do
    fake_server = Path.join(tmp_dir, "fake_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    thread_id = "thr_runner"
    turn_id = "turn_runner"

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "result": {"thread": {"id": thread_id}}}), flush=True)
        elif method == "turn/start":
            print(json.dumps({"id": msg["id"], "result": {"turn": {"id": turn_id}}}), flush=True)
            print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "delta": "Done."}}), flush=True)
            print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}}), flush=True)
    """)

    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: key
      project_slug: demo
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    codex:
      command: python3 #{fake_server}
    agent:
      max_turns: 1
    ---
    Work on {{ issue.identifier }}.
    """)

    manager = ConfigManager.new(workflow_path, environ: %{})
    {manager, _, _} = ConfigManager.load_startup(manager)

    tracker = %{
      fetch_issue_states_by_ids: fn ["1"] ->
        [%Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Review"}]
      end
    }

    parent = self()
    runner = AgentRunner.new(manager, tracker)
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    result =
      AgentRunner.run_issue(runner, issue, nil, fn issue_id, event ->
        send(parent, {:event, issue_id, event})
      end)

    assert %AgentRunResult{
             normal: true,
             reason: "issue_left_active_state",
             workspace_path: workspace_path
           } = result

    assert File.dir?(workspace_path)
    assert_receive {:event, "1", %{"event" => "session_started"}}
  end

  @tag :tmp_dir
  test "run_issue preserves response error detail for retry health checks", %{
    tmp_dir: tmp_dir
  } do
    fake_server = Path.join(tmp_dir, "fake_app_server_error.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "error": {"code": "tool_rejected", "message": "user rejected MCP tool call"}}), flush=True)
    """)

    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: key
      project_slug: demo
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    codex:
      command: python3 #{fake_server}
    agent:
      max_turns: 1
    ---
    Work on {{ issue.identifier }}.
    """)

    manager = ConfigManager.new(workflow_path, environ: %{})
    {manager, _, _} = ConfigManager.load_startup(manager)

    runner = AgentRunner.new(manager, %{})
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    result = AgentRunner.run_issue(runner, issue, nil, fn _issue_id, _event -> :ok end)

    assert %AgentRunResult{normal: false, reason: reason} = result
    assert reason =~ "response_error"
    assert reason =~ "user rejected MCP tool call"
  end
end
