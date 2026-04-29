from __future__ import annotations

import logging
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .errors import ConfigError, WorkflowError
from .logging import log_event
from .models import WorkflowDefinition
from .utils import normalize_state
from .workflow import load_workflow, resolve_workflow_path

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class TrackerConfig:
    kind: str | None = None
    endpoint: str | None = None
    api_key: str | None = None
    project_slug: str | None = None
    team: str | None = None
    mcp_command: str = "codex app-server"
    mcp_server: str = "codex_apps"
    active_states: list[str] = field(default_factory=lambda: ["Todo", "In Progress"])
    terminal_states: list[str] = field(default_factory=lambda: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    review_states: list[str] = field(default_factory=lambda: ["In Review", "Merging"])
    required_labels: list[str] = field(default_factory=list)
    handoff_state: str = "In Review"
    done_state: str = "Done"
    merge_base_branch: str = "dev"

    @property
    def active_state_set(self) -> set[str]:
        return {normalize_state(state) for state in self.active_states}

    @property
    def terminal_state_set(self) -> set[str]:
        return {normalize_state(state) for state in self.terminal_states}

    @property
    def review_state_set(self) -> set[str]:
        return {normalize_state(state) for state in self.review_states}

    @property
    def required_label_set(self) -> set[str]:
        return {str(label).strip().lower() for label in self.required_labels if str(label).strip()}


@dataclass(frozen=True, slots=True)
class PollingConfig:
    interval_ms: int = 30000


@dataclass(frozen=True, slots=True)
class WorkspaceConfig:
    root: Path


@dataclass(frozen=True, slots=True)
class HooksConfig:
    after_create: str | None = None
    before_run: str | None = None
    after_run: str | None = None
    before_remove: str | None = None
    timeout_ms: int = 60000


@dataclass(frozen=True, slots=True)
class AgentConfig:
    max_concurrent_agents: int = 10
    max_turns: int = 20
    max_retry_backoff_ms: int = 300000
    max_concurrent_agents_by_state: dict[str, int] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class CodexConfig:
    command: str = "codex app-server"
    approval_policy: Any = "never"
    thread_sandbox: Any = "workspace-write"
    turn_sandbox_policy: Any = None
    turn_timeout_ms: int = 3600000
    read_timeout_ms: int = 5000
    stall_timeout_ms: int = 300000
    model: str | None = None
    effort: str | None = None
    summary: str | None = None
    personality: str | None = None


@dataclass(frozen=True, slots=True)
class ServerConfig:
    port: int | None = None
    host: str = "127.0.0.1"


@dataclass(frozen=True, slots=True)
class CodingContextConfig:
    enabled: bool = False
    classifier: str = "rules"
    classification_fallback: str = "inject"
    classifier_model: str | None = None
    classifier_effort: str | None = "low"
    classification_timeout_ms: int = 120000
    skill_paths: list[Path] = field(default_factory=list)
    label_triggers: list[str] = field(default_factory=list)
    keyword_triggers: list[str] = field(default_factory=list)
    max_chars: int = 40000

    @property
    def label_trigger_set(self) -> set[str]:
        return {label.strip().lower() for label in self.label_triggers if label.strip()}


@dataclass(frozen=True, slots=True)
class ContextConfig:
    coding: CodingContextConfig = field(default_factory=CodingContextConfig)


@dataclass(frozen=True, slots=True)
class DashboardConfig:
    summaries_enabled: bool = False
    summary_update_interval_ms: int = 45000
    summary_timeout_ms: int = 120000
    summary_max_events: int = 60
    summary_max_chars: int = 14000
    summary_model: str | None = None
    summary_effort: str | None = "low"


@dataclass(frozen=True, slots=True)
class RepositoryConfig:
    slug: str
    local_path: Path | None = None
    remote_url: str | None = None
    aliases: list[str] = field(default_factory=list)
    description: str | None = None
    base_branch: str | None = None

    @property
    def path_name(self) -> str:
        return self.slug.rsplit("/", 1)[-1] if "/" in self.slug else self.slug

    def to_prompt_data(self) -> dict[str, Any]:
        return {
            "slug": self.slug,
            "local_path": str(self.local_path) if self.local_path else None,
            "remote_url": self.remote_url,
            "aliases": list(self.aliases),
            "description": self.description,
            "base_branch": self.base_branch,
        }


@dataclass(frozen=True, slots=True)
class RepositoryPlanningConfig:
    enabled: bool = False
    planner: str = "rules"
    plan_model: str | None = None
    plan_effort: str | None = "low"
    plan_timeout_ms: int = 120000
    fallback: str = "rules"
    block_on_needs_human: bool = True
    quarantine_on_mismatch: bool = True
    clone_timeout_ms: int = 300000
    base_branch: str = "dev"
    branch_prefix: str = "Symphony"
    repositories: list[RepositoryConfig] = field(default_factory=list)

    @property
    def repository_by_slug(self) -> dict[str, RepositoryConfig]:
        return {repo.slug: repo for repo in self.repositories}


@dataclass(frozen=True, slots=True)
class ServiceConfig:
    workflow_path: Path
    tracker: TrackerConfig
    polling: PollingConfig
    workspace: WorkspaceConfig
    hooks: HooksConfig
    agent: AgentConfig
    codex: CodexConfig
    server: ServerConfig = field(default_factory=ServerConfig)
    context: ContextConfig = field(default_factory=ContextConfig)
    dashboard: DashboardConfig = field(default_factory=DashboardConfig)
    repositories: RepositoryPlanningConfig = field(default_factory=RepositoryPlanningConfig)


def _section(raw: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    value = raw.get(key) or {}
    if not isinstance(value, Mapping):
        raise ConfigError("config_invalid_section", f"{key} must be an object")
    return value


def _resolve_env_reference(value: Any, environ: Mapping[str, str]) -> Any:
    if not isinstance(value, str):
        return value
    if len(value) > 1 and value.startswith("$") and value[1:].replace("_", "").isalnum():
        return environ.get(value[1:], "") or None
    return value


def _resolve_path(value: Any, *, default: Path, workflow_dir: Path, environ: Mapping[str, str]) -> Path:
    resolved = _resolve_env_reference(value, environ) if value is not None else default
    path = Path(str(resolved)).expanduser()
    if not path.is_absolute():
        path = workflow_dir / path
    return path.resolve(strict=False)


def _string_list(value: Any, default: list[str], field_name: str) -> list[str]:
    if value is None:
        return list(default)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ConfigError("config_invalid_value", f"{field_name} must be a list of strings")
    return list(value)


def _int_value(value: Any, default: int, field_name: str, *, positive: bool = False, minimum: int | None = None) -> int:
    if value is None:
        result = default
    elif isinstance(value, bool):
        raise ConfigError("config_invalid_value", f"{field_name} must be an integer")
    else:
        try:
            result = int(value)
        except (TypeError, ValueError) as exc:
            raise ConfigError("config_invalid_value", f"{field_name} must be an integer", cause=exc) from exc
    if positive and result <= 0:
        raise ConfigError("config_invalid_value", f"{field_name} must be positive")
    if minimum is not None and result < minimum:
        raise ConfigError("config_invalid_value", f"{field_name} must be >= {minimum}")
    return result


def _bool_value(value: Any, default: bool, field_name: str) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    raise ConfigError("config_invalid_value", f"{field_name} must be a boolean")


def _state_limits(value: Any) -> dict[str, int]:
    if not isinstance(value, Mapping):
        return {}
    limits: dict[str, int] = {}
    for key, raw_limit in value.items():
        try:
            limit = int(raw_limit)
        except (TypeError, ValueError):
            continue
        if limit > 0:
            limits[normalize_state(str(key))] = limit
    return limits


def _path_list(value: Any, *, workflow_dir: Path, environ: Mapping[str, str], field_name: str) -> list[Path]:
    return [
        _resolve_path(item, default=workflow_dir, workflow_dir=workflow_dir, environ=environ)
        for item in _string_list(value, [], field_name)
    ]


def _repository_list(value: Any, *, workflow_dir: Path, environ: Mapping[str, str]) -> list[RepositoryConfig]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ConfigError("config_invalid_value", "repositories.known must be a list of objects")
    repositories: list[RepositoryConfig] = []
    for index, item in enumerate(value):
        if not isinstance(item, Mapping):
            raise ConfigError("config_invalid_value", f"repositories.known[{index}] must be an object")
        slug = item.get("slug")
        if not isinstance(slug, str) or not slug.strip():
            raise ConfigError("config_invalid_value", f"repositories.known[{index}].slug must be a non-empty string")
        local_path = None
        if item.get("local_path") is not None:
            local_path = _resolve_path(
                item.get("local_path"),
                default=workflow_dir,
                workflow_dir=workflow_dir,
                environ=environ,
            )
        remote_url = item.get("remote_url")
        repositories.append(
            RepositoryConfig(
                slug=slug.strip(),
                local_path=local_path,
                remote_url=str(remote_url).strip() if remote_url is not None and str(remote_url).strip() else None,
                aliases=_string_list(item.get("aliases"), [], f"repositories.known[{index}].aliases"),
                description=str(item["description"]).strip() if item.get("description") is not None else None,
                base_branch=str(item["base_branch"]).strip() if item.get("base_branch") is not None and str(item["base_branch"]).strip() else None,
            )
        )
    return repositories


def resolve_config(workflow: WorkflowDefinition, environ: Mapping[str, str] | None = None) -> ServiceConfig:
    env = environ or os.environ
    raw = workflow.config
    workflow_dir = workflow.path.parent

    tracker_raw = _section(raw, "tracker")
    kind = tracker_raw.get("kind")
    kind = str(kind) if kind is not None else None
    endpoint = tracker_raw.get("endpoint")
    if endpoint is None and kind == "linear":
        endpoint = "https://api.linear.app/graphql"
    api_key = _resolve_env_reference(tracker_raw.get("api_key"), env)
    project_slug = tracker_raw.get("project_slug")

    tracker = TrackerConfig(
        kind=kind,
        endpoint=str(endpoint) if endpoint is not None else None,
        api_key=str(api_key) if api_key else None,
        project_slug=str(project_slug) if project_slug is not None else None,
        team=str(tracker_raw["team"]) if tracker_raw.get("team") is not None else None,
        mcp_command=str(tracker_raw.get("mcp_command", "codex app-server")),
        mcp_server=str(tracker_raw.get("mcp_server", "codex_apps")),
        active_states=_string_list(tracker_raw.get("active_states"), ["Todo", "In Progress"], "tracker.active_states"),
        terminal_states=_string_list(
            tracker_raw.get("terminal_states"),
            ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
            "tracker.terminal_states",
        ),
        review_states=_string_list(tracker_raw.get("review_states"), ["In Review", "Merging"], "tracker.review_states"),
        required_labels=_string_list(tracker_raw.get("required_labels"), [], "tracker.required_labels"),
        handoff_state=str(tracker_raw.get("handoff_state", "In Review")),
        done_state=str(tracker_raw.get("done_state", "Done")),
        merge_base_branch=str(tracker_raw.get("merge_base_branch", "dev")),
    )

    polling_raw = _section(raw, "polling")
    polling = PollingConfig(interval_ms=_int_value(polling_raw.get("interval_ms"), 30000, "polling.interval_ms", positive=True))

    workspace_raw = _section(raw, "workspace")
    workspace = WorkspaceConfig(
        root=_resolve_path(
            workspace_raw.get("root"),
            default=Path(tempfile.gettempdir()) / "symphony_workspaces",
            workflow_dir=workflow_dir,
            environ=env,
        )
    )

    hooks_raw = _section(raw, "hooks")
    hooks = HooksConfig(
        after_create=hooks_raw.get("after_create"),
        before_run=hooks_raw.get("before_run"),
        after_run=hooks_raw.get("after_run"),
        before_remove=hooks_raw.get("before_remove"),
        timeout_ms=_int_value(hooks_raw.get("timeout_ms"), 60000, "hooks.timeout_ms", positive=True),
    )

    agent_raw = _section(raw, "agent")
    agent = AgentConfig(
        max_concurrent_agents=_int_value(agent_raw.get("max_concurrent_agents"), 10, "agent.max_concurrent_agents", positive=True),
        max_turns=_int_value(agent_raw.get("max_turns"), 20, "agent.max_turns", positive=True),
        max_retry_backoff_ms=_int_value(
            agent_raw.get("max_retry_backoff_ms"), 300000, "agent.max_retry_backoff_ms", positive=True
        ),
        max_concurrent_agents_by_state=_state_limits(agent_raw.get("max_concurrent_agents_by_state")),
    )

    codex_raw = _section(raw, "codex")
    command = codex_raw.get("command", "codex app-server")
    codex = CodexConfig(
        command=str(command) if command is not None else "",
        approval_policy=codex_raw.get("approval_policy", "never"),
        thread_sandbox=codex_raw.get("thread_sandbox", "workspace-write"),
        turn_sandbox_policy=codex_raw.get("turn_sandbox_policy"),
        turn_timeout_ms=_int_value(codex_raw.get("turn_timeout_ms"), 3600000, "codex.turn_timeout_ms", positive=True),
        read_timeout_ms=_int_value(codex_raw.get("read_timeout_ms"), 5000, "codex.read_timeout_ms", positive=True),
        stall_timeout_ms=_int_value(codex_raw.get("stall_timeout_ms"), 300000, "codex.stall_timeout_ms"),
        model=str(codex_raw["model"]) if codex_raw.get("model") is not None else None,
        effort=str(codex_raw["effort"]) if codex_raw.get("effort") is not None else None,
        summary=str(codex_raw["summary"]) if codex_raw.get("summary") is not None else None,
        personality=str(codex_raw["personality"]) if codex_raw.get("personality") is not None else None,
    )

    server_raw = _section(raw, "server")
    port = server_raw.get("port")
    server = ServerConfig(
        port=_int_value(port, 0, "server.port", minimum=0) if port is not None else None,
        host=str(server_raw.get("host", "127.0.0.1")),
    )

    context_raw = _section(raw, "context")
    coding_raw = _section(context_raw, "coding")
    context = ContextConfig(
        coding=CodingContextConfig(
            enabled=_bool_value(coding_raw.get("enabled"), False, "context.coding.enabled"),
            classifier=str(coding_raw.get("classifier", "rules")).strip().lower(),
            classification_fallback=str(coding_raw.get("classification_fallback", "inject")).strip().lower(),
            classifier_model=str(coding_raw["classifier_model"]) if coding_raw.get("classifier_model") is not None else None,
            classifier_effort=str(coding_raw["classifier_effort"]) if coding_raw.get("classifier_effort") is not None else "low",
            classification_timeout_ms=_int_value(
                coding_raw.get("classification_timeout_ms"),
                120000,
                "context.coding.classification_timeout_ms",
                positive=True,
            ),
            skill_paths=_path_list(
                coding_raw.get("skill_paths"),
                workflow_dir=workflow_dir,
                environ=env,
                field_name="context.coding.skill_paths",
            ),
            label_triggers=_string_list(coding_raw.get("label_triggers"), [], "context.coding.label_triggers"),
            keyword_triggers=_string_list(coding_raw.get("keyword_triggers"), [], "context.coding.keyword_triggers"),
            max_chars=_int_value(coding_raw.get("max_chars"), 40000, "context.coding.max_chars", positive=True),
        )
    )

    dashboard_raw = _section(raw, "dashboard")
    summaries_raw = _section(dashboard_raw, "summaries")
    dashboard = DashboardConfig(
        summaries_enabled=_bool_value(summaries_raw.get("enabled"), False, "dashboard.summaries.enabled"),
        summary_update_interval_ms=_int_value(
            summaries_raw.get("update_interval_ms"),
            45000,
            "dashboard.summaries.update_interval_ms",
            positive=True,
        ),
        summary_timeout_ms=_int_value(
            summaries_raw.get("timeout_ms"),
            120000,
            "dashboard.summaries.timeout_ms",
            positive=True,
        ),
        summary_max_events=_int_value(
            summaries_raw.get("max_events"),
            60,
            "dashboard.summaries.max_events",
            positive=True,
        ),
        summary_max_chars=_int_value(
            summaries_raw.get("max_chars"),
            14000,
            "dashboard.summaries.max_chars",
            positive=True,
        ),
        summary_model=str(summaries_raw["model"]) if summaries_raw.get("model") is not None else None,
        summary_effort=str(summaries_raw["effort"]) if summaries_raw.get("effort") is not None else "low",
    )

    repositories_raw = _section(raw, "repositories")
    repositories = RepositoryPlanningConfig(
        enabled=_bool_value(repositories_raw.get("enabled"), False, "repositories.enabled"),
        planner=str(repositories_raw.get("planner", "rules")).strip().lower(),
        plan_model=str(repositories_raw["model"]) if repositories_raw.get("model") is not None else None,
        plan_effort=str(repositories_raw["effort"]) if repositories_raw.get("effort") is not None else "low",
        plan_timeout_ms=_int_value(
            repositories_raw.get("timeout_ms"),
            120000,
            "repositories.timeout_ms",
            positive=True,
        ),
        fallback=str(repositories_raw.get("fallback", "rules")).strip().lower(),
        block_on_needs_human=_bool_value(
            repositories_raw.get("block_on_needs_human"),
            True,
            "repositories.block_on_needs_human",
        ),
        quarantine_on_mismatch=_bool_value(
            repositories_raw.get("quarantine_on_mismatch"),
            True,
            "repositories.quarantine_on_mismatch",
        ),
        clone_timeout_ms=_int_value(
            repositories_raw.get("clone_timeout_ms"),
            300000,
            "repositories.clone_timeout_ms",
            positive=True,
        ),
        base_branch=str(repositories_raw.get("base_branch", "dev")).strip() or "dev",
        branch_prefix=str(repositories_raw.get("branch_prefix", "Symphony")).strip().strip("/") or "Symphony",
        repositories=_repository_list(repositories_raw.get("known"), workflow_dir=workflow_dir, environ=env),
    )

    return ServiceConfig(
        workflow_path=workflow.path,
        tracker=tracker,
        polling=polling,
        workspace=workspace,
        hooks=hooks,
        agent=agent,
        codex=codex,
        server=server,
        context=context,
        dashboard=dashboard,
        repositories=repositories,
    )


def validate_dispatch_config(config: ServiceConfig) -> None:
    if config.tracker.kind not in {"linear", "linear_mcp"}:
        raise ConfigError("unsupported_tracker_kind", "tracker.kind must be 'linear' or 'linear_mcp'")
    if config.tracker.kind == "linear" and not config.tracker.api_key:
        raise ConfigError("missing_tracker_api_key", "tracker.api_key is required after $VAR resolution")
    if config.tracker.kind == "linear" and not config.tracker.project_slug:
        raise ConfigError("missing_tracker_project_slug", "tracker.project_slug is required for raw Linear GraphQL")
    if config.tracker.kind == "linear_mcp" and not config.tracker.project_slug and not config.tracker.team:
        raise ConfigError("missing_tracker_scope", "tracker.team or tracker.project_slug is required for Linear MCP")
    if not config.codex.command.strip():
        raise ConfigError("missing_codex_command", "codex.command must be present and non-empty")
    if config.tracker.kind == "linear_mcp" and not config.tracker.mcp_command.strip():
        raise ConfigError("missing_tracker_mcp_command", "tracker.mcp_command must be present and non-empty")
    if config.context.coding.enabled:
        if config.context.coding.classifier not in {"rules", "llm", "always"}:
            raise ConfigError(
                "invalid_coding_context_classifier",
                "context.coding.classifier must be one of: rules, llm, always",
            )
        if config.context.coding.classification_fallback not in {"rules", "inject", "skip"}:
            raise ConfigError(
                "invalid_coding_context_fallback",
                "context.coding.classification_fallback must be one of: rules, inject, skip",
            )
        if not config.context.coding.skill_paths:
            raise ConfigError("missing_coding_context_skills", "context.coding.skill_paths must be present when coding context is enabled")
        for path in config.context.coding.skill_paths:
            if not path.exists():
                raise ConfigError("missing_coding_context_skill", f"context coding skill path does not exist: {path}")
    if config.repositories.enabled:
        if config.repositories.planner not in {"rules", "llm"}:
            raise ConfigError("invalid_repository_planner", "repositories.planner must be one of: rules, llm")
        if config.repositories.fallback not in {"rules", "block"}:
            raise ConfigError("invalid_repository_planner_fallback", "repositories.fallback must be one of: rules, block")
        if not config.repositories.repositories:
            raise ConfigError("missing_known_repositories", "repositories.known must contain at least one repository when repositories.enabled is true")
        seen: set[str] = set()
        for repo in config.repositories.repositories:
            key = repo.slug.lower()
            if key in seen:
                raise ConfigError("duplicate_known_repository", f"duplicate repository slug: {repo.slug}")
            seen.add(key)
            if repo.local_path is not None and not repo.local_path.exists():
                raise ConfigError("missing_repository_local_path", f"repository local_path does not exist: {repo.local_path}")
            if repo.local_path is None and not repo.remote_url:
                raise ConfigError(
                    "repository_missing_source",
                    f"repository must define local_path or remote_url: {repo.slug}",
                )


class ConfigManager:
    """Owns workflow reload and last-known-good config semantics."""

    def __init__(self, workflow_path: str | Path | None = None, *, environ: Mapping[str, str] | None = None):
        self.workflow_path = resolve_workflow_path(workflow_path)
        self.environ = environ or os.environ
        self.workflow: WorkflowDefinition | None = None
        self.config: ServiceConfig | None = None
        self.last_reload_error: Exception | None = None

    def load_startup(self) -> tuple[WorkflowDefinition, ServiceConfig]:
        workflow = load_workflow(self.workflow_path)
        config = resolve_config(workflow, self.environ)
        validate_dispatch_config(config)
        self.workflow = workflow
        self.config = config
        self.last_reload_error = None
        return workflow, config

    def current(self) -> tuple[WorkflowDefinition, ServiceConfig]:
        if self.workflow is None or self.config is None:
            return self.load_startup()
        return self.workflow, self.config

    def reload_if_changed(self) -> bool:
        if self.workflow is None:
            self.load_startup()
            return True
        try:
            current_mtime = self.workflow_path.stat().st_mtime_ns
        except OSError as exc:
            self.last_reload_error = WorkflowError("missing_workflow_file", f"workflow file cannot be read: {self.workflow_path}", cause=exc)
            log_event(LOGGER, logging.ERROR, "workflow_reload_failed", reason=self.last_reload_error)
            return False
        if current_mtime == self.workflow.mtime_ns:
            return False
        try:
            workflow = load_workflow(self.workflow_path)
            config = resolve_config(workflow, self.environ)
            validate_dispatch_config(config)
        except (WorkflowError, ConfigError) as exc:
            self.last_reload_error = exc
            log_event(LOGGER, logging.ERROR, "workflow_reload_failed", reason=exc)
            return False
        self.workflow = workflow
        self.config = config
        self.last_reload_error = None
        log_event(LOGGER, logging.INFO, "workflow_reloaded", workflow_path=workflow.path)
        return True

    def validate_for_dispatch(self) -> None:
        self.reload_if_changed()
        if self.last_reload_error is not None:
            raise ConfigError("workflow_reload_invalid", str(self.last_reload_error), cause=self.last_reload_error)
        _, config = self.current()
        validate_dispatch_config(config)
