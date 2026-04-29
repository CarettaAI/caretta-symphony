from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
import urllib.error
import urllib.request
from typing import Any, Protocol

from .config import TrackerConfig
from .errors import TrackerError
from .logging import log_event
from .models import BlockerRef, Issue, IssueAttachment
from .utils import (
    JSONL_READ_LIMIT_BYTES,
    tool_request_user_input_approval_answers,
    tool_request_user_input_unavailable_answers,
    parse_datetime,
)

LOGGER = logging.getLogger(__name__)

LINEAR_PAGE_SIZE = 50
LINEAR_TIMEOUT_SECONDS = 30
CODEX_MCP_GATEWAY_ATTEMPTS = 3
LINEAR_MCP_TOOL_LIST_ISSUES = "linear mcp server_list_issues"
LINEAR_MCP_TOOL_GET_ISSUE = "linear mcp server_get_issue"
LINEAR_MCP_TOOL_LIST_COMMENTS = "linear mcp server_list_comments"
LINEAR_MCP_TOOL_SAVE_COMMENT = "linear mcp server_save_comment"
LINEAR_MCP_TOOL_SAVE_ISSUE = "linear mcp server_save_issue"


class IssueTracker(Protocol):
    async def fetch_candidate_issues(self) -> list[Issue]:
        ...

    async def fetch_issues_by_states(self, state_names: list[str]) -> list[Issue]:
        ...

    async def fetch_issue_states_by_ids(self, issue_ids: list[str]) -> list[Issue]:
        ...


class IssueTrackerWriter(Protocol):
    async def list_issue_comments(self, issue_id: str) -> list[dict[str, Any]]:
        ...

    async def save_issue_comment(self, issue_id: str, body: str, *, comment_id: str | None = None) -> dict[str, Any]:
        ...

    async def save_issue_state(self, issue_id: str, state: str) -> dict[str, Any]:
        ...


