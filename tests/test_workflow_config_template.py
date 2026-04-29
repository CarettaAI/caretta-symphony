from __future__ import annotations

import os
from pathlib import Path

import pytest

from symphony.coding_context import augment_prompt_with_coding_context
from symphony.config import ConfigManager, resolve_config, validate_dispatch_config
from symphony.errors import TemplateError, WorkflowError
from symphony.models import Issue
from symphony.templating import continuation_prompt, render_prompt
from symphony.workflow import load_workflow, resolve_workflow_path


def test_workflow_front_matter_config_and_prompt(tmp_path: Path) -> None:
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        """---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
  required_labels: ["Codex"]
workspace:
  root: ./work
agent:
  max_concurrent_agents_by_state:
    Todo: 1
    Bad: 0
codex:
  command: codex app-server --listen stdio://
---
Work on {{ issue.identifier }} attempt={{ attempt }}.
""",
        encoding="utf-8",
    )

    workflow = load_workflow(workflow_path)
    config = resolve_config(workflow, {"LINEAR_API_KEY": "lin-key"})

    assert workflow.config["tracker"]["kind"] == "linear"
    assert workflow.prompt_template == "Work on {{ issue.identifier }} attempt={{ attempt }}."
    assert config.tracker.api_key == "lin-key"
    assert config.tracker.required_label_set == {"codex"}
    assert config.tracker.handoff_state == "In Review"
    assert config.tracker.done_state == "Done"
    assert config.tracker.merge_base_branch == "dev"
    assert config.tracker.review_states == ["In Review", "Merging"]
    assert config.workspace.root == tmp_path / "work"
    assert config.agent.max_concurrent_agents_by_state == {"todo": 1}
    assert config.codex.command == "codex app-server --listen stdio://"

    rendered = render_prompt(workflow.prompt_template, Issue(id="1", identifier="ABC-1", title="Title", state="Todo"), 2)
    assert rendered == "Work on ABC-1 attempt=2."


def test_missing_and_non_map_workflow_errors(tmp_path: Path) -> None:
    with pytest.raises(WorkflowError) as missing:
        load_workflow(tmp_path / "WORKFLOW.md")
    assert missing.value.code == "missing_workflow_file"

    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text("---\n- nope\n---\nbody\n", encoding="utf-8")
    with pytest.raises(WorkflowError) as non_map:
        load_workflow(workflow_path)
    assert non_map.value.code == "workflow_front_matter_not_a_map"


def test_strict_template_unknown_variable_fails() -> None:
    with pytest.raises(TemplateError):
        render_prompt("{{ issue.identifier }} {{ missing.value }}", Issue(id="1", identifier="ABC-1", title="Title", state="Todo"))


def test_config_manager_invalid_reload_blocks_dispatch(tmp_path: Path) -> None:
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        """---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
---
body
""",
        encoding="utf-8",
    )
    manager = ConfigManager(workflow_path, environ={"LINEAR_API_KEY": "key"})
    manager.load_startup()

    workflow_path.write_text("---\ntracker: []\n---\nbody\n", encoding="utf-8")
    assert manager.reload_if_changed() is False
    with pytest.raises(Exception):
        manager.validate_for_dispatch()


def test_default_workflow_path_uses_cwd(tmp_path: Path) -> None:
    assert resolve_workflow_path(None, cwd=tmp_path) == tmp_path / "WORKFLOW.md"


@pytest.mark.asyncio
async def test_coding_context_config_and_prompt_augmentation(tmp_path: Path) -> None:
    skill_dir = tmp_path / "platform-architecture"
    references_dir = skill_dir / "references"
    references_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text("---\nname: platform-architecture\n---\nRead the repo map.\n", encoding="utf-8")
    (references_dir / "repo-map.md").write_text("Use desktop-runtime for live workflow provider work.\n", encoding="utf-8")

    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        f"""---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
context:
  coding:
    enabled: true
    skill_paths:
      - {skill_dir}
    label_triggers: ["codex"]
    keyword_triggers: ["provider"]
    max_chars: 5000
dashboard:
  summaries:
    enabled: true
    update_interval_ms: 30000
repositories:
  enabled: true
  planner: llm
  fallback: rules
  block_on_needs_human: true
  known:
    - slug: ExampleOrg/desktop-runtime
      local_path: {tmp_path}
      remote_url: https://github.com/ExampleOrg/desktop-runtime.git
      aliases: ["desktop-runtime", "desktop"]
      description: Desktop app runtime
---
Work on {{ issue.identifier }}.
""",
        encoding="utf-8",
    )

    config = resolve_config(load_workflow(workflow_path), {"LINEAR_API_KEY": "lin-key"})
    validate_dispatch_config(config)

    issue = Issue(id="1", identifier="ENG-1", title="Use Linkup provider", state="Todo", labels=["codex"])
    augmented = await augment_prompt_with_coding_context("Original prompt", issue, config.context.coding)

    assert config.context.coding.enabled is True
    assert config.context.coding.classifier == "rules"
    assert config.context.coding.skill_paths == [skill_dir]
    assert config.dashboard.summaries_enabled is True
    assert config.dashboard.summary_update_interval_ms == 30000
    assert config.repositories.enabled is True
    assert config.repositories.planner == "llm"
    assert config.repositories.repositories[0].slug == "ExampleOrg/desktop-runtime"
    assert "<symphony_coding_context>" in augmented
    assert "Use desktop-runtime for live workflow provider work." in augmented
    assert augmented.endswith("Original prompt")


