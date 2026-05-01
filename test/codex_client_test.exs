defmodule Symphony.CodexClientTest do
  use ExUnit.Case, async: true

  alias Symphony.CodexClient
  alias Symphony.Config.{CodexConfig, TrackerConfig}
  alias Symphony.Error

  @tag :tmp_dir
  test "Codex JSONL client runs turn and handles approval", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    thread_id = "thr_1"
    turn_id = "turn_1"

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print(json.dumps({"id": msg["id"], "result": {"userAgent": "fake"}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "result": {"thread": {"id": thread_id}}}), flush=True)
        elif method == "turn/start":
            print(json.dumps({"id": msg["id"], "result": {"turn": {"id": turn_id, "status": "inProgress", "items": [], "error": None}}}), flush=True)
            print(json.dumps({"method": "item/commandExecution/requestApproval", "id": 99, "params": {"threadId": thread_id, "turnId": turn_id}}), flush=True)
        elif msg.get("id") == 99:
            assert msg["result"]["decision"] == "acceptForSession"
            print(json.dumps({"method": "thread/tokenUsage/updated", "params": {"threadId": thread_id, "turnId": turn_id, "tokenUsage": {"last": {"inputTokens": 1, "outputTokens": 2, "totalTokens": 3}, "total": {"inputTokens": 4, "outputTokens": 5, "totalTokens": 9}}}}), flush=True)
            print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "items": [], "error": None}}}), flush=True)
    """)

    parent = self()
    on_event = fn event -> send(parent, {:event, event}) end

    session =
      CodexClient.start_session(%CodexConfig{command: "python3 #{fake_server}"}, tmp_dir,
        tracker_config: %TrackerConfig{
          kind: "linear",
          endpoint: "https://example.test/graphql",
          api_key: "key",
          project_slug: "proj"
        },
        on_event: on_event
      )

    {result, session} = CodexClient.run_turn(session, "hello")
    CodexClient.stop_session(session)

    assert result.thread_id == "thr_1"
    assert result.turn_id == "turn_1"
    assert_receive {:event, %{"event" => "approval_auto_approved"}}

    assert_receive {:event,
                    %{
                      "usage_absolute" => %{
                        "input_tokens" => 4,
                        "output_tokens" => 5,
                        "total_tokens" => 9
                      }
                    }}
  end

  @tag :tmp_dir
  test "Codex JSONL client auto answers freeform tool input", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    thread_id = "thr_freeform"
    turn_id = "turn_freeform"
    answer = "This is a non-interactive session. Operator input is unavailable."

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
            print(json.dumps({"id": 111, "method": "item/tool/requestUserInput", "params": {"threadId": thread_id, "turnId": turn_id, "questions": [{"id": "freeform-1", "options": None, "question": "What should I write?"}]}}), flush=True)
        elif msg.get("id") == 111:
            assert msg["result"]["answers"]["freeform-1"]["answers"] == [answer]
            print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}}), flush=True)
    """)

    parent = self()

    session =
      CodexClient.start_session(%CodexConfig{command: "python3 #{fake_server}"}, tmp_dir,
        tracker_config: nil,
        on_event: fn event -> send(parent, {:event, event}) end
      )

    {result, session} = CodexClient.run_turn(session, "answer")
    CodexClient.stop_session(session)

    assert result.status == "completed"
    assert_receive {:event, %{"event" => "tool_input_auto_answered"}}
  end

  @tag :tmp_dir
  test "Codex JSONL client accepts dynamic tool name alias", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    thread_id = "thr_tool_name"
    turn_id = "turn_tool_name"

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
            print(json.dumps({"id": 112, "method": "item/tool/call", "params": {"threadId": thread_id, "turnId": turn_id, "name": "linear_graphql", "arguments": {"query": "query Viewer { viewer { id } }"}}}), flush=True)
        elif msg.get("id") == 112:
            content = msg["result"]["contentItems"][0]["text"]
            assert "missing_auth" in content
            assert "unsupported_tool" not in content
            print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}}), flush=True)
    """)

    session =
      CodexClient.start_session(%CodexConfig{command: "python3 #{fake_server}"}, tmp_dir,
        tracker_config: nil,
        on_event: fn _ -> :ok end
      )

    {result, session} = CodexClient.run_turn(session, "call")
    CodexClient.stop_session(session)

    assert result.status == "completed"
  end

  @tag :tmp_dir
  test "Codex JSONL client ignores app-server stderr logs", %{tmp_dir: tmp_dir} do
    fake_server = Path.join(tmp_dir, "fake_noisy_app_server.py")

    File.write!(fake_server, ~S"""
    import json
    import sys

    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            print("\x1b[31mERROR\x1b[0m non-json diagnostic", file=sys.stderr, flush=True)
            print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
        elif method == "initialized":
            pass
        elif method == "thread/start":
            print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "thr_stderr"}}}), flush=True)
    """)

    session =
      CodexClient.start_session(%CodexConfig{command: "python3 #{fake_server}"}, tmp_dir,
        tracker_config: nil,
        on_event: fn _ -> :ok end
      )

    assert session.thread_id == "thr_stderr"
    CodexClient.stop_session(session)
  end

  @tag :tmp_dir
  test "Codex JSONL client cleans up when start times out", %{tmp_dir: tmp_dir} do
    marker = Path.join(tmp_dir, "pid.txt")
    fake_server = Path.join(tmp_dir, "fake_hanging_app_server.py")

    File.write!(fake_server, ~S"""
    import pathlib
    import sys
    import time

    pathlib.Path(sys.argv[1]).write_text(str(__import__("os").getpid()), encoding="utf-8")
    while True:
        time.sleep(1)
    """)

    assert_raise Error, ~r/response_timeout/, fn ->
      CodexClient.start_session(
        %CodexConfig{command: "python3 #{fake_server} #{marker}", read_timeout_ms: 1000},
        tmp_dir,
        tracker_config: nil,
        on_event: fn _ -> :ok end
      )
    end

    assert wait_until(fn -> File.exists?(marker) end)
    pid = marker |> File.read!() |> String.trim()
    {_out, status} = System.cmd("ps", ["-p", pid], stderr_to_stdout: true)
    assert status != 0
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(fun, attempts - 1)
    end
  end
end
