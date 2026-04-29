from __future__ import annotations

import json
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .codex_client import CodexAppServerSession
from .config import CodexConfig, DashboardConfig
from .models import Issue
from .utils import truncate


@dataclass(frozen=True, slots=True)
class DashboardSummary:
    summary: str
    current_step: str
    needs_human: bool
    human_reason: str | None
    risk: str
    confidence: float | None


async def summarize_activity(
    *,
    issue: Issue,
    activity: list[dict[str, Any]],
    previous_summary: str | None,
    codex_config: CodexConfig,
    dashboard_config: DashboardConfig,
    workspace_path: Path,
) -> DashboardSummary:
    summary_config = replace(
        codex_config,
        model=dashboard_config.summary_model or codex_config.model,
        effort=dashboard_config.summary_effort,
        turn_timeout_ms=dashboard_config.summary_timeout_ms,
        summary=None,
        personality=None,
    )

    async def ignore_event(_: dict[str, Any]) -> None:
        return None

    async with CodexAppServerSession(summary_config, workspace_path, tracker_config=None, on_event=ignore_event) as session:
        result = await session.run_turn(
            _summary_prompt(
                issue=issue,
                activity=activity,
                previous_summary=previous_summary,
                max_chars=dashboard_config.summary_max_chars,
            ),
            capture_agent_text=True,
        )
    data = _parse_summary_json(result.agent_message_text)
    return DashboardSummary(
        summary=truncate(str(data.get("summary") or "No substantive activity has been summarized yet."), 800),
        current_step=truncate(str(data.get("current_step") or "Unknown."), 300),
        needs_human=bool(data.get("needs_human")),
        human_reason=truncate(str(data.get("human_reason")), 500) if data.get("human_reason") else None,
        risk=_normalize_risk(data.get("risk")),
        confidence=_normalize_confidence(data.get("confidence")),
    )


def _summary_prompt(*, issue: Issue, activity: list[dict[str, Any]], previous_summary: str | None, max_chars: int) -> str:
    payload = {
        "issue": issue.to_template_data(),
        "previous_summary": previous_summary,
        "recent_activity": activity,
    }
    payload_json = truncate(json.dumps(payload, sort_keys=True, default=str), max_chars)
    return (
        "You summarize a running background coding agent for a human dashboard.\n"
        "Use only the visible activity events. Do not claim completion unless the events show it. "
        "Flag human attention if the agent appears blocked, confused, repeatedly failing, using the wrong repo, "
        "waiting for credentials/decisions, asking for input, or operating with high uncertainty. "
        "Also flag human attention if the issue reads like product/runtime/UI work but the activity shows the agent "
        "working mostly in unrelated infrastructure, gateway, prompt/config, or deployment files.\n\n"
        "Return only one JSON object, no markdown and no prose.\n"
        "Schema:\n"
        "{\n"
        '  "summary": "1-2 sentence present-tense summary of what the agent is doing",\n'
        '  "current_step": "short phrase for the current/next step",\n'
        '  "needs_human": boolean,\n'
        '  "human_reason": "why a human should step in, or null",\n'
        '  "risk": "low|medium|high|unknown",\n'
        '  "confidence": number\n'
        "}\n\n"
        f"Dashboard input JSON:\n{payload_json}"
    )


def _parse_summary_json(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        raise ValueError("summary model returned empty text")
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        value = json.loads(_extract_json_object(stripped))
    if not isinstance(value, dict):
        raise ValueError("summary JSON is not an object")
    return value


def _extract_json_object(text: str) -> str:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("summary output did not contain a JSON object")
    return text[start : end + 1]


def _normalize_risk(value: Any) -> str:
    risk = str(value or "unknown").strip().lower()
    return risk if risk in {"low", "medium", "high", "unknown"} else "unknown"


def _normalize_confidence(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return None
