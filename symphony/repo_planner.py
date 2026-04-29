from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path
from typing import Any

from .codex_client import CodexAppServerSession
from .coding_context import CodingClassification, load_coding_context
from .config import CodexConfig, CodingContextConfig, RepositoryConfig, RepositoryPlanningConfig
from .models import Issue, RepoPlan, RepoPlanItem
from .utils import now_utc, sanitize_workspace_key, truncate


async def plan_repositories(
    issue: Issue,
    config: RepositoryPlanningConfig,
    coding_config: CodingContextConfig,
    classification: CodingClassification,
    *,
    codex_config: CodexConfig,
    workspace_path: Path,
) -> RepoPlan | None:
    if not config.enabled:
        return None
    if not classification.is_coding_task:
        return RepoPlan(
            issue_identifier=issue.identifier,
            coding_task=False,
            planner=config.planner,
            source=classification.source,
            confidence=classification.confidence,
            notes="Issue was not classified as a coding task.",
            created_at=now_utc(),
        )
    if config.planner == "llm":
        try:
            return await _plan_with_llm(issue, config, coding_config, codex_config, workspace_path)
        except Exception as exc:
            if config.fallback == "block":
                return RepoPlan(
                    issue_identifier=issue.identifier,
                    coding_task=True,
                    planner=config.planner,
                    source="fallback:block",
                    needs_human=True,
                    human_reason=f"Repository planner failed and fallback is block: {truncate(str(exc), 300)}",
                    created_at=now_utc(),
                )
    return _plan_with_rules(issue, config, source="rules" if config.planner == "rules" else "fallback:rules")


def apply_repo_plan_to_prompt(prompt: str, repo_plan: RepoPlan | None, workspace_path: Path) -> str:
    if repo_plan is None or not repo_plan.coding_task:
        return prompt
    plan_json = json.dumps(repo_plan.to_dict(), sort_keys=True, default=str, indent=2)
    git_metadata = _workspace_git_metadata(workspace_path)
    git_guardrail = (
        "Git hygiene guardrail: commit and push only the expected branch recorded for each repo in "
        "`.symphony-workspace.json`. Never push an inherited source checkout branch. If "
        "`git branch --show-current` differs from the repo's expected branch, stop and report the mismatch. "
        "The workspace-local pre-push hook rejects pushes to any other branch.\n"
    )
    if git_metadata:
        git_guardrail += f"Prepared git branches:\n{json.dumps(git_metadata, sort_keys=True, default=str, indent=2)}\n"
    return (
        "<symphony_repo_plan>\n"
        "Symphony prepared an explicit repository plan for this issue. Treat it as a guardrail, not as proof the "
        "implementation is already understood.\n\n"
        f"Workspace root: {workspace_path}\n"
        "Repositories are checked out under `repos/<path_name>` inside the workspace root.\n"
        "Start by inspecting the primary repo. You may read secondary and read-only context repos as needed. "
        "Only edit the primary repo and secondary repos whose `edit_allowed` value is true. Do not edit "
        "read-only context repos. If the current Linear issue text proves the repo plan is wrong or incomplete, "
        "stop and report that instead of patching an unapproved repo.\n\n"
        f"{git_guardrail}\n"
        f"{plan_json}\n"
        "</symphony_repo_plan>\n\n"
        f"{prompt}"
    )


def _workspace_git_metadata(workspace_path: Path) -> list[dict[str, Any]]:
    metadata_path = workspace_path / ".symphony-workspace.json"
    if not metadata_path.exists():
        return []
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    repositories = payload.get("repositories")
    if not isinstance(repositories, list):
        return []
    result: list[dict[str, Any]] = []
    for item in repositories:
        if not isinstance(item, dict):
            continue
        git = item.get("git")
        if not isinstance(git, dict):
            continue
        result.append(
            {
                "slug": item.get("slug"),
                "path": item.get("path"),
                "edit_allowed": item.get("edit_allowed"),
                "expected_branch": git.get("expected_branch"),
                "expected_ref": git.get("expected_ref"),
                "base_ref": git.get("base_ref"),
            }
        )
    return result


