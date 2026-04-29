from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from symphony.agent_runner import AgentRunResult
from symphony.config import ConfigManager
from symphony.models import BlockerRef, Issue, IssueAttachment, RepoPlan, RepoPlanItem, RunningEntry
from symphony.orchestrator import Orchestrator
from symphony.review import PullRequestInfo, PullRequestRef, ReviewMergeResult
from symphony.utils import now_utc


def make_manager(tmp_path: Path) -> ConfigManager:
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        f"""---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
  required_labels: ["codex"]
workspace:
  root: {tmp_path / "workspaces"}
agent:
  max_concurrent_agents: 2
  max_retry_backoff_ms: 15000
  max_concurrent_agents_by_state:
    Todo: 1
codex:
  command: fake
---
body
""",
        encoding="utf-8",
    )
    manager = ConfigManager(workflow_path, environ={"LINEAR_API_KEY": "key"})
    manager.load_startup()
    return manager


def test_sort_and_blocker_eligibility(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    _, config = orchestrator.config_manager.current()
    blocked = Issue(
        id="2",
        identifier="ABC-2",
        title="Blocked",
        priority=1,
        state="Todo",
        blocked_by=[BlockerRef(identifier="ABC-1", state="In Progress")],
    )
    unblocked = Issue(
        id="1",
        identifier="ABC-1",
        title="Ready",
        priority=2,
        state="Todo",
        labels=["codex"],
        blocked_by=[BlockerRef(identifier="ABC-0", state="Done")],
    )

    assert orchestrator.sort_for_dispatch([unblocked, blocked])[0] is blocked
    assert orchestrator.is_dispatch_eligible_locked(blocked, config) is False
    assert orchestrator.is_dispatch_eligible_locked(unblocked, config) is True


def test_required_label_gate(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    _, config = orchestrator.config_manager.current()

    missing_label = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress", labels=["backend"])
    matching = Issue(id="2", identifier="ABC-2", title="Ready", state="In Progress", labels=["Codex", "backend"])

    assert orchestrator.is_dispatch_eligible_locked(missing_label, config) is False
    assert orchestrator.is_dispatch_eligible_locked(matching, config) is True


@pytest.mark.asyncio
async def test_review_reconciliation_moves_done_only_after_all_prs_merged(tmp_path: Path) -> None:
    class FakeTracker:
        def __init__(self) -> None:
            self.saved_states: list[tuple[str, str]] = []

        async def fetch_issues_by_states(self, state_names: list[str]) -> list[Issue]:
            assert state_names == ["In Review", "Merging"]
            return [
                Issue(
                    id="ABC-1",
                    identifier="ABC-1",
                    title="Ready",
                    state="In Review",
                    labels=["codex"],
                    attachments=[IssueAttachment(url="https://github.com/ExampleOrg/app/pull/1")],
                )
            ]

        async def fetch_issue_states_by_ids(self, issue_ids: list[str]) -> list[Issue]:
            assert issue_ids == ["ABC-1"]
            return [
                Issue(
                    id="ABC-1",
                    identifier="ABC-1",
                    title="Ready",
                    state="In Review",
                    labels=["codex"],
                    attachments=[IssueAttachment(url="https://github.com/ExampleOrg/app/pull/1")],
                )
            ]

        async def list_issue_comments(self, issue_id: str):
            assert issue_id == "ABC-1"
            return [{"body": "## Codex Workpad\nhttps://github.com/ExampleOrg/api/pull/2"}]

        async def save_issue_state(self, issue_id: str, state: str):
            self.saved_states.append((issue_id, state))
            return {"id": issue_id, "state": state}

    class FakeResolver:
        async def evaluate(self, issue, *, comments, workspace_path, base_branch):
            assert issue.identifier == "ABC-1"
            assert base_branch == "dev"
            assert comments
            return ReviewMergeResult(
                ready=True,
                required_prs=[
                    PullRequestInfo(
                        ref=PullRequestRef(owner="ExampleOrg", repo="app", number=1),
                        url="https://github.com/ExampleOrg/app/pull/1",
                        state="MERGED",
                        base_ref_name="dev",
                    ),
                    PullRequestInfo(
                        ref=PullRequestRef(owner="ExampleOrg", repo="api", number=2),
                        url="https://github.com/ExampleOrg/api/pull/2",
                        state="MERGED",
                        base_ref_name="dev",
                    ),
                ],
            )

    tracker = FakeTracker()
    orchestrator = Orchestrator(make_manager(tmp_path), review_resolver=FakeResolver())
    _, config = orchestrator.config_manager.current()

    await orchestrator.reconcile_review_issues(tracker, config)

    assert tracker.saved_states == [("ABC-1", "Done")]


@pytest.mark.asyncio
async def test_retry_backoff_is_capped(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress")

    await orchestrator.schedule_retry(issue, 3, error="boom")
    retry = orchestrator.state.retry_attempts["1"]
    assert retry.attempt == 3
    assert retry.error == "boom"
    assert 0 < retry.due_at_monotonic - asyncio.get_running_loop().time() < 20
    assert retry.timer_handle is not None
    state = await orchestrator.snapshot()
    assert state["retrying"][0]["kind"] == "retry"
    assert state["counts"]["retrying"] == 1
    assert state["counts"]["continuing"] == 0
    retry.timer_handle.cancel()


@pytest.mark.asyncio
async def test_normal_worker_completion_schedules_continuation(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress", labels=["codex"])

    async def _completed_result():
        return AgentRunResult(issue_id=issue.id, issue_identifier=issue.identifier, normal=True, reason="issue_left_active_state")

    task = asyncio.create_task(_completed_result())
    await task
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=tmp_path,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
    )
    orchestrator.state.claimed.add(issue.id)

    await orchestrator.handle_worker_done(issue.id, task)
    _, config = orchestrator.config_manager.current()

    assert issue.id in orchestrator.state.completed
    assert issue.id in orchestrator.state.retry_attempts
    retry = orchestrator.state.retry_attempts[issue.id]
    assert retry.attempt == 1
    assert retry.error is None
    assert 0 < retry.due_at_monotonic - asyncio.get_running_loop().time() < 2
    assert orchestrator.is_dispatch_eligible_locked(issue, config, ignore_claimed_issue_id=issue.id) is True
    state = await orchestrator.snapshot()
    assert state["retrying"][0]["kind"] == "continuation"
    assert state["retrying"][0]["status"] == "continuing"
    assert state["counts"]["continuing"] == 1
    assert state["counts"]["retrying"] == 0
    assert state["counts"]["completed"] == 1
    assert state["completed"][0]["issue_identifier"] == "ABC-1"
    retry.timer_handle.cancel()


@pytest.mark.asyncio
async def test_token_usage_absolute_deltas_are_aggregated(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress")
    task = asyncio.create_task(asyncio.sleep(10))
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=None,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
    )

    await orchestrator.handle_codex_event("1", {"event": "thread_tokenUsage_updated", "usage_absolute": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}})
    await orchestrator.handle_codex_event("1", {"event": "thread_tokenUsage_updated", "usage_absolute": {"input_tokens": 12, "output_tokens": 7, "total_tokens": 19}})

    assert orchestrator.state.codex_totals.input_tokens == 12
    assert orchestrator.state.codex_totals.output_tokens == 7
    assert orchestrator.state.codex_totals.total_tokens == 19
    task.cancel()


@pytest.mark.asyncio
async def test_runtime_state_persists_across_orchestrator_restart(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress", labels=["codex"])

    async def _completed_result():
        return AgentRunResult(issue_id=issue.id, issue_identifier=issue.identifier, normal=True, reason="issue_left_active_state")

    task = asyncio.create_task(_completed_result())
    await task
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=tmp_path,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
        summary_text="Implementation complete.",
        turn_count=2,
    )
    await orchestrator.handle_codex_event(
        issue.id,
        {"event": "thread_tokenUsage_updated", "usage_absolute": {"input_tokens": 7, "output_tokens": 8, "total_tokens": 15}},
    )
    await orchestrator.handle_worker_done(issue.id, task)
    retry = orchestrator.state.retry_attempts[issue.id]
    retry.timer_handle.cancel()

    reloaded = Orchestrator(make_manager(tmp_path))
    state = await reloaded.snapshot()

    assert state["codex_totals"]["input_tokens"] == 7
    assert state["codex_totals"]["output_tokens"] == 8
    assert state["codex_totals"]["total_tokens"] == 15
    assert state["counts"]["completed"] == 1
    assert state["completed"][0]["issue_identifier"] == "ABC-1"
    assert state["completed"][0]["summary"]["text"] == "Implementation complete."
    assert state["retrying"][0]["kind"] == "continuation"


@pytest.mark.asyncio
async def test_snapshot_includes_activity_and_dashboard_summary(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Ready", state="In Progress", labels=["codex"])
    task = asyncio.create_task(asyncio.sleep(10))
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=tmp_path,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
        summary_text="The agent is inspecting the repo.",
        summary_current_step="Inspect architecture",
        summary_needs_human=True,
        summary_human_reason="Repo choice is ambiguous.",
        summary_risk="high",
        summary_confidence=0.82,
        summary_source="llm",
    )

    await orchestrator.handle_codex_event(
        "1",
        {
            "event": "item_completed",
            "payload": {"item": {"type": "commandExecution", "command": "rg provider", "status": "completed"}},
            "message": "command=rg provider status=completed",
        },
    )
    state = await orchestrator.snapshot()
    running = state["running"][0]

    assert running["title"] == "Ready"
    assert running["summary"]["text"] == "The agent is inspecting the repo."
    assert running["summary"]["needs_human"] is True
    assert running["activity"][0]["message"] == "Command completed: rg provider"
    task.cancel()


@pytest.mark.asyncio
async def test_snapshot_flags_possible_repo_boundary_mismatch(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Screen capture for live call answers", state="In Progress", labels=["codex"])
    task = asyncio.create_task(asyncio.sleep(10))
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=tmp_path,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
    )

    await orchestrator.handle_codex_event(
        "1",
        {
            "event": "item_completed",
            "payload": {
                "item": {
                    "type": "commandExecution",
                    "command": "git diff -- infrastructure/config/schemas/functions/analyze_transcript/system_template.minijinja",
                    "status": "completed",
                }
            },
            "message": "command=git diff status=completed",
        },
    )
    state = await orchestrator.snapshot()
    summary = state["running"][0]["summary"]

    assert summary["needs_human"] is True
    assert summary["risk"] == "high"
    assert "repo boundary" in summary["human_reason"]
    task.cancel()


@pytest.mark.asyncio
async def test_snapshot_flags_file_changes_outside_repo_plan(tmp_path: Path) -> None:
    orchestrator = Orchestrator(make_manager(tmp_path))
    issue = Issue(id="1", identifier="ABC-1", title="Live suggestions", state="In Progress", labels=["codex"])
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    task = asyncio.create_task(asyncio.sleep(10))
    orchestrator.state.running[issue.id] = RunningEntry(
        issue=issue,
        task=task,
        cancel_event=asyncio.Event(),
        workspace_path=workspace,
        started_at=now_utc(),
        started_monotonic=asyncio.get_running_loop().time(),
        repo_plan=RepoPlan(
            issue_identifier="ABC-1",
            coding_task=True,
            planner="llm",
            source="llm",
            primary_repo=RepoPlanItem(slug="ExampleOrg/desktop-runtime", role="primary", path_name="desktop-runtime"),
            read_only_context_repos=[
                RepoPlanItem(slug="ExampleOrg/knowledge-docs", role="read_only_context", path_name="knowledge-docs", edit_allowed=False)
            ],
        ),
    )

    await orchestrator.handle_codex_event(
        "1",
        {
            "event": "item_completed",
            "payload": {
                "item": {
                    "type": "fileChange",
                    "path": str(workspace / "repos" / "knowledge-docs" / "README.md"),
                    "status": "updated",
                }
            },
            "message": "file changed",
        },
    )
    state = await orchestrator.snapshot()
    running = state["running"][0]

    assert running["summary"]["needs_human"] is True
    assert "read-only repo" in running["summary"]["human_reason"]
    assert running["repo_deviations"]
    task.cancel()
