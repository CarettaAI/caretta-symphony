defmodule Symphony.Config do
  @moduledoc false

  alias Symphony.Error
  alias Symphony.Models.WorkflowDefinition
  alias Symphony.Utils
  alias Symphony.Workflow

  defmodule TrackerConfig do
    defstruct kind: nil,
              endpoint: nil,
              api_key: nil,
              project_slug: nil,
              team: nil,
              mcp_command: "codex app-server",
              mcp_server: "codex_apps",
              active_states: ["Todo", "In Progress"],
              terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
              review_states: ["In Review", "Merging"],
              required_labels: [],
              handoff_state: "In Review",
              done_state: "Done",
              merge_base_branch: "dev"

    def active_state_set(config), do: state_set(config.active_states)
    def terminal_state_set(config), do: state_set(config.terminal_states)
    def review_state_set(config), do: state_set(config.review_states)

    def required_label_set(config) do
      config.required_labels
      |> Enum.map(&(to_string(&1) |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()
    end

    defp state_set(states), do: states |> Enum.map(&Utils.normalize_state/1) |> MapSet.new()
  end

  defmodule PollingConfig do
    defstruct interval_ms: 30_000
  end

  defmodule WorkspaceConfig do
    defstruct root: nil
  end

  defmodule HooksConfig do
    defstruct after_create: nil,
              before_run: nil,
              after_run: nil,
              before_remove: nil,
              timeout_ms: 60_000
  end

  defmodule AgentConfig do
    defstruct max_concurrent_agents: 10,
              max_turns: 20,
              max_retry_backoff_ms: 300_000,
              max_concurrent_agents_by_state: %{}
  end

  defmodule CodexConfig do
    defstruct command: "codex app-server",
              approval_policy: "never",
              thread_sandbox: "workspace-write",
              turn_sandbox_policy: nil,
              turn_timeout_ms: 3_600_000,
              read_timeout_ms: 5_000,
              stall_timeout_ms: 300_000,
              model: nil,
              effort: nil,
              summary: nil,
              personality: nil
  end

  defmodule ServerConfig do
    defstruct port: nil, host: "127.0.0.1"
  end

  defmodule CodingContextConfig do
    defstruct enabled: false,
              classifier: "rules",
              classification_fallback: "inject",
              classifier_model: nil,
              classifier_effort: "low",
              classification_timeout_ms: 120_000,
              skill_paths: [],
              label_triggers: [],
              keyword_triggers: [],
              max_chars: 40_000

    def label_trigger_set(config) do
      config.label_triggers
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()
    end
  end

  defmodule ContextConfig do
    defstruct coding: %CodingContextConfig{}
  end

  defmodule DashboardConfig do
    defstruct summaries_enabled: false,
              summary_update_interval_ms: 45_000,
              summary_timeout_ms: 120_000,
              summary_max_events: 60,
              summary_max_chars: 14_000,
              summary_model: nil,
              summary_effort: "low"
  end

  defmodule RepositoryConfig do
    defstruct slug: nil,
              local_path: nil,
              remote_url: nil,
              aliases: [],
              description: nil,
              base_branch: nil

    def path_name(%__MODULE__{slug: slug}) do
      slug |> to_string() |> String.split("/") |> List.last()
    end

    def to_prompt_data(%__MODULE__{} = repo) do
      %{
        "slug" => repo.slug,
        "local_path" => repo.local_path,
        "remote_url" => repo.remote_url,
        "aliases" => repo.aliases,
        "description" => repo.description,
        "base_branch" => repo.base_branch
      }
    end
  end

  defmodule RepositoryPlanningConfig do
    defstruct enabled: false,
              planner: "rules",
              plan_model: nil,
              plan_effort: "low",
              plan_timeout_ms: 120_000,
              fallback: "rules",
              block_on_needs_human: true,
              quarantine_on_mismatch: true,
              clone_timeout_ms: 300_000,
              base_branch: "dev",
              branch_prefix: "Symphony",
              repositories: []

    def repository_by_slug(config) do
      Map.new(config.repositories, &{&1.slug, &1})
    end
  end

  defmodule ServiceConfig do
    defstruct workflow_path: nil,
              tracker: %TrackerConfig{},
              polling: %PollingConfig{},
              workspace: %WorkspaceConfig{},
              hooks: %HooksConfig{},
              agent: %AgentConfig{},
              codex: %CodexConfig{},
              server: %ServerConfig{},
              context: %ContextConfig{},
              dashboard: %DashboardConfig{},
              repositories: %RepositoryPlanningConfig{}
  end

  defmodule ConfigManager do
    defstruct workflow_path: nil, environ: %{}, workflow: nil, config: nil, last_reload_error: nil

    def new(workflow_path \\ nil, opts \\ []) do
      %__MODULE__{
        workflow_path: Workflow.resolve_workflow_path(workflow_path),
        environ: Keyword.get(opts, :environ, System.get_env())
      }
    end

    def load_startup(%__MODULE__{} = manager) do
      workflow = Workflow.load_workflow(manager.workflow_path)
      config = Symphony.Config.resolve_config(workflow, manager.environ)
      Symphony.Config.validate_dispatch_config!(config)
      {%{manager | workflow: workflow, config: config, last_reload_error: nil}, workflow, config}
    end

    def current(%__MODULE__{workflow: nil} = manager), do: load_startup(manager)
    def current(%__MODULE__{} = manager), do: {manager, manager.workflow, manager.config}

    def reload_if_changed(%__MODULE__{workflow: nil} = manager) do
      {manager, _workflow, _config} = load_startup(manager)
      {manager, true}
    end

    def reload_if_changed(%__MODULE__{} = manager) do
      current_mtime = Workflow.mtime(manager.workflow_path)
      changed? = current_mtime != manager.workflow.mtime_ns

      try do
        workflow = Workflow.load_workflow(manager.workflow_path)
        config = Symphony.Config.resolve_config(workflow, manager.environ)
        Symphony.Config.validate_dispatch_config!(config)
        {%{manager | workflow: workflow, config: config, last_reload_error: nil}, changed?}
      rescue
        error in Error ->
          {%{manager | last_reload_error: error}, false}
      end
    end

    def validate_for_dispatch!(%__MODULE__{} = manager) do
      {manager, _changed} = reload_if_changed(manager)

      if manager.last_reload_error do
        raise Error,
          code: :workflow_reload_invalid,
          message: Exception.message(manager.last_reload_error),
          cause: manager.last_reload_error
      end

      {_manager, _workflow, config} = current(manager)
      Symphony.Config.validate_dispatch_config!(config)
      manager
    end
  end

  def resolve_config(%WorkflowDefinition{} = workflow, environ \\ System.get_env()) do
    raw = workflow.config
    workflow_dir = Path.dirname(workflow.path)

    tracker_raw = section(raw, "tracker")
    kind = string_or_nil(get(tracker_raw, "kind"))

    endpoint =
      get(tracker_raw, "endpoint") || if(kind == "linear", do: "https://api.linear.app/graphql")

    api_key = resolve_env_reference(get(tracker_raw, "api_key"), environ)

    tracker = %TrackerConfig{
      kind: kind,
      endpoint: string_or_nil(endpoint),
      api_key: string_or_nil(api_key),
      project_slug: string_or_nil(get(tracker_raw, "project_slug")),
      team: string_or_nil(get(tracker_raw, "team")),
      mcp_command: to_string(get(tracker_raw, "mcp_command", "codex app-server")),
      mcp_server: to_string(get(tracker_raw, "mcp_server", "codex_apps")),
      active_states:
        string_list(
          get(tracker_raw, "active_states"),
          ["Todo", "In Progress"],
          "tracker.active_states"
        ),
      terminal_states:
        string_list(
          get(tracker_raw, "terminal_states"),
          ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          "tracker.terminal_states"
        ),
      review_states:
        string_list(
          get(tracker_raw, "review_states"),
          ["In Review", "Merging"],
          "tracker.review_states"
        ),
      required_labels:
        string_list(get(tracker_raw, "required_labels"), [], "tracker.required_labels"),
      handoff_state: to_string(get(tracker_raw, "handoff_state", "In Review")),
      done_state: to_string(get(tracker_raw, "done_state", "Done")),
      merge_base_branch: to_string(get(tracker_raw, "merge_base_branch", "dev"))
    }

    polling_raw = section(raw, "polling")

    polling = %PollingConfig{
      interval_ms:
        int_value(get(polling_raw, "interval_ms"), 30_000, "polling.interval_ms", positive: true)
    }

    workspace_raw = section(raw, "workspace")

    workspace = %WorkspaceConfig{
      root:
        resolve_path(get(workspace_raw, "root"),
          default: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          workflow_dir: workflow_dir,
          environ: environ
        )
    }

    hooks_raw = section(raw, "hooks")

    hooks = %HooksConfig{
      after_create: get(hooks_raw, "after_create"),
      before_run: get(hooks_raw, "before_run"),
      after_run: get(hooks_raw, "after_run"),
      before_remove: get(hooks_raw, "before_remove"),
      timeout_ms:
        int_value(get(hooks_raw, "timeout_ms"), 60_000, "hooks.timeout_ms", positive: true)
    }

    agent_raw = section(raw, "agent")

    agent = %AgentConfig{
      max_concurrent_agents:
        int_value(get(agent_raw, "max_concurrent_agents"), 10, "agent.max_concurrent_agents",
          positive: true
        ),
      max_turns: int_value(get(agent_raw, "max_turns"), 20, "agent.max_turns", positive: true),
      max_retry_backoff_ms:
        int_value(get(agent_raw, "max_retry_backoff_ms"), 300_000, "agent.max_retry_backoff_ms",
          positive: true
        ),
      max_concurrent_agents_by_state:
        state_limits(get(agent_raw, "max_concurrent_agents_by_state"))
    }

    codex_raw = section(raw, "codex")

    codex = %CodexConfig{
      command: to_string(get(codex_raw, "command", "codex app-server")),
      approval_policy: get(codex_raw, "approval_policy", "never"),
      thread_sandbox: get(codex_raw, "thread_sandbox", "workspace-write"),
      turn_sandbox_policy: get(codex_raw, "turn_sandbox_policy"),
      turn_timeout_ms:
        int_value(get(codex_raw, "turn_timeout_ms"), 3_600_000, "codex.turn_timeout_ms",
          positive: true
        ),
      read_timeout_ms:
        int_value(get(codex_raw, "read_timeout_ms"), 5_000, "codex.read_timeout_ms",
          positive: true
        ),
      stall_timeout_ms:
        int_value(get(codex_raw, "stall_timeout_ms"), 300_000, "codex.stall_timeout_ms"),
      model: string_or_nil(get(codex_raw, "model")),
      effort: string_or_nil(get(codex_raw, "effort")),
      summary: string_or_nil(get(codex_raw, "summary")),
      personality: string_or_nil(get(codex_raw, "personality"))
    }

    server_raw = section(raw, "server")
    port = get(server_raw, "port")

    server = %ServerConfig{
      port: if(port == nil, do: nil, else: int_value(port, 0, "server.port", minimum: 0)),
      host: to_string(get(server_raw, "host", "127.0.0.1"))
    }

    context_raw = section(raw, "context")
    coding_raw = section(context_raw, "coding")

    coding = %CodingContextConfig{
      enabled: bool_value(get(coding_raw, "enabled"), false, "context.coding.enabled"),
      classifier:
        get(coding_raw, "classifier", "rules")
        |> to_string()
        |> String.trim()
        |> String.downcase(),
      classification_fallback:
        get(coding_raw, "classification_fallback", "inject")
        |> to_string()
        |> String.trim()
        |> String.downcase(),
      classifier_model: string_or_nil(get(coding_raw, "classifier_model")),
      classifier_effort: string_or_nil(get(coding_raw, "classifier_effort")) || "low",
      classification_timeout_ms:
        int_value(
          get(coding_raw, "classification_timeout_ms"),
          120_000,
          "context.coding.classification_timeout_ms",
          positive: true
        ),
      skill_paths:
        path_list(get(coding_raw, "skill_paths"),
          workflow_dir: workflow_dir,
          environ: environ,
          field_name: "context.coding.skill_paths"
        ),
      label_triggers:
        string_list(get(coding_raw, "label_triggers"), [], "context.coding.label_triggers"),
      keyword_triggers:
        string_list(get(coding_raw, "keyword_triggers"), [], "context.coding.keyword_triggers"),
      max_chars:
        int_value(get(coding_raw, "max_chars"), 40_000, "context.coding.max_chars",
          positive: true
        )
    }

    dashboard_raw = section(raw, "dashboard")
    summaries_raw = section(dashboard_raw, "summaries")

    dashboard = %DashboardConfig{
      summaries_enabled:
        bool_value(get(summaries_raw, "enabled"), false, "dashboard.summaries.enabled"),
      summary_update_interval_ms:
        int_value(
          get(summaries_raw, "update_interval_ms"),
          45_000,
          "dashboard.summaries.update_interval_ms",
          positive: true
        ),
      summary_timeout_ms:
        int_value(get(summaries_raw, "timeout_ms"), 120_000, "dashboard.summaries.timeout_ms",
          positive: true
        ),
      summary_max_events:
        int_value(get(summaries_raw, "max_events"), 60, "dashboard.summaries.max_events",
          positive: true
        ),
      summary_max_chars:
        int_value(get(summaries_raw, "max_chars"), 14_000, "dashboard.summaries.max_chars",
          positive: true
        ),
      summary_model: string_or_nil(get(summaries_raw, "model")),
      summary_effort: string_or_nil(get(summaries_raw, "effort")) || "low"
    }

    repositories_raw = section(raw, "repositories")

    repositories = %RepositoryPlanningConfig{
      enabled: bool_value(get(repositories_raw, "enabled"), false, "repositories.enabled"),
      planner:
        get(repositories_raw, "planner", "rules")
        |> to_string()
        |> String.trim()
        |> String.downcase(),
      plan_model: string_or_nil(get(repositories_raw, "model")),
      plan_effort: string_or_nil(get(repositories_raw, "effort")) || "low",
      plan_timeout_ms:
        int_value(get(repositories_raw, "timeout_ms"), 120_000, "repositories.timeout_ms",
          positive: true
        ),
      fallback:
        get(repositories_raw, "fallback", "rules")
        |> to_string()
        |> String.trim()
        |> String.downcase(),
      block_on_needs_human:
        bool_value(
          get(repositories_raw, "block_on_needs_human"),
          true,
          "repositories.block_on_needs_human"
        ),
      quarantine_on_mismatch:
        bool_value(
          get(repositories_raw, "quarantine_on_mismatch"),
          true,
          "repositories.quarantine_on_mismatch"
        ),
      clone_timeout_ms:
        int_value(
          get(repositories_raw, "clone_timeout_ms"),
          300_000,
          "repositories.clone_timeout_ms",
          positive: true
        ),
      base_branch: clean_default(get(repositories_raw, "base_branch"), "dev"),
      branch_prefix:
        get(repositories_raw, "branch_prefix", "Symphony")
        |> to_string()
        |> String.trim("/")
        |> clean_default("Symphony"),
      repositories:
        repository_list(get(repositories_raw, "known"),
          workflow_dir: workflow_dir,
          environ: environ
        )
    }

    %ServiceConfig{
      workflow_path: workflow.path,
      tracker: tracker,
      polling: polling,
      workspace: workspace,
      hooks: hooks,
      agent: agent,
      codex: codex,
      server: server,
      context: %ContextConfig{coding: coding},
      dashboard: dashboard,
      repositories: repositories
    }
  end

  def validate_dispatch_config!(%ServiceConfig{} = config) do
    cond do
      config.tracker.kind not in ["linear", "linear_mcp"] ->
        raise Error,
          code: :unsupported_tracker_kind,
          message: "tracker.kind must be 'linear' or 'linear_mcp'"

      config.tracker.kind == "linear" and !truthy_string?(config.tracker.api_key) ->
        raise Error,
          code: :missing_tracker_api_key,
          message: "tracker.api_key is required after $VAR resolution"

      config.tracker.kind == "linear" and !truthy_string?(config.tracker.project_slug) ->
        raise Error,
          code: :missing_tracker_project_slug,
          message: "tracker.project_slug is required for raw Linear GraphQL"

      config.tracker.kind == "linear_mcp" and !truthy_string?(config.tracker.project_slug) and
          !truthy_string?(config.tracker.team) ->
        raise Error,
          code: :missing_tracker_scope,
          message: "tracker.team or tracker.project_slug is required for Linear MCP"

      String.trim(config.codex.command || "") == "" ->
        raise Error,
          code: :missing_codex_command,
          message: "codex.command must be present and non-empty"

      config.tracker.kind == "linear_mcp" and String.trim(config.tracker.mcp_command || "") == "" ->
        raise Error,
          code: :missing_tracker_mcp_command,
          message: "tracker.mcp_command must be present and non-empty"

      true ->
        validate_coding_context!(config.context.coding)
        validate_repositories!(config.repositories)
        :ok
    end
  end

  defp validate_coding_context!(%CodingContextConfig{enabled: false}), do: :ok

  defp validate_coding_context!(%CodingContextConfig{} = config) do
    if config.classifier not in ["rules", "llm", "always"] do
      raise Error,
        code: :invalid_coding_context_classifier,
        message: "context.coding.classifier must be one of: rules, llm, always"
    end

    if config.classification_fallback not in ["rules", "inject", "skip"] do
      raise Error,
        code: :invalid_coding_context_fallback,
        message: "context.coding.classification_fallback must be one of: rules, inject, skip"
    end

    if config.skill_paths == [] do
      raise Error,
        code: :missing_coding_context_skills,
        message: "context.coding.skill_paths must be present when coding context is enabled"
    end

    Enum.each(config.skill_paths, fn path ->
      unless File.exists?(path) do
        raise Error,
          code: :missing_coding_context_skill,
          message: "context coding skill path does not exist: #{path}"
      end
    end)
  end

  defp validate_repositories!(%RepositoryPlanningConfig{enabled: false}), do: :ok

  defp validate_repositories!(%RepositoryPlanningConfig{} = config) do
    if config.planner not in ["rules", "llm"] do
      raise Error,
        code: :invalid_repository_planner,
        message: "repositories.planner must be one of: rules, llm"
    end

    if config.fallback not in ["rules", "block"] do
      raise Error,
        code: :invalid_repository_planner_fallback,
        message: "repositories.fallback must be one of: rules, block"
    end

    if config.repositories == [] do
      raise Error,
        code: :missing_known_repositories,
        message:
          "repositories.known must contain at least one repository when repositories.enabled is true"
    end

    config.repositories
    |> Enum.reduce(MapSet.new(), fn repo, seen ->
      key = String.downcase(repo.slug)

      if MapSet.member?(seen, key) do
        raise Error,
          code: :duplicate_known_repository,
          message: "duplicate repository slug: #{repo.slug}"
      end

      if repo.local_path && !File.exists?(repo.local_path) do
        raise Error,
          code: :missing_repository_local_path,
          message: "repository local_path does not exist: #{repo.local_path}"
      end

      if is_nil(repo.local_path) and !truthy_string?(repo.remote_url) do
        raise Error,
          code: :repository_missing_source,
          message: "repository must define local_path or remote_url: #{repo.slug}"
      end

      MapSet.put(seen, key)
    end)

    :ok
  end

  defp section(raw, key) do
    value = get(raw, key, %{}) || %{}

    unless is_map(value) do
      raise Error, code: :config_invalid_section, message: "#{key} must be an object"
    end

    value
  end

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_binary(key) ->
        case existing_atom(key) do
          nil -> default
          atom -> Map.get(map, atom, default)
        end

      true ->
        default
    end
  end

  def get(_, _, default), do: default

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp resolve_env_reference(value, environ) when is_binary(value) do
    if String.starts_with?(value, "$") and String.length(value) > 1 and
         Regex.match?(~r/^\$[A-Za-z0-9_]+$/, value) do
      Map.get(environ, String.trim_leading(value, "$")) |> blank_to_nil()
    else
      value
    end
  end

  defp resolve_env_reference(value, _environ), do: value

  defp resolve_path(value, opts) do
    default = Keyword.fetch!(opts, :default)
    workflow_dir = Keyword.fetch!(opts, :workflow_dir)
    environ = Keyword.fetch!(opts, :environ)
    resolved = if is_nil(value), do: default, else: resolve_env_reference(value, environ)
    path = resolved |> to_string() |> Path.expand(workflow_dir)
    Path.expand(path)
  end

  defp string_list(nil, default, _field_name), do: default

  defp string_list(value, _default, field_name) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      value
    else
      raise Error, code: :config_invalid_value, message: "#{field_name} must be a list of strings"
    end
  end

  defp string_list(_value, _default, field_name) do
    raise Error, code: :config_invalid_value, message: "#{field_name} must be a list of strings"
  end

  defp int_value(value, default, field_name, opts \\ []) do
    result =
      cond do
        is_nil(value) ->
          default

        is_boolean(value) ->
          raise Error, code: :config_invalid_value, message: "#{field_name} must be an integer"

        is_integer(value) ->
          value

        true ->
          Utils.to_int(value) ||
            raise(Error, code: :config_invalid_value, message: "#{field_name} must be an integer")
      end

    if Keyword.get(opts, :positive, false) and result <= 0 do
      raise Error, code: :config_invalid_value, message: "#{field_name} must be positive"
    end

    minimum = Keyword.get(opts, :minimum)

    if minimum && result < minimum do
      raise Error, code: :config_invalid_value, message: "#{field_name} must be >= #{minimum}"
    end

    result
  end

  defp bool_value(nil, default, _field_name), do: default
  defp bool_value(value, _default, _field_name) when is_boolean(value), do: value

  defp bool_value(_value, _default, field_name) do
    raise Error, code: :config_invalid_value, message: "#{field_name} must be a boolean"
  end

  defp state_limits(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_limit}, acc ->
      case Utils.to_int(raw_limit) do
        limit when is_integer(limit) and limit > 0 ->
          Map.put(acc, Utils.normalize_state(key), limit)

        _ ->
          acc
      end
    end)
  end

  defp state_limits(_), do: %{}

  defp path_list(value, opts) do
    field_name = Keyword.fetch!(opts, :field_name)

    value
    |> string_list([], field_name)
    |> Enum.map(
      &resolve_path(&1,
        default: Keyword.fetch!(opts, :workflow_dir),
        workflow_dir: Keyword.fetch!(opts, :workflow_dir),
        environ: Keyword.fetch!(opts, :environ)
      )
    )
  end

  defp repository_list(nil, _opts), do: []

  defp repository_list(value, opts) when is_list(value) do
    Enum.with_index(value)
    |> Enum.map(fn {item, index} ->
      unless is_map(item) do
        raise Error,
          code: :config_invalid_value,
          message: "repositories.known[#{index}] must be an object"
      end

      slug = item |> get("slug") |> string_or_nil()

      unless truthy_string?(slug) do
        raise Error,
          code: :config_invalid_value,
          message: "repositories.known[#{index}].slug must be a non-empty string"
      end

      local_path =
        if get(item, "local_path") do
          resolve_path(get(item, "local_path"),
            default: Keyword.fetch!(opts, :workflow_dir),
            workflow_dir: Keyword.fetch!(opts, :workflow_dir),
            environ: Keyword.fetch!(opts, :environ)
          )
        end

      %RepositoryConfig{
        slug: String.trim(slug),
        local_path: local_path,
        remote_url: clean_nil(get(item, "remote_url")),
        aliases: string_list(get(item, "aliases"), [], "repositories.known[#{index}].aliases"),
        description: clean_nil(get(item, "description")),
        base_branch: clean_nil(get(item, "base_branch"))
      }
    end)
  end

  defp repository_list(_value, _opts) do
    raise Error,
      code: :config_invalid_value,
      message: "repositories.known must be a list of objects"
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value), do: to_string(value)
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp clean_nil(nil), do: nil

  defp clean_nil(value) do
    text = String.trim(to_string(value))
    if text == "", do: nil, else: text
  end

  defp clean_default(value, default) do
    clean_nil(value) || default
  end

  defp truthy_string?(value), do: is_binary(value) and String.trim(value) != ""
end
