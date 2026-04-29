from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

import pytest

from symphony.codex_client import CodexAppServerSession
from symphony.config import CodexConfig, TrackerConfig
from symphony.errors import AgentError


@pytest.mark.asyncio
async def test_codex_jsonl_client_runs_turn_and_handles_approval(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_app_server.py"
    fake_server.write_text(
        r'''
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
        print(json.dumps({"method": "thread/tokenUsage/updated", "params": {"threadId": thread_id, "turnId": turn_id, "tokenUsage": {"last": {"inputTokens": 1, "outputTokens": 2, "totalTokens": 3, "cachedInputTokens": 0, "reasoningOutputTokens": 0}, "total": {"inputTokens": 4, "outputTokens": 5, "totalTokens": 9, "cachedInputTokens": 0, "reasoningOutputTokens": 0}}}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "items": [], "error": None}}}), flush=True)
''',
        encoding="utf-8",
    )
    events = []

    async def on_event(event):
        events.append(event)

    async with CodexAppServerSession(
        CodexConfig(command=f"{os.environ.get('PYTHON', 'python3')} {fake_server}"),
        tmp_path,
        tracker_config=TrackerConfig(kind="linear", endpoint="https://example.test/graphql", api_key="key", project_slug="proj"),
        on_event=on_event,
    ) as session:
        result = await session.run_turn("hello")

    assert result.thread_id == "thr_1"
    assert result.turn_id == "turn_1"
    assert any(event["event"] == "approval_auto_approved" for event in events)
    usage_events = [event for event in events if event.get("usage_absolute")]
    assert usage_events[0]["usage_absolute"] == {"input_tokens": 4, "output_tokens": 5, "total_tokens": 9}


@pytest.mark.asyncio
async def test_codex_jsonl_client_auto_approves_tool_user_input(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_app_server.py"
    fake_server.write_text(
        r'''
import json
import sys

thread_id = "thr_approval"
turn_id = "turn_approval"

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
        print(json.dumps({"id": 110, "method": "item/tool/requestUserInput", "params": {"threadId": thread_id, "turnId": turn_id, "questions": [{"id": "mcp_tool_call_approval_call-1", "options": [{"label": "Approve Once"}, {"label": "Approve this Session"}, {"label": "Deny"}], "question": "Allow this Linear write?"}]}}), flush=True)
    elif msg.get("id") == 110:
        assert msg["result"]["answers"]["mcp_tool_call_approval_call-1"]["answers"] == ["Approve this Session"]
        print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}}), flush=True)
''',
        encoding="utf-8",
    )
    events = []

    async def on_event(event):
        events.append(event)

    async with CodexAppServerSession(
        CodexConfig(command=f"{os.environ.get('PYTHON', 'python3')} {fake_server}"),
        tmp_path,
        tracker_config=None,
        on_event=on_event,
    ) as session:
        result = await session.run_turn("approve the tool call")

    assert result.status == "completed"
    assert any(event["event"] == "approval_auto_approved" for event in events)


@pytest.mark.asyncio
async def test_codex_jsonl_client_auto_answers_freeform_tool_user_input(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_app_server.py"
    fake_server.write_text(
        r'''
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
''',
        encoding="utf-8",
    )
    events = []

    async def on_event(event):
        events.append(event)

    async with CodexAppServerSession(
        CodexConfig(command=f"{os.environ.get('PYTHON', 'python3')} {fake_server}"),
        tmp_path,
        tracker_config=None,
        on_event=on_event,
    ) as session:
        result = await session.run_turn("answer the prompt")

    assert result.status == "completed"
    assert any(event["event"] == "tool_input_auto_answered" for event in events)


@pytest.mark.asyncio
async def test_codex_jsonl_client_accepts_dynamic_tool_name_alias(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_app_server.py"
    fake_server.write_text(
        r'''
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
''',
        encoding="utf-8",
    )

    async def on_event(event):
        pass

    async with CodexAppServerSession(
        CodexConfig(command=f"{os.environ.get('PYTHON', 'python3')} {fake_server}"),
        tmp_path,
        tracker_config=None,
        on_event=on_event,
    ) as session:
        result = await session.run_turn("call the tool")

    assert result.status == "completed"


@pytest.mark.asyncio
async def test_codex_jsonl_client_cleans_up_when_start_times_out(tmp_path: Path) -> None:
    marker = tmp_path / "pid.txt"
    fake_server = tmp_path / "fake_hanging_app_server.py"
    fake_server.write_text(
        r'''
import pathlib
import sys
import time

pathlib.Path(sys.argv[1]).write_text(str(__import__("os").getpid()), encoding="utf-8")
while True:
    time.sleep(1)
''',
        encoding="utf-8",
    )
    events = []

    async def on_event(event):
        events.append(event)

    session = CodexAppServerSession(
        CodexConfig(command=f"{sys.executable} {fake_server} {marker}", read_timeout_ms=100),
        tmp_path,
        tracker_config=None,
        on_event=on_event,
    )

    with pytest.raises(AgentError) as exc:
        await session.start()

    assert exc.value.code == "response_timeout"
    pid = next(int(event["codex_app_server_pid"]) for event in events if event["event"] == "app_server_started")
    probe = subprocess.run(["ps", "-p", str(pid)], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert probe.returncode != 0
    assert any(event["event"] == "app_server_stopped" for event in events)


@pytest.mark.asyncio
async def test_codex_jsonl_client_handles_large_jsonl_notifications(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_large_message_app_server.py"
    fake_server.write_text(
        r'''
import json
import sys

thread_id = "thr_large"
turn_id = "turn_large"
large_delta = "x" * 120000

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
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "delta": large_delta}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}}), flush=True)
''',
        encoding="utf-8",
    )

    async def on_event(event):
        pass

    async with CodexAppServerSession(
        CodexConfig(command=f"{sys.executable} {fake_server}"),
        tmp_path,
        tracker_config=None,
        on_event=on_event,
    ) as session:
        result = await session.run_turn("handle large output")

    assert result.status == "completed"