@pytest.mark.asyncio
async def test_coding_context_ignores_non_coding_issue(tmp_path: Path) -> None:
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        """---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
context:
  coding:
    enabled: true
    skill_paths:
      - ./skill.md
    label_triggers: ["codex"]
---
body
""",
        encoding="utf-8",
    )
    (tmp_path / "skill.md").write_text("context", encoding="utf-8")
    config = resolve_config(load_workflow(workflow_path), {"LINEAR_API_KEY": "lin-key"})

    issue = Issue(id="1", identifier="ENG-1", title="Triage only", state="Todo", labels=[])
    assert await augment_prompt_with_coding_context("Original prompt", issue, config.context.coding) == "Original prompt"


@pytest.mark.asyncio
async def test_llm_coding_context_classifier_controls_prompt_augmentation(tmp_path: Path) -> None:
    fake_server = tmp_path / "fake_classifier_server.py"
    fake_server.write_text(
        r'''
import json
import sys

thread_id = "thr_classifier"
turn_id = "turn_classifier"

for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {}}), flush=True)
    elif method == "initialized":
        pass
    elif method == "thread/start":
        print(json.dumps({"id": msg["id"], "result": {"thread": {"id": thread_id}}}), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": msg["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "delta": "{\"coding_context_needed\": true, \"confidence\": 0.91, \"reason\": \"Requires repo changes.\"}"}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed", "items": [], "error": None}}}), flush=True)
''',
        encoding="utf-8",
    )

    skill_dir = tmp_path / "platform-architecture"
    skill_dir.mkdir()
    (skill_dir / "SKILL.md").write_text("Architecture context", encoding="utf-8")
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        f"""---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
codex:
  command: {os.environ.get('PYTHON', 'python3')} {fake_server}
context:
  coding:
    enabled: true
    classifier: llm
    classification_fallback: skip
    skill_paths:
      - {skill_dir}
---
body
""",
        encoding="utf-8",
    )

    config = resolve_config(load_workflow(workflow_path), {"LINEAR_API_KEY": "lin-key"})
    events = []

    async def on_event(event):
        events.append(event)

    issue = Issue(id="1", identifier="ENG-1", title="Ambiguous but code", state="Todo", labels=[])
    augmented = await augment_prompt_with_coding_context(
        "Original prompt",
        issue,
        config.context.coding,
        codex_config=config.codex,
        workspace_path=tmp_path,
        on_event=on_event,
    )

    assert "<symphony_coding_context>" in augmented
    assert "Classification source: llm" in augmented
    assert "Architecture context" in augmented
    assert events[0]["coding_context_injected"] is True
    assert events[0]["classification_source"] == "llm"


def test_missing_enabled_coding_context_skill_fails_validation(tmp_path: Path) -> None:
    workflow_path = tmp_path / "WORKFLOW.md"
    workflow_path.write_text(
        """---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: demo
context:
  coding:
    enabled: true
    skill_paths:
      - ./missing-skill
---
body
""",
        encoding="utf-8",
    )

    config = resolve_config(load_workflow(workflow_path), {"LINEAR_API_KEY": "lin-key"})
    with pytest.raises(Exception) as missing_skill:
        validate_dispatch_config(config)
    assert getattr(missing_skill.value, "code", None) == "missing_coding_context_skill"


def test_continuation_prompt_includes_fresh_linear_snapshot() -> None:
    issue = Issue(
        id="1",
        identifier="ENG-251",
        title="Web search provider",
        state="In Progress",
        url="https://linear.app/example/issue/ENG-251",
        labels=["codex"],
        description="Use Linkup for web search provider work.",
    )

    prompt = continuation_prompt(issue, turn_number=2, max_turns=20)

    assert "Current Linear issue snapshot" in prompt
    assert "ENG-251 - Web search provider" in prompt
    assert "Labels: codex" in prompt
    assert "Use Linkup for web search provider work." in prompt
    assert "current Linear text" in prompt
