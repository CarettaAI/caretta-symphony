from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Awaitable, Callable

from .codex_client import CodexAppServerSession
from .config import ConfigManager
from .coding_context import augment_prompt_with_coding_context
from .coding_context import classify_coding_issue
from .errors import SymphonyError
from .logging import log_event
from .models import Issue, RepoPlan
from .repo_planner import apply_repo_plan_to_prompt, plan_repositories
from .templating import continuation_prompt, render_prompt
from .tracker import IssueTracker
from .utils import isoformat_z, normalize_state, now_utc, truncate
from .workspace import WorkspaceManager

LOGGER = logging.getLogger(__name__)

RunnerEventCallback = Callable[[str, dict], Awaitable[None]]
IssueEventCallback = Callable[[dict], Awaitable[None]]


@dataclass(slots=True)
class AgentRunResult:
    issue_id: str
    issue_identifier: str
    normal: bool
    reason: str = "normal"
    retryable: bool = True
    blocked: bool = False
    workspace_path: str | None = None
    repo_plan: RepoPlan | None = None


class AgentRunner:
    def __init__(self, config_manager: ConfigManager, tracker: IssueTracker):
        self.config_manager = config_manager
        self.tracker = tracker

    async def run_issue(self, issue: Issue, attempt: int | None, on_event: RunnerEventCallback) -> AgentRunResult:
        workflow, config = self.config_manager.current()
        workspace_manager = WorkspaceManager(config.workspace, config.hooks)
        workspace = await workspace_manager.create_for_issue(issue.identifier)
        log_event(
            LOGGER,
            logging.INFO,
            "run_attempt_started",
            issue_id=issue.id,
            issue_identifier=issue.identifier,
            attempt=attempt,
            workspace_path=workspace.path,
        )
        try:
            async def emit(event: dict) -> None:
                await on_event(issue.id, event)

            first_prompt = render_prompt(workflow.prompt_template, issue, attempt)
            classification = await classify_coding_issue(
                issue,
                config.context.coding,
                codex_config=config.codex,
                workspace_path=workspace.path,
            )
            repo_plan = await plan_repositories(
                issue,
                config.repositories,
                config.context.coding,
                classification,
                codex_config=config.codex,
                workspace_path=workspace.path,
            )
            if repo_plan is not None:
                await emit(
                    {
                        "event": "repo_plan_created",
                        "repo_plan": repo_plan.to_dict(),
                        "repo_plan_needs_human": repo_plan.needs_human,
                        "repo_plan_human_reason": repo_plan.human_reason,
                    }
                )
                if repo_plan.needs_human and config.repositories.block_on_needs_human:
                    return AgentRunResult(
                        issue_id=issue.id,
                        issue_identifier=issue.identifier,
                        normal=False,
                        reason="repo_plan_needs_human",
                        retryable=False,
                        blocked=True,
                        workspace_path=str(workspace.path),
                        repo_plan=repo_plan,
                    )
                workspace = await workspace_manager.materialize_repo_plan(workspace, repo_plan, config.repositories)
                await emit(
                    {
                        "event": "repo_workspace_prepared",
                        "repo_plan": repo_plan.to_dict(),
                        "workspace_path": str(workspace.path),
                        "primary_repo_path": str(workspace.primary_repo_path) if workspace.primary_repo_path else None,
                    }
                )
            await workspace_manager.before_run(workspace.path)
            first_prompt = await augment_prompt_with_coding_context(
                first_prompt,
                issue,
                config.context.coding,
                codex_config=config.codex,
                workspace_path=workspace.path,
                classification=classification,
                on_event=emit,
            )
            first_prompt = apply_repo_plan_to_prompt(first_prompt, repo_plan, workspace.path)
            max_turns = config.agent.max_turns

            async with CodexAppServerSession(
                config.codex,
                workspace.path,
                tracker_config=config.tracker,
                on_event=emit,
            ) as session:
                turn_number = 1
                current_issue = issue
                while True:
                    prompt = first_prompt if turn_number == 1 else continuation_prompt(current_issue, turn_number, max_turns)
                    turn_result = await session.run_turn(prompt, capture_agent_text=True)
                    refreshed = await self.tracker.fetch_issue_states_by_ids([issue.id])
                    if refreshed:
                        current_issue = refreshed[0]
                    state = normalize_state(current_issue.state)
                    if state in config.tracker.active_state_set:
                        delivered = await self._try_delivery_fallback(
                            current_issue,
                            turn_result.agent_message_text,
                            workspace_path=str(workspace.path),
                            handoff_state=config.tracker.handoff_state,
                            on_event=emit,
                        )
                        if delivered:
                            current_issue.state = config.tracker.handoff_state
                            state = normalize_state(current_issue.state)
                    if state not in config.tracker.active_state_set:
                        return AgentRunResult(
                            issue_id=issue.id,
                            issue_identifier=issue.identifier,
                            normal=True,
                            reason="issue_left_active_state",
                            retryable=False,
                            workspace_path=str(workspace.path),
                            repo_plan=repo_plan,
                        )
                    if turn_number >= max_turns:
                        return AgentRunResult(
                            issue_id=issue.id,
                            issue_identifier=issue.identifier,
                            normal=True,
                            reason="max_turns_reached",
                            retryable=True,
                            workspace_path=str(workspace.path),
                            repo_plan=repo_plan,
                        )
                    turn_number += 1
            return AgentRunResult(
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                normal=True,
                workspace_path=str(workspace.path),
                repo_plan=repo_plan,
            )
        except SymphonyError as exc:
            log_event(
                LOGGER,
                logging.ERROR,
                "run_attempt_failed",
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                reason=exc,
            )
            return AgentRunResult(
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                normal=False,
                reason=exc.code,
                workspace_path=str(workspace.path),
            )
        except Exception as exc:
            log_event(
                LOGGER,
                logging.ERROR,
                "run_attempt_failed",
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                reason=exc,
            )
            return AgentRunResult(
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                normal=False,
                reason="unhandled_agent_error",
                workspace_path=str(workspace.path),
            )
        finally:
            try:
                await workspace_manager.after_run(workspace.path)
            except Exception as exc:
                log_event(
                    LOGGER,
                    logging.WARNING,
                    "after_run_ignored_failure",
                    issue_id=issue.id,
                    issue_identifier=issue.identifier,
                    reason=exc,
                )

    async def _try_delivery_fallback(
        self,
        issue: Issue,
        agent_message_text: str,
        *,
        workspace_path: str,
        handoff_state: str,
        on_event: IssueEventCallback,
    ) -> bool:
        if not _agent_reported_linear_delivery_blocker(agent_message_text):
            return False
        writer = self.tracker
        required_methods = ("list_issue_comments", "save_issue_comment", "save_issue_state")
        if not all(hasattr(writer, method) for method in required_methods):
            await on_event(
                {
                    "event": "delivery_fallback_unavailable",
                    "message": "Tracker does not expose first-class Linear write methods.",
                },
            )
            return False
        await on_event(
            {
                "event": "delivery_fallback_started",
                "message": "Agent completed work but reported Linear delivery rejection; Symphony is attempting tracker-owned handoff.",
            },
        )
        try:
            comments = await writer.list_issue_comments(issue.identifier)  # type: ignore[attr-defined]
            comment_id = _existing_workpad_comment_id(comments)
            body = _fallback_workpad_body(issue, agent_message_text, workspace_path)
            await writer.save_issue_comment(issue.identifier, body, comment_id=comment_id)  # type: ignore[attr-defined]
            await writer.save_issue_state(issue.identifier, handoff_state)  # type: ignore[attr-defined]
        except Exception as exc:
            await on_event(
                {
                    "event": "delivery_fallback_failed",
                    "message": f"Tracker-owned Linear handoff failed: {truncate(str(exc), 500)}",
                },
            )
            return False
        await on_event(
            {
                "event": "delivery_fallback_completed",
                "message": f"Updated Linear workpad and moved issue to {handoff_state}.",
            },
        )
        return True