async def _plan_with_llm(
    issue: Issue,
    config: RepositoryPlanningConfig,
    coding_config: CodingContextConfig,
    codex_config: CodexConfig,
    workspace_path: Path,
) -> RepoPlan:
    planner_codex_config = replace(
        codex_config,
        model=config.plan_model or codex_config.model,
        effort=config.plan_effort,
        turn_timeout_ms=config.plan_timeout_ms,
        summary=None,
        personality=None,
    )

    async def ignore_event(_: dict[str, Any]) -> None:
        return None

    async with CodexAppServerSession(
        planner_codex_config,
        workspace_path,
        tracker_config=None,
        on_event=ignore_event,
    ) as session:
        result = await session.run_turn(_planner_prompt(issue, config, coding_config), capture_agent_text=True)
    data = _parse_json_object(result.agent_message_text)
    return _normalize_plan(issue, data, config, planner="llm", source="llm")


def _planner_prompt(issue: Issue, config: RepositoryPlanningConfig, coding_config: CodingContextConfig) -> str:
    payload = {
        "issue": issue.to_template_data(),
        "repositories": [repo.to_prompt_data() for repo in config.repositories],
        "coding_context": truncate(load_coding_context(coding_config), 30000) if coding_config.enabled else "",
    }
    return (
        "You are Symphony's repository planner for a background coding agent.\n"
        "Pick the repository set the agent is allowed to use for this Linear issue. Many valid tasks span multiple "
        "repos, so return a primary repo plus optional secondary/edit repos and read-only context repos. Prefer the "
        "runtime/product repo that owns the behavior as primary. Do not choose a gateway/config repo merely because "
        "the issue mentions AI, search, prompts, or suggestions if the runtime/UI/provider adapter lives elsewhere. "
        "If the issue requests a specific provider/integration, keep that provider direction in the reason.\n\n"
        "Return only one JSON object, no markdown, no prose, and no tool calls.\n"
        "Schema:\n"
        "{\n"
        '  "coding_task": true,\n'
        '  "primary_repo": {"slug": "owner/name", "reason": "why this repo is the start"},\n'
        '  "secondary_repos": [{"slug": "owner/name", "reason": "why it may need edits", "edit_allowed": true}],\n'
        '  "read_only_context_repos": [{"slug": "owner/name", "reason": "why it is useful context"}],\n'
        '  "confidence": 0.0,\n'
        '  "needs_human": false,\n'
        '  "human_reason": null,\n'
        '  "notes": "short operational note"\n'
        "}\n\n"
        "Rules:\n"
        "- Use only repository slugs listed in the input catalog.\n"
        "- If there is no clear primary repo, set needs_human=true and explain.\n"
        "- If a secondary repo might need edits, include it as secondary_repos with edit_allowed=true.\n"
        "- If a repo is only background material, include it as read_only_context_repos.\n"
        "- If the issue is not a coding/repository task, set coding_task=false and leave repo lists empty.\n\n"
        f"Planner input JSON:\n{json.dumps(payload, sort_keys=True, default=str)}"
    )


def _plan_with_rules(issue: Issue, config: RepositoryPlanningConfig, *, source: str) -> RepoPlan:
    text = f"{issue.identifier}\n{issue.title}\n{issue.description or ''}\n{' '.join(issue.labels)}".lower()
    scored: list[tuple[int, RepositoryConfig, list[str]]] = []
    for repo in config.repositories:
        reasons: list[str] = []
        score = 0
        candidates = {repo.slug.lower(), repo.path_name.lower(), *(alias.lower() for alias in repo.aliases)}
        for candidate in sorted(candidate for candidate in candidates if candidate):
            if candidate in text:
                score += 4 if candidate in {repo.slug.lower(), repo.path_name.lower()} else 2
                reasons.append(candidate)
        if repo.description:
            for word in _keyword_terms(repo.description):
                if word in text:
                    score += 1
                    reasons.append(word)
        if score > 0:
            scored.append((score, repo, reasons[:6]))
    scored.sort(key=lambda row: (-row[0], row[1].slug))
    if not scored:
        return RepoPlan(
            issue_identifier=issue.identifier,
            coding_task=True,
            planner=config.planner,
            source=source,
            needs_human=True,
            human_reason="No configured repository matched the issue text.",
            confidence=0.0,
            created_at=now_utc(),
        )
    top_score, top_repo, top_reasons = scored[0]
    tied = [repo.slug for score, repo, _ in scored if score == top_score]
    needs_human = len(tied) > 1
    primary = _item(top_repo, "primary", f"Rules matched: {', '.join(top_reasons)}")
    secondary = [
        _item(repo, "secondary", f"Rules also matched: {', '.join(reasons)}")
        for score, repo, reasons in scored[1:4]
        if score > 0
    ]
    return RepoPlan(
        issue_identifier=issue.identifier,
        coding_task=True,
        planner=config.planner,
        source=source,
        primary_repo=primary,
        secondary_repos=secondary,
        confidence=min(0.85, max(0.2, top_score / 12)),
        needs_human=needs_human,
        human_reason=f"Rules planner found tied primary repositories: {', '.join(tied)}" if needs_human else None,
        created_at=now_utc(),
    )


