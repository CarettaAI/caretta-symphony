from __future__ import annotations

from .errors import TemplateError
from .models import Issue

DEFAULT_PROMPT = "You are working on an issue from Linear."


def render_prompt(template_text: str, issue: Issue, attempt: int | None = None) -> str:
    source = template_text.strip() or DEFAULT_PROMPT
    try:
        from liquid import Environment, StrictUndefined
        from liquid.exceptions import LiquidError

        env = Environment(undefined=StrictUndefined, strict_filters=True)
        template = env.from_string(source)
        rendered = template.render({"issue": issue.to_template_data(), "attempt": attempt})
    except ImportError as exc:
        raise TemplateError("template_parse_error", "python-liquid is required for prompt rendering", cause=exc) from exc
    except LiquidError as exc:
        raise TemplateError("template_render_error", str(exc), cause=exc) from exc
    except Exception as exc:
        raise TemplateError("template_render_error", str(exc), cause=exc) from exc
    return str(rendered).strip()


def _format_labels(labels: list[str]) -> str:
    return ", ".join(labels) if labels else "(none)"


def _format_description(description: str | None) -> str:
    if description and description.strip():
        return description.strip()
    return "(none)"


def continuation_prompt(issue: Issue, turn_number: int, max_turns: int) -> str:
    issue_data = issue.to_template_data()
    return (
        "Continue working on the same Linear issue in this existing Codex thread.\n\n"
        f"Continuation turn: {turn_number} of {max_turns}.\n\n"
        "Current Linear issue snapshot, authoritative for this turn:\n"
        f"Issue: {issue.identifier} - {issue.title}\n"
        f"URL: {issue.url or '(none)'}\n"
        f"State: {issue.state or '(unknown)'}\n"
        f"Priority: {issue.priority if issue.priority is not None else '(none)'}\n"
        f"Labels: {_format_labels(issue.labels)}\n"
        f"Updated at: {issue_data.get('updated_at') or '(unknown)'}\n\n"
        "Description:\n"
        f"{_format_description(issue.description)}\n\n"
        "Do not resend the original task from scratch. Inspect current progress, complete the next needed work, "
        "validate the result, and perform the workflow-defined handoff if ready. If this current snapshot differs "
        "from earlier assumptions, pause and adapt to the current Linear text before editing more code. Do not choose "
        "a repository from sibling issue workspaces; use the injected coding context, repo map, or explicit issue text."
    )