def _agent_reported_linear_delivery_blocker(text: str) -> bool:
    normalized = text.lower()
    if "linear" not in normalized:
        return False
    blocker = any(
        phrase in normalized
        for phrase in (
            "rejected",
            "could not update",
            "can't update",
            "couldn't update",
            "could not create",
            "can't create",
            "couldn't create",
        )
    )
    completed = any(
        phrase in normalized
        for phrase in (
            "completed:",
            "completed actions",
            "validation passed",
            "validation previously completed",
            "pr is open",
            "pr #",
            "pull request",
            "branch clean",
            "committed and pushed",
            "already committed and pushed",
        )
    )
    return blocker and completed


def _existing_workpad_comment_id(comments: list[dict]) -> str | None:
    for comment in comments:
        body = comment.get("body") or comment.get("text") or comment.get("content") or ""
        if isinstance(body, str) and "## Codex Workpad" in body:
            comment_id = comment.get("id")
            return str(comment_id) if comment_id else None
    return None


def _fallback_workpad_body(issue: Issue, agent_message_text: str, workspace_path: str) -> str:
    timestamp = isoformat_z(now_utc())
    summary = truncate(agent_message_text.strip(), 5000)
    return f"""## Codex Workpad

```text
{workspace_path}
```

### Plan

- [x] Agent completed implementation work.
- [x] Agent attempted Linear workpad/state handoff.
- [x] Symphony applied tracker-owned delivery fallback after the in-agent Linear write was rejected.

### Acceptance Criteria

- [x] {issue.identifier} final agent handoff captured below.

### Validation

- [x] See final agent handoff below.

### Notes

- {timestamp}: Symphony fallback created this workpad because the agent reported that Linear MCP writes were rejected inside the Codex turn.

#### Final Agent Handoff

```text
{summary}
```

### Confusions

- In-agent Linear MCP writes were rejected; Symphony used tracker-owned Linear MCP writes for delivery.
"""