class LinearClient:
    def __init__(self, config: TrackerConfig, *, transport: Any | None = None):
        self.config = config
        self.transport = transport

    async def fetch_candidate_issues(self) -> list[Issue]:
        return await self._fetch_by_states(self.config.active_states)

    async def fetch_issues_by_states(self, state_names: list[str]) -> list[Issue]:
        if not state_names:
            return []
        return await self._fetch_by_states(state_names)

    async def fetch_issue_states_by_ids(self, issue_ids: list[str]) -> list[Issue]:
        if not issue_ids:
            return []
        query = """
        query SymphonyIssueStates($ids: [ID!]) {
          issues(filter: { id: { in: $ids } }, first: 100) {
            nodes {
              id
              identifier
              title
              description
              priority
              branchName
              url
              createdAt
              updatedAt
              state { name }
              labels { nodes { name } }
              attachments { nodes { id title subtitle url } }
              inverseRelations { nodes { type issue { id identifier state { name } } } }
            }
          }
        }
        """
        body = await self._graphql(query, {"ids": issue_ids})
        nodes = (((body.get("data") or {}).get("issues") or {}).get("nodes"))
        if not isinstance(nodes, list):
            raise TrackerError("linear_unknown_payload", "state refresh payload missing issues.nodes")
        return [self._normalize_issue(node) for node in nodes]

    async def execute_graphql_once(self, query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
        return await self._graphql(query, variables or {})

    async def _fetch_by_states(self, state_names: list[str]) -> list[Issue]:
        query = """
        query SymphonyIssuesByState($projectSlug: String!, $stateNames: [String!], $first: Int!, $after: String) {
          issues(
            filter: {
              project: { slugId: { eq: $projectSlug } }
              state: { name: { in: $stateNames } }
            }
            first: $first
            after: $after
          ) {
            nodes {
              id
              identifier
              title
              description
              priority
              branchName
              url
              createdAt
              updatedAt
              state { name }
              labels { nodes { name } }
              attachments { nodes { id title subtitle url } }
              inverseRelations { nodes { type issue { id identifier state { name } } } }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        """
        issues: list[Issue] = []
        after: str | None = None
        while True:
            body = await self._graphql(
                query,
                {
                    "projectSlug": self.config.project_slug,
                    "stateNames": state_names,
                    "first": LINEAR_PAGE_SIZE,
                    "after": after,
                },
            )
            connection = ((body.get("data") or {}).get("issues") or {})
            nodes = connection.get("nodes")
            page_info = connection.get("pageInfo")
            if not isinstance(nodes, list) or not isinstance(page_info, dict):
                raise TrackerError("linear_unknown_payload", "candidate payload missing issues.nodes/pageInfo")
            issues.extend(self._normalize_issue(node) for node in nodes)
            if not page_info.get("hasNextPage"):
                return issues
            after = page_info.get("endCursor")
            if not after:
                raise TrackerError("linear_missing_end_cursor", "Linear pagination requested another page without endCursor")

    async def _graphql(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        if self.transport is not None:
            body = await self.transport(query, variables)
        else:
            body = await asyncio.to_thread(self._graphql_sync, query, variables)
        if not isinstance(body, dict):
            raise TrackerError("linear_unknown_payload", "Linear response is not a JSON object")
        if body.get("errors"):
            raise TrackerError("linear_graphql_errors", "Linear GraphQL returned errors")
        return body

    def _graphql_sync(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        if not self.config.endpoint:
            raise TrackerError("linear_api_request", "Linear endpoint is missing")
        if not self.config.api_key:
            raise TrackerError("missing_tracker_api_key", "Linear API key is missing")
        payload = json.dumps({"query": query, "variables": variables}).encode("utf-8")
        request = urllib.request.Request(
            self.config.endpoint,
            data=payload,
            method="POST",
            headers={
                "Authorization": self.config.api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=LINEAR_TIMEOUT_SECONDS) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as exc:
            raise TrackerError("linear_api_status", f"Linear HTTP status {exc.code}", cause=exc) from exc
        except OSError as exc:
            raise TrackerError("linear_api_request", f"Linear request failed: {exc}", cause=exc) from exc
        if status != 200:
            raise TrackerError("linear_api_status", f"Linear HTTP status {status}")
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise TrackerError("linear_unknown_payload", "Linear returned invalid JSON", cause=exc) from exc

    def _normalize_issue(self, node: Any) -> Issue:
        if not isinstance(node, dict):
            raise TrackerError("linear_unknown_payload", "issue node is not an object")
        state = ((node.get("state") or {}).get("name")) if isinstance(node.get("state"), dict) else None
        labels: list[str] = []
        label_nodes = (((node.get("labels") or {}).get("nodes")) if isinstance(node.get("labels"), dict) else []) or []
        if isinstance(label_nodes, list):
            labels = [str(label.get("name", "")).lower() for label in label_nodes if isinstance(label, dict) and label.get("name")]

        attachments = _normalize_attachments(
            (((node.get("attachments") or {}).get("nodes")) if isinstance(node.get("attachments"), dict) else [])
        )

        blockers: list[BlockerRef] = []
        relation_nodes = (
            ((node.get("inverseRelations") or {}).get("nodes")) if isinstance(node.get("inverseRelations"), dict) else []
        ) or []
        if isinstance(relation_nodes, list):
            for relation in relation_nodes:
                if not isinstance(relation, dict) or relation.get("type") != "blocks":
                    continue
                issue = relation.get("issue") or {}
                if not isinstance(issue, dict):
                    continue
                relation_state = ((issue.get("state") or {}).get("name")) if isinstance(issue.get("state"), dict) else None
                blockers.append(BlockerRef(id=issue.get("id"), identifier=issue.get("identifier"), state=relation_state))

        priority_raw = node.get("priority")
        priority = priority_raw if isinstance(priority_raw, int) and not isinstance(priority_raw, bool) else None
        try:
            return Issue(
                id=str(node["id"]),
                identifier=str(node["identifier"]),
                title=str(node["title"]),
                description=node.get("description"),
                priority=priority,
                state=str(state or ""),
                branch_name=node.get("branchName"),
                url=node.get("url"),
                labels=labels,
                attachments=attachments,
                blocked_by=blockers,
                created_at=parse_datetime(node.get("createdAt")),
                updated_at=parse_datetime(node.get("updatedAt")),
            )
        except KeyError as exc:
            raise TrackerError("linear_unknown_payload", f"issue node missing required field {exc}") from exc


def make_tracker(config: TrackerConfig) -> IssueTracker:
    if config.kind == "linear_mcp":
        log_event(
            LOGGER,
            logging.DEBUG,
            "tracker_created",
            kind="linear_mcp",
            project_slug=config.project_slug,
            team=config.team,
            mcp_server=config.mcp_server,
        )
        return LinearMcpClient(config)
    if config.kind != "linear":
        raise TrackerError("unsupported_tracker_kind", f"unsupported tracker kind: {config.kind}")
    log_event(LOGGER, logging.DEBUG, "tracker_created", kind="linear", endpoint=config.endpoint, project_slug=config.project_slug)
    return LinearClient(config)


class LinearMcpClient:
    """Linear reader backed by the Codex app-server MCP tool gateway.

    This is an extension for environments where the Linear connector is available
    through Codex OAuth, but a raw Linear API key should not be managed by Symphony.
    The MCP tool output exposes issue identifiers rather than GraphQL UUIDs, so
    this adapter intentionally uses the issue identifier as the stable issue id.
    """

    def __init__(self, config: TrackerConfig, *, gateway: "CodexMcpGateway | None" = None):
        self.config = config
        self.gateway = gateway or CodexMcpGateway(command=config.mcp_command, server=config.mcp_server)

    async def fetch_candidate_issues(self) -> list[Issue]:
        issues: list[Issue] = []
        for state in self.config.active_states:
            issues.extend(await self._list_issues(state=state))
        await self._hydrate_todo_blockers(issues)
        return _dedupe_issues(issues)

    async def fetch_issues_by_states(self, state_names: list[str]) -> list[Issue]:
        if not state_names:
            return []
        issues: list[Issue] = []
        for state in state_names:
            issues.extend(await self._list_issues(state=state))
        return _dedupe_issues(issues)

    async def fetch_issue_states_by_ids(self, issue_ids: list[str]) -> list[Issue]:
        issues: list[Issue] = []
        for issue_id in issue_ids:
            body = await self.gateway.call_tool(
                LINEAR_MCP_TOOL_GET_ISSUE,
                {"id": issue_id, "includeRelations": True},
            )
            issues.append(self._normalize_issue(body))
        return issues

    async def list_issue_comments(self, issue_id: str) -> list[dict[str, Any]]:
        body = await self.gateway.call_tool(
            LINEAR_MCP_TOOL_LIST_COMMENTS,
            {"issueId": issue_id, "limit": 250, "orderBy": "createdAt"},
        )
        if isinstance(body, list):
            return [comment for comment in body if isinstance(comment, dict)]
        if not isinstance(body, dict):
            raise TrackerError("linear_unknown_payload", "Linear MCP comments payload is not an object or list")
        comments = body.get("comments")
        if comments is None:
            comments = body.get("nodes")
        if not isinstance(comments, list):
            raise TrackerError("linear_unknown_payload", "Linear MCP comments payload missing comments list")
        return [comment for comment in comments if isinstance(comment, dict)]

    async def save_issue_comment(self, issue_id: str, body: str, *, comment_id: str | None = None) -> dict[str, Any]:
        args: dict[str, Any] = {"body": body}
        if comment_id:
            args["id"] = comment_id
        else:
            args["issueId"] = issue_id
        response = await self.gateway.call_tool(LINEAR_MCP_TOOL_SAVE_COMMENT, args)
        if not isinstance(response, dict):
            raise TrackerError("linear_unknown_payload", "Linear MCP save comment response is not an object")
        return response

    async def save_issue_state(self, issue_id: str, state: str) -> dict[str, Any]:
        response = await self.gateway.call_tool(LINEAR_MCP_TOOL_SAVE_ISSUE, {"id": issue_id, "state": state})
        if not isinstance(response, dict):
            raise TrackerError("linear_unknown_payload", "Linear MCP save issue response is not an object")
        return response

    async def _list_issues(self, *, state: str) -> list[Issue]:
        cursor: str | None = None
        issues: list[Issue] = []
        while True:
            args: dict[str, Any] = {
                "limit": min(LINEAR_PAGE_SIZE, 250),
                "state": state,
                "includeArchived": False,
            }
            if self.config.project_slug:
                args["project"] = self.config.project_slug
            if self.config.team:
                args["team"] = self.config.team
            if self.config.required_labels:
                args["label"] = self.config.required_labels[0]
            if cursor:
                args["cursor"] = cursor
            body = await self.gateway.call_tool(LINEAR_MCP_TOOL_LIST_ISSUES, args)
            nodes = body.get("issues")
            if not isinstance(nodes, list):
                raise TrackerError("linear_unknown_payload", "Linear MCP payload missing issues list")
            issues.extend(self._normalize_issue(node) for node in nodes)
            if not body.get("hasNextPage"):
                return issues
            cursor = body.get("cursor")
            if not cursor:
                raise TrackerError("linear_missing_end_cursor", "Linear MCP pagination requested another page without cursor")

    async def _hydrate_todo_blockers(self, issues: list[Issue]) -> None:
        for index, issue in enumerate(list(issues)):
            if issue.state.lower() != "todo":
                continue
            body = await self.gateway.call_tool(
                LINEAR_MCP_TOOL_GET_ISSUE,
                {"id": issue.identifier, "includeRelations": True},
            )
            issues[index] = self._normalize_issue(body)

    def _normalize_issue(self, node: Any) -> Issue:
        if not isinstance(node, dict):
            raise TrackerError("linear_unknown_payload", "Linear MCP issue payload is not an object")
        identifier = str(node.get("id") or "")
        if not identifier:
            raise TrackerError("linear_unknown_payload", "Linear MCP issue payload missing id")
        priority = None
        priority_raw = node.get("priority")
        if isinstance(priority_raw, dict):
            value = priority_raw.get("value")
            priority = value if isinstance(value, int) and value > 0 else None
        elif isinstance(priority_raw, int) and priority_raw > 0:
            priority = priority_raw

        labels = [str(label).lower() for label in node.get("labels", []) if label]
        attachments = _normalize_attachments(node.get("attachments"))
        blocked_by = []
        relations = node.get("relations")
        if isinstance(relations, dict):
            for blocker in relations.get("blockedBy", []) or []:
                if not isinstance(blocker, dict):
                    continue
                blocker_id = blocker.get("id") or blocker.get("identifier")
                blocked_by.append(
                    BlockerRef(
                        id=str(blocker_id) if blocker_id else None,
                        identifier=str(blocker_id) if blocker_id else None,
                        state=blocker.get("status") or blocker.get("state"),
                    )
                )

        return Issue(
            id=identifier,
            identifier=identifier,
            title=str(node.get("title") or ""),
            description=node.get("description"),
            priority=priority,
            state=str(node.get("status") or node.get("state") or ""),
            branch_name=node.get("gitBranchName") or node.get("branchName"),
            url=node.get("url"),
            labels=labels,
            attachments=attachments,
            blocked_by=blocked_by,
            created_at=parse_datetime(node.get("createdAt")),
            updated_at=parse_datetime(node.get("updatedAt")),
        )


class CodexMcpGateway:
    def __init__(self, *, command: str = "codex app-server", server: str = "codex_apps", cwd: Path | None = None):
        self.command = command
        self.server = server
        self.cwd = cwd or Path.cwd()
        self._next_id = 1

    async def call_tool(self, tool: str, arguments: dict[str, Any]) -> Any:
        last_error: TrackerError | None = None
        for attempt in range(1, CODEX_MCP_GATEWAY_ATTEMPTS + 1):
            try:
                return await self._call_tool_once(tool, arguments)
            except TrackerError as exc:
                last_error = exc
                if not _retryable_mcp_gateway_error(exc) or attempt >= CODEX_MCP_GATEWAY_ATTEMPTS:
                    raise
                await asyncio.sleep(min(2 * attempt, 5))
        if last_error is not None:
            raise last_error
        raise TrackerError("linear_mcp_app_server", "MCP gateway did not produce a response")

    async def _call_tool_once(self, tool: str, arguments: dict[str, Any]) -> Any:
        proc = await asyncio.create_subprocess_exec(
            "bash",
            "-lc",
            self.command,
            cwd=self.cwd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=JSONL_READ_LIMIT_BYTES,
        )
        try:
            await self._request(
                proc,
                "initialize",
                {
                    "clientInfo": {"name": "symphony_linear_mcp", "title": "Symphony Linear MCP", "version": "0.1.0"},
                    "capabilities": {"experimentalApi": True},
                },
            )
            await self._send(proc, {"method": "initialized", "params": {}})
            thread_response = await self._request(
                proc,
                "thread/start",
                {
                    "cwd": str(self.cwd.resolve(strict=False)),
                    "approvalPolicy": "never",
                    "sandbox": "workspace-write",
                    "serviceName": "symphony_linear_mcp",
                    "ephemeral": True,
                },
            )
            thread_id = ((thread_response.get("thread") or {}).get("id")) if isinstance(thread_response, dict) else None
            if not thread_id:
                raise TrackerError("linear_mcp_app_server", "thread/start response missing thread.id")
            response = await self._request(
                proc,
                "mcpServer/tool/call",
                {"threadId": thread_id, "server": self.server, "tool": tool, "arguments": arguments},
            )
            return self._decode_tool_response(response)
        finally:
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=5)
                except TimeoutError:
                    proc.kill()
                    await proc.wait()

    async def _request(self, proc: asyncio.subprocess.Process, method: str, params: dict[str, Any]) -> Any:
        request_id = self._next_id
        self._next_id += 1
        await self._send(proc, {"method": method, "id": request_id, "params": params})
        while True:
            msg = await self._read(proc)
            if "id" in msg and msg.get("id") == request_id and "method" not in msg:
                if "error" in msg:
                    raise TrackerError("linear_mcp_app_server", json.dumps(msg["error"], sort_keys=True))
                return msg.get("result", {})
            if "method" in msg and "id" in msg:
                await self._handle_server_request(proc, msg)

    async def _send(self, proc: asyncio.subprocess.Process, message: dict[str, Any]) -> None:
        if proc.stdin is None:
            raise TrackerError("linear_mcp_app_server", "app-server stdin closed")
        proc.stdin.write(json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n")
        await proc.stdin.drain()

    async def _handle_server_request(self, proc: asyncio.subprocess.Process, msg: dict[str, Any]) -> None:
        request_id = msg.get("id")
        method = str(msg.get("method"))
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        if method in {"item/commandExecution/requestApproval", "item/fileChange/requestApproval"}:
            await self._send(proc, {"id": request_id, "result": {"decision": "acceptForSession"}})
            return
        if method in {"item/tool/requestUserInput", "tool/requestUserInput"}:
            answers = tool_request_user_input_approval_answers(params)
            if answers is None:
                answers = tool_request_user_input_unavailable_answers(params)
            if answers is not None:
                await self._send(proc, {"id": request_id, "result": {"answers": answers}})
                return
        await self._send(
            proc,
            {"id": request_id, "error": {"code": -32601, "message": f"unsupported server request: {method}"}},
        )

    async def _read(self, proc: asyncio.subprocess.Process) -> dict[str, Any]:
        if proc.stdout is None:
            raise TrackerError("linear_mcp_app_server", "app-server stdout closed")
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=30)
        except TimeoutError as exc:
            raise TrackerError("linear_mcp_app_server", "timed out waiting for app-server MCP response", cause=exc) from exc
        except ValueError as exc:
            raise TrackerError("linear_mcp_app_server", f"app-server MCP message exceeded reader limit: {exc}", cause=exc) from exc
        if not line:
            stderr = ""
            if proc.stderr:
                stderr = (await proc.stderr.read()).decode(errors="replace")
            raise TrackerError("linear_mcp_app_server", f"app-server exited before MCP response: {stderr[-1000:]}")
        try:
            msg = json.loads(line.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise TrackerError("linear_mcp_app_server", "app-server returned malformed JSON", cause=exc) from exc
        if not isinstance(msg, dict):
            raise TrackerError("linear_mcp_app_server", "app-server message is not an object")
        return msg

    def _decode_tool_response(self, response: Any) -> Any:
        if not isinstance(response, dict):
            raise TrackerError("linear_mcp_app_server", "MCP tool response is not an object")
        if response.get("isError"):
            raise TrackerError("linear_mcp_tool_error", json.dumps(response, sort_keys=True, default=str))
        content = response.get("content")
        if not isinstance(content, list):
            raise TrackerError("linear_mcp_app_server", "MCP tool response missing content list")
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                try:
                    body = json.loads(item["text"])
                except json.JSONDecodeError as exc:
                    raise TrackerError("linear_mcp_app_server", "Linear MCP text response is not JSON", cause=exc) from exc
                return body
        raise TrackerError("linear_mcp_app_server", "MCP tool response did not contain text JSON")


def _dedupe_issues(issues: list[Issue]) -> list[Issue]:
    seen: set[str] = set()
    deduped: list[Issue] = []
    for issue in issues:
        if issue.id in seen:
            continue
        seen.add(issue.id)
        deduped.append(issue)
    return deduped


def _normalize_attachments(value: Any) -> list[IssueAttachment]:
    if not isinstance(value, list):
        return []
    attachments: list[IssueAttachment] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        attachment_id = item.get("id")
        title = item.get("title")
        subtitle = item.get("subtitle")
        url = item.get("url")
        attachments.append(
            IssueAttachment(
                id=str(attachment_id) if attachment_id is not None else None,
                title=str(title) if title is not None else None,
                subtitle=str(subtitle) if subtitle is not None else None,
                url=str(url) if url is not None else None,
            )
        )
    return attachments


def _retryable_mcp_gateway_error(error: TrackerError) -> bool:
    if error.code == "linear_mcp_app_server":
        return True
    if error.code != "linear_mcp_tool_error":
        return False
    text = str(error).lower()
    return any(fragment in text for fragment in ("transport", "http request failed", "timed out", "failed to get client"))
