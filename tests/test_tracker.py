from __future__ import annotations

from typing import Any

import pytest

from symphony.config import TrackerConfig
from symphony.tracker import CodexMcpGateway, LinearClient, LinearMcpClient


@pytest.mark.asyncio
async def test_linear_candidate_pagination_and_normalization() -> None:
    calls: list[tuple[str, dict[str, Any]]] = []

    async def transport(query: str, variables: dict[str, Any]) -> dict[str, Any]:
        calls.append((query, variables))
        assert "slugId" in query
        if variables["after"] is None:
            return {
                "data": {
                    "issues": {
                        "nodes": [
                            {
                                "id": "id-1",
                                "identifier": "ABC-1",
                                "title": "First",
                                "description": "Body",
                                "priority": 1,
                                "branchName": "abc-1",
                                "url": "https://linear.app/x/ABC-1",
                                "createdAt": "2026-01-01T00:00:00Z",
                                "updatedAt": "2026-01-02T00:00:00Z",
                                "state": {"name": "Todo"},
                                "labels": {"nodes": [{"name": "Backend"}]},
                                "inverseRelations": {
                                    "nodes": [
                                        {
                                            "type": "blocks",
                                            "issue": {"id": "blocker", "identifier": "ABC-0", "state": {"name": "Done"}},
                                        }
                                    ]
                                },
                            }
                        ],
                        "pageInfo": {"hasNextPage": True, "endCursor": "cursor-1"},
                    }
                }
            }
        return {"data": {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}

    client = LinearClient(
        TrackerConfig(kind="linear", endpoint="https://example.test/graphql", api_key="key", project_slug="proj"),
        transport=transport,
    )
    issues = await client.fetch_candidate_issues()

    assert len(calls) == 2
    assert calls[0][1]["stateNames"] == ["Todo", "In Progress"]
    assert issues[0].labels == ["backend"]
    assert issues[0].blocked_by[0].identifier == "ABC-0"
    assert issues[0].created_at is not None


@pytest.mark.asyncio
async def test_empty_fetch_by_states_skips_api_call() -> None:
    called = False

    async def transport(query: str, variables: dict[str, Any]) -> dict[str, Any]:
        nonlocal called
        called = True
        return {}

    client = LinearClient(
        TrackerConfig(kind="linear", endpoint="https://example.test/graphql", api_key="key", project_slug="proj"),
        transport=transport,
    )

    assert await client.fetch_issues_by_states([]) == []
    assert called is False


@pytest.mark.asyncio
async def test_state_refresh_query_uses_graphql_id_typing() -> None:
    captured = ""

    async def transport(query: str, variables: dict[str, Any]) -> dict[str, Any]:
        nonlocal captured
        captured = query
        return {
            "data": {
                "issues": {
                    "nodes": [
                        {
                            "id": "id-1",
                            "identifier": "ABC-1",
                            "title": "First",
                            "state": {"name": "In Progress"},
                            "labels": {"nodes": []},
                            "inverseRelations": {"nodes": []},
                        }
                    ]
                }
            }
        }

    client = LinearClient(
        TrackerConfig(kind="linear", endpoint="https://example.test/graphql", api_key="key", project_slug="proj"),
        transport=transport,
    )
    issues = await client.fetch_issue_states_by_ids(["id-1"])

    assert "[ID!]" in captured
    assert issues[0].state == "In Progress"


@pytest.mark.asyncio
async def test_linear_mcp_client_lists_and_hydrates_todo_blockers() -> None:
    class FakeGateway:
        def __init__(self) -> None:
            self.calls: list[tuple[str, dict[str, Any]]] = []

        async def call_tool(self, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
            self.calls.append((tool, arguments))
            if tool.endswith("list_issues"):
                return {
                    "issues": [
                        {
                            "id": "ENG-1",
                            "title": "Ready",
                            "status": "Todo",
                            "priority": {"value": 2, "name": "High"},
                            "labels": ["Bug"],
                            "gitBranchName": "agent/eng-1-ready",
                            "attachments": [
                                {"id": "att-1", "title": "PR 1", "url": "https://github.com/ExampleOrg/app/pull/1"},
                                {"id": "att-2", "title": "PR 2", "url": "https://github.com/ExampleOrg/app/pull/2"},
                            ],
                        }
                    ],
                    "hasNextPage": False,
                }
            return {
                "id": "ENG-1",
                "title": "Ready",
                "status": "Todo",
                "priority": {"value": 2, "name": "High"},
                "labels": ["Bug"],
                "attachments": [
                    {"id": "att-1", "title": "PR 1", "url": "https://github.com/ExampleOrg/app/pull/1"},
                    {"id": "att-2", "title": "PR 2", "url": "https://github.com/ExampleOrg/app/pull/2"},
                ],
                "relations": {"blockedBy": [{"id": "ENG-0", "status": "Done"}]},
            }

    gateway = FakeGateway()
    client = LinearMcpClient(
        TrackerConfig(kind="linear_mcp", project_slug="Pilot", team="Platform Automation", active_states=["Todo"], required_labels=["codex"]),
        gateway=gateway,
    )

    issues = await client.fetch_candidate_issues()

    assert issues[0].id == "ENG-1"
    assert issues[0].identifier == "ENG-1"
    assert issues[0].labels == ["bug"]
    assert [attachment.url for attachment in issues[0].attachments] == [
        "https://github.com/ExampleOrg/app/pull/1",
        "https://github.com/ExampleOrg/app/pull/2",
    ]
    assert issues[0].blocked_by[0].identifier == "ENG-0"
    assert gateway.calls[0][1]["project"] == "Pilot"
    assert gateway.calls[0][1]["team"] == "Platform Automation"
    assert gateway.calls[0][1]["label"] == "codex"


@pytest.mark.asyncio
async def test_linear_mcp_client_can_query_team_without_project_scope() -> None:
    class FakeGateway:
        def __init__(self) -> None:
            self.calls: list[tuple[str, dict[str, Any]]] = []

        async def call_tool(self, tool: str, arguments: dict[str, Any]) -> Any:
            self.calls.append((tool, arguments))
            if tool.endswith("list_issues"):
                return {
                    "issues": [
                        {
                            "id": "ENG-240",
                            "title": "Dependabot",
                            "status": "Todo",
                            "labels": ["codex"],
                        }
                    ],
                    "hasNextPage": False,
                }
            return {
                "id": arguments["id"],
                "title": "Dependabot",
                "status": "Todo",
                "labels": ["codex"],
                "relations": {"blockedBy": []},
            }

    gateway = FakeGateway()
    client = LinearMcpClient(
        TrackerConfig(kind="linear_mcp", team="Platform Automation", active_states=["Todo"], required_labels=["codex"]),
        gateway=gateway,
    )

    issues = await client.fetch_candidate_issues()

    assert issues[0].identifier == "ENG-240"
    assert "project" not in gateway.calls[0][1]
    assert gateway.calls[0][1]["team"] == "Platform Automation"
    assert gateway.calls[0][1]["label"] == "codex"


@pytest.mark.asyncio
async def test_linear_mcp_client_writes_comments_and_state() -> None:
    class FakeGateway:
        def __init__(self) -> None:
            self.calls: list[tuple[str, dict[str, Any]]] = []

        async def call_tool(self, tool: str, arguments: dict[str, Any]) -> Any:
            self.calls.append((tool, arguments))
            if tool.endswith("list_comments"):
                return {"comments": [{"id": "comment-1", "body": "## Codex Workpad\nold"}]}
            if tool.endswith("save_comment"):
                return {"id": arguments.get("id") or "comment-2"}
            if tool.endswith("save_issue"):
                return {"id": arguments["id"], "state": arguments["state"]}
            raise AssertionError(tool)

    gateway = FakeGateway()
    client = LinearMcpClient(
        TrackerConfig(kind="linear_mcp", project_slug="Pilot"),
        gateway=gateway,
    )

    comments = await client.list_issue_comments("ENG-1")
    await client.save_issue_comment("ENG-1", "## Codex Workpad\nnew", comment_id=comments[0]["id"])
    await client.save_issue_state("ENG-1", "completed")

    assert gateway.calls == [
        ("linear mcp server_list_comments", {"issueId": "ENG-1", "limit": 250, "orderBy": "createdAt"}),
        ("linear mcp server_save_comment", {"body": "## Codex Workpad\nnew", "id": "comment-1"}),
        ("linear mcp server_save_issue", {"id": "ENG-1", "state": "completed"}),
    ]


@pytest.mark.asyncio
async def test_codex_mcp_gateway_decodes_tool_response(tmp_path) -> None:
    fake_server = tmp_path / "fake_app_server.py"
    fake_server.write_text(
        r'''
import json
import sys

call_request_id = None

for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
    elif method == "initialized":
        pass
    elif method == "thread/start":
        print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "thr_1"}}}), flush=True)
    elif method == "mcpServer/tool/call":
        print(json.dumps({"id": msg["id"], "result": {"content": [{"type": "text", "text": "{\"issues\": [], \"hasNextPage\": false}"}], "isError": False}}), flush=True)
''',
        encoding="utf-8",
    )
    gateway = CodexMcpGateway(command=f"python3 {fake_server}", cwd=tmp_path)

    body = await gateway.call_tool("linear mcp server_list_issues", {"limit": 1})

    assert body == {"issues": [], "hasNextPage": False}


@pytest.mark.asyncio
async def test_codex_mcp_gateway_handles_large_tool_response(tmp_path) -> None:
    fake_server = tmp_path / "fake_large_app_server.py"
    fake_server.write_text(
        r'''
import json
import sys

large_description = "x" * 120000

for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
    elif method == "initialized":
        pass
    elif method == "thread/start":
        print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "thr_1"}}}), flush=True)
    elif method == "mcpServer/tool/call":
        payload = {"issues": [{"id": "ENG-1", "description": large_description}], "hasNextPage": False}
        print(json.dumps({"id": msg["id"], "result": {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": False}}), flush=True)
''',
        encoding="utf-8",
    )
    gateway = CodexMcpGateway(command=f"python3 {fake_server}", cwd=tmp_path)

    body = await gateway.call_tool("linear mcp server_list_issues", {"limit": 1})

    assert body["issues"][0]["id"] == "ENG-1"
    assert len(body["issues"][0]["description"]) == 120000


@pytest.mark.asyncio
async def test_codex_mcp_gateway_auto_approves_tool_user_input(tmp_path) -> None:
    fake_server = tmp_path / "fake_approval_app_server.py"
    fake_server.write_text(
        r'''
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
        print(json.dumps({"id": msg["id"], "result": {"thread": {"id": "thr_1"}}}), flush=True)
    elif method == "mcpServer/tool/call":
        call_request_id = msg["id"]
        print(json.dumps({"id": 110, "method": "item/tool/requestUserInput", "params": {"questions": [{"id": "mcp_tool_call_approval_call-1", "options": [{"label": "Approve Once"}, {"label": "Approve this Session"}, {"label": "Deny"}]}]}}), flush=True)
    elif msg.get("id") == 110:
        assert msg["result"]["answers"]["mcp_tool_call_approval_call-1"]["answers"] == ["Approve this Session"]
        print(json.dumps({"id": call_request_id, "result": {"content": [{"type": "text", "text": "{\"ok\": true}"}], "isError": False}}), flush=True)
''',
        encoding="utf-8",
    )
    gateway = CodexMcpGateway(command=f"python3 {fake_server}", cwd=tmp_path)

    body = await gateway.call_tool("linear mcp server_save_issue", {"id": "ENG-1", "state": "completed"})

    assert body == {"ok": True}