def _normalize_plan(
    issue: Issue,
    data: dict[str, Any],
    config: RepositoryPlanningConfig,
    *,
    planner: str,
    source: str,
) -> RepoPlan:
    known = config.repository_by_slug
    unknown: list[str] = []

    def parse_item(raw: Any, role: str) -> RepoPlanItem | None:
        if not isinstance(raw, dict):
            return None
        slug = str(raw.get("slug") or "").strip()
        if not slug:
            return None
        repo = known.get(slug)
        if repo is None:
            unknown.append(slug)
            return None
        edit_allowed = bool(raw.get("edit_allowed", role != "read_only_context")) and role != "read_only_context"
        return _item(repo, role, truncate(str(raw.get("reason") or ""), 500) or None, edit_allowed=edit_allowed)

    coding_task = bool(data.get("coding_task", data.get("is_coding_task", True)))
    primary = parse_item(data.get("primary_repo"), "primary")
    secondary = _dedupe_items(
        [
            item
            for raw in _list_value(data.get("secondary_repos"))
            if (item := parse_item(raw, "secondary")) is not None
        ]
    )
    read_only = _dedupe_items(
        [
            item
            for raw in _list_value(data.get("read_only_context_repos"))
            if (item := parse_item(raw, "read_only_context")) is not None
        ]
    )
    if primary is not None:
        secondary = [item for item in secondary if item.slug != primary.slug]
        read_only = [item for item in read_only if item.slug != primary.slug]
    confidence = _confidence(data.get("confidence"))
    needs_human = bool(data.get("needs_human"))
    human_reason = truncate(str(data.get("human_reason") or ""), 500) or None
    if coding_task and primary is None:
        needs_human = True
        human_reason = human_reason or "Repository planner did not return a primary repo."
    if unknown:
        needs_human = True
        suffix = f"Planner returned unknown repositories: {', '.join(sorted(set(unknown)))}."
        human_reason = f"{human_reason} {suffix}".strip() if human_reason else suffix
    return RepoPlan(
        issue_identifier=issue.identifier,
        coding_task=coding_task,
        planner=planner,
        source=source,
        primary_repo=primary,
        secondary_repos=secondary,
        read_only_context_repos=read_only,
        confidence=confidence,
        needs_human=needs_human,
        human_reason=human_reason,
        notes=truncate(str(data.get("notes") or ""), 500) or None,
        created_at=now_utc(),
    )


def _item(repo: RepositoryConfig, role: str, reason: str | None, *, edit_allowed: bool = True) -> RepoPlanItem:
    if role == "read_only_context":
        edit_allowed = False
    return RepoPlanItem(
        slug=repo.slug,
        role=role,
        reason=reason,
        path_name=sanitize_workspace_key(repo.path_name),
        edit_allowed=edit_allowed,
    )


def _dedupe_items(items: list[RepoPlanItem]) -> list[RepoPlanItem]:
    seen: set[str] = set()
    deduped: list[RepoPlanItem] = []
    for item in items:
        if item.slug in seen:
            continue
        seen.add(item.slug)
        deduped.append(item)
    return deduped


def _list_value(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _confidence(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return None


def _parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        raise ValueError("repo planner returned empty text")
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        value = json.loads(_extract_json_object(stripped))
    if not isinstance(value, dict):
        raise ValueError("repo planner JSON is not an object")
    return value


def _extract_json_object(text: str) -> str:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("repo planner output did not contain a JSON object")
    return text[start : end + 1]


def _keyword_terms(text: str) -> list[str]:
    stop = {"the", "and", "for", "with", "from", "that", "this", "repo", "choose", "validation", "local", "path"}
    terms: list[str] = []
    for raw in text.lower().replace("/", " ").replace("-", " ").split():
        word = "".join(ch for ch in raw if ch.isalnum())
        if len(word) >= 5 and word not in stop:
            terms.append(word)
    return terms[:40]
