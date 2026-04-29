from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable

from .config import CodexConfig, TrackerConfig
from .errors import AgentError
from .logging import log_event
from .tracker import LinearClient
from .utils import (
    JSONL_READ_LIMIT_BYTES,
    NON_INTERACTIVE_TOOL_INPUT_ANSWER,
    now_utc,
    tool_request_user_input_approval_answers,
    tool_request_user_input_unavailable_answers,
    truncate,
)

LOGGER = logging.getLogger(__name__)

CodexEventCallback = Callable[[dict[str, Any]], Awaitable[None]]


@dataclass(slots=True)
class TurnResult:
    thread_id: str
    turn_id: str
    status: str
    agent_message_text: str = ""


class CodexAppServerSession:
    def __init__(
        self,
        config: CodexConfig,
        workspace_path: Path,
        *,
        tracker_config: TrackerConfig | None,
        on_event: CodexEventCallback,
    ):
        self.config = config
        self.workspace_path = workspace_path.resolve(strict=False)
        self.tracker_config = tracker_config
        self.on_event = on_event
        self.proc: asyncio.subprocess.Process | None = None
        self._next_id = 1
        self.thread_id: str | None = None
        self.stderr_tail: list[str] = []
        self._stderr_task: asyncio.Task[None] | None = None
        self._agent_text_capture: list[str] | None = None

    async def __aenter__(self) -> "CodexAppServerSession":
        await self.start()
        return self

    async def __aexit__(self, exc_type: object, exc: object, tb: object) -> None:
        await self.stop()

    async def start(self) -> None:
        if not self.workspace_path.is_dir():
            raise AgentError("invalid_workspace_cwd", f"workspace cwd does not exist: {self.workspace_path}")
        self.proc = await asyncio.create_subprocess_exec(
            "bash",
            "-lc",
            self.config.command,
            cwd=self.workspace_path,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=JSONL_READ_LIMIT_BYTES,
        )
        self._stderr_task = asyncio.create_task(self._read_stderr())
        await self._emit({"event": "app_server_started", "codex_app_server_pid": str(self.proc.pid)})
        try:
            await self._request(
                "initialize",
                {
                    "clientInfo": {"name": "symphony_runner", "title": "Symphony Runner", "version": "0.1.0"},
                    "capabilities": {"experimentalApi": True},
                },
                timeout_ms=self.config.read_timeout_ms,
            )
            await self._notify("initialized", {})
            thread_params: dict[str, Any] = {
                "cwd": str(self.workspace_path),
                "approvalPolicy": self.config.approval_policy,
                "sandbox": self.config.thread_sandbox,
                "serviceName": "symphony_runner",
                "sessionStartSource": "startup",
            }
            if self.config.model:
                thread_params["model"] = self.config.model
            if self.config.personality:
                thread_params["personality"] = self.config.personality
            response = await self._request("thread/start", thread_params, timeout_ms=self.config.read_timeout_ms)
        except FileNotFoundError as exc:
            await self.stop()
            raise AgentError("codex_not_found", "codex app-server command could not be launched", cause=exc) from exc
        except AgentError:
            await self.stop()
            raise
        except Exception as exc:
            await self.stop()
            raise AgentError("response_error", f"app-server startup failed: {exc}", cause=exc) from exc
        thread = (response.get("thread") or {}) if isinstance(response, dict) else {}
        thread_id = thread.get("id")
        if not thread_id:
            raise AgentError("response_error", "thread/start response did not include thread.id")
        self.thread_id = str(thread_id)

    async def stop(self) -> None:
        proc = self.proc
        if proc is None:
            return
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except TimeoutError:
                proc.kill()
                await proc.wait()
        if self._stderr_task:
            self._stderr_task.cancel()
            try:
                await self._stderr_task
            except asyncio.CancelledError:
                pass
        await self._emit({"event": "app_server_stopped", "codex_app_server_pid": str(proc.pid), "returncode": proc.returncode})
        self.proc = None

    async def run_turn(self, prompt: str, *, capture_agent_text: bool = False) -> TurnResult:
        if not self.thread_id:
            raise AgentError("response_error", "thread has not been started")
        params: dict[str, Any] = {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": prompt}],
            "cwd": str(self.workspace_path),
            "approvalPolicy": self.config.approval_policy,
            "sandboxPolicy": self._turn_sandbox_policy(),
        }
        if self.config.model:
            params["model"] = self.config.model
        if self.config.effort:
            params["effort"] = self.config.effort
        if self.config.summary:
            params["summary"] = self.config.summary
        if self.config.personality:
            params["personality"] = self.config.personality
        response = await self._request("turn/start", params, timeout_ms=self.config.read_timeout_ms)
        turn = (response.get("turn") or {}) if isinstance(response, dict) else {}
        turn_id = turn.get("id")
        if not turn_id:
            raise AgentError("response_error", "turn/start response did not include turn.id")
        session_id = f"{self.thread_id}-{turn_id}"
        await self._emit(
            {
                "event": "session_started",
                "thread_id": self.thread_id,
                "turn_id": turn_id,
                "session_id": session_id,
                "codex_app_server_pid": str(self.proc.pid) if self.proc else None,
            }
        )
        previous_capture = self._agent_text_capture
        self._agent_text_capture = [] if capture_agent_text else None
        try:
            status = await self._wait_for_turn(str(turn_id))
            agent_message_text = "".join(self._agent_text_capture or [])
        finally:
            self._agent_text_capture = previous_capture
        return TurnResult(thread_id=self.thread_id, turn_id=str(turn_id), status=status, agent_message_text=agent_message_text)

    def _turn_sandbox_policy(self) -> Any:
        if self.config.turn_sandbox_policy is not None:
            return self.config.turn_sandbox_policy
        return {"type": "workspaceWrite", "writableRoots": [str(self.workspace_path)], "networkAccess": True}

    async def _request(self, method: str, params: dict[str, Any] | None = None, *, timeout_ms: int) -> Any:
        request_id = self._next_id
        self._next_id += 1
        await self._send({"method": method, "id": request_id, "params": params or {}})
        while True:
            msg = await self._read_message(timeout_ms=timeout_ms)
            if "id" in msg and msg.get("id") == request_id and "method" not in msg:
                if "error" in msg:
                    raise AgentError("response_error", json.dumps(msg["error"], sort_keys=True))
                return msg.get("result", {})
            if "method" in msg and "id" in msg:
                fatal = await self._handle_server_request(msg)
                if fatal:
                    raise fatal
            elif "method" in msg:
                await self._handle_notification(msg)

    async def _notify(self, method: str, params: dict[str, Any]) -> None:
        await self._send({"method": method, "params": params})

    async def _send(self, message: dict[str, Any]) -> None:
        if self.proc is None or self.proc.stdin is None:
            raise AgentError("port_exit", "app-server stdin is closed")
        self.proc.stdin.write(json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n")
        await self.proc.stdin.drain()

    async def _read_message(self, *, timeout_ms: int) -> dict[str, Any]:
        if self.proc is None or self.proc.stdout is None:
            raise AgentError("port_exit", "app-server stdout is closed")
        try:
            line = await asyncio.wait_for(self.proc.stdout.readline(), timeout=timeout_ms / 1000)
        except TimeoutError as exc:
            raise AgentError("response_timeout", f"timed out waiting for app-server response after {timeout_ms} ms", cause=exc) from exc
        except ValueError as exc:
            raise AgentError("response_error", f"app-server JSONL message exceeded reader limit: {exc}", cause=exc) from exc
        if not line:
            stderr = "\n".join(self.stderr_tail[-10:])
            raise AgentError("port_exit", f"app-server exited before response: {truncate(stderr, 1000)}")
        if len(line) > 10 * 1024 * 1024:
            raise AgentError("response_error", "app-server JSONL message exceeded 10 MB")
        try:
            msg = json.loads(line.decode("utf-8"))
        except json.JSONDecodeError as exc:
            await self._emit({"event": "malformed", "message": truncate(line.decode(errors="replace"), 1000)})
            raise AgentError("response_error", "malformed app-server JSON", cause=exc) from exc
        if not isinstance(msg, dict):
            raise AgentError("response_error", "app-server message is not an object")
        return msg

    async def _wait_for_turn(self, turn_id: str) -> str:
        deadline = asyncio.get_running_loop().time() + self.config.turn_timeout_ms / 1000
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise AgentError("turn_timeout", f"turn timed out after {self.config.turn_timeout_ms} ms")
            msg = await self._read_message(timeout_ms=max(1, int(remaining * 1000)))
            if "method" in msg and "id" in msg:
                fatal = await self._handle_server_request(msg)
                if fatal:
                    raise fatal
                continue
            if "method" not in msg:
                continue
            await self._handle_notification(msg)
            if msg.get("method") != "turn/completed":
                continue
            params = msg.get("params") or {}
            turn = params.get("turn") or {}
            completed_id = turn.get("id")
            if completed_id and str(completed_id) != turn_id:
                continue
            status = str(turn.get("status") or "")
            if status == "completed":
                return status
            if status == "interrupted":
                raise AgentError("turn_cancelled", "turn was interrupted")
            error = turn.get("error") or params.get("error")
            raise AgentError("turn_failed", truncate(json.dumps(error, sort_keys=True, default=str), 1000) if error else "turn failed")

    async def _handle_notification(self, msg: dict[str, Any]) -> None:
        method = str(msg.get("method"))
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        event: dict[str, Any] = {
            "event": self._event_name(method),
            "method": method,
            "payload": params,
            "codex_app_server_pid": str(self.proc.pid) if self.proc else None,
        }
        thread_id = params.get("threadId") or params.get("thread_id")
        turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
        turn_id = params.get("turnId") or params.get("turn_id") or turn.get("id")
        if thread_id:
            event["thread_id"] = thread_id
        if turn_id:
            event["turn_id"] = turn_id
        if thread_id and turn_id:
            event["session_id"] = f"{thread_id}-{turn_id}"
        if method == "thread/tokenUsage/updated":
            token_usage = params.get("tokenUsage") or {}
            total = token_usage.get("total") if isinstance(token_usage, dict) else {}
            if isinstance(total, dict):
                event["usage_absolute"] = {
                    "input_tokens": total.get("inputTokens"),
                    "output_tokens": total.get("outputTokens"),
                    "total_tokens": total.get("totalTokens"),
                }
        if method in {"account/rateLimits/updated", "account/rateLimitsUpdated"}:
            event["rate_limits"] = params
        agent_text = self._agent_text_from_notification(method, params)
        if agent_text and self._agent_text_capture is not None:
            self._agent_text_capture.append(agent_text)
        event["message"] = self._summarize(method, params)
        await self._emit(event)

    async def _handle_server_request(self, msg: dict[str, Any]) -> AgentError | None:
        request_id = msg.get("id")
        method = str(msg.get("method"))
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        if method == "item/commandExecution/requestApproval":
            await self._send({"id": request_id, "result": {"decision": "acceptForSession"}})
            await self._emit({"event": "approval_auto_approved", "method": method, "payload": params})
            return None
        if method == "item/fileChange/requestApproval":
            await self._send({"id": request_id, "result": {"decision": "acceptForSession"}})
            await self._emit({"event": "approval_auto_approved", "method": method, "payload": params})
            return None
        if method == "item/tool/requestUserInput":
            if await self._auto_answer_tool_user_input(request_id, method, params):
                return None
            if request_id is not None:
                await self._send({"id": request_id, "result": {"answers": {}}})
            await self._emit({"event": "turn_input_required", "method": method, "payload": params})
            return AgentError("turn_input_required", "app-server requested user input")
        if method == "item/tool/call":
            result = await self._handle_dynamic_tool(params)
            await self._send({"id": request_id, "result": result})
            return None
        await self._send({"id": request_id, "error": {"code": -32601, "message": f"unsupported server request: {method}"}})
        await self._emit({"event": "unsupported_tool_call", "method": method, "payload": params})
        return None

    async def _handle_dynamic_tool(self, params: dict[str, Any]) -> dict[str, Any]:
        tool = params.get("tool") or params.get("name")
        if tool != "linear_graphql":
            return self._tool_text(False, {"error": {"code": "unsupported_tool", "message": f"unsupported tool: {tool}"}})
        if self.tracker_config is None or self.tracker_config.kind != "linear" or not self.tracker_config.api_key:
            return self._tool_text(False, {"error": {"code": "missing_auth", "message": "Linear auth is not configured"}})
        arguments = params.get("arguments")
        if isinstance(arguments, str):
            query = arguments
            variables: dict[str, Any] = {}
        elif isinstance(arguments, dict):
            query = arguments.get("query")
            variables = arguments.get("variables") or {}
        else:
            return self._tool_text(False, {"error": {"code": "invalid_input", "message": "arguments must be an object or query string"}})
        if not isinstance(query, str) or not query.strip():
            return self._tool_text(False, {"error": {"code": "invalid_input", "message": "query must be a non-empty string"}})
        if not isinstance(variables, dict):
            return self._tool_text(False, {"error": {"code": "invalid_input", "message": "variables must be an object"}})
        if _looks_like_multiple_graphql_operations(query):
            return self._tool_text(False, {"error": {"code": "invalid_input", "message": "query must contain exactly one operation"}})
        try:
            body = await LinearClient(self.tracker_config).execute_graphql_once(query, variables)
        except Exception as exc:
            return self._tool_text(False, {"error": {"code": "linear_graphql", "message": str(exc)}})
        return self._tool_text(True, body)

    def _tool_text(self, success: bool, payload: dict[str, Any]) -> dict[str, Any]:
        output = json.dumps(payload, sort_keys=True, default=str)
        return {"success": success, "output": output, "contentItems": [{"type": "inputText", "text": output}]}

    async def _auto_answer_tool_user_input(self, request_id: Any, method: str, params: dict[str, Any]) -> bool:
        if request_id is None:
            return False
        answers = tool_request_user_input_approval_answers(params)
        if answers:
            await self._send({"id": request_id, "result": {"answers": answers}})
            await self._emit(
                {
                    "event": "approval_auto_approved",
                    "method": method,
                    "payload": params,
                    "decision": "Approve this Session",
                }
            )
            return True
        answers = tool_request_user_input_unavailable_answers(params)
        if answers:
            await self._send({"id": request_id, "result": {"answers": answers}})
            await self._emit(
                {
                    "event": "tool_input_auto_answered",
                    "method": method,
                    "payload": params,
                    "answer": NON_INTERACTIVE_TOOL_INPUT_ANSWER,
                }
            )
            return True
        return False

    async def _emit(self, event: dict[str, Any]) -> None:
        event.setdefault("timestamp", now_utc())
        await self.on_event(event)

    async def _read_stderr(self) -> None:
        if self.proc is None or self.proc.stderr is None:
            return
        while True:
            line = await self.proc.stderr.readline()
            if not line:
                return
            text = line.decode(errors="replace").rstrip()
            self.stderr_tail.append(text)
            self.stderr_tail = self.stderr_tail[-50:]
            log_event(LOGGER, logging.DEBUG, "app_server_stderr", message=truncate(text, 1000))

    def _event_name(self, method: str) -> str:
        if method == "turn/completed":
            return "turn_completed"
        if method == "turn/started":
            return "turn_started"
        if method == "item/tool/requestUserInput":
            return "turn_input_required"
        return method.replace("/", "_")

    def _summarize(self, method: str, params: dict[str, Any]) -> str:
        if method == "item/agentMessage/delta":
            return truncate(str(params.get("delta") or params.get("text") or ""), 500)
        item = params.get("item")
        if isinstance(item, dict):
            if item.get("type") == "agentMessage":
                return truncate(str(item.get("text") or ""), 500)
            if item.get("type") == "commandExecution":
                command = item.get("command")
                return truncate(f"command={command} status={item.get('status')}", 500)
            return truncate(f"item_type={item.get('type')} status={item.get('status')}", 500)
        if method == "turn/completed":
            turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
            return f"status={turn.get('status')}"
        return truncate(json.dumps(params, sort_keys=True, default=str), 500)

    def _agent_text_from_notification(self, method: str, params: dict[str, Any]) -> str:
        if method == "item/agentMessage/delta":
            return str(params.get("delta") or params.get("text") or "")
        item = params.get("item") if isinstance(params.get("item"), dict) else None
        if item and item.get("type") == "agentMessage" and not self._agent_text_capture:
            return str(item.get("text") or "")
        if method == "turn/completed" and not self._agent_text_capture:
            turn = params.get("turn") if isinstance(params.get("turn"), dict) else {}
            items = turn.get("items") if isinstance(turn.get("items"), list) else []
            parts = [
                str(item.get("text") or "")
                for item in items
                if isinstance(item, dict) and item.get("type") == "agentMessage" and item.get("text")
            ]
            return "\n".join(parts)
        return ""


def _looks_like_multiple_graphql_operations(query: str) -> bool:
    cleaned = " ".join(line.split("#", 1)[0] for line in query.splitlines())
    operation_words = 0
    for word in ("query", "mutation", "subscription"):
        operation_words += len(cleaned.split(word)) - 1
    return operation_words > 1
