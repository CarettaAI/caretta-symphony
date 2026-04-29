from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any

from .agent_runner import AgentRunResult, AgentRunner
from .config import ConfigManager, ServiceConfig
from .dashboard_summary import DashboardSummary, summarize_activity
from .errors import ConfigError, TrackerError
from .logging import log_event
from .models import (
    BlockedEntry,
    BlockerRef,
    CodexTotals,
    CompletedEntry,
    Issue,
    IssueAttachment,
    RepoPlan,
    RepoPlanItem,
    RetryEntry,
    RunningEntry,
    RuntimeState,
)
from .tracker import IssueTracker, make_tracker
from .utils import isoformat_z, normalize_state, now_utc, parse_datetime, truncate
from .review import ReviewPullRequestResolver
from .workspace import WorkspaceManager

LOGGER = logging.getLogger(__name__)
CONTINUATION_RETRY_MS = 1000
STATE_FILE_NAME = ".symphony-state.json"


class Orchestrator:
    def __init__(self, config_manager: ConfigManager, *, review_resolver: ReviewPullRequestResolver | None = None):
        self.config_manager = config_manager
        _, config = self.config_manager.current()
        self.state = RuntimeState(
            poll_interval_ms=config.polling.interval_ms,
            max_concurrent_agents=config.agent.max_concurrent_agents,
        )
        self.review_resolver = review_resolver or ReviewPullRequestResolver()
        self._lock = asyncio.Lock()
        self._refresh_event = asyncio.Event()
        self._stopping = False
        self._summary_tasks: dict[str, asyncio.Task[Any]] = {}
        self._load_persisted_state()

    async def start(self) -> None:
        self.config_manager.load_startup()
        await self.startup_terminal_workspace_cleanup()
        async with self._lock:
            self._restore_retry_timers_locked()
            self.state.service_status = "running"
            self.state.startup_completed_at = now_utc()
            self.state.last_poll_error = None
            self._persist_state_locked()
        log_event(LOGGER, logging.INFO, "service_started", workflow_path=self.config_manager.workflow_path)
        await self.request_refresh()
        while not self._stopping:
            await self._refresh_event.wait()
            self._refresh_event.clear()
            await self.tick()
            _, config = self.config_manager.current()
            try:
                await asyncio.wait_for(self._refresh_event.wait(), timeout=config.polling.interval_ms / 1000)
            except TimeoutError:
                self._refresh_event.set()

    async def stop(self) -> None:
        self._stopping = True
        self._refresh_event.set()
        tasks: list[asyncio.Task[Any]] = []
        async with self._lock:
            for entry in list(self.state.running.values()):
                entry.forced_outcome = "release"
                entry.cancel_event.set()
                entry.task.cancel()
                tasks.append(entry.task)
            for retry in self.state.retry_attempts.values():
                if retry.timer_handle:
                    retry.timer_handle.cancel()
                    tasks.append(retry.timer_handle)
            for task in self._summary_tasks.values():
                task.cancel()
                tasks.append(task)
            self._summary_tasks.clear()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        async with self._lock:
            self._persist_state_locked()

    async def request_refresh(self) -> bool:
        already_set = self._refresh_event.is_set()
        self._refresh_event.set()
        return already_set

    async def tick(self) -> None:
        self.config_manager.reload_if_changed()
        _, config = self.config_manager.current()
        async with self._lock:
            self.state.service_status = "polling"
            self.state.poll_interval_ms = config.polling.interval_ms
            self.state.max_concurrent_agents = config.agent.max_concurrent_agents
            self.state.last_poll_started_at = now_utc()
            self.state.last_poll_error = None
        tracker = make_tracker(config.tracker)
        await self.reconcile_running_issues(tracker, config)
        try:
            self.config_manager.validate_for_dispatch()
        except ConfigError as exc:
            await self._mark_poll_failed(exc)
            log_event(LOGGER, logging.ERROR, "dispatch_validation_failed", reason=exc)
            return
        _, config = self.config_manager.current()
        tracker = make_tracker(config.tracker)
        await self.reconcile_review_issues(tracker, config)
        try:
            candidates = await tracker.fetch_candidate_issues()
        except TrackerError as exc:
            await self._mark_poll_failed(exc)
            log_event(LOGGER, logging.ERROR, "candidate_fetch_failed", reason=exc)
            return
        for issue in self.sort_for_dispatch(candidates):
            async with self._lock:
                if self.available_global_slots_locked(config) <= 0:
                    break
                eligible = self.is_dispatch_eligible_locked(issue, config)
            if eligible:
                await self.dispatch_issue(issue, attempt=None, tracker=tracker)
        await self._mark_poll_completed(len(candidates))

    async def _mark_poll_failed(self, exc: Exception) -> None:
        async with self._lock:
            self.state.service_status = "degraded"
            self.state.last_poll_completed_at = now_utc()
            self.state.last_poll_error = truncate(str(exc), 500)
            self._persist_state_locked()

    async def _mark_poll_completed(self, candidate_count: int) -> None:
        async with self._lock:
            self.state.service_status = "running"
            self.state.last_poll_completed_at = now_utc()
            self.state.last_candidate_count = candidate_count
            self.state.last_poll_error = None
            self._persist_state_locked()

    async def startup_terminal_workspace_cleanup(self) -> None:
        _, config = self.config_manager.current()
        tracker = make_tracker(config.tracker)
        try:
            terminal = await tracker.fetch_issues_by_states(config.tracker.terminal_states)
        except TrackerError as exc:
            log_event(LOGGER, logging.WARNING, "startup_cleanup_failed", reason=exc)
            return
        workspace_manager = WorkspaceManager(config.workspace, config.hooks)
        for issue in terminal:
            await workspace_manager.remove_for_identifier(issue.identifier)

    async def reconcile_running_issues(self, tracker: IssueTracker, config: ServiceConfig) -> None:
        await self._reconcile_stalled(config)
        async with self._lock:
            running_ids = list(self.state.running.keys())
        if not running_ids:
            return
        try:
            refreshed = await tracker.fetch_issue_states_by_ids(running_ids)
        except TrackerError as exc:
            log_event(LOGGER, logging.WARNING, "running_state_refresh_failed", reason=exc)
            return
        refreshed_by_id = {issue.id: issue for issue in refreshed}
        for issue_id in running_ids:
            issue = refreshed_by_id.get(issue_id)
            if issue is None:
                continue
            state = normalize_state(issue.state)
            if state in config.tracker.terminal_state_set:
                await self.terminate_running_issue(issue_id, cleanup_workspace=True, retry=False, reason="terminal_state")
            elif not self._has_required_labels(issue, config):
                await self.terminate_running_issue(issue_id, cleanup_workspace=False, retry=False, reason="required_label_removed")
            elif state in config.tracker.active_state_set:
                async with self._lock:
                    if issue_id in self.state.running:
                        self.state.running[issue_id].issue = issue
            else:
                await self.terminate_running_issue(issue_id, cleanup_workspace=False, retry=False, reason="non_active_state")

    async def reconcile_review_issues(self, tracker: IssueTracker, config: ServiceConfig) -> None:
        if not config.tracker.review_states:
            return
        if not hasattr(tracker, "save_issue_state"):
            log_event(LOGGER, logging.DEBUG, "review_reconciliation_skipped", reason="tracker does not expose state writes")
            return
        try:
            review_issues = await tracker.fetch_issues_by_states(config.tracker.review_states)
        except TrackerError as exc:
            log_event(LOGGER, logging.WARNING, "review_issue_fetch_failed", reason=exc)
            return
        if not review_issues:
            return
        try:
            refreshed = await tracker.fetch_issue_states_by_ids([issue.id for issue in review_issues])
        except TrackerError as exc:
            log_event(LOGGER, logging.WARNING, "review_issue_hydration_failed", reason=exc)
            refreshed = review_issues
        workspace_manager = WorkspaceManager(config.workspace, config.hooks)
        for issue in _dedupe_by_id(refreshed):
            if not self._has_required_labels(issue, config):
                continue
            comments: list[dict[str, Any]] = []
            if hasattr(tracker, "list_issue_comments"):
                try:
                    comments = await tracker.list_issue_comments(issue.identifier)  # type: ignore[attr-defined]
                except Exception as exc:
                    log_event(
                        LOGGER,
                        logging.WARNING,
                        "review_comment_fetch_failed",
                        issue_id=issue.id,
                        issue_identifier=issue.identifier,
                        reason=truncate(str(exc), 500),
                    )
            workspace_path = workspace_manager.workspace_path_for_identifier(issue.identifier)
            try:
                result = await self.review_resolver.evaluate(
                    issue,
                    comments=comments,
                    workspace_path=workspace_path,
                    base_branch=config.tracker.merge_base_branch,
                )
            except Exception as exc:
                log_event(
                    LOGGER,
                    logging.WARNING,
                    "review_merge_gate_failed",
                    issue_id=issue.id,
                    issue_identifier=issue.identifier,
                    reason=truncate(str(exc), 500),
                )
                continue
            log_event(
                LOGGER,
                logging.INFO if result.ready else logging.DEBUG,
                "review_merge_gate_evaluated",
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                ready=result.ready,
                required_prs=len(result.required_prs),
                reason=result.reason,
            )
            if not result.ready:
                continue
            try:
                await tracker.save_issue_state(issue.identifier, config.tracker.done_state)  # type: ignore[attr-defined]
            except Exception as exc:
                log_event(
                    LOGGER,
                    logging.WARNING,
                    "review_done_transition_failed",
                    issue_id=issue.id,
                    issue_identifier=issue.identifier,
                    reason=truncate(str(exc), 500),
                )
                continue
            log_event(
                LOGGER,
                logging.INFO,
                "review_done_transition_completed",
                issue_id=issue.id,
                issue_identifier=issue.identifier,
                done_state=config.tracker.done_state,
                required_prs=len(result.required_prs),
            )

    async def _reconcile_stalled(self, config: ServiceConfig) -> None:
        if config.codex.stall_timeout_ms <= 0:
            return
        now = now_utc()
        stalled: list[str] = []
        async with self._lock:
            for issue_id, entry in self.state.running.items():
                since = entry.last_codex_timestamp or entry.started_at
                elapsed_ms = (now - since).total_seconds() * 1000
                if elapsed_ms > config.codex.stall_timeout_ms:
                    stalled.append(issue_id)
        for issue_id in stalled:
            await self.terminate_running_issue(issue_id, cleanup_workspace=False, retry=True, reason="stalled")

    async def dispatch_issue(self, issue: Issue, attempt: int | None, tracker: IssueTracker) -> None:
        runner = AgentRunner(self.config_manager, tracker)
        cancel_event = asyncio.Event()
        _, config = self.config_manager.current()
        workspace_path = WorkspaceManager(config.workspace, config.hooks).workspace_path_for_identifier(issue.identifier)
        async with self._lock:
            task = asyncio.create_task(runner.run_issue(issue, attempt, self.handle_codex_event))
            task.add_done_callback(lambda completed, issue_id=issue.id: asyncio.create_task(self.handle_worker_done(issue_id, completed)))
            entry = RunningEntry(
                issue=issue,
                task=task,
                cancel_event=cancel_event,
                workspace_path=workspace_path,
                started_at=now_utc(),
                started_monotonic=time.monotonic(),
                retry_attempt=attempt,
            )
            self.state.running[issue.id] = entry
            self.state.claimed.add(issue.id)
            retry = self.state.retry_attempts.pop(issue.id, None)
            if retry and retry.timer_handle:
                retry.timer_handle.cancel()
            self._persist_state_locked()
        log_event(
            LOGGER,
            logging.INFO,
            "issue_dispatched",
            issue_id=issue.id,
            issue_identifier=issue.identifier,
            attempt=attempt,
        )

    async def handle_worker_done(self, issue_id: str, completed: asyncio.Task[Any]) -> None:
        async with self._lock:
            entry = self.state.running.pop(issue_id, None)
        if entry is None:
            return
        elapsed = time.monotonic() - entry.started_monotonic
        async with self._lock:
            self.state.codex_totals.seconds_running += elapsed
            self._persist_state_locked()
        if entry.forced_outcome == "release":
            if entry.cleanup_workspace:
                await self._cleanup_workspace(entry.issue)
            async with self._lock:
                self.state.claimed.discard(issue_id)
                self._persist_state_locked()
            log_event(
                LOGGER,
                logging.INFO,
                "worker_released",
                issue_id=issue_id,
                issue_identifier=entry.issue.identifier,
                reason=entry.forced_error,
            )
            return
        if entry.forced_outcome == "retry":
            await self.schedule_retry(entry.issue, self._next_attempt(entry.retry_attempt), error=entry.forced_error or "worker cancelled")
            return
        try:
            result = completed.result()
        except asyncio.CancelledError:
            await self.schedule_retry(entry.issue, self._next_attempt(entry.retry_attempt), error="worker cancelled")
            return
        except Exception as exc:
            await self.schedule_retry(entry.issue, self._next_attempt(entry.retry_attempt), error=f"worker crashed: {exc}")
            return
        if isinstance(result, AgentRunResult) and result.normal:
            async with self._lock:
                self.state.completed[issue_id] = _completed_entry_from_running(entry, reason=result.reason, elapsed=elapsed)
                self.state.claimed.add(issue_id)
                self._persist_state_locked()
            log_event(
                LOGGER,
                logging.INFO,
                "worker_completed",
                issue_id=issue_id,
                issue_identifier=entry.issue.identifier,
                reason=result.reason,
            )
            await self.schedule_retry(
                entry.issue,
                1,
                delay_ms=CONTINUATION_RETRY_MS,
                error=None,
            )
        else:
            reason = result.reason if isinstance(result, AgentRunResult) else "worker failed"
            if isinstance(result, AgentRunResult) and result.blocked:
                async with self._lock:
                    self.state.blocked[issue_id] = BlockedEntry(
                        issue=entry.issue,
                        reason=result.repo_plan.human_reason if result.repo_plan and result.repo_plan.human_reason else reason,
                        blocked_at=now_utc(),
                        workspace_path=entry.workspace_path,
                        repo_plan=result.repo_plan,
                    )
                    self.state.claimed.add(issue_id)
                    self._persist_state_locked()
                log_event(
                    LOGGER,
                    logging.WARNING,
                    "worker_blocked",
                    issue_id=issue_id,
                    issue_identifier=entry.issue.identifier,
                    reason=reason,
                )
            elif isinstance(result, AgentRunResult) and not result.retryable:
                async with self._lock:
                    self.state.claimed.discard(issue_id)
                    self._persist_state_locked()
                log_event(LOGGER, logging.WARNING, "worker_not_retried", issue_id=issue_id, reason=reason)
            else:
                await self.schedule_retry(entry.issue, self._next_attempt(entry.retry_attempt), error=reason)

    async def terminate_running_issue(self, issue_id: str, *, cleanup_workspace: bool, retry: bool, reason: str) -> None:
        async with self._lock:
            entry = self.state.running.get(issue_id)
            if entry is None:
                return
            entry.forced_outcome = "retry" if retry else "release"
            entry.forced_error = reason
            entry.cleanup_workspace = cleanup_workspace
            entry.cancel_event.set()
            entry.task.cancel()
        log_event(LOGGER, logging.INFO, "worker_termination_requested", issue_id=issue_id, reason=reason, retry=retry)

    async def schedule_retry(
        self,
        issue: Issue,
        attempt: int,
        *,
        delay_ms: int | None = None,
        error: str | None,
    ) -> None:
        _, config = self.config_manager.current()
        if delay_ms is None:
            delay_ms = min(10000 * (2 ** max(attempt - 1, 0)), config.agent.max_retry_backoff_ms)
        due_at_monotonic = time.monotonic() + delay_ms / 1000
        timer = asyncio.create_task(self._retry_after(issue.id, delay_ms))
        entry = RetryEntry(
            issue_id=issue.id,
            identifier=issue.identifier,
            attempt=attempt,
            due_at_monotonic=due_at_monotonic,
            due_at_wall=now_utc_from_monotonic_delay(delay_ms),
            error=error,
            timer_handle=timer,
        )
        async with self._lock:
            old = self.state.retry_attempts.get(issue.id)
            if old and old.timer_handle:
                old.timer_handle.cancel()
            self.state.retry_attempts[issue.id] = entry
            self.state.claimed.add(issue.id)
            self._persist_state_locked()
        log_event(
            LOGGER,
            logging.INFO,
            "retry_scheduled",
            issue_id=issue.id,
            issue_identifier=issue.identifier,
            attempt=attempt,
            delay_ms=delay_ms,
            error=error,
            retry_kind="continuation" if error is None else "retry",
        )

    async def _retry_after(self, issue_id: str, delay_ms: int) -> None:
        try:
            await asyncio.sleep(delay_ms / 1000)
            await self.handle_retry_timer(issue_id)
        except asyncio.CancelledError:
            return

    async def handle_retry_timer(self, issue_id: str) -> None:
        async with self._lock:
            retry_entry = self.state.retry_attempts.pop(issue_id, None)
            if retry_entry is not None:
                self._persist_state_locked()
        if retry_entry is None:
            return
        _, config = self.config_manager.current()
        tracker = make_tracker(config.tracker)
        try:
            candidates = await tracker.fetch_candidate_issues()
        except TrackerError:
            issue = Issue(id=issue_id, identifier=retry_entry.identifier, title="", state="")
            await self.schedule_retry(issue, retry_entry.attempt + 1, error="retry poll failed")
            return
        issue = next((candidate for candidate in candidates if candidate.id == issue_id), None)
        if issue is None:
            async with self._lock:
                self.state.claimed.discard(issue_id)
                self._persist_state_locked()
            return
        async with self._lock:
            slots = self.available_global_slots_locked(config)
            eligible = self.is_dispatch_eligible_locked(issue, config, ignore_claimed_issue_id=issue_id)
        if slots <= 0 or not eligible:
            await self.schedule_retry(issue, retry_entry.attempt, error="no available orchestrator slots")
            return
        await self.dispatch_issue(issue, retry_entry.attempt, tracker)

    async def handle_codex_event(self, issue_id: str, event: dict[str, Any]) -> None:
        timestamp = event.get("timestamp") if hasattr(event.get("timestamp"), "tzinfo") else now_utc()
        schedule_summary = False
        async with self._lock:
            entry = self.state.running.get(issue_id)
            if entry is None:
                return
            entry.last_codex_event = event.get("event")
            entry.last_codex_timestamp = timestamp
            entry.last_codex_message = event.get("message")
            entry.codex_app_server_pid = event.get("codex_app_server_pid") or entry.codex_app_server_pid
            entry.thread_id = event.get("thread_id") or entry.thread_id
            entry.turn_id = event.get("turn_id") or entry.turn_id
            entry.session_id = event.get("session_id") or entry.session_id
            if event.get("event") == "session_started":
                entry.turn_count += 1
            if event.get("event") in {"repo_plan_created", "repo_workspace_prepared"} and isinstance(event.get("repo_plan"), dict):
                entry.repo_plan = _repo_plan_from_dict(event["repo_plan"])
            if event.get("workspace_path"):
                try:
                    entry.workspace_path = Path(str(event.get("workspace_path")))
                except TypeError:
                    pass
            deviation = _repo_deviation_from_event(entry, event)
            if deviation and deviation not in entry.repo_deviations:
                entry.repo_deviations.append(deviation)
                entry.repo_deviations = entry.repo_deviations[-20:]
            usage = event.get("usage_absolute")
            if isinstance(usage, dict):
                self._apply_usage_locked(entry, usage)
            if isinstance(event.get("rate_limits"), dict):
                self.state.codex_rate_limits = event["rate_limits"]
            self._record_activity_locked(entry, event, timestamp)
            _, config = self.config_manager.current()
            schedule_summary = self._should_schedule_summary_locked(entry, config)
            if isinstance(usage, dict) or isinstance(event.get("rate_limits"), dict):
                self._persist_state_locked()
        if schedule_summary:
            task = asyncio.create_task(self._summarize_running_issue(issue_id))
            self._summary_tasks[issue_id] = task
            task.add_done_callback(lambda _completed, key=issue_id: self._summary_tasks.pop(key, None))
        log_event(
            LOGGER,
            logging.DEBUG,
            "codex_event",
            issue_id=issue_id,
            session_id=event.get("session_id"),
            codex_event=event.get("event"),
        )

    def _record_activity_locked(self, entry: RunningEntry, event: dict[str, Any], timestamp: Any) -> None:
        message = _activity_message(event)
        if not message:
            return
        entry.recent_activity.append(
            {
                "at": isoformat_z(timestamp),
                "event": event.get("event"),
                "message": truncate(message, 1000),
            }
        )
        entry.recent_activity = entry.recent_activity[-100:]
        entry.activity_revision += 1

    def _should_schedule_summary_locked(self, entry: RunningEntry, config: ServiceConfig) -> bool:
        if not config.dashboard.summaries_enabled:
            return False
        if entry.summary_pending or entry.workspace_path is None:
            return False
        if entry.activity_revision <= entry.summary_revision or not entry.recent_activity:
            return False
        if not _has_work_signal(entry.recent_activity):
            return False
        now = time.monotonic()
        interval = config.dashboard.summary_update_interval_ms / 1000
        if entry.summary_text and now - entry.last_summary_monotonic < interval:
            return False
        entry.summary_pending = True
        return True

    async def _summarize_running_issue(self, issue_id: str) -> None:
        async with self._lock:
            entry = self.state.running.get(issue_id)
            if entry is None or entry.workspace_path is None:
                return
            _, config = self.config_manager.current()
            issue = entry.issue
            workspace_path = entry.workspace_path
            activity_revision = entry.activity_revision
            activity = list(entry.recent_activity[-config.dashboard.summary_max_events :])
            previous_summary = entry.summary_text
        try:
            summary = await summarize_activity(
                issue=issue,
                activity=activity,
                previous_summary=previous_summary,
                codex_config=config.codex,
                dashboard_config=config.dashboard,
                workspace_path=workspace_path,
            )
        except Exception as exc:
            async with self._lock:
                entry = self.state.running.get(issue_id)
                if entry is not None:
                    entry.summary_pending = False
                    entry.summary_revision = max(entry.summary_revision, activity_revision)
                    entry.summary_error = truncate(str(exc), 500)
                    entry.summary_updated_at = now_utc()
                    entry.summary_source = "llm"
                    entry.last_summary_monotonic = time.monotonic()
            log_event(LOGGER, logging.WARNING, "dashboard_summary_failed", issue_id=issue_id, reason=exc)
            return
        async with self._lock:
            entry = self.state.running.get(issue_id)
            if entry is None:
                return
            self._apply_summary_locked(entry, summary, activity_revision)

    def _apply_summary_locked(self, entry: RunningEntry, summary: DashboardSummary, activity_revision: int) -> None:
        entry.summary_pending = False
        entry.summary_revision = max(entry.summary_revision, activity_revision)
        entry.summary_text = summary.summary
        entry.summary_current_step = summary.current_step
        entry.summary_needs_human = summary.needs_human
        entry.summary_human_reason = summary.human_reason
        entry.summary_risk = summary.risk
        entry.summary_confidence = summary.confidence
        entry.summary_updated_at = now_utc()
        entry.summary_error = None
        entry.summary_source = "llm"
        entry.last_summary_monotonic = time.monotonic()

    def _apply_usage_locked(self, entry: RunningEntry, usage: dict[str, Any]) -> None:
        input_tokens = _to_int(usage.get("input_tokens"))
        output_tokens = _to_int(usage.get("output_tokens"))
        total_tokens = _to_int(usage.get("total_tokens"))
        if input_tokens is not None:
            delta = max(input_tokens - entry.last_reported_input_tokens, 0)
            self.state.codex_totals.input_tokens += delta
            entry.last_reported_input_tokens = max(entry.last_reported_input_tokens, input_tokens)
            entry.codex_input_tokens = input_tokens
        if output_tokens is not None:
            delta = max(output_tokens - entry.last_reported_output_tokens, 0)
            self.state.codex_totals.output_tokens += delta
            entry.last_reported_output_tokens = max(entry.last_reported_output_tokens, output_tokens)
            entry.codex_output_tokens = output_tokens
        if total_tokens is not None:
            delta = max(total_tokens - entry.last_reported_total_tokens, 0)
            self.state.codex_totals.total_tokens += delta
            entry.last_reported_total_tokens = max(entry.last_reported_total_tokens, total_tokens)
            entry.codex_total_tokens = total_tokens

    def _state_path(self) -> Path:
        _, config = self.config_manager.current()
        return config.workspace.root.resolve(strict=False) / STATE_FILE_NAME

    def _load_persisted_state(self) -> None:
        path = self._state_path()
        if not path.exists():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            log_event(LOGGER, logging.WARNING, "state_load_failed", state_path=path, reason=exc)
            return
        if not isinstance(payload, dict):
            return
        self.state.codex_totals = _codex_totals_from_dict(payload.get("codex_totals"))
        self.state.codex_rate_limits = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else None
        service = payload.get("service") if isinstance(payload.get("service"), dict) else {}
        self.state.last_poll_completed_at = parse_datetime(service.get("last_poll_completed_at"))
        self.state.last_poll_error = str(service["last_poll_error"]) if service.get("last_poll_error") is not None else None
        self.state.last_candidate_count = _to_int(service.get("last_candidate_count"))
        self.state.completed = {
            entry.issue.id: entry
            for raw in payload.get("completed") or []
            if isinstance(raw, dict) and (entry := _completed_entry_from_dict(raw)) is not None
        }
        self.state.blocked = {
            entry.issue.id: entry
            for raw in payload.get("blocked") or []
            if isinstance(raw, dict) and (entry := _blocked_entry_from_dict(raw)) is not None
        }
        self.state.retry_attempts = {
            entry.issue_id: entry
            for raw in payload.get("retry_attempts") or []
            if isinstance(raw, dict) and (entry := _retry_entry_from_dict(raw)) is not None
        }
        self.state.claimed = set(self.state.blocked) | set(self.state.retry_attempts)
        log_event(
            LOGGER,
            logging.INFO,
            "state_loaded",
            state_path=path,
            completed=len(self.state.completed),
            blocked=len(self.state.blocked),
            retry_attempts=len(self.state.retry_attempts),
            total_tokens=self.state.codex_totals.total_tokens,
        )

    def _restore_retry_timers_locked(self) -> None:
        now = now_utc()
        for retry in self.state.retry_attempts.values():
            if retry.timer_handle is not None and not retry.timer_handle.done():
                continue
            delay_seconds = max((retry.due_at_wall - now).total_seconds(), 0)
            retry.due_at_monotonic = time.monotonic() + delay_seconds
            retry.timer_handle = asyncio.create_task(self._retry_after(retry.issue_id, int(delay_seconds * 1000)))

    def _persist_state_locked(self) -> None:
        path = self._state_path()
        payload = {
            "version": 1,
            "updated_at": isoformat_z(now_utc()),
            "service": {
                "last_poll_completed_at": isoformat_z(self.state.last_poll_completed_at),
                "last_poll_error": self.state.last_poll_error,
                "last_candidate_count": self.state.last_candidate_count,
            },
            "codex_totals": self.state.codex_totals.to_dict(),
            "rate_limits": self.state.codex_rate_limits,
            "completed": [
                _completed_entry_to_dict(entry)
                for entry in sorted(self.state.completed.values(), key=lambda item: item.completed_at, reverse=True)
            ],
            "blocked": [
                _blocked_entry_to_dict(entry)
                for entry in sorted(self.state.blocked.values(), key=lambda item: item.blocked_at, reverse=True)
            ],
            "retry_attempts": [
                _retry_entry_to_dict(entry)
                for entry in sorted(self.state.retry_attempts.values(), key=lambda item: item.due_at_wall)
            ],
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = path.with_name(f"{path.name}.tmp")
            tmp_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
            tmp_path.replace(path)
        except OSError as exc:
            log_event(LOGGER, logging.WARNING, "state_persist_failed", state_path=path, reason=exc)

    def sort_for_dispatch(self, issues: list[Issue]) -> list[Issue]:
        return sorted(
            issues,
            key=lambda issue: (
                issue.priority if issue.priority is not None else 999999,
                issue.created_at or now_utc(),
                issue.identifier,
            ),
        )

    def available_global_slots_locked(self, config: ServiceConfig) -> int:
        return max(config.agent.max_concurrent_agents - len(self.state.running), 0)

    def is_dispatch_eligible_locked(
        self,
        issue: Issue,
        config: ServiceConfig,
        *,
        ignore_claimed_issue_id: str | None = None,
    ) -> bool:
        if not issue.id or not issue.identifier or not issue.title or not issue.state:
            return False
        state = normalize_state(issue.state)
        if state not in config.tracker.active_state_set or state in config.tracker.terminal_state_set:
            return False
        if not self._has_required_labels(issue, config):
            return False
        if issue.id in self.state.running:
            return False
        if issue.id in self.state.blocked:
            return False
        if issue.id in self.state.claimed and issue.id != ignore_claimed_issue_id:
            return False
        if self.available_global_slots_locked(config) <= 0:
            return False
        state_limit = config.agent.max_concurrent_agents_by_state.get(state, config.agent.max_concurrent_agents)
        state_running = sum(1 for entry in self.state.running.values() if normalize_state(entry.issue.state) == state)
        if state_running >= state_limit:
            return False
        if state == "todo":
            for blocker in issue.blocked_by:
                if normalize_state(blocker.state) not in config.tracker.terminal_state_set:
                    return False
        return True

    def _has_required_labels(self, issue: Issue, config: ServiceConfig) -> bool:
        required = config.tracker.required_label_set
        if not required:
            return True
        issue_labels = {label.lower() for label in issue.labels}
        return required.issubset(issue_labels)

    async def _cleanup_workspace(self, issue: Issue) -> None:
        _, config = self.config_manager.current()
        await WorkspaceManager(config.workspace, config.hooks).remove_for_identifier(issue.identifier)

    def _next_attempt(self, attempt: int | None) -> int:
        return 1 if attempt is None else attempt + 1

    async def snapshot(self) -> dict[str, Any]:
        generated_at = now_utc()
        async with self._lock:
            running = []
            active_runtime = 0.0
            for entry in self.state.running.values():
                active_runtime += time.monotonic() - entry.started_monotonic
                attention_override = _attention_override(entry)
                repo_deviation_reason = "; ".join(entry.repo_deviations[-3:]) if entry.repo_deviations else None
                needs_human = entry.summary_needs_human or attention_override is not None
                human_reason = entry.summary_human_reason or attention_override
                if repo_deviation_reason:
                    needs_human = True
                    human_reason = repo_deviation_reason
                risk = "high" if attention_override or repo_deviation_reason else (entry.summary_risk or "unknown")
                running.append(
                    {
                        "issue_id": entry.issue.id,
                        "issue_identifier": entry.issue.identifier,
                        "state": entry.issue.state,
                        "session_id": entry.session_id,
                        "turn_count": entry.turn_count,
                        "last_event": entry.last_codex_event,
                        "last_message": entry.last_codex_message,
                        "started_at": isoformat_z(entry.started_at),
                        "last_event_at": isoformat_z(entry.last_codex_timestamp),
                        "elapsed_seconds": max(time.monotonic() - entry.started_monotonic, 0),
                        "title": entry.issue.title,
                        "url": entry.issue.url,
                        "priority": entry.issue.priority,
                        "labels": list(entry.issue.labels),
                        "updated_at": isoformat_z(entry.issue.updated_at),
                        "workspace": {"path": str(entry.workspace_path) if entry.workspace_path else None},
                        "repo_plan": entry.repo_plan.to_dict() if entry.repo_plan else None,
                        "repo_deviations": list(entry.repo_deviations),
                        "tokens": {
                            "input_tokens": entry.codex_input_tokens,
                            "output_tokens": entry.codex_output_tokens,
                            "total_tokens": entry.codex_total_tokens,
                        },
                        "summary": {
                            "text": entry.summary_text,
                            "current_step": entry.summary_current_step,
                            "needs_human": needs_human,
                            "human_reason": human_reason,
                            "risk": risk,
                            "confidence": entry.summary_confidence,
                            "updated_at": isoformat_z(entry.summary_updated_at),
                            "pending": entry.summary_pending,
                            "stale": entry.activity_revision > entry.summary_revision,
                            "error": entry.summary_error,
                            "source": entry.summary_source,
                        },
                        "activity": list(entry.recent_activity[-12:]),
                    }
                )
            retrying = [
                {
                    "issue_id": retry.issue_id,
                    "issue_identifier": retry.identifier,
                    "kind": "continuation" if retry.error is None else "retry",
                    "status": "continuing" if retry.error is None else "retrying",
                    "attempt": retry.attempt,
                    "due_at": isoformat_z(retry.due_at_wall),
                    "due_in_seconds": max(retry.due_at_monotonic - time.monotonic(), 0),
                    "error": retry.error,
                }
                for retry in self.state.retry_attempts.values()
            ]
            continuing_count = sum(1 for retry in retrying if retry["kind"] == "continuation")
            retrying_count = len(retrying) - continuing_count
            blocked = [
                {
                    "issue_id": blocked.issue.id,
                    "issue_identifier": blocked.issue.identifier,
                    "title": blocked.issue.title,
                    "url": blocked.issue.url,
                    "state": blocked.issue.state,
                    "labels": list(blocked.issue.labels),
                    "blocked_at": isoformat_z(blocked.blocked_at),
                    "reason": blocked.reason,
                    "workspace": {"path": str(blocked.workspace_path) if blocked.workspace_path else None},
                    "repo_plan": blocked.repo_plan.to_dict() if blocked.repo_plan else None,
                }
                for blocked in self.state.blocked.values()
            ]
            completed = [
                {
                    "issue_id": completed.issue.id,
                    "issue_identifier": completed.issue.identifier,
                    "title": completed.issue.title,
                    "url": completed.issue.url,
                    "state": completed.issue.state,
                    "labels": list(completed.issue.labels),
                    "completed_at": isoformat_z(completed.completed_at),
                    "reason": completed.reason,
                    "workspace": {"path": str(completed.workspace_path) if completed.workspace_path else None},
                    "repo_plan": completed.repo_plan.to_dict() if completed.repo_plan else None,
                    "repo_deviations": list(completed.repo_deviations),
                    "duration_seconds": completed.duration_seconds,
                    "turn_count": completed.turn_count,
                    "session_id": completed.session_id,
                    "thread_id": completed.thread_id,
                    "turn_id": completed.turn_id,
                    "tokens": {
                        "input_tokens": completed.codex_input_tokens,
                        "output_tokens": completed.codex_output_tokens,
                        "total_tokens": completed.codex_total_tokens,
                    },
                    "summary": {
                        "text": completed.summary_text,
                        "current_step": completed.summary_current_step,
                        "needs_human": completed.summary_needs_human,
                        "human_reason": completed.summary_human_reason,
                        "risk": completed.summary_risk,
                        "confidence": completed.summary_confidence,
                        "updated_at": isoformat_z(completed.summary_updated_at),
                    },
                    "activity": list(completed.recent_activity[-12:]),
                }
                for completed in sorted(self.state.completed.values(), key=lambda item: item.completed_at, reverse=True)
            ]
            totals = self.state.codex_totals.to_dict()
            totals["seconds_running"] += active_runtime
            return {
                "generated_at": isoformat_z(generated_at),
                "service": {
                    "status": self.state.service_status,
                    "startup_completed_at": isoformat_z(self.state.startup_completed_at),
                    "last_poll_started_at": isoformat_z(self.state.last_poll_started_at),
                    "last_poll_completed_at": isoformat_z(self.state.last_poll_completed_at),
                    "last_poll_error": self.state.last_poll_error,
                    "last_candidate_count": self.state.last_candidate_count,
                    "poll_interval_ms": self.state.poll_interval_ms,
                    "max_concurrent_agents": self.state.max_concurrent_agents,
                },
                "counts": {
                    "running": len(running),
                    "continuing": continuing_count,
                    "retrying": retrying_count,
                    "queued": len(retrying),
                    "blocked": len(blocked),
                    "completed": len(completed),
                },
                "running": running,
                "retrying": retrying,
                "blocked": blocked,
                "completed": completed,
                "codex_totals": totals,
                "rate_limits": self.state.codex_rate_limits,
            }

    async def issue_snapshot(self, issue_identifier: str) -> dict[str, Any] | None:
        state = await self.snapshot()
        for running in state["running"]:
            if running["issue_identifier"] == issue_identifier:
                return {
                    "issue_identifier": issue_identifier,
                    "issue_id": running["issue_id"],
                    "status": "running",
                    "workspace": running.get("workspace"),
                    "attempts": {"restart_count": None, "current_retry_attempt": None},
                    "running": running,
                    "retry": None,
                    "logs": {"codex_session_logs": []},
                    "recent_events": [],
                    "last_error": None,
                    "tracked": {},
                }
        for retry in state["retrying"]:
            if retry["issue_identifier"] == issue_identifier:
                return {
                    "issue_identifier": issue_identifier,
                    "issue_id": retry["issue_id"],
                    "status": retry.get("status") or "retrying",
                    "workspace": {"path": None},
                    "attempts": {"restart_count": None, "current_retry_attempt": retry["attempt"]},
                    "running": None,
                    "retry": retry,
                    "logs": {"codex_session_logs": []},
                    "recent_events": [],
                    "last_error": retry.get("error"),
                    "tracked": {},
                }
        for blocked in state.get("blocked", []):
            if blocked["issue_identifier"] == issue_identifier:
                return {
                    "issue_identifier": issue_identifier,
                    "issue_id": blocked["issue_id"],
                    "status": "blocked",
                    "workspace": blocked.get("workspace"),
                    "attempts": {"restart_count": None, "current_retry_attempt": None},
                    "running": None,
                    "retry": None,
                    "blocked": blocked,
                    "logs": {"codex_session_logs": []},
                    "recent_events": [],
                    "last_error": blocked.get("reason"),
                    "tracked": {},
                }
        for completed in state.get("completed", []):
            if completed["issue_identifier"] == issue_identifier:
                return {
                    "issue_identifier": issue_identifier,
                    "issue_id": completed["issue_id"],
                    "status": "completed",
                    "workspace": completed.get("workspace"),
                    "attempts": {"restart_count": None, "current_retry_attempt": None},
                    "running": None,
                    "retry": None,
                    "completed": completed,
                    "logs": {"codex_session_logs": []},
                    "recent_events": completed.get("activity", []),
                    "last_error": None,
                    "tracked": {},
                }
        return None


def _dedupe_by_id(issues: list[Issue]) -> list[Issue]:
    seen: set[str] = set()
    deduped: list[Issue] = []
    for issue in issues:
        if issue.id in seen:
            continue
        seen.add(issue.id)
        deduped.append(issue)
    return deduped


def _completed_entry_from_running(entry: RunningEntry, *, reason: str, elapsed: float) -> CompletedEntry:
    return CompletedEntry(
        issue=entry.issue,
        completed_at=now_utc(),
        reason=reason,
        workspace_path=entry.workspace_path,
        repo_plan=entry.repo_plan,
        duration_seconds=max(elapsed, 0),
        turn_count=entry.turn_count,
        session_id=entry.session_id,
        thread_id=entry.thread_id,
        turn_id=entry.turn_id,
        codex_input_tokens=entry.codex_input_tokens,
        codex_output_tokens=entry.codex_output_tokens,
        codex_total_tokens=entry.codex_total_tokens,
        summary_text=entry.summary_text,
        summary_current_step=entry.summary_current_step,
        summary_needs_human=entry.summary_needs_human,
        summary_human_reason=entry.summary_human_reason,
        summary_risk=entry.summary_risk,
        summary_confidence=entry.summary_confidence,
        summary_updated_at=entry.summary_updated_at,
        repo_deviations=list(entry.repo_deviations),
        recent_activity=list(entry.recent_activity[-100:]),
    )


def _codex_totals_from_dict(value: Any) -> CodexTotals:
    if not isinstance(value, dict):
        return CodexTotals()
    return CodexTotals(
        input_tokens=_to_int(value.get("input_tokens")) or 0,
        output_tokens=_to_int(value.get("output_tokens")) or 0,
        total_tokens=_to_int(value.get("total_tokens")) or 0,
        seconds_running=float(value.get("seconds_running") or 0),
    )


def _retry_entry_to_dict(entry: RetryEntry) -> dict[str, Any]:
    return {
        "issue_id": entry.issue_id,
        "issue_identifier": entry.identifier,
        "attempt": entry.attempt,
        "due_at": isoformat_z(entry.due_at_wall),
        "error": entry.error,
    }


def _retry_entry_from_dict(value: dict[str, Any]) -> RetryEntry | None:
    issue_id = str(value.get("issue_id") or "").strip()
    identifier = str(value.get("issue_identifier") or value.get("identifier") or "").strip()
    due_at_wall = parse_datetime(value.get("due_at") or value.get("due_at_wall"))
    if not issue_id or not identifier or due_at_wall is None:
        return None
    delay_seconds = max((due_at_wall - now_utc()).total_seconds(), 0)
    return RetryEntry(
        issue_id=issue_id,
        identifier=identifier,
        attempt=_to_int(value.get("attempt")) or 1,
        due_at_monotonic=time.monotonic() + delay_seconds,
        due_at_wall=due_at_wall,
        error=str(value["error"]) if value.get("error") is not None else None,
        timer_handle=None,
    )


def _blocked_entry_to_dict(entry: BlockedEntry) -> dict[str, Any]:
    return {
        "issue": entry.issue.to_template_data(),
        "reason": entry.reason,
        "blocked_at": isoformat_z(entry.blocked_at),
        "workspace_path": str(entry.workspace_path) if entry.workspace_path else None,
        "repo_plan": entry.repo_plan.to_dict() if entry.repo_plan else None,
    }


def _blocked_entry_from_dict(value: dict[str, Any]) -> BlockedEntry | None:
    issue = _issue_from_dict(value.get("issue"))
    blocked_at = parse_datetime(value.get("blocked_at"))
    if issue is None or blocked_at is None:
        return None
    repo_plan_raw = value.get("repo_plan")
    return BlockedEntry(
        issue=issue,
        reason=str(value.get("reason") or ""),
        blocked_at=blocked_at,
        workspace_path=Path(str(value["workspace_path"])) if value.get("workspace_path") else None,
        repo_plan=_repo_plan_from_dict(repo_plan_raw) if isinstance(repo_plan_raw, dict) else None,
    )


def _completed_entry_to_dict(entry: CompletedEntry) -> dict[str, Any]:
    return {
        "issue": entry.issue.to_template_data(),
        "completed_at": isoformat_z(entry.completed_at),
        "reason": entry.reason,
        "workspace_path": str(entry.workspace_path) if entry.workspace_path else None,
        "repo_plan": entry.repo_plan.to_dict() if entry.repo_plan else None,
        "duration_seconds": entry.duration_seconds,
        "turn_count": entry.turn_count,
        "session_id": entry.session_id,
        "thread_id": entry.thread_id,
        "turn_id": entry.turn_id,
        "tokens": {
            "input_tokens": entry.codex_input_tokens,
            "output_tokens": entry.codex_output_tokens,
            "total_tokens": entry.codex_total_tokens,
        },
        "summary": {
            "text": entry.summary_text,
            "current_step": entry.summary_current_step,
            "needs_human": entry.summary_needs_human,
            "human_reason": entry.summary_human_reason,
            "risk": entry.summary_risk,
            "confidence": entry.summary_confidence,
            "updated_at": isoformat_z(entry.summary_updated_at),
        },
        "repo_deviations": list(entry.repo_deviations),
        "recent_activity": list(entry.recent_activity[-100:]),
    }


def _completed_entry_from_dict(value: dict[str, Any]) -> CompletedEntry | None:
    issue = _issue_from_dict(value.get("issue"))
    completed_at = parse_datetime(value.get("completed_at"))
    if issue is None or completed_at is None:
        return None
    tokens = value.get("tokens") if isinstance(value.get("tokens"), dict) else {}
    summary = value.get("summary") if isinstance(value.get("summary"), dict) else {}
    repo_plan_raw = value.get("repo_plan")
    activity = value.get("recent_activity") if isinstance(value.get("recent_activity"), list) else []
    repo_deviations = value.get("repo_deviations") if isinstance(value.get("repo_deviations"), list) else []
    return CompletedEntry(
        issue=issue,
        completed_at=completed_at,
        reason=str(value.get("reason") or ""),
        workspace_path=Path(str(value["workspace_path"])) if value.get("workspace_path") else None,
        repo_plan=_repo_plan_from_dict(repo_plan_raw) if isinstance(repo_plan_raw, dict) else None,
        duration_seconds=float(value.get("duration_seconds") or 0),
        turn_count=_to_int(value.get("turn_count")) or 0,
        session_id=str(value["session_id"]) if value.get("session_id") is not None else None,
        thread_id=str(value["thread_id"]) if value.get("thread_id") is not None else None,
        turn_id=str(value["turn_id"]) if value.get("turn_id") is not None else None,
        codex_input_tokens=_to_int(tokens.get("input_tokens")) or 0,
        codex_output_tokens=_to_int(tokens.get("output_tokens")) or 0,
        codex_total_tokens=_to_int(tokens.get("total_tokens")) or 0,
        summary_text=str(summary["text"]) if summary.get("text") is not None else None,
        summary_current_step=str(summary["current_step"]) if summary.get("current_step") is not None else None,
        summary_needs_human=bool(summary.get("needs_human")),
        summary_human_reason=str(summary["human_reason"]) if summary.get("human_reason") is not None else None,
        summary_risk=str(summary["risk"]) if summary.get("risk") is not None else None,
        summary_confidence=_float_or_none(summary.get("confidence")),
        summary_updated_at=parse_datetime(summary.get("updated_at")),
        repo_deviations=[str(item) for item in repo_deviations],
        recent_activity=[item for item in activity if isinstance(item, dict)],
    )


def _issue_from_dict(value: Any) -> Issue | None:
    if not isinstance(value, dict):
        return None
    issue_id = str(value.get("id") or "").strip()
    identifier = str(value.get("identifier") or "").strip()
    title = str(value.get("title") or "").strip()
    if not issue_id or not identifier:
        return None
    blockers = []
    for raw in value.get("blocked_by") or []:
        if isinstance(raw, dict):
            blockers.append(
                BlockerRef(
                    id=str(raw["id"]) if raw.get("id") is not None else None,
                    identifier=str(raw["identifier"]) if raw.get("identifier") is not None else None,
                    state=str(raw["state"]) if raw.get("state") is not None else None,
                )
            )
    attachments = []
    for raw in value.get("attachments") or []:
        if isinstance(raw, dict):
            attachments.append(
                IssueAttachment(
                    id=str(raw["id"]) if raw.get("id") is not None else None,
                    title=str(raw["title"]) if raw.get("title") is not None else None,
                    subtitle=str(raw["subtitle"]) if raw.get("subtitle") is not None else None,
                    url=str(raw["url"]) if raw.get("url") is not None else None,
                )
            )
    return Issue(
        id=issue_id,
        identifier=identifier,
        title=title,
        description=str(value["description"]) if value.get("description") is not None else None,
        priority=_to_int(value.get("priority")),
        state=str(value.get("state") or ""),
        branch_name=str(value["branch_name"]) if value.get("branch_name") is not None else None,
        url=str(value["url"]) if value.get("url") is not None else None,
        labels=[str(label) for label in value.get("labels") or []],
        attachments=attachments,
        blocked_by=blockers,
        created_at=parse_datetime(value.get("created_at")),
        updated_at=parse_datetime(value.get("updated_at")),
    )


def now_utc_from_monotonic_delay(delay_ms: int):
    from datetime import timedelta

    return now_utc() + timedelta(milliseconds=delay_ms)


def _to_int(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _activity_message(event: dict[str, Any]) -> str | None:
    name = str(event.get("event") or "")
    if name in {
        "thread_tokenUsage_updated",
        "account_rateLimits_updated",
        "account_rateLimitsUpdated",
        "mcpServer_startupStatus_updated",
        "thread_started",
        "thread_status_changed",
        "item_commandExecution_outputDelta",
    }:
        return None
    if name == "coding_context_classified":
        injected = event.get("coding_context_injected")
        source = event.get("classification_source")
        reason = event.get("classification_reason")
        return f"Coding context classified: injected={injected}, source={source}, reason={reason or 'none'}."
    if name == "repo_plan_created":
        plan = event.get("repo_plan") if isinstance(event.get("repo_plan"), dict) else {}
        primary = (plan.get("primary_repo") or {}).get("slug") if isinstance(plan.get("primary_repo"), dict) else None
        secondary = plan.get("secondary_repos") if isinstance(plan.get("secondary_repos"), list) else []
        read_only = plan.get("read_only_context_repos") if isinstance(plan.get("read_only_context_repos"), list) else []
        return (
            f"Repo plan created: primary={primary or 'none'}, secondary={len(secondary)}, "
            f"read_only_context={len(read_only)}, needs_human={bool(plan.get('needs_human'))}."
        )
    if name == "repo_workspace_prepared":
        primary_path = event.get("primary_repo_path")
        return f"Repo workspace prepared: primary_path={primary_path or 'none'}."
    if name == "session_started":
        return f"Started Codex turn {event.get('turn_id') or ''}."
    if name == "approval_auto_approved":
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        return f"Auto-approved Codex request: {payload.get('command') or event.get('method') or 'approval'}."
    if name == "turn_input_required":
        return "The agent requested user input."

    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    item = payload.get("item") if isinstance(payload.get("item"), dict) else {}
    item_type = item.get("type")
    if item_type in {"reasoning", "userMessage"}:
        return None
    if item_type == "agentMessage":
        text = str(item.get("text") or event.get("message") or "").strip()
        return f"Agent said: {text}" if text else None
    if item_type == "commandExecution":
        command = str(item.get("command") or "").strip()
        status = str(item.get("status") or "unknown").strip()
        return f"Command {status}: {command}" if command else f"Command status: {status}"
    if item_type == "fileChange":
        path = item.get("path") or item.get("filePath") or item.get("file")
        status = item.get("status") or "updated"
        return f"File change {status}: {path}" if path else f"File change {status}."

    message = str(event.get("message") or "").strip()
    if not message:
        return None
    if name == "item_agentMessage_delta" and (len(message) < 40 or message in {".", ",", ":", ";"}):
        return None
    if name in {"item_started", "item_completed"} and message.startswith("item_type="):
        return None
    if name == "turn_completed":
        return f"Turn completed: {message}."
    if name.startswith("turn_"):
        return f"{name}: {message}"
    if name.startswith("item_"):
        return f"{name}: {message}"
    return message


def _has_work_signal(activity: list[dict[str, Any]]) -> bool:
    for item in activity:
        message = str(item.get("message") or "")
        if message.startswith(("Agent said:", "Command ", "File change ", "The agent requested user input")):
            return True
    return False


def _attention_override(entry: RunningEntry) -> str | None:
    issue_text = f"{entry.issue.title}\n{entry.issue.description or ''}".lower()
    activity_text = "\n".join(str(item.get("message") or "") for item in entry.recent_activity[-20:]).lower()
    product_runtime_words = (
        "screen capture",
        "screenshot",
        "slides",
        "call",
        "live",
        "overlay",
        "proactive",
        "suggest",
        "answer",
        "browser extension",
        "electron",
        "integration",
    )
    infra_config_words = (
        "infrastructure/",
        "terraform",
        ".tf",
        "model-gateway",
        "gateway",
        "schemas/functions",
        "system_template.minijinja",
        "user_template.minijinja",
    )
    if any(word in issue_text for word in product_runtime_words) and any(word in activity_text for word in infra_config_words):
        return (
            "Recent activity is focused on infrastructure/gateway/config files while the issue reads like product, runtime, "
            "or integration work. Check the repo boundary before letting this continue."
        )
    if "command failed:" in activity_text:
        failed_count = activity_text.count("command failed:")
        if failed_count >= 3:
            return "Several recent commands failed; the agent may be stuck or looking in the wrong place."
    return None


def _repo_plan_from_dict(data: dict[str, Any]) -> RepoPlan:
    def item(raw: Any) -> RepoPlanItem | None:
        if not isinstance(raw, dict):
            return None
        slug = str(raw.get("slug") or "").strip()
        if not slug:
            return None
        return RepoPlanItem(
            slug=slug,
            role=str(raw.get("role") or ""),
            reason=str(raw.get("reason")) if raw.get("reason") is not None else None,
            path_name=str(raw.get("path_name")) if raw.get("path_name") is not None else None,
            edit_allowed=bool(raw.get("edit_allowed", True)),
        )

    primary = item(data.get("primary_repo"))
    return RepoPlan(
        issue_identifier=str(data.get("issue_identifier") or ""),
        coding_task=bool(data.get("coding_task")),
        planner=str(data.get("planner") or ""),
        source=str(data.get("source") or ""),
        primary_repo=primary,
        secondary_repos=[parsed for raw in data.get("secondary_repos") or [] if (parsed := item(raw)) is not None],
        read_only_context_repos=[
            parsed for raw in data.get("read_only_context_repos") or [] if (parsed := item(raw)) is not None
        ],
        confidence=_float_or_none(data.get("confidence")),
        needs_human=bool(data.get("needs_human")),
        human_reason=str(data.get("human_reason")) if data.get("human_reason") is not None else None,
        notes=str(data.get("notes")) if data.get("notes") is not None else None,
        created_at=now_utc(),
    )


def _repo_deviation_from_event(entry: RunningEntry, event: dict[str, Any]) -> str | None:
    if entry.repo_plan is None or entry.workspace_path is None:
        return None
    path = _file_change_path(event)
    if path is None:
        return None
    repo_slug = _repo_slug_for_path(entry, path)
    if repo_slug is None:
        return f"File change is outside the approved repo plan: {path}"
    if repo_slug not in entry.repo_plan.edit_allowed_slugs():
        return f"File change is in an unapproved or read-only repo ({repo_slug}): {path}"
    return None


def _file_change_path(event: dict[str, Any]) -> str | None:
    payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
    item = payload.get("item") if isinstance(payload.get("item"), dict) else {}
    if item.get("type") != "fileChange":
        return None
    raw = item.get("path") or item.get("filePath") or item.get("file")
    return str(raw) if raw else None


def _repo_slug_for_path(entry: RunningEntry, raw_path: str) -> str | None:
    workspace_path = entry.workspace_path
    if workspace_path is None or entry.repo_plan is None:
        return None
    try:
        path = Path(raw_path)
        if not path.is_absolute():
            path = workspace_path / path
        relative = path.resolve(strict=False).relative_to(workspace_path.resolve(strict=False))
    except (OSError, ValueError):
        return None
    parts = relative.parts
    if len(parts) < 2 or parts[0] != "repos":
        return None
    repo_dir = parts[1]
    for repo in entry.repo_plan.all_repos():
        if repo.path_name == repo_dir:
            return repo.slug
    return None


def _float_or_none(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None
