from __future__ import annotations

import os
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

_WORKSPACE_KEY_RE = re.compile(r"[^A-Za-z0-9._-]")
_SECRET_FIELD_RE = re.compile(r"(api[_-]?key|token|secret|authorization)", re.IGNORECASE)
JSONL_READ_LIMIT_BYTES = 10 * 1024 * 1024 + 1
NON_INTERACTIVE_TOOL_INPUT_ANSWER = "This is a non-interactive session. Operator input is unavailable."


def now_utc() -> datetime:
    return datetime.now(UTC)


def isoformat_z(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def parse_datetime(value: Any) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def normalize_state(value: str | None) -> str:
    return (value or "").strip().lower()


def sanitize_workspace_key(identifier: str) -> str:
    sanitized = _WORKSPACE_KEY_RE.sub("_", identifier)
    return sanitized or "_"


def resolve_under_root(root: Path, child_name: str) -> Path:
    root_abs = root.expanduser().resolve(strict=False)
    child = (root_abs / child_name).resolve(strict=False)
    if os.path.commonpath([str(root_abs), str(child)]) != str(root_abs):
        raise ValueError(f"path escapes workspace root: {child}")
    return child


def truncate(value: str | None, limit: int = 4000) -> str:
    if not value:
        return ""
    if len(value) <= limit:
        return value
    return f"{value[:limit]}...<truncated>"


def redact_field(key: str, value: Any) -> Any:
    if _SECRET_FIELD_RE.search(key):
        return "<redacted>"
    return value


def key_value_message(event: str, **fields: Any) -> str:
    parts = [f"event={event}"]
    for key, value in fields.items():
        safe = redact_field(key, value)
        if isinstance(safe, datetime):
            safe = isoformat_z(safe)
        if safe is None:
            safe = "null"
        text = str(safe).replace("\n", "\\n")
        if " " in text:
            text = repr(text)
        parts.append(f"{key}={text}")
    return " ".join(parts)


def tool_request_user_input_approval_answers(params: dict[str, Any]) -> dict[str, Any] | None:
    questions = params.get("questions")
    if not isinstance(questions, list):
        return None
    answers: dict[str, Any] = {}
    for question in questions:
        if not isinstance(question, dict):
            return None
        question_id = question.get("id")
        if not isinstance(question_id, str) or not question_id:
            return None
        answer_label = _approval_option_label(question.get("options"))
        if not answer_label:
            return None
        answers[question_id] = {"answers": [answer_label]}
    return answers or None


def tool_request_user_input_unavailable_answers(params: dict[str, Any]) -> dict[str, Any] | None:
    questions = params.get("questions")
    if not isinstance(questions, list):
        return None
    answers: dict[str, Any] = {}
    for question in questions:
        if not isinstance(question, dict):
            return None
        question_id = question.get("id")
        if not isinstance(question_id, str) or not question_id:
            return None
        answers[question_id] = {"answers": [NON_INTERACTIVE_TOOL_INPUT_ANSWER]}
    return answers or None


def _approval_option_label(options: Any) -> str | None:
    if not isinstance(options, list):
        return None
    labels = [option.get("label") for option in options if isinstance(option, dict) and isinstance(option.get("label"), str)]
    for preferred in ("Approve this Session", "Approve Once"):
        if preferred in labels:
            return preferred
    for label in labels:
        normalized = label.strip().lower()
        if normalized.startswith("approve") or normalized.startswith("allow"):
            return label
    return None
