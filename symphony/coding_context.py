from __future__ import annotations

import json
from dataclasses import dataclass
from dataclasses import replace
from pathlib import Path
from typing import Any, Awaitable, Callable

from .codex_client import CodexAppServerSession
from .config import CodexConfig, CodingContextConfig
from .models import Issue
from .utils import truncate

ClassifierEventCallback = Callable[[dict[str, Any]], Awaitable[None]]


@dataclass(frozen=True, slots=True)
class CodingClassification:
    is_coding_task: bool
    source: str
    confidence: float | None = None
    reason: str | None = None


def is_coding_issue(issue: Issue, config: CodingContextConfig) -> bool:
    return _rules_classify(issue, config)


async def classify_coding_issue(
    issue: Issue,
    config: CodingContextConfig,
    *,
    codex_config: CodexConfig | None = None,
    workspace_path: Path | None = None,
) -> CodingClassification:
    if not config.enabled:
        return CodingClassification(False, source="disabled")
    if config.classifier == "always":
        return CodingClassification(True, source="always", confidence=1.0, reason="Configured to always inject coding context.")
    if config.classifier == "rules":
        return CodingClassification(_rules_classify(issue, config), source="rules")
    if codex_config is None or workspace_path is None:
        return _fallback_classification(issue, config, "LLM classifier unavailable: missing codex config or workspace.")
    try:
        return await _classify_with_llm(issue, config, codex_config, workspace_path)
    except Exception as exc:
        return _fallback_classification(issue, config, f"LLM classifier failed: {exc}")


async def augment_prompt_with_coding_context(
    prompt: str,
    issue: Issue,
    config: CodingContextConfig,
    *,
    codex_config: CodexConfig | None = None,
    workspace_path: Path | None = None,
    classification: CodingClassification | None = None,
    on_event: ClassifierEventCallback | None = None,
) -> str:
    if classification is None:
        classification = await classify_coding_issue(issue, config, codex_config=codex_config, workspace_path=workspace_path)
    if on_event is not None:
        await on_event(
            {
                "event": "coding_context_classified",
                "coding_context_injected": classification.is_coding_task,
                "classification_source": classification.source,
                "classification_confidence": classification.confidence,
                "classification_reason": classification.reason,
            }
        )
    if not classification.is_coding_task:
        return prompt
    context = load_coding_context(config)
    if not context.strip():
        return prompt
    return (
        "<symphony_coding_context>\n"
        "This Linear issue is classified as a coding task. Read this context before choosing a repo or editing files. "
        "If this context conflicts with older assumptions, this context and the current Linear issue text win.\n\n"
        f"Classification source: {classification.source}\n"
        f"Classification reason: {classification.reason or '(none)'}\n\n"
        f"{context}\n"
        "</symphony_coding_context>\n\n"
        f"{prompt}"
    )


def _rules_classify(issue: Issue, config: CodingContextConfig) -> bool:
    issue_labels = {label.lower() for label in issue.labels}
    if config.label_trigger_set and config.label_trigger_set.intersection(issue_labels):
        return True
    haystack = f"{issue.title}\n{issue.description or ''}".lower()
    return any(keyword.lower() in haystack for keyword in config.keyword_triggers)


def _fallback_classification(issue: Issue, config: CodingContextConfig, reason: str) -> CodingClassification:
    if config.classification_fallback == "inject":
        return CodingClassification(True, source="fallback:inject", confidence=0.0, reason=reason)
    if config.classification_fallback == "skip":
        return CodingClassification(False, source="fallback:skip", confidence=0.0, reason=reason)
    return CodingClassification(_rules_classify(issue, config), source="fallback:rules", confidence=0.0, reason=reason)


async def _classify_with_llm(
    issue: Issue,
    config: CodingContextConfig,
    codex_config: CodexConfig,
    workspace_path: Path,
) -> CodingClassification:
    classifier_codex_config = replace(
        codex_config,
        model=config.classifier_model or codex_config.model,
        effort=config.classifier_effort,
        turn_timeout_ms=config.classification_timeout_ms,
        summary=None,
        personality=None,
    )

    async def ignore_classifier_event(_: dict[str, Any]) -> None:
        return None

    async with CodexAppServerSession(
        classifier_codex_config,
        workspace_path,
        tracker_config=None,
        on_event=ignore_classifier_event,
    ) as session:
        result = await session.run_turn(_classification_prompt(issue), capture_agent_text=True)
    data = _parse_classifier_json(result.agent_message_text)
    needed = data.get("coding_context_needed", data.get("is_coding_task"))
    if not isinstance(needed, bool):
        raise ValueError("classifier JSON missing boolean coding_context_needed")
    confidence = data.get("confidence")
    if isinstance(confidence, (int, float)) and not isinstance(confidence, bool):
        confidence_value = max(0.0, min(1.0, float(confidence)))
    else:
        confidence_value = None
    reason = data.get("reason")
    return CodingClassification(
        needed,
        source="llm",
        confidence=confidence_value,
        reason=truncate(str(reason), 500) if reason is not None else None,
    )


def _classification_prompt(issue: Issue) -> str:
    issue_json = json.dumps(issue.to_template_data(), sort_keys=True, default=str)
    return (
        "You are a classifier for Symphony, a background coding agent runner.\n"
        "Decide whether the current Linear issue is a coding/repository task that should receive architecture and repo-map context before the agent edits files.\n\n"
        "Return only a single JSON object, no markdown, no prose, no tool calls.\n"
        "Schema:\n"
        "{\n"
        '  "coding_context_needed": boolean,\n'
        '  "confidence": number,\n'
        '  "reason": "short reason"\n'
        "}\n\n"
        "Use true for tasks that likely require code, config, scripts, repository changes, debugging, tests, provider integration, product implementation, or repo selection.\n"
        "Use false for pure Linear/project-management actions, status checks, tagging, prioritization, or discussion with no likely repo changes.\n"
        "If ambiguous, choose true. False negatives are more harmful than extra context.\n\n"
        f"Linear issue JSON:\n{issue_json}"
    )


def _parse_classifier_json(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        raise ValueError("classifier returned empty text")
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        value = json.loads(_extract_json_object(stripped))
    if not isinstance(value, dict):
        raise ValueError("classifier JSON is not an object")
    return value


def _extract_json_object(text: str) -> str:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("classifier output did not contain a JSON object")
    return text[start : end + 1]


def load_coding_context(config: CodingContextConfig) -> str:
    chunks: list[str] = []
    remaining = config.max_chars
    for path in config.skill_paths:
        for file_path in _context_files(path):
            if remaining <= 0:
                break
            try:
                text = file_path.read_text(encoding="utf-8")
            except OSError:
                continue
            header = f"## {file_path}\n"
            chunk = header + text.strip() + "\n"
            if len(chunk) > remaining:
                chunk = chunk[:remaining].rstrip() + "\n[truncated]\n"
            chunks.append(chunk)
            remaining -= len(chunk)
    return "\n".join(chunks).strip()


def _context_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        return []
    files: list[Path] = []
    skill_file = path / "SKILL.md"
    if skill_file.is_file():
        files.append(skill_file)
    references = path / "references"
    if references.is_dir():
        files.extend(sorted(references.glob("*.md")))
    return files
