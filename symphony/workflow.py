from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from .errors import WorkflowError
from .models import WorkflowDefinition


def default_workflow_path(cwd: Path | None = None) -> Path:
    return (cwd or Path.cwd()) / "WORKFLOW.md"


def resolve_workflow_path(path: str | Path | None, cwd: Path | None = None) -> Path:
    selected = Path(path) if path is not None else default_workflow_path(cwd)
    return selected.expanduser().resolve(strict=False)


def load_workflow(path: str | Path | None = None, cwd: Path | None = None) -> WorkflowDefinition:
    workflow_path = resolve_workflow_path(path, cwd)
    try:
        raw = workflow_path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise WorkflowError("missing_workflow_file", f"workflow file not found: {workflow_path}", cause=exc) from exc
    except OSError as exc:
        raise WorkflowError("missing_workflow_file", f"workflow file cannot be read: {workflow_path}", cause=exc) from exc

    config: dict[str, Any]
    body: str
    if raw.startswith("---"):
        lines = raw.splitlines()
        closing_index: int | None = None
        for index, line in enumerate(lines[1:], start=1):
            if line.strip() == "---":
                closing_index = index
                break
        if closing_index is None:
            raise WorkflowError("workflow_parse_error", "YAML front matter is missing closing ---")
        front_matter = "\n".join(lines[1:closing_index])
        body = "\n".join(lines[closing_index + 1 :])
        try:
            parsed = yaml.safe_load(front_matter) if front_matter.strip() else {}
        except yaml.YAMLError as exc:
            raise WorkflowError("workflow_parse_error", f"invalid YAML front matter: {exc}", cause=exc) from exc
        if parsed is None:
            config = {}
        elif isinstance(parsed, dict):
            config = parsed
        else:
            raise WorkflowError("workflow_front_matter_not_a_map", "YAML front matter must decode to a map/object")
    else:
        config = {}
        body = raw

    try:
        mtime_ns = workflow_path.stat().st_mtime_ns
    except OSError:
        mtime_ns = None

    return WorkflowDefinition(config=config, prompt_template=body.strip(), path=workflow_path, mtime_ns=mtime_ns)
