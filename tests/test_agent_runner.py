from __future__ import annotations

from symphony.agent_runner import _agent_reported_linear_delivery_blocker, _existing_workpad_comment_id


def test_agent_reported_linear_delivery_blocker_requires_completion_signal() -> None:
    assert _agent_reported_linear_delivery_blocker(
        "Completed: implementation is committed and pushed. Validation passed. "
        "Blocker: Linear MCP calls were rejected for the workpad and state transition."
    )
    assert not _agent_reported_linear_delivery_blocker("Linear rejected the initial read; continuing repo inspection.")


def test_existing_workpad_comment_id_finds_codex_workpad() -> None:
    assert (
        _existing_workpad_comment_id(
            [
                {"id": "comment-1", "body": "ordinary note"},
                {"id": "comment-2", "body": "## Codex Workpad\nstatus"},
            ]
        )
        == "comment-2"
    )
