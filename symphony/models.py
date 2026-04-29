from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from .utils import isoformat_z


@dataclass(slots=True)
class BlockerRef:
    id: str | None = None
    identifier: str | None = None
    state: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "identifier": self.identifier, "state": self.state}


@dataclass(slots=True)
class IssueAttachment:
    id: str | None = None
    title: str | None = None
    subtitle: str | None = None
    url: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "title": self.title, "subtitle": self.subtitle, "url": self.url}


@dataclass(slots=True)
class Issue:
    id: str
    identifier: str
    title: str
    description: str | None = None
    priority: int | None = None
    state: str = ""
    branch_name: str | None = None
    url: str | None = None
    labels: list[str] = field(default_factory=list)
    attachments: list[IssueAttachment] = field(default_factory=list)
    blocked_by: list[BlockerRef] = field(default_factory=list)
    created_at: datetime | None = None
    updated_at: datetime | None = None

    def to_template_data(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "identifier": self.identifier,
            "title": self.title,
            "description": self.description,
            "priority": self.priority,
            "state": self.state,
            "branch_name": self.branch_name,
            "url": self.url,
            "labels": list(self.labels),
            "attachments": [attachment.to_dict() for attachment in self.attachments],
            "blocked_by": [blocker.to_dict() for blocker in self.blocked_by],
            "created_at": isoformat_z(self.created_at),
            "updated_at": isoformat_z(self.updated_at),
        }


@dataclass(slots=True)
class WorkflowDefinition:
    config: dict[str, Any]
    prompt_template: str
    path: Path
    mtime_ns: int | None = None


@dataclass(slots=True)
class Workspace:
    path: Path
    workspace_key: str
    created_now: bool
    repo_plan: RepoPlan | None = None
    primary_repo_path: Path | None = None


@dataclass(frozen=True, slots=True)
class RepoPlanItem:
    slug: str
    role: str
    reason: str | None = None
    path_name: str | None = None
    edit_allowed: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "slug": self.slug,
            "role": self.role,
            "reason": self.reason,
            "path_name": self.path_name,
            "edit_allowed": self.edit_allowed,
        }


@dataclass(frozen=True, slots=True)
class RepoPlan:
    issue_identifier: str
    coding_task: bool
    planner: str
    source: str
    primary_repo: RepoPlanItem | None = None
    secondary_repos: list[RepoPlanItem] = field(default_factory=list)
    read_only_context_repos: list[RepoPlanItem] = field(default_factory=list)
    confidence: float | None = None
    needs_human: bool = False
    human_reason: str | None = None
    notes: str | None = None
    created_at: datetime | None = None

    def all_repos(self) -> list[RepoPlanItem]:
        repos: list[RepoPlanItem] = []
        if self.primary_repo is not None:
            repos.append(self.primary_repo)
        repos.extend(self.secondary_repos)
        repos.extend(self.read_only_context_repos)
        return repos

    def edit_allowed_slugs(self) -> set[str]:
        return {repo.slug for repo in self.all_repos() if repo.edit_allowed and repo.role != "read_only_context"}

    def to_dict(self) -> dict[str, Any]:
        return {
            "issue_identifier": self.issue_identifier,
            "coding_task": self.coding_task,
            "planner": self.planner,
            "source": self.source,
            "primary_repo": self.primary_repo.to_dict() if self.primary_repo else None,
            "secondary_repos": [repo.to_dict() for repo in self.secondary_repos],
            "read_only_context_repos": [repo.to_dict() for repo in self.read_only_context_repos],
            "confidence": self.confidence,
            "needs_human": self.needs_human,
            "human_reason": self.human_reason,
            "notes": self.notes,
            "created_at": isoformat_z(self.created_at),
        }


@dataclass(slots=True)
class CodexTotals:
    input_tokens: int = 0
    output_tokens: int = 0
    total_tokens: int = 0
    seconds_running: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "total_tokens": self.total_tokens,
            "seconds_running": self.seconds_running,
        }


@dataclass(slots=True)
class RetryEntry:
    issue_id: str
    identifier: str
    attempt: int
    due_at_monotonic: float
    due_at_wall: datetime
    error: str | None = None
    timer_handle: asyncio.Task[None] | None = None


@dataclass(slots=True)
class BlockedEntry:
    issue: Issue
    reason: str
    blocked_at: datetime
    workspace_path: Path | None = None
    repo_plan: RepoPlan | None = None


@dataclass(slots=True)
class CompletedEntry:
    issue: Issue
    completed_at: datetime
    reason: str
    workspace_path: Path | None = None
    repo_plan: RepoPlan | None = None
    duration_seconds: float = 0.0
    turn_count: int = 0
    session_id: str | None = None
    thread_id: str | None = None
    turn_id: str | None = None
    codex_input_tokens: int = 0
    codex_output_tokens: int = 0
    codex_total_tokens: int = 0
    summary_text: str | None = None
    summary_current_step: str | None = None
    summary_needs_human: bool = False
    summary_human_reason: str | None = None
    summary_risk: str | None = None
    summary_confidence: float | None = None
    summary_updated_at: datetime | None = None
    repo_deviations: list[str] = field(default_factory=list)
    recent_activity: list[dict[str, Any]] = field(default_factory=list)


@dataclass(slots=True)
class RunningEntry:
    issue: Issue
    task: asyncio.Task[Any]
    cancel_event: asyncio.Event
    workspace_path: Path | None
    started_at: datetime
    started_monotonic: float
    retry_attempt: int | None = None
    session_id: str | None = None
    thread_id: str | None = None
    turn_id: str | None = None
    codex_app_server_pid: str | None = None
    last_codex_event: str | None = None
    last_codex_timestamp: datetime | None = None
    last_codex_message: str | None = None
    repo_plan: RepoPlan | None = None
    repo_deviations: list[str] = field(default_factory=list)
    recent_activity: list[dict[str, Any]] = field(default_factory=list)
    activity_revision: int = 0
    summary_revision: int = 0
    summary_pending: bool = False
    summary_text: str | None = None
    summary_current_step: str | None = None
    summary_needs_human: bool = False
    summary_human_reason: str | None = None
    summary_risk: str | None = None
    summary_confidence: float | None = None
    summary_updated_at: datetime | None = None
    summary_error: str | None = None
    summary_source: str | None = None
    last_summary_monotonic: float = 0.0
    codex_input_tokens: int = 0
    codex_output_tokens: int = 0
    codex_total_tokens: int = 0
    last_reported_input_tokens: int = 0
    last_reported_output_tokens: int = 0
    last_reported_total_tokens: int = 0
    turn_count: int = 0
    forced_outcome: str | None = None
    forced_error: str | None = None
    cleanup_workspace: bool = False


@dataclass(slots=True)
class RuntimeState:
    poll_interval_ms: int
    max_concurrent_agents: int
    service_status: str = "starting"
    startup_completed_at: datetime | None = None
    last_poll_started_at: datetime | None = None
    last_poll_completed_at: datetime | None = None
    last_poll_error: str | None = None
    last_candidate_count: int | None = None
    running: dict[str, RunningEntry] = field(default_factory=dict)
    claimed: set[str] = field(default_factory=set)
    retry_attempts: dict[str, RetryEntry] = field(default_factory=dict)
    blocked: dict[str, BlockedEntry] = field(default_factory=dict)
    completed: dict[str, CompletedEntry] = field(default_factory=dict)
    codex_totals: CodexTotals = field(default_factory=CodexTotals)
    codex_rate_limits: dict[str, Any] | None = None
