defmodule Symphony.AgentRunner do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.CodingContext
  alias Symphony.Config.ConfigManager
  alias Symphony.Config.TrackerConfig
  alias Symphony.Models.RepoPlan
  alias Symphony.Models.Issue
  alias Symphony.RepoPlanner
  alias Symphony.Templating
  alias Symphony.Utils
  alias Symphony.Workspace.Manager, as: WorkspaceManager

  defmodule AgentRunResult do
    defstruct issue_id: nil,
              issue_identifier: nil,
              normal: false,
              reason: "normal",
              retryable: true,
              blocked: false,
              workspace_path: nil,
              repo_plan: nil
  end

  def agent_reported_linear_delivery_blocker?(text) do
    normalized = String.downcase(text || "")

    blocker =
      Enum.any?(
        [
          "rejected",
          "could not update",
          "can't update",
          "couldn't update",
          "could not create",
          "can't create",
          "couldn't create"
        ],
        &String.contains?(normalized, &1)
      )

    completed =
      Enum.any?(
        [
          "completed:",
          "completed actions",
          "validation passed",
          "validation previously completed",
          "pr is open",
          "pr #",
          "pull request",
          "branch clean",
          "committed and pushed",
          "already committed and pushed"
        ],
        &String.contains?(normalized, &1)
      )

    String.contains?(normalized, "linear") and blocker and completed
  end

  def agent_reported_unresolved_external_blocker?(text) do
    normalized = String.downcase(text || "")

    linear_delivery_only? =
      agent_reported_linear_delivery_blocker?(text) and
        String.contains?(normalized, "linear") and
        Enum.any?(
          [
            "workpad",
            "state",
            "moving",
            "move",
            "in review",
            "comment"
          ],
          &String.contains?(normalized, &1)
        ) and
        not Enum.any?(
          [
            "data migration was not run",
            "migration was not run",
            "not applied",
            "not executed",
            "dry-run only",
            "production data",
            "supabase",
            "postgres",
            "database"
          ],
          &String.contains?(normalized, &1)
        )

    (not linear_delivery_only? and
       Enum.any?(
         [
           "missing postgres url",
           "missing database url",
           "missing db url",
           "missing database_url",
           "missing credentials",
           "missing credential",
           "no production credentials",
           "credentials are missing",
           "not applied",
           "not executed",
           "data migration was not run",
           "migration was not run",
           "dry-run only",
           "operator must run",
           "someone must run"
         ],
         &String.contains?(normalized, &1)
       )) or
      (String.contains?(normalized, "blocked") and
         Enum.any?(
           [
             "credential",
             "credentials",
             "supabase",
             "postgres",
             "database",
             "aws",
             "permission",
             "permissions"
           ],
           &String.contains?(normalized, &1)
         )) or
      (String.contains?(normalized, "requires") and
         Enum.any?(
           [
             "privileged postgres",
             "production credential",
             "database credential",
             "supabase_transaction_pooler_url",
             "supabase_db_url",
             "service role"
           ],
           &String.contains?(normalized, &1)
         ))
  end

  def existing_workpad_comment_id(comments) do
    Enum.find_value(comments, fn comment ->
      body =
        comment["body"] || comment[:body] || comment["text"] || comment[:text] ||
          comment["content"] || comment[:content] || ""

      if is_binary(body) and String.contains?(body, "## Codex Workpad") do
        id = comment["id"] || comment[:id]
        if id, do: to_string(id)
      end
    end)
  end

  def fallback_workpad_body(%Issue{} = issue, agent_message_text, workspace_path) do
    timestamp = Utils.isoformat_z(Utils.now_utc())
    summary = agent_message_text |> to_string() |> String.trim() |> Utils.truncate(5000)

    """
    ## Codex Workpad

    ```text
    #{workspace_path}
    ```

    ### Plan

    - [x] Agent completed implementation work.
    - [x] Agent attempted Linear workpad/state handoff.
    - [x] Symphony applied tracker-owned delivery fallback after the in-agent Linear write was rejected.

    ### Acceptance Criteria

    - [x] #{issue.identifier} final agent handoff captured below.

    ### Validation

    - [x] See final agent handoff below.

    ### Notes

    - #{timestamp}: Symphony fallback created this workpad because the agent reported that Linear MCP writes were rejected inside the Codex turn.

    #### Final Agent Handoff

    ```text
    #{summary}
    ```

    ### Confusions

    - In-agent Linear MCP writes were rejected; Symphony used tracker-owned Linear MCP writes for delivery.
    """
  end

  def new(config_manager, tracker), do: %{config_manager: config_manager, tracker: tracker}

  def run_issue(
        %{config_manager: config_manager, tracker: tracker},
        %Issue{} = issue,
        attempt,
        on_event
      ) do
    {_manager, workflow, config} = ConfigManager.current(config_manager)
    workspace_manager = WorkspaceManager.new(config.workspace, config.hooks)
    workspace = WorkspaceManager.create_for_issue(workspace_manager, issue.identifier)

    try do
      emit = fn event -> on_event.(issue.id, event) end
      first_prompt = Templating.render_prompt(workflow.prompt_template, issue, attempt)

      classification =
        CodingContext.classify_coding_issue(issue, config.context.coding,
          codex_config: config.codex,
          workspace_path: workspace.path
        )

      repo_plan =
        RepoPlanner.plan_repositories(
          issue,
          config.repositories,
          config.context.coding,
          classification,
          codex_config: config.codex,
          workspace_path: workspace.path
        )

      workspace =
        if repo_plan do
          emit.(%{
            "event" => "repo_plan_created",
            "repo_plan" => RepoPlan.to_map(repo_plan),
            "repo_plan_needs_human" => repo_plan.needs_human,
            "repo_plan_human_reason" => repo_plan.human_reason
          })

          if repo_plan.needs_human and config.repositories.block_on_needs_human do
            throw({:blocked, repo_plan})
          end

          prepared =
            WorkspaceManager.materialize_repo_plan(
              workspace_manager,
              workspace,
              repo_plan,
              config.repositories
            )

          emit.(%{
            "event" => "repo_workspace_prepared",
            "repo_plan" => RepoPlan.to_map(repo_plan),
            "workspace_path" => prepared.path,
            "primary_repo_path" => prepared.primary_repo_path
          })

          prepared
        else
          workspace
        end

      WorkspaceManager.before_run(workspace_manager, workspace.path)

      first_prompt =
        first_prompt
        |> CodingContext.augment_prompt_with_coding_context(issue, config.context.coding,
          codex_config: config.codex,
          workspace_path: workspace.path,
          classification: classification,
          on_event: emit
        )
        |> RepoPlanner.apply_repo_plan_to_prompt(repo_plan, workspace.path)

      session =
        CodexClient.start_session(config.codex, workspace.path,
          tracker_config: config.tracker,
          on_event: emit
        )

      try do
        run_turn_loop(session, tracker, issue, first_prompt, config, workspace.path, repo_plan)
      after
        CodexClient.stop_session(session)
      end
    rescue
      error in Symphony.Error ->
        %AgentRunResult{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          normal: false,
          reason: to_string(error.code),
          workspace_path: workspace.path
        }

      _error ->
        %AgentRunResult{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          normal: false,
          reason: "unhandled_agent_error",
          workspace_path: workspace.path
        }
    catch
      {:blocked, %RepoPlan{} = repo_plan} ->
        %AgentRunResult{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          normal: false,
          reason: "repo_plan_needs_human",
          retryable: false,
          blocked: true,
          workspace_path: workspace.path,
          repo_plan: repo_plan
        }
    after
      WorkspaceManager.after_run(workspace_manager, workspace.path)
    end
  end

  defp run_turn_loop(session, tracker, issue, first_prompt, config, workspace_path, repo_plan) do
    Enum.reduce_while(1..config.agent.max_turns, {issue, session}, fn turn_number,
                                                                      {current_issue, session} ->
      prompt =
        if turn_number == 1 do
          first_prompt
        else
          Templating.continuation_prompt(current_issue, turn_number, config.agent.max_turns)
        end

      {turn_result, session} = CodexClient.run_turn(session, prompt, capture_agent_text: true)
      refreshed = call_tracker(tracker, :fetch_issue_states_by_ids, [[issue.id]])
      current_issue = List.first(refreshed) || current_issue

      {current_issue, state} =
        if MapSet.member?(
             TrackerConfig.active_state_set(config.tracker),
             Utils.normalize_state(current_issue.state)
           ) and
             try_delivery_fallback(tracker, current_issue, turn_result.agent_message_text,
               workspace_path: workspace_path,
               handoff_state: config.tracker.handoff_state
             ) do
          {%{current_issue | state: config.tracker.handoff_state},
           Utils.normalize_state(config.tracker.handoff_state)}
        else
          {current_issue, Utils.normalize_state(current_issue.state)}
        end

      cond do
        agent_reported_unresolved_external_blocker?(turn_result.agent_message_text) ->
          {:halt,
           %AgentRunResult{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             normal: false,
             reason: "unresolved_external_blocker",
             retryable: false,
             blocked: true,
             workspace_path: workspace_path,
             repo_plan: repo_plan
           }}

        !MapSet.member?(TrackerConfig.active_state_set(config.tracker), state) ->
          {:halt,
           %AgentRunResult{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             normal: true,
             reason: "issue_left_active_state",
             retryable: false,
             workspace_path: workspace_path,
             repo_plan: repo_plan
           }}

        turn_number >= config.agent.max_turns ->
          {:halt,
           %AgentRunResult{
             issue_id: issue.id,
             issue_identifier: issue.identifier,
             normal: true,
             reason: "max_turns_reached",
             retryable: true,
             workspace_path: workspace_path,
             repo_plan: repo_plan
           }}

        true ->
          {:cont, {current_issue, session}}
      end
    end)
    |> case do
      {%Issue{}, _session} ->
        %AgentRunResult{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          normal: true,
          workspace_path: workspace_path,
          repo_plan: repo_plan
        }

      %AgentRunResult{} = result ->
        result
    end
  end

  def try_delivery_fallback(tracker, %Issue{} = issue, agent_message_text, opts) do
    if agent_reported_linear_delivery_blocker?(agent_message_text) and
         not agent_reported_unresolved_external_blocker?(agent_message_text) and
         tracker_supports_writes?(tracker) do
      comments = call_tracker(tracker, :list_issue_comments, [issue.identifier])
      comment_id = existing_workpad_comment_id(comments)

      body =
        fallback_workpad_body(issue, agent_message_text, Keyword.fetch!(opts, :workspace_path))

      call_tracker(tracker, :save_issue_comment, [
        issue.identifier,
        body,
        [comment_id: comment_id]
      ])

      call_tracker(tracker, :save_issue_state, [
        issue.identifier,
        Keyword.fetch!(opts, :handoff_state)
      ])

      true
    else
      false
    end
  rescue
    _ -> false
  end

  defp tracker_supports_writes?(%{__struct__: _module}), do: true

  defp tracker_supports_writes?(tracker) when is_map(tracker) do
    Enum.all?(
      [:list_issue_comments, :save_issue_comment, :save_issue_state],
      &Map.has_key?(tracker, &1)
    )
  end

  defp tracker_supports_writes?(_), do: true

  defp call_tracker(%{__struct__: module} = tracker, function, args),
    do: apply(module, function, [tracker | args])

  defp call_tracker(tracker, function, args) when is_atom(tracker),
    do: apply(tracker, function, args)

  defp call_tracker(tracker, function, args) when is_map(tracker),
    do: apply(Map.fetch!(tracker, function), args)
end
