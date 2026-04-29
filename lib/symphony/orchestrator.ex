defmodule Symphony.Orchestrator do
  @moduledoc false

  use GenServer

  alias Symphony.AgentRunner.AgentRunResult
  alias Symphony.CodingContext.CodingClassification
  alias Symphony.Config.{ConfigManager, ServiceConfig, TrackerConfig}
  alias Symphony.DashboardSummary
  alias Symphony.Logging
  alias Symphony.RepoPlanner

  alias Symphony.Models.{
    BlockedEntry,
    BlockerRef,
    CodexTotals,
    CompletedEntry,
    Issue,
    IssueAttachment,
    RepoPlan,
    RepoPlanItem,
    RetryEntry,
    RunningEntry,
    RuntimeState
  }

  alias Symphony.Review.ReviewPullRequestResolver
  alias Symphony.Tracker
  alias Symphony.Utils
  alias Symphony.Workspace.Manager, as: WorkspaceManager

  @continuation_retry_ms 1_000
  @default_call_timeout_ms 5_000
  @persist_coalesce_ms 500
  @review_reconcile_timeout_ms 30_000
  @snapshot_cache_table :symphony_orchestrator_snapshot_cache
  @state_file_name ".symphony-state.json"

  defstruct config_manager: nil,
            state: nil,
            review_resolver: nil,
            task_supervisor: nil,
            refresh_requested: false,
            refreshing: false,
            refresh_timer_ref: nil,
            persist_timer_ref: nil,
            review_task: nil,
            worker_tasks: %{},
            summary_tasks: %{},
            agent_runner: Symphony.AgentRunner,
            dashboard_summary: DashboardSummary,
            tracker_factory: &Tracker.make_tracker/1

  def start_link(%ConfigManager{} = manager, opts \\ []) do
    genserver_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {manager, opts}, genserver_opts)
  end

  def request_refresh(pid, timeout \\ @default_call_timeout_ms) when is_pid(pid),
    do: GenServer.call(pid, :request_refresh, timeout)

  def stop(pid) when is_pid(pid), do: GenServer.stop(pid, :normal, :infinity)

  @impl true
  def init({%ConfigManager{} = manager, opts}) do
    Process.flag(:trap_exit, true)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    orchestrator =
      manager
      |> new(opts)
      |> Map.put(:task_supervisor, task_supervisor)

    ensure_snapshot_cache_table!()

    {:ok, orchestrator, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, orchestrator) do
    orchestrator = publish_snapshot_cache(orchestrator)

    orchestrator =
      orchestrator
      |> startup_terminal_workspace_cleanup()
      |> restore_retry_timers()

    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    orchestrator = reconcile_blocked_issues(orchestrator, [], config)

    state = %{
      orchestrator.state
      | service_status: "running",
        startup_completed_at: Utils.now_utc(),
        last_poll_error: nil
    }

    orchestrator =
      orchestrator
      |> Map.put(:state, state)
      |> persist_state()
      |> publish_snapshot_cache()
      |> request_refresh_internal()

    Logging.log_event(:info, "service_started",
      workflow_path: orchestrator.config_manager.workflow_path
    )

    {:noreply, publish_snapshot_cache(orchestrator)}
  end

  @impl true
  def handle_call(:request_refresh, _from, orchestrator) do
    coalesced =
      orchestrator.refresh_requested or orchestrator.refreshing or
        not is_nil(orchestrator.refresh_timer_ref)

    {:reply, coalesced, request_refresh_internal(orchestrator)}
  end

  def handle_call(:snapshot, _from, orchestrator),
    do: {:reply, snapshot(orchestrator), orchestrator}

  def handle_call({:issue_snapshot, issue_identifier}, _from, orchestrator),
    do: {:reply, issue_snapshot(orchestrator, issue_identifier), orchestrator}

  @impl true
  def handle_cast({:codex_event, issue_id, event}, orchestrator) do
    orchestrator = handle_codex_event(orchestrator, issue_id, event)
    orchestrator = maybe_schedule_summary(orchestrator, issue_id)
    orchestrator = publish_snapshot_cache(orchestrator)
    {:noreply, publish_snapshot_cache(orchestrator)}
  end

  @impl true
  def handle_info(:run_refresh, %{refreshing: true} = orchestrator),
    do: {:noreply, %{orchestrator | refresh_requested: true, refresh_timer_ref: nil}}

  def handle_info(:run_refresh, orchestrator) do
    orchestrator =
      orchestrator
      |> Map.put(:refreshing, true)
      |> Map.put(:refresh_requested, false)
      |> Map.put(:refresh_timer_ref, nil)
      |> tick_runtime()
      |> Map.put(:refreshing, false)
      |> publish_snapshot_cache()

    orchestrator =
      if orchestrator.refresh_requested do
        orchestrator
        |> Map.put(:refresh_requested, false)
        |> request_refresh_internal()
      else
        schedule_next_refresh(orchestrator)
      end

    {:noreply, orchestrator}
  end

  def handle_info(:persist_state, orchestrator) do
    orchestrator =
      orchestrator
      |> Map.put(:persist_timer_ref, nil)
      |> persist_state()

    {:noreply, orchestrator}
  end

  def handle_info({:summary_timeout, ref}, orchestrator) when is_reference(ref) do
    case Map.pop(orchestrator.summary_tasks, ref) do
      {nil, _summary_tasks} ->
        {:noreply, orchestrator}

      {meta, summary_tasks} ->
        Process.demonitor(ref, [:flush])
        shutdown_task(meta.task)

        reason = "summary timed out after #{meta.timeout_ms} ms"

        orchestrator =
          %{orchestrator | summary_tasks: summary_tasks}
          |> apply_summary_result(meta.issue_id, meta.activity_revision, {:error, reason})
          |> publish_snapshot_cache()

        {:noreply, orchestrator}
    end
  end

  def handle_info({:retry_due, issue_id}, orchestrator) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    tracker = make_tracker(orchestrator, config.tracker)
    retry = orchestrator.state.retry_attempts[issue_id]

    orchestrator =
      if retry && available_global_slots(orchestrator, config) > 0 do
        state = %{
          orchestrator.state
          | retry_attempts: Map.delete(orchestrator.state.retry_attempts, issue_id)
        }

        orchestrator = %{orchestrator | state: state}
        issue = refresh_retry_issue(tracker, retry)

        if MapSet.member?(
             TrackerConfig.active_state_set(config.tracker),
             Utils.normalize_state(issue.state)
           ) and
             is_dispatch_eligible(orchestrator, issue, config, ignore_claimed_issue_id: issue_id) do
          dispatch_issue_async(orchestrator, issue, tracker, retry.attempt)
        else
          state = %{
            orchestrator.state
            | claimed: MapSet.delete(orchestrator.state.claimed, issue_id)
          }

          %{orchestrator | state: state}
          |> persist_state()
          |> publish_snapshot_cache()
        end
      else
        orchestrator
      end

    {:noreply, orchestrator}
  end

  def handle_info({ref, %AgentRunResult{} = result}, orchestrator) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {issue_id, worker_tasks} = Map.pop(orchestrator.worker_tasks, ref)
    orchestrator = %{orchestrator | worker_tasks: worker_tasks}

    orchestrator =
      if issue_id, do: handle_worker_done(orchestrator, issue_id, result), else: orchestrator

    {:noreply, publish_snapshot_cache(orchestrator)}
  end

  def handle_info({ref, {:summary_result, issue_id, activity_revision, result}}, orchestrator)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {meta, summary_tasks} = Map.pop(orchestrator.summary_tasks, ref)
    if meta && meta.timer_ref, do: Process.cancel_timer(meta.timer_ref)
    orchestrator = %{orchestrator | summary_tasks: summary_tasks}

    {:noreply,
     orchestrator
     |> apply_summary_result(issue_id, activity_revision, result)
     |> publish_snapshot_cache()}
  end

  def handle_info({ref, {:review_reconcile_result, result}}, orchestrator)
      when is_reference(ref) do
    case orchestrator.review_task do
      %{ref: ^ref} = task_meta ->
        Process.demonitor(ref, [:flush])
        if task_meta.timer_ref, do: Process.cancel_timer(task_meta.timer_ref)
        log_review_reconcile_result(result)
        {:noreply, %{orchestrator | review_task: nil}}

      _ ->
        {:noreply, orchestrator}
    end
  end

  def handle_info({:review_reconcile_timeout, ref}, orchestrator) when is_reference(ref) do
    case orchestrator.review_task do
      %{ref: ^ref, task: task} ->
        Process.demonitor(ref, [:flush])
        shutdown_task(task)

        Logging.log_event(:warning, "review_reconcile_timed_out",
          timeout_ms: review_reconcile_timeout_ms()
        )

        {:noreply, %{orchestrator | review_task: nil}}

      _ ->
        {:noreply, orchestrator}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, orchestrator) do
    {issue_id, worker_tasks} = Map.pop(orchestrator.worker_tasks, ref)
    {summary_meta, summary_tasks} = Map.pop(orchestrator.summary_tasks, ref)

    cond do
      issue_id ->
        orchestrator = %{orchestrator | worker_tasks: worker_tasks}

        result = %AgentRunResult{
          issue_id: issue_id,
          normal: false,
          reason: "worker crashed: #{inspect(reason)}"
        }

        {:noreply,
         orchestrator |> handle_worker_done(issue_id, result) |> publish_snapshot_cache()}

      summary_meta ->
        if summary_meta.timer_ref, do: Process.cancel_timer(summary_meta.timer_ref)

        orchestrator =
          %{orchestrator | summary_tasks: summary_tasks}
          |> apply_summary_result(
            summary_meta.issue_id,
            summary_meta.activity_revision,
            {:error, "summary worker crashed: #{inspect(reason)}"}
          )
          |> publish_snapshot_cache()

        {:noreply, orchestrator}

      orchestrator.review_task && orchestrator.review_task.ref == ref ->
        if orchestrator.review_task.timer_ref,
          do: Process.cancel_timer(orchestrator.review_task.timer_ref)

        Logging.log_event(:warning, "review_reconcile_task_exited", reason: inspect(reason))

        {:noreply, %{orchestrator | review_task: nil}}

      true ->
        {:noreply, orchestrator}
    end
  end

  def handle_info({:EXIT, _source, :normal}, orchestrator), do: {:noreply, orchestrator}

  def handle_info({:EXIT, source, reason}, orchestrator) do
    Logging.log_event(:warning, "linked_process_exited",
      source: inspect(source),
      reason: inspect(reason)
    )

    {:noreply, orchestrator}
  end

  def handle_info(message, orchestrator) do
    Logging.log_event(:debug, "unexpected_orchestrator_message", message: inspect(message))
    {:noreply, orchestrator}
  end

  @impl true
  def terminate(_reason, orchestrator) do
    Enum.each(orchestrator.state.retry_attempts, fn {_issue_id, retry} ->
      if retry.timer_ref, do: Process.cancel_timer(retry.timer_ref)
    end)

    Enum.each(orchestrator.state.running, fn {_issue_id, entry} ->
      shutdown_task(entry.task)
    end)

    Enum.each(orchestrator.summary_tasks, fn {ref, meta} ->
      if meta.timer_ref, do: Process.cancel_timer(meta.timer_ref)
      Process.demonitor(ref, [:flush])
      shutdown_task(meta.task)
    end)

    if orchestrator.review_task do
      if orchestrator.review_task.timer_ref,
        do: Process.cancel_timer(orchestrator.review_task.timer_ref)

      Process.demonitor(orchestrator.review_task.ref, [:flush])
      shutdown_task(orchestrator.review_task.task)
    end

    if orchestrator.persist_timer_ref, do: Process.cancel_timer(orchestrator.persist_timer_ref)
    delete_snapshot_cache()
    persist_state(orchestrator)
    :ok
  end

  def new(%ConfigManager{} = manager, opts \\ []) do
    {manager, _workflow, config} = ConfigManager.current(manager)

    orchestrator = %__MODULE__{
      config_manager: manager,
      state: %RuntimeState{
        poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
      },
      review_resolver: Keyword.get(opts, :review_resolver, ReviewPullRequestResolver.new()),
      agent_runner: Keyword.get(opts, :agent_runner, Symphony.AgentRunner),
      dashboard_summary: Keyword.get(opts, :dashboard_summary, DashboardSummary),
      tracker_factory: Keyword.get(opts, :tracker_factory, &Tracker.make_tracker/1)
    }

    load_persisted_state(orchestrator)
  end

  def sort_for_dispatch(issues) do
    Enum.sort_by(issues, fn issue ->
      {issue.priority || 999_999, issue.created_at || Utils.now_utc(), issue.identifier}
    end)
  end

  def tick(%__MODULE__{} = orchestrator) do
    {manager, _changed?} = ConfigManager.reload_if_changed(orchestrator.config_manager)
    orchestrator = %{orchestrator | config_manager: manager}

    try do
      ConfigManager.validate_for_dispatch!(manager)
      {_manager, _workflow, config} = ConfigManager.current(manager)
      tracker = Tracker.make_tracker(config.tracker)

      orchestrator = %{
        orchestrator
        | state: %{
            orchestrator.state
            | service_status: "polling",
              last_poll_started_at: Utils.now_utc(),
              last_poll_error: nil
          }
      }

      orchestrator = process_due_retries(orchestrator, tracker, config)
      candidates = call_tracker(tracker, :fetch_candidate_issues, [])

      orchestrator =
        reconcile_blocked_issues(orchestrator, candidates, config,
          candidate_snapshot_complete: true
        )

      orchestrator =
        candidates
        |> sort_for_dispatch()
        |> Enum.reduce(orchestrator, fn issue, acc ->
          if available_global_slots(acc, config) > 0 and is_dispatch_eligible(acc, issue, config) do
            dispatch_issue_sync(acc, issue, tracker)
          else
            acc
          end
        end)

      orchestrator = safe_reconcile_review_issues(orchestrator, tracker, config)

      state = %{
        orchestrator.state
        | service_status: "running",
          last_poll_completed_at: Utils.now_utc(),
          last_candidate_count: length(candidates),
          last_poll_error: nil
      }

      persist_state(%{orchestrator | state: state})
    rescue
      error ->
        state = %{
          orchestrator.state
          | service_status: "degraded",
            last_poll_completed_at: Utils.now_utc(),
            last_poll_error: Utils.truncate(Exception.message(error), 500)
        }

        persist_state(%{orchestrator | state: state})
    end
  end

  defp request_refresh_internal(%{refreshing: true} = orchestrator),
    do: %{orchestrator | refresh_requested: true}

  defp request_refresh_internal(orchestrator) do
    if orchestrator.refresh_timer_ref, do: Process.cancel_timer(orchestrator.refresh_timer_ref)
    ref = Process.send_after(self(), :run_refresh, 0)
    %{orchestrator | refresh_timer_ref: ref, refresh_requested: false}
  end

  defp schedule_next_refresh(orchestrator) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    if orchestrator.refresh_timer_ref, do: Process.cancel_timer(orchestrator.refresh_timer_ref)
    ref = Process.send_after(self(), :run_refresh, config.polling.interval_ms)
    %{orchestrator | refresh_timer_ref: ref, refresh_requested: false}
  end

  defp tick_runtime(%__MODULE__{} = orchestrator) do
    {manager, _changed?} = ConfigManager.reload_if_changed(orchestrator.config_manager)
    orchestrator = %{orchestrator | config_manager: manager}

    {_manager, _workflow, config} = ConfigManager.current(manager)
    tracker = make_tracker(orchestrator, config.tracker)

    orchestrator =
      %{
        orchestrator
        | state: %{
            orchestrator.state
            | service_status: "polling",
              poll_interval_ms: config.polling.interval_ms,
              max_concurrent_agents: config.agent.max_concurrent_agents,
              last_poll_started_at: Utils.now_utc(),
              last_poll_error: nil
          }
      }
      |> reconcile_running_issues(tracker, config)

    try do
      ConfigManager.validate_for_dispatch!(manager)

      candidates = call_tracker(tracker, :fetch_candidate_issues, [])

      orchestrator =
        reconcile_blocked_issues(orchestrator, candidates, config,
          candidate_snapshot_complete: true
        )

      orchestrator =
        candidates
        |> sort_for_dispatch()
        |> Enum.reduce(orchestrator, fn issue, acc ->
          if available_global_slots(acc, config) > 0 and is_dispatch_eligible(acc, issue, config) do
            dispatch_issue_async(acc, issue, tracker)
          else
            acc
          end
        end)

      state = %{
        orchestrator.state
        | service_status: "running",
          last_poll_completed_at: Utils.now_utc(),
          last_candidate_count: length(candidates),
          last_poll_error: nil
      }

      orchestrator
      |> Map.put(:state, state)
      |> persist_state()
      |> start_review_reconciliation(tracker, config)
    rescue
      error ->
        state = %{
          orchestrator.state
          | service_status: "degraded",
            last_poll_completed_at: Utils.now_utc(),
            last_poll_error: Utils.truncate(Exception.message(error), 500)
        }

        Logging.log_event(:error, "poll_failed", reason: Exception.message(error))
        persist_state(%{orchestrator | state: state})
    end
  end

  def startup_terminal_workspace_cleanup(%__MODULE__{} = orchestrator) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    tracker = make_tracker(orchestrator, config.tracker)

    terminal =
      try do
        call_tracker(tracker, :fetch_issues_by_states, [config.tracker.terminal_states])
      rescue
        error ->
          Logging.log_event(:warning, "startup_cleanup_failed", reason: Exception.message(error))
          []
      end

    workspace_manager = WorkspaceManager.new(config.workspace, config.hooks)
    Enum.each(terminal, &WorkspaceManager.remove_for_identifier(workspace_manager, &1.identifier))
    orchestrator
  end

  def reconcile_running_issues(%__MODULE__{} = orchestrator, tracker, %ServiceConfig{} = config) do
    orchestrator = reconcile_stalled(orchestrator, config)
    running_ids = Map.keys(orchestrator.state.running)

    if running_ids == [] do
      orchestrator
    else
      refreshed =
        try do
          call_tracker(tracker, :fetch_issue_states_by_ids, [running_ids])
        rescue
          error ->
            Logging.log_event(:warning, "running_state_refresh_failed",
              reason: Exception.message(error)
            )

            []
        end

      refreshed_by_id = Map.new(refreshed, &{&1.id, &1})

      Enum.reduce(running_ids, orchestrator, fn issue_id, acc ->
        case refreshed_by_id[issue_id] do
          nil ->
            acc

          %Issue{} = issue ->
            state = Utils.normalize_state(issue.state)

            cond do
              MapSet.member?(TrackerConfig.terminal_state_set(config.tracker), state) ->
                terminate_running_issue(acc, issue_id,
                  cleanup_workspace: true,
                  retry: false,
                  reason: "terminal_state"
                )

              !has_required_labels?(issue, config) ->
                terminate_running_issue(acc, issue_id,
                  cleanup_workspace: false,
                  retry: false,
                  reason: "required_label_removed"
                )

              MapSet.member?(TrackerConfig.active_state_set(config.tracker), state) ->
                update_in(acc.state.running[issue_id].issue, fn _ -> issue end)

              true ->
                terminate_running_issue(acc, issue_id,
                  cleanup_workspace: false,
                  retry: false,
                  reason: "non_active_state"
                )
            end
        end
      end)
    end
  end

  def reconcile_blocked_issues(orchestrator, candidates, config, opts \\ [])

  def reconcile_blocked_issues(
        %__MODULE__{} = orchestrator,
        candidates,
        %ServiceConfig{} = config,
        opts
      )
      when is_list(candidates) do
    candidates_by_id = Map.new(candidates, &{&1.id, &1})
    candidate_snapshot_complete? = Keyword.get(opts, :candidate_snapshot_complete, false)

    orchestrator.state.blocked
    |> Enum.reduce(orchestrator, fn {issue_id, blocked}, acc ->
      current_issue = candidates_by_id[issue_id]
      issue = current_issue || blocked.issue

      cond do
        candidate_snapshot_complete? and is_nil(current_issue) ->
          release_blocked_issue(acc, issue_id, "blocked issue is no longer a candidate")

        !blocked_issue_still_active?(issue, config) ->
          release_blocked_issue(acc, issue_id, "blocked issue is no longer dispatchable")

        !blocked_rules_tie?(blocked) ->
          acc

        true ->
          rules_config = %{config.repositories | planner: "rules"}

          plan =
            RepoPlanner.plan_repositories(
              issue,
              rules_config,
              config.context.coding,
              %CodingClassification{is_coding_task: true, source: "blocked_reconcile"}
            )

          if plan && !plan.needs_human do
            Logging.log_event(:info, "repo_plan_block_released",
              issue_id: issue.id,
              issue_identifier: issue.identifier,
              primary_repo: plan.primary_repo && plan.primary_repo.slug
            )

            release_blocked_issue(acc, issue_id, "rules repo plan no longer needs human")
          else
            acc
          end
      end
    end)
  end

  def reconcile_blocked_issues(%__MODULE__{} = orchestrator, _candidates, _config, _opts),
    do: orchestrator

  defp blocked_rules_tie?(%BlockedEntry{repo_plan: %RepoPlan{} = plan}) do
    to_string(plan.source) =~ "rules" and plan.needs_human and
      to_string(plan.human_reason) =~ "Rules planner found tied primary repositories"
  end

  defp blocked_rules_tie?(_blocked), do: false

  defp blocked_issue_still_active?(%Issue{} = issue, %ServiceConfig{} = config) do
    state = Utils.normalize_state(issue.state)

    MapSet.member?(TrackerConfig.active_state_set(config.tracker), state) and
      has_required_labels?(issue, config)
  end

  defp release_blocked_issue(%__MODULE__{} = orchestrator, issue_id, _reason) do
    state = %{
      orchestrator.state
      | blocked: Map.delete(orchestrator.state.blocked, issue_id),
        claimed: MapSet.delete(orchestrator.state.claimed, issue_id)
    }

    %{orchestrator | state: state}
  end

  defp reconcile_stalled(%__MODULE__{} = orchestrator, %ServiceConfig{} = config) do
    if config.codex.stall_timeout_ms <= 0 do
      orchestrator
    else
      now = Utils.now_utc()

      orchestrator.state.running
      |> Enum.filter(fn {_issue_id, entry} ->
        since = entry.last_codex_timestamp || entry.started_at || now
        DateTime.diff(now, since, :millisecond) > config.codex.stall_timeout_ms
      end)
      |> Enum.reduce(orchestrator, fn {issue_id, _entry}, acc ->
        terminate_running_issue(acc, issue_id,
          cleanup_workspace: false,
          retry: true,
          reason: "stalled"
        )
      end)
    end
  end

  def terminate_running_issue(%__MODULE__{} = orchestrator, issue_id, opts) do
    cleanup_workspace = Keyword.fetch!(opts, :cleanup_workspace)
    retry? = Keyword.fetch!(opts, :retry)
    reason = Keyword.fetch!(opts, :reason)

    case orchestrator.state.running[issue_id] do
      nil ->
        orchestrator

      entry ->
        entry = %{
          entry
          | forced_outcome: if(retry?, do: "retry", else: "release"),
            forced_error: reason,
            cleanup_workspace: cleanup_workspace
        }

        shutdown_task(entry.task)

        state = %{
          orchestrator.state
          | running: Map.put(orchestrator.state.running, issue_id, entry)
        }

        %{orchestrator | state: state}
    end
  end

  defp dispatch_issue_async(
         %__MODULE__{} = orchestrator,
         %Issue{} = issue,
         tracker,
         attempt \\ nil
       ) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    workspace_manager = WorkspaceManager.new(config.workspace, config.hooks)
    server = self()
    runner_module = orchestrator.agent_runner

    task =
      Task.Supervisor.async_nolink(orchestrator.task_supervisor, fn ->
        runner = apply(runner_module, :new, [orchestrator.config_manager, tracker])

        apply(runner_module, :run_issue, [
          runner,
          issue,
          attempt,
          fn issue_id, event -> GenServer.cast(server, {:codex_event, issue_id, event}) end
        ])
      end)

    entry = %RunningEntry{
      issue: issue,
      task: task,
      workspace_path:
        WorkspaceManager.workspace_path_for_identifier(workspace_manager, issue.identifier),
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond),
      retry_attempt: attempt
    }

    retry = orchestrator.state.retry_attempts[issue.id]
    if retry && retry.timer_ref, do: Process.cancel_timer(retry.timer_ref)

    state = %{
      orchestrator.state
      | running: Map.put(orchestrator.state.running, issue.id, entry),
        retry_attempts: Map.delete(orchestrator.state.retry_attempts, issue.id),
        claimed: MapSet.put(orchestrator.state.claimed, issue.id)
    }

    orchestrator =
      %{
        orchestrator
        | state: state,
          worker_tasks: Map.put(orchestrator.worker_tasks, task.ref, issue.id)
      }
      |> persist_state()

    Logging.log_event(:info, "issue_dispatched",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      attempt: attempt
    )

    orchestrator
  end

  defp schedule_retry_runtime(%__MODULE__{} = orchestrator, %Issue{} = issue, attempt, opts) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)

    delay_ms =
      Keyword.get(opts, :delay_ms) ||
        min(10_000 * trunc(:math.pow(2, max(attempt - 1, 0))), config.agent.max_retry_backoff_ms)

    error = Keyword.get(opts, :error)
    timer_ref = Process.send_after(self(), {:retry_due, issue.id}, delay_ms)

    entry = %RetryEntry{
      issue_id: issue.id,
      identifier: issue.identifier,
      attempt: attempt,
      due_at_monotonic: System.monotonic_time(:millisecond) + delay_ms,
      due_at_wall: DateTime.add(Utils.now_utc(), delay_ms, :millisecond),
      error: error,
      timer_ref: timer_ref
    }

    old = orchestrator.state.retry_attempts[issue.id]
    if old && old.timer_ref, do: Process.cancel_timer(old.timer_ref)

    state = %{
      orchestrator.state
      | retry_attempts: Map.put(orchestrator.state.retry_attempts, issue.id, entry),
        claimed: MapSet.put(orchestrator.state.claimed, issue.id)
    }

    %{orchestrator | state: state}
    |> persist_state()
  end

  defp restore_retry_timers(%__MODULE__{} = orchestrator) do
    now = Utils.now_utc()

    retry_attempts =
      Map.new(orchestrator.state.retry_attempts, fn {issue_id, retry} ->
        delay_ms = max(DateTime.diff(retry.due_at_wall, now, :millisecond), 0)
        timer_ref = Process.send_after(self(), {:retry_due, issue_id}, delay_ms)

        {issue_id,
         %{
           retry
           | due_at_monotonic: System.monotonic_time(:millisecond) + delay_ms,
             timer_ref: timer_ref
         }}
      end)

    %{orchestrator | state: %{orchestrator.state | retry_attempts: retry_attempts}}
  end

  defp maybe_schedule_summary(%__MODULE__{} = orchestrator, issue_id) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    entry = orchestrator.state.running[issue_id]

    if should_schedule_summary?(entry, config) do
      entry = %{entry | summary_pending: true}

      state = %{
        orchestrator.state
        | running: Map.put(orchestrator.state.running, issue_id, entry)
      }

      orchestrator = %{orchestrator | state: state} |> schedule_persist_state()
      summary_module = orchestrator.dashboard_summary
      activity_revision = entry.activity_revision
      activity = Enum.take(entry.recent_activity, -config.dashboard.summary_max_events)

      task =
        Task.Supervisor.async_nolink(orchestrator.task_supervisor, fn ->
          result =
            try do
              {:ok,
               apply(summary_module, :summarize_activity, [
                 [
                   issue: entry.issue,
                   activity: activity,
                   previous_summary: entry.summary_text,
                   codex_config: config.codex,
                   dashboard_config: config.dashboard,
                   workspace_path: entry.workspace_path
                 ]
               ])}
            rescue
              error -> {:error, Utils.truncate(Exception.message(error), 500)}
            end

          {:summary_result, issue_id, activity_revision, result}
        end)

      timer_ref =
        Process.send_after(
          self(),
          {:summary_timeout, task.ref},
          config.dashboard.summary_timeout_ms
        )

      meta = %{
        issue_id: issue_id,
        task: task,
        timer_ref: timer_ref,
        activity_revision: activity_revision,
        timeout_ms: config.dashboard.summary_timeout_ms
      }

      %{orchestrator | summary_tasks: Map.put(orchestrator.summary_tasks, task.ref, meta)}
    else
      orchestrator
    end
  end

  defp should_schedule_summary?(nil, _config), do: false

  defp should_schedule_summary?(entry, %ServiceConfig{} = config) do
    ((config.dashboard.summaries_enabled and !entry.summary_pending and entry.workspace_path) &&
       entry.activity_revision > entry.summary_revision) and entry.recent_activity != [] and
      has_work_signal?(entry.recent_activity) and
      (is_nil(entry.summary_text) or
         System.monotonic_time(:millisecond) - entry.last_summary_monotonic >=
           config.dashboard.summary_update_interval_ms)
  end

  defp has_work_signal?(activity) do
    Enum.any?(activity, fn item ->
      message = to_string(item["message"] || "")

      Enum.any?(
        ["Agent said:", "Command ", "File change ", "The agent requested user input"],
        &String.starts_with?(message, &1)
      )
    end)
  end

  defp apply_summary_result(orchestrator, issue_id, activity_revision, result) do
    case orchestrator.state.running[issue_id] do
      nil ->
        orchestrator

      entry ->
        entry =
          case result do
            {:ok, %DashboardSummary{} = summary} ->
              %{
                entry
                | summary_pending: false,
                  summary_revision: max(entry.summary_revision, activity_revision),
                  summary_text: summary.summary,
                  summary_current_step: summary.current_step,
                  summary_needs_human: summary.needs_human,
                  summary_human_reason: summary.human_reason,
                  summary_risk: summary.risk,
                  summary_confidence: summary.confidence,
                  summary_updated_at: Utils.now_utc(),
                  summary_error: nil,
                  summary_source: "llm",
                  last_summary_monotonic: System.monotonic_time(:millisecond)
              }

            {:error, reason} ->
              %{
                entry
                | summary_pending: false,
                  summary_revision: max(entry.summary_revision, activity_revision),
                  summary_error: reason,
                  summary_updated_at: Utils.now_utc(),
                  summary_source: "llm",
                  last_summary_monotonic: System.monotonic_time(:millisecond)
              }
          end

        state = %{
          orchestrator.state
          | running: Map.put(orchestrator.state.running, issue_id, entry)
        }

        persist_state(%{orchestrator | state: state})
    end
  end

  defp make_tracker(%__MODULE__{} = orchestrator, %TrackerConfig{} = config) do
    orchestrator.tracker_factory.(config)
  end

  defp schedule_retry_for(%__MODULE__{task_supervisor: nil} = orchestrator, issue, attempt, opts),
    do: schedule_retry(orchestrator, issue, attempt, opts)

  defp schedule_retry_for(%__MODULE__{} = orchestrator, issue, attempt, opts),
    do: schedule_retry_runtime(orchestrator, issue, attempt, opts)

  defp cleanup_workspace(%__MODULE__{} = orchestrator, %Issue{} = issue) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)

    config.workspace
    |> WorkspaceManager.new(config.hooks)
    |> WorkspaceManager.remove_for_identifier(issue.identifier)
  end

  defp shutdown_task(%Task{} = task), do: Task.shutdown(task, :brutal_kill)
  defp shutdown_task(_task), do: :ok

  def available_global_slots(%__MODULE__{} = orchestrator, %ServiceConfig{} = config) do
    max(config.agent.max_concurrent_agents - map_size(orchestrator.state.running), 0)
  end

  def is_dispatch_eligible(
        %__MODULE__{} = orchestrator,
        %Issue{} = issue,
        %ServiceConfig{} = config,
        opts \\ []
      ) do
    ignore_claimed_issue_id = Keyword.get(opts, :ignore_claimed_issue_id)
    state = Utils.normalize_state(issue.state)

    cond do
      blank?(issue.id) or blank?(issue.identifier) or blank?(issue.title) or blank?(issue.state) ->
        false

      !MapSet.member?(TrackerConfig.active_state_set(config.tracker), state) or
          MapSet.member?(TrackerConfig.terminal_state_set(config.tracker), state) ->
        false

      !has_required_labels?(issue, config) ->
        false

      Map.has_key?(orchestrator.state.running, issue.id) ->
        false

      Map.has_key?(orchestrator.state.blocked, issue.id) ->
        false

      MapSet.member?(orchestrator.state.claimed, issue.id) and issue.id != ignore_claimed_issue_id ->
        false

      available_global_slots(orchestrator, config) <= 0 ->
        false

      state_running_count(orchestrator, state) >=
          Map.get(
            config.agent.max_concurrent_agents_by_state,
            state,
            config.agent.max_concurrent_agents
          ) ->
        false

      state == "todo" and
          Enum.any?(
            issue.blocked_by,
            &(not MapSet.member?(
                TrackerConfig.terminal_state_set(config.tracker),
                Utils.normalize_state(&1.state)
              ))
          ) ->
        false

      true ->
        true
    end
  end

  defp start_review_reconciliation(
         %__MODULE__{} = orchestrator,
         tracker,
         %ServiceConfig{} = config
       ) do
    cond do
      !review_reconcile_supported?(tracker, config) ->
        orchestrator

      orchestrator.review_task ->
        orchestrator

      is_nil(orchestrator.task_supervisor) ->
        safe_reconcile_review_issues(orchestrator, tracker, config)

      true ->
        task =
          Task.Supervisor.async_nolink(orchestrator.task_supervisor, fn ->
            {:review_reconcile_result, run_review_reconciliation(orchestrator, tracker, config)}
          end)

        timer_ref =
          Process.send_after(
            self(),
            {:review_reconcile_timeout, task.ref},
            review_reconcile_timeout_ms()
          )

        %{
          orchestrator
          | review_task: %{
              ref: task.ref,
              task: task,
              timer_ref: timer_ref,
              started_at: Utils.now_utc()
            }
        }
    end
  end

  defp safe_reconcile_review_issues(
         %__MODULE__{} = orchestrator,
         tracker,
         %ServiceConfig{} = config
       ) do
    if review_reconcile_supported?(tracker, config) do
      parent = self()
      ref = make_ref()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          send(parent, {ref, run_review_reconciliation(orchestrator, tracker, config)})
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          log_review_reconcile_result(result)
          orchestrator

        {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
          Logging.log_event(:warning, "review_reconcile_task_exited", reason: inspect(reason))
          orchestrator
      after
        review_reconcile_timeout_ms() ->
          Process.demonitor(monitor_ref, [:flush])
          Process.exit(pid, :kill)

          Logging.log_event(:warning, "review_reconcile_timed_out",
            timeout_ms: review_reconcile_timeout_ms()
          )

          orchestrator
      end
    else
      orchestrator
    end
  end

  defp run_review_reconciliation(orchestrator, tracker, config) do
    reconcile_review_issues(orchestrator, tracker, config)
    :ok
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp review_reconcile_supported?(tracker, %ServiceConfig{} = config),
    do: config.tracker.review_states != [] and tracker_supports?(tracker, :save_issue_state)

  defp review_reconcile_timeout_ms do
    Application.get_env(
      :caretta_symphony,
      :review_reconcile_timeout_ms,
      @review_reconcile_timeout_ms
    )
  end

  defp log_review_reconcile_result(:ok), do: :ok

  defp log_review_reconcile_result({:error, reason}) do
    Logging.log_event(:warning, "review_reconcile_failed", reason: Utils.truncate(reason, 500))
  end

  def reconcile_review_issues(%__MODULE__{} = orchestrator, tracker, %ServiceConfig{} = config) do
    if config.tracker.review_states == [] or !tracker_supports?(tracker, :save_issue_state) do
      orchestrator
    else
      review_issues =
        try do
          call_tracker(tracker, :fetch_issues_by_states, [config.tracker.review_states])
        rescue
          _ -> []
        end

      refreshed =
        try do
          call_tracker(tracker, :fetch_issue_states_by_ids, [Enum.map(review_issues, & &1.id)])
        rescue
          _ -> review_issues
        end

      workspace_manager = WorkspaceManager.new(config.workspace, config.hooks)

      refreshed
      |> dedupe_by_id()
      |> Enum.each(fn issue ->
        if has_required_labels?(issue, config) do
          comments =
            if tracker_supports?(tracker, :list_issue_comments) do
              try do
                call_tracker(tracker, :list_issue_comments, [issue.identifier])
              rescue
                _ -> []
              end
            else
              []
            end

          workspace_path =
            WorkspaceManager.workspace_path_for_identifier(workspace_manager, issue.identifier)

          result =
            evaluate_review(orchestrator.review_resolver, issue,
              comments: comments,
              workspace_path: workspace_path,
              base_branch: config.tracker.merge_base_branch
            )

          if result.ready do
            call_tracker(tracker, :save_issue_state, [issue.identifier, config.tracker.done_state])
          end
        end
      end)

      orchestrator
    end
  end

  def dispatch_issue_sync(%__MODULE__{} = orchestrator, %Issue{} = issue, tracker, attempt \\ nil) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    workspace_manager = WorkspaceManager.new(config.workspace, config.hooks)

    entry = %RunningEntry{
      issue: issue,
      workspace_path:
        WorkspaceManager.workspace_path_for_identifier(workspace_manager, issue.identifier),
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond),
      retry_attempt: attempt
    }

    orchestrator = %{
      orchestrator
      | state: %{
          orchestrator.state
          | running: Map.put(orchestrator.state.running, issue.id, entry),
            claimed: MapSet.put(orchestrator.state.claimed, issue.id)
        }
    }

    {:ok, holder} = Agent.start_link(fn -> orchestrator end)

    result =
      Symphony.AgentRunner.new(orchestrator.config_manager, tracker)
      |> Symphony.AgentRunner.run_issue(issue, attempt, fn issue_id, event ->
        Agent.update(holder, &handle_codex_event(&1, issue_id, event))
      end)

    orchestrator = Agent.get(holder, & &1)
    Agent.stop(holder)
    handle_worker_done(orchestrator, issue.id, result)
  end

  def schedule_retry(%__MODULE__{} = orchestrator, %Issue{} = issue, attempt, opts \\ []) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)

    delay_ms =
      Keyword.get(opts, :delay_ms) ||
        min(10_000 * trunc(:math.pow(2, max(attempt - 1, 0))), config.agent.max_retry_backoff_ms)

    error = Keyword.get(opts, :error)
    due_at_monotonic = System.monotonic_time(:millisecond) + delay_ms

    entry = %RetryEntry{
      issue_id: issue.id,
      identifier: issue.identifier,
      attempt: attempt,
      due_at_monotonic: due_at_monotonic,
      due_at_wall: DateTime.add(Utils.now_utc(), delay_ms, :millisecond),
      error: error
    }

    old = orchestrator.state.retry_attempts[issue.id]
    if old && old.timer_ref, do: Process.cancel_timer(old.timer_ref)

    state = %{
      orchestrator.state
      | retry_attempts: Map.put(orchestrator.state.retry_attempts, issue.id, entry),
        claimed: MapSet.put(orchestrator.state.claimed, issue.id)
    }

    persist_state(%{orchestrator | state: state})
  end

  def process_due_retries(%__MODULE__{} = orchestrator, tracker, %ServiceConfig{} = config) do
    now = System.monotonic_time(:millisecond)

    orchestrator.state.retry_attempts
    |> Map.values()
    |> Enum.filter(&(&1.due_at_monotonic <= now))
    |> Enum.sort_by(& &1.due_at_monotonic)
    |> Enum.reduce(orchestrator, fn retry, acc ->
      if available_global_slots(acc, config) > 0 do
        state = %{
          acc.state
          | retry_attempts: Map.delete(acc.state.retry_attempts, retry.issue_id)
        }

        acc = %{acc | state: state}
        issue = refresh_retry_issue(tracker, retry)

        if MapSet.member?(
             TrackerConfig.active_state_set(config.tracker),
             Utils.normalize_state(issue.state)
           ) do
          dispatch_issue_sync(acc, issue, tracker, retry.attempt)
        else
          persist_state(acc)
        end
      else
        acc
      end
    end)
  end

  def handle_worker_done(%__MODULE__{} = orchestrator, issue_id, %AgentRunResult{} = result) do
    {entry, running} = Map.pop(orchestrator.state.running, issue_id)

    if is_nil(entry) do
      orchestrator
    else
      elapsed = max((System.monotonic_time(:millisecond) - entry.started_monotonic) / 1000, 0)

      state = %{
        orchestrator.state
        | running: running,
          codex_totals: %{
            orchestrator.state.codex_totals
            | seconds_running: orchestrator.state.codex_totals.seconds_running + elapsed
          }
      }

      orchestrator = %{orchestrator | state: state}

      cond do
        entry.forced_outcome == "release" ->
          if entry.cleanup_workspace, do: cleanup_workspace(orchestrator, entry.issue)

          state = %{
            orchestrator.state
            | claimed: MapSet.delete(orchestrator.state.claimed, issue_id)
          }

          persist_state(%{orchestrator | state: state})

        entry.forced_outcome == "retry" ->
          schedule_retry_for(orchestrator, entry.issue, (entry.retry_attempt || 0) + 1,
            error: entry.forced_error || "worker cancelled"
          )

        result.normal ->
          completed = completed_entry_from_running(entry, result.reason, elapsed)

          state = %{
            orchestrator.state
            | completed: Map.put(orchestrator.state.completed, issue_id, completed),
              claimed: MapSet.put(orchestrator.state.claimed, issue_id)
          }

          orchestrator
          |> Map.put(:state, state)
          |> persist_state()
          |> schedule_retry_for(entry.issue, 1, delay_ms: @continuation_retry_ms, error: nil)

        result.blocked ->
          blocked = %BlockedEntry{
            issue: entry.issue,
            reason:
              if(result.repo_plan && result.repo_plan.human_reason,
                do: result.repo_plan.human_reason,
                else: result.reason
              ),
            blocked_at: Utils.now_utc(),
            workspace_path: entry.workspace_path,
            repo_plan: result.repo_plan
          }

          state = %{
            orchestrator.state
            | blocked: Map.put(orchestrator.state.blocked, issue_id, blocked),
              claimed: MapSet.put(orchestrator.state.claimed, issue_id)
          }

          persist_state(%{orchestrator | state: state})

        !result.retryable ->
          state = %{
            orchestrator.state
            | claimed: MapSet.delete(orchestrator.state.claimed, issue_id)
          }

          persist_state(%{orchestrator | state: state})

        true ->
          schedule_retry_for(orchestrator, entry.issue, (entry.retry_attempt || 0) + 1,
            error: result.reason
          )
      end
    end
  end

  def handle_codex_event(%__MODULE__{} = orchestrator, issue_id, event) do
    entry = orchestrator.state.running[issue_id]

    if is_nil(entry) do
      orchestrator
    else
      timestamp =
        if match?(%DateTime{}, event["timestamp"]), do: event["timestamp"], else: Utils.now_utc()

      entry =
        %{
          entry
          | last_codex_event: event["event"],
            last_codex_timestamp: timestamp,
            last_codex_message: event["message"],
            codex_app_server_pid: event["codex_app_server_pid"] || entry.codex_app_server_pid,
            thread_id: event["thread_id"] || entry.thread_id,
            turn_id: event["turn_id"] || entry.turn_id,
            session_id: event["session_id"] || entry.session_id,
            turn_count:
              entry.turn_count + if(event["event"] == "session_started", do: 1, else: 0),
            workspace_path: event["workspace_path"] || entry.workspace_path
        }

      entry =
        if event["event"] in ["repo_plan_created", "repo_workspace_prepared"] and
             is_map(event["repo_plan"]) do
          %{entry | repo_plan: repo_plan_from_map(event["repo_plan"])}
        else
          entry
        end

      deviation = repo_deviation_from_event(entry, event)

      entry =
        if deviation && deviation not in entry.repo_deviations,
          do: %{entry | repo_deviations: Enum.take(entry.repo_deviations ++ [deviation], -20)},
          else: entry

      {entry, totals} =
        if is_map(event["usage_absolute"]) do
          apply_usage(entry, orchestrator.state.codex_totals, event["usage_absolute"])
        else
          {entry, orchestrator.state.codex_totals}
        end

      entry = record_activity(entry, event, timestamp)

      state = %{
        orchestrator.state
        | running: Map.put(orchestrator.state.running, issue_id, entry),
          codex_totals: totals,
          codex_rate_limits:
            if(is_map(event["rate_limits"]),
              do: event["rate_limits"],
              else: orchestrator.state.codex_rate_limits
            )
      }

      %{orchestrator | state: state}
      |> schedule_persist_state()
    end
  end

  def cached_snapshot(pid) when is_pid(pid) do
    case :ets.whereis(@snapshot_cache_table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, pid) do
          [{^pid, snapshot}] -> snapshot
          _ -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  def cached_issue_snapshot(pid, issue_identifier) when is_pid(pid) do
    case cached_snapshot(pid) do
      nil -> nil
      state -> issue_snapshot_from_state(state, issue_identifier)
    end
  end

  def snapshot(pid) when is_pid(pid), do: snapshot(pid, @default_call_timeout_ms)

  def snapshot(%__MODULE__{} = orchestrator) do
    generated_at = Utils.now_utc()
    now_monotonic = System.monotonic_time(:millisecond)

    running =
      orchestrator.state.running
      |> Map.values()
      |> Enum.map(fn entry ->
        attention_override = attention_override(entry)

        repo_deviation_reason =
          if entry.repo_deviations == [],
            do: nil,
            else: entry.repo_deviations |> Enum.take(-3) |> Enum.join("; ")

        needs_human =
          entry.summary_needs_human or !is_nil(attention_override) or
            !is_nil(repo_deviation_reason)

        human_reason = repo_deviation_reason || entry.summary_human_reason || attention_override

        risk =
          if(attention_override || repo_deviation_reason,
            do: "high",
            else: entry.summary_risk || "unknown"
          )

        %{
          "issue_id" => entry.issue.id,
          "issue_identifier" => entry.issue.identifier,
          "state" => entry.issue.state,
          "session_id" => entry.session_id,
          "turn_count" => entry.turn_count,
          "last_event" => entry.last_codex_event,
          "last_message" => entry.last_codex_message,
          "started_at" => Utils.isoformat_z(entry.started_at),
          "last_event_at" => Utils.isoformat_z(entry.last_codex_timestamp),
          "elapsed_seconds" => max((now_monotonic - entry.started_monotonic) / 1000, 0),
          "title" => entry.issue.title,
          "url" => entry.issue.url,
          "priority" => entry.issue.priority,
          "labels" => entry.issue.labels,
          "updated_at" => Utils.isoformat_z(entry.issue.updated_at),
          "workspace" => %{"path" => entry.workspace_path && to_string(entry.workspace_path)},
          "repo_plan" => entry.repo_plan && RepoPlan.to_map(entry.repo_plan),
          "repo_deviations" => entry.repo_deviations,
          "tokens" => %{
            "input_tokens" => entry.codex_input_tokens,
            "output_tokens" => entry.codex_output_tokens,
            "total_tokens" => entry.codex_total_tokens
          },
          "summary" => %{
            "text" => entry.summary_text,
            "current_step" => entry.summary_current_step,
            "needs_human" => needs_human,
            "human_reason" => human_reason,
            "risk" => risk,
            "confidence" => entry.summary_confidence,
            "updated_at" => Utils.isoformat_z(entry.summary_updated_at),
            "pending" => entry.summary_pending,
            "stale" => entry.activity_revision > entry.summary_revision,
            "error" => entry.summary_error,
            "source" => entry.summary_source
          },
          "activity" => Enum.take(entry.recent_activity, -12)
        }
      end)

    retrying =
      orchestrator.state.retry_attempts
      |> Map.values()
      |> Enum.map(fn retry ->
        kind = if is_nil(retry.error), do: "continuation", else: "retry"

        %{
          "issue_id" => retry.issue_id,
          "issue_identifier" => retry.identifier,
          "kind" => kind,
          "status" => if(kind == "continuation", do: "continuing", else: "retrying"),
          "attempt" => retry.attempt,
          "due_at" => Utils.isoformat_z(retry.due_at_wall),
          "due_in_seconds" => max((retry.due_at_monotonic - now_monotonic) / 1000, 0),
          "error" => retry.error
        }
      end)

    continuing_count = Enum.count(retrying, &(&1["kind"] == "continuation"))
    retrying_count = length(retrying) - continuing_count

    blocked =
      orchestrator.state.blocked
      |> Map.values()
      |> Enum.map(fn blocked ->
        %{
          "issue_id" => blocked.issue.id,
          "issue_identifier" => blocked.issue.identifier,
          "title" => blocked.issue.title,
          "url" => blocked.issue.url,
          "state" => blocked.issue.state,
          "labels" => blocked.issue.labels,
          "blocked_at" => Utils.isoformat_z(blocked.blocked_at),
          "reason" => blocked.reason,
          "workspace" => %{"path" => blocked.workspace_path && to_string(blocked.workspace_path)},
          "repo_plan" => blocked.repo_plan && RepoPlan.to_map(blocked.repo_plan)
        }
      end)

    completed =
      orchestrator.state.completed
      |> Map.values()
      |> Enum.sort_by(&DateTime.to_unix(&1.completed_at, :microsecond), :desc)
      |> Enum.map(&completed_entry_snapshot/1)

    active_runtime =
      orchestrator.state.running
      |> Map.values()
      |> Enum.reduce(0.0, fn entry, acc ->
        acc + max((now_monotonic - entry.started_monotonic) / 1000, 0)
      end)

    totals = CodexTotals.to_map(orchestrator.state.codex_totals)
    totals = Map.update!(totals, "seconds_running", &(&1 + active_runtime))

    %{
      "generated_at" => Utils.isoformat_z(generated_at),
      "service" => %{
        "status" => orchestrator.state.service_status,
        "startup_completed_at" => Utils.isoformat_z(orchestrator.state.startup_completed_at),
        "last_poll_started_at" => Utils.isoformat_z(orchestrator.state.last_poll_started_at),
        "last_poll_completed_at" => Utils.isoformat_z(orchestrator.state.last_poll_completed_at),
        "last_poll_error" => orchestrator.state.last_poll_error,
        "last_candidate_count" => orchestrator.state.last_candidate_count,
        "poll_interval_ms" => orchestrator.state.poll_interval_ms,
        "max_concurrent_agents" => orchestrator.state.max_concurrent_agents
      },
      "counts" => %{
        "running" => length(running),
        "continuing" => continuing_count,
        "retrying" => retrying_count,
        "queued" => length(retrying),
        "blocked" => length(blocked),
        "completed" => length(completed)
      },
      "running" => running,
      "retrying" => retrying,
      "blocked" => blocked,
      "completed" => completed,
      "codex_totals" => totals,
      "rate_limits" => orchestrator.state.codex_rate_limits
    }
  end

  def snapshot(pid, timeout) when is_pid(pid),
    do: GenServer.call(pid, :snapshot, timeout)

  def issue_snapshot(pid, issue_identifier) when is_pid(pid),
    do: issue_snapshot(pid, issue_identifier, @default_call_timeout_ms)

  def issue_snapshot(%__MODULE__{} = orchestrator, issue_identifier) do
    state = snapshot(orchestrator)
    issue_snapshot_from_state(state, issue_identifier)
  end

  defp issue_snapshot_from_state(state, issue_identifier) do
    cond do
      item = Enum.find(state["running"], &(&1["issue_identifier"] == issue_identifier)) ->
        %{
          "issue_identifier" => issue_identifier,
          "issue_id" => item["issue_id"],
          "status" => "running",
          "workspace" => item["workspace"],
          "running" => item
        }

      item = Enum.find(state["retrying"], &(&1["issue_identifier"] == issue_identifier)) ->
        %{
          "issue_identifier" => issue_identifier,
          "issue_id" => item["issue_id"],
          "status" => item["status"],
          "retry" => item,
          "last_error" => item["error"]
        }

      item = Enum.find(state["blocked"], &(&1["issue_identifier"] == issue_identifier)) ->
        %{
          "issue_identifier" => issue_identifier,
          "issue_id" => item["issue_id"],
          "status" => "blocked",
          "blocked" => item,
          "last_error" => item["reason"]
        }

      item = Enum.find(state["completed"], &(&1["issue_identifier"] == issue_identifier)) ->
        %{
          "issue_identifier" => issue_identifier,
          "issue_id" => item["issue_id"],
          "status" => "completed",
          "completed" => item,
          "recent_events" => item["activity"]
        }

      true ->
        nil
    end
  end

  def issue_snapshot(pid, issue_identifier, timeout) when is_pid(pid),
    do: GenServer.call(pid, {:issue_snapshot, issue_identifier}, timeout)

  def has_required_labels?(%Issue{} = issue, %ServiceConfig{} = config) do
    required = TrackerConfig.required_label_set(config.tracker)
    issue_labels = issue.labels |> Enum.map(&String.downcase/1) |> MapSet.new()
    MapSet.subset?(required, issue_labels)
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp state_running_count(orchestrator, state) do
    orchestrator.state.running
    |> Map.values()
    |> Enum.count(&(Utils.normalize_state(&1.issue.state) == state))
  end

  defp tracker_supports?(%{__struct__: module}, function),
    do: Enum.any?(1..3, &function_exported?(module, function, &1))

  defp tracker_supports?(tracker, function) when is_atom(tracker),
    do: Enum.any?(1..3, &function_exported?(tracker, function, &1))

  defp tracker_supports?(tracker, function) when is_map(tracker),
    do: Map.has_key?(tracker, function)

  defp tracker_supports?(_tracker, _function), do: true

  defp call_tracker(%{__struct__: module} = tracker, function, args),
    do: apply(module, function, [tracker | args])

  defp call_tracker(tracker, function, args) when is_atom(tracker),
    do: apply(tracker, function, args)

  defp call_tracker(tracker, function, args) when is_map(tracker),
    do: apply(Map.fetch!(tracker, function), args)

  defp refresh_retry_issue(tracker, %RetryEntry{} = retry) do
    case call_tracker(tracker, :fetch_issue_states_by_ids, [[retry.issue_id]]) do
      [%Issue{} = issue | _] ->
        issue

      _ ->
        %Issue{
          id: retry.issue_id,
          identifier: retry.identifier,
          title: "",
          state: "In Progress"
        }
    end
  rescue
    _ ->
      %Issue{
        id: retry.issue_id,
        identifier: retry.identifier,
        title: "",
        state: "In Progress"
      }
  end

  defp evaluate_review(%ReviewPullRequestResolver{} = resolver, issue, opts),
    do: ReviewPullRequestResolver.evaluate(resolver, issue, opts)

  defp evaluate_review(resolver, issue, opts) when is_map(resolver),
    do: resolver.evaluate.(issue, opts)

  defp evaluate_review(resolver, issue, opts) when is_atom(resolver),
    do: apply(resolver, :evaluate, [issue, opts])

  defp dedupe_by_id(issues) do
    issues
    |> Enum.reduce({MapSet.new(), []}, fn issue, {seen, acc} ->
      if MapSet.member?(seen, issue.id),
        do: {seen, acc},
        else: {MapSet.put(seen, issue.id), acc ++ [issue]}
    end)
    |> elem(1)
  end

  defp completed_entry_from_running(entry, reason, elapsed) do
    %CompletedEntry{
      issue: entry.issue,
      completed_at: Utils.now_utc(),
      reason: reason,
      workspace_path: entry.workspace_path,
      repo_plan: entry.repo_plan,
      duration_seconds: elapsed,
      turn_count: entry.turn_count,
      session_id: entry.session_id,
      thread_id: entry.thread_id,
      turn_id: entry.turn_id,
      codex_input_tokens: entry.codex_input_tokens,
      codex_output_tokens: entry.codex_output_tokens,
      codex_total_tokens: entry.codex_total_tokens,
      summary_text: entry.summary_text,
      summary_current_step: entry.summary_current_step,
      summary_needs_human: entry.summary_needs_human,
      summary_human_reason: entry.summary_human_reason,
      summary_risk: entry.summary_risk,
      summary_confidence: entry.summary_confidence,
      summary_updated_at: entry.summary_updated_at,
      repo_deviations: entry.repo_deviations,
      recent_activity: Enum.take(entry.recent_activity, -100)
    }
  end

  defp apply_usage(entry, totals, usage) do
    {entry, totals} =
      apply_usage_value(
        entry,
        totals,
        usage["input_tokens"],
        :last_reported_input_tokens,
        :codex_input_tokens,
        :input_tokens
      )

    {entry, totals} =
      apply_usage_value(
        entry,
        totals,
        usage["output_tokens"],
        :last_reported_output_tokens,
        :codex_output_tokens,
        :output_tokens
      )

    apply_usage_value(
      entry,
      totals,
      usage["total_tokens"],
      :last_reported_total_tokens,
      :codex_total_tokens,
      :total_tokens
    )
  end

  defp apply_usage_value(entry, totals, value, last_field, current_field, total_field) do
    case Utils.to_int(value) do
      nil ->
        {entry, totals}

      reported ->
        last_reported = Map.fetch!(entry, last_field)
        delta = max(reported - last_reported, 0)

        entry =
          entry
          |> Map.put(last_field, max(last_reported, reported))
          |> Map.put(current_field, reported)

        totals = Map.update!(totals, total_field, &(&1 + delta))
        {entry, totals}
    end
  end

  defp record_activity(entry, event, timestamp) do
    case activity_message(event) do
      nil ->
        entry

      message ->
        activity =
          entry.recent_activity ++
            [
              %{
                "at" => Utils.isoformat_z(timestamp),
                "event" => event["event"],
                "message" => Utils.truncate(message, 1000)
              }
            ]

        %{
          entry
          | recent_activity: Enum.take(activity, -100),
            activity_revision: entry.activity_revision + 1
        }
    end
  end

  defp activity_message(event) do
    name = to_string(event["event"] || "")

    if name in [
         "thread_tokenUsage_updated",
         "account_rateLimits_updated",
         "account_rateLimitsUpdated",
         "mcpServer_startupStatus_updated",
         "thread_started",
         "thread_status_changed",
         "item_agentMessage_delta",
         "item_commandExecution_outputDelta"
       ] do
      nil
    else
      payload = if is_map(event["payload"]), do: event["payload"], else: %{}
      item = if is_map(payload["item"]), do: payload["item"], else: %{}

      cond do
        name == "coding_context_classified" ->
          "Coding context classified: injected=#{event["coding_context_injected"]}, source=#{event["classification_source"]}, reason=#{event["classification_reason"] || "none"}."

        name == "session_started" ->
          "Started Codex turn #{event["turn_id"] || ""}."

        name == "approval_auto_approved" ->
          "Auto-approved Codex request: #{get_in(event, ["payload", "command"]) || event["method"] || "approval"}."

        name == "turn_input_required" ->
          "The agent requested user input."

        item["type"] in ["reasoning", "userMessage"] ->
          nil

        item["type"] == "agentMessage" ->
          text = String.trim(to_string(item["text"] || event["message"] || ""))
          if text == "", do: nil, else: "Agent said: #{text}"

        item["type"] == "commandExecution" ->
          command = String.trim(to_string(item["command"] || ""))
          status = String.trim(to_string(item["status"] || "unknown"))
          if command == "", do: "Command status: #{status}", else: "Command #{status}: #{command}"

        item["type"] == "fileChange" ->
          path = item["path"] || item["filePath"] || item["file"]
          status = item["status"] || "updated"
          if path, do: "File change #{status}: #{path}", else: "File change #{status}."

        String.trim(to_string(event["message"] || "")) == "" ->
          nil

        name == "turn_completed" ->
          "Turn completed: #{event["message"]}."

        String.starts_with?(name, "turn_") ->
          "#{name}: #{event["message"]}"

        String.starts_with?(name, "item_") and
            !String.starts_with?(to_string(event["message"]), "item_type=") ->
          "#{name}: #{event["message"]}"

        true ->
          event["message"]
      end
    end
  end

  defp attention_override(entry) do
    issue_text = "#{entry.issue.title}\n#{entry.issue.description || ""}" |> String.downcase()

    activity_text =
      entry.recent_activity
      |> Enum.take(-20)
      |> Enum.map_join("\n", &to_string(&1["message"] || ""))
      |> String.downcase()

    product_runtime_words = [
      "screen capture",
      "screenshot",
      "slides",
      "call",
      "live",
      "overlay",
      "proactive",
      "suggest",
      "answer",
      "browser extension",
      "electron",
      "integration"
    ]

    infra_config_words = [
      "infrastructure/",
      "terraform",
      ".tf",
      "model-gateway",
      "gateway",
      "schemas/functions",
      "system_template.minijinja",
      "user_template.minijinja"
    ]

    cond do
      Enum.any?(product_runtime_words, &String.contains?(issue_text, &1)) and
          Enum.any?(infra_config_words, &String.contains?(activity_text, &1)) ->
        "Recent activity is focused on infrastructure/gateway/config files while the issue reads like product, runtime, or integration work. Check the repo boundary before letting this continue."

      String.contains?(activity_text, "command failed:") and
          length(String.split(activity_text, "command failed:")) - 1 >= 3 ->
        "Several recent commands failed; the agent may be stuck or looking in the wrong place."

      true ->
        nil
    end
  end

  defp repo_deviation_from_event(entry, event) do
    if entry.repo_plan && entry.workspace_path do
      path = file_change_path(event)

      if path do
        repo_slug = repo_slug_for_path(entry, path)

        cond do
          is_nil(repo_slug) ->
            "File change is outside the approved repo plan: #{path}"

          !MapSet.member?(RepoPlan.edit_allowed_slugs(entry.repo_plan), repo_slug) ->
            "File change is in an unapproved or read-only repo (#{repo_slug}): #{path}"

          true ->
            nil
        end
      end
    end
  end

  defp file_change_path(event) do
    payload = if is_map(event["payload"]), do: event["payload"], else: %{}
    item = if is_map(payload["item"]), do: payload["item"], else: %{}
    if item["type"] == "fileChange", do: item["path"] || item["filePath"] || item["file"]
  end

  defp repo_slug_for_path(entry, raw_path) do
    workspace_path = Path.expand(entry.workspace_path)

    path =
      if Path.type(raw_path) == :absolute,
        do: Path.expand(raw_path),
        else: Path.expand(Path.join(workspace_path, raw_path))

    relative = safe_relative(path, workspace_path)

    with relative when is_binary(relative) <- relative,
         ["repos", repo_dir | _] <- Path.split(relative) do
      entry.repo_plan
      |> RepoPlan.all_repos()
      |> Enum.find_value(fn repo -> if repo.path_name == repo_dir, do: repo.slug end)
    else
      _ -> nil
    end
  end

  defp safe_relative(path, root) do
    root_parts = Path.split(Path.expand(root))
    path_parts = Path.split(Path.expand(path))

    if Enum.take(path_parts, length(root_parts)) == root_parts do
      path_parts |> Enum.drop(length(root_parts)) |> Path.join()
    end
  end

  defp state_path(%__MODULE__{} = orchestrator) do
    {_manager, _workflow, config} = ConfigManager.current(orchestrator.config_manager)
    Path.join(Path.expand(config.workspace.root), @state_file_name)
  end

  defp schedule_persist_state(%__MODULE__{task_supervisor: nil} = orchestrator),
    do: orchestrator

  defp schedule_persist_state(%__MODULE__{persist_timer_ref: nil} = orchestrator) do
    ref = Process.send_after(self(), :persist_state, @persist_coalesce_ms)
    %{orchestrator | persist_timer_ref: ref}
  end

  defp schedule_persist_state(%__MODULE__{} = orchestrator), do: orchestrator

  defp ensure_snapshot_cache_table! do
    case :ets.whereis(@snapshot_cache_table) do
      :undefined ->
        :ets.new(@snapshot_cache_table, [:named_table, :public, read_concurrency: true])

      _table ->
        @snapshot_cache_table
    end
  rescue
    ArgumentError ->
      @snapshot_cache_table
  end

  defp publish_snapshot_cache(%__MODULE__{task_supervisor: nil} = orchestrator),
    do: orchestrator

  defp publish_snapshot_cache(%__MODULE__{} = orchestrator) do
    ensure_snapshot_cache_table!()

    snapshot =
      orchestrator
      |> snapshot()
      |> put_in(["service", "snapshot_source"], "live_cache")

    :ets.insert(@snapshot_cache_table, {self(), snapshot})
    orchestrator
  rescue
    _ -> orchestrator
  end

  defp delete_snapshot_cache do
    case :ets.whereis(@snapshot_cache_table) do
      :undefined -> :ok
      table -> :ets.delete(table, self())
    end
  rescue
    ArgumentError -> :ok
  end

  defp persist_state(%__MODULE__{} = orchestrator) do
    path = state_path(orchestrator)
    File.mkdir_p!(Path.dirname(path))

    payload = %{
      "version" => 1,
      "updated_at" => Utils.isoformat_z(Utils.now_utc()),
      "service" => %{
        "last_poll_completed_at" => Utils.isoformat_z(orchestrator.state.last_poll_completed_at),
        "last_poll_error" => orchestrator.state.last_poll_error,
        "last_candidate_count" => orchestrator.state.last_candidate_count
      },
      "codex_totals" => CodexTotals.to_map(orchestrator.state.codex_totals),
      "rate_limits" => orchestrator.state.codex_rate_limits,
      "completed" =>
        orchestrator.state.completed |> Map.values() |> Enum.map(&completed_entry_to_map/1),
      "blocked" =>
        orchestrator.state.blocked |> Map.values() |> Enum.map(&blocked_entry_to_map/1),
      "retry_attempts" =>
        orchestrator.state.retry_attempts |> Map.values() |> Enum.map(&retry_entry_to_map/1)
    }

    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(payload, pretty: true))
    File.rename!(tmp, path)
    orchestrator
  end

  defp load_persisted_state(%__MODULE__{} = orchestrator) do
    path = state_path(orchestrator)

    with {:ok, body} <- File.read(path),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      state = %{
        orchestrator.state
        | codex_totals: codex_totals_from_map(payload["codex_totals"]),
          codex_rate_limits:
            if(is_map(payload["rate_limits"]), do: payload["rate_limits"], else: nil),
          completed:
            (payload["completed"] || [])
            |> Enum.flat_map(fn raw ->
              if entry = completed_entry_from_map(raw), do: [{entry.issue.id, entry}], else: []
            end)
            |> Map.new(),
          blocked:
            (payload["blocked"] || [])
            |> Enum.flat_map(fn raw ->
              if entry = blocked_entry_from_map(raw), do: [{entry.issue.id, entry}], else: []
            end)
            |> Map.new(),
          retry_attempts:
            (payload["retry_attempts"] || [])
            |> Enum.flat_map(fn raw ->
              if entry = retry_entry_from_map(raw), do: [{entry.issue_id, entry}], else: []
            end)
            |> Map.new()
      }

      %{
        orchestrator
        | state: %{
            state
            | claimed:
                state.blocked
                |> Map.keys()
                |> MapSet.new()
                |> MapSet.union(Map.keys(state.retry_attempts) |> MapSet.new())
          }
      }
    else
      _ -> orchestrator
    end
  end

  defp completed_entry_snapshot(completed) do
    %{
      "issue_id" => completed.issue.id,
      "issue_identifier" => completed.issue.identifier,
      "title" => completed.issue.title,
      "url" => completed.issue.url,
      "state" => completed.issue.state,
      "labels" => completed.issue.labels,
      "completed_at" => Utils.isoformat_z(completed.completed_at),
      "reason" => completed.reason,
      "workspace" => %{"path" => completed.workspace_path && to_string(completed.workspace_path)},
      "repo_plan" => completed.repo_plan && RepoPlan.to_map(completed.repo_plan),
      "repo_deviations" => completed.repo_deviations,
      "duration_seconds" => completed.duration_seconds,
      "turn_count" => completed.turn_count,
      "session_id" => completed.session_id,
      "thread_id" => completed.thread_id,
      "turn_id" => completed.turn_id,
      "tokens" => %{
        "input_tokens" => completed.codex_input_tokens,
        "output_tokens" => completed.codex_output_tokens,
        "total_tokens" => completed.codex_total_tokens
      },
      "summary" => %{
        "text" => completed.summary_text,
        "current_step" => completed.summary_current_step,
        "needs_human" => completed.summary_needs_human,
        "human_reason" => completed.summary_human_reason,
        "risk" => completed.summary_risk,
        "confidence" => completed.summary_confidence,
        "updated_at" => Utils.isoformat_z(completed.summary_updated_at)
      },
      "activity" => Enum.take(completed.recent_activity, -12)
    }
  end

  defp retry_entry_to_map(entry),
    do: %{
      "issue_id" => entry.issue_id,
      "issue_identifier" => entry.identifier,
      "attempt" => entry.attempt,
      "due_at" => Utils.isoformat_z(entry.due_at_wall),
      "error" => entry.error
    }

  defp blocked_entry_to_map(entry),
    do: %{
      "issue" => Issue.to_template_data(entry.issue),
      "reason" => entry.reason,
      "blocked_at" => Utils.isoformat_z(entry.blocked_at),
      "workspace_path" => entry.workspace_path && to_string(entry.workspace_path),
      "repo_plan" => entry.repo_plan && RepoPlan.to_map(entry.repo_plan)
    }

  defp completed_entry_to_map(entry) do
    %{
      "issue" => Issue.to_template_data(entry.issue),
      "completed_at" => Utils.isoformat_z(entry.completed_at),
      "reason" => entry.reason,
      "workspace_path" => entry.workspace_path && to_string(entry.workspace_path),
      "repo_plan" => entry.repo_plan && RepoPlan.to_map(entry.repo_plan),
      "duration_seconds" => entry.duration_seconds,
      "turn_count" => entry.turn_count,
      "session_id" => entry.session_id,
      "thread_id" => entry.thread_id,
      "turn_id" => entry.turn_id,
      "tokens" => %{
        "input_tokens" => entry.codex_input_tokens,
        "output_tokens" => entry.codex_output_tokens,
        "total_tokens" => entry.codex_total_tokens
      },
      "summary" => %{
        "text" => entry.summary_text,
        "current_step" => entry.summary_current_step,
        "needs_human" => entry.summary_needs_human,
        "human_reason" => entry.summary_human_reason,
        "risk" => entry.summary_risk,
        "confidence" => entry.summary_confidence,
        "updated_at" => Utils.isoformat_z(entry.summary_updated_at)
      },
      "repo_deviations" => entry.repo_deviations,
      "recent_activity" => Enum.take(entry.recent_activity, -100)
    }
  end

  defp codex_totals_from_map(value) when is_map(value) do
    %CodexTotals{
      input_tokens: Utils.to_int(value["input_tokens"]) || 0,
      output_tokens: Utils.to_int(value["output_tokens"]) || 0,
      total_tokens: Utils.to_int(value["total_tokens"]) || 0,
      seconds_running: Utils.to_float(value["seconds_running"]) || 0.0
    }
  end

  defp codex_totals_from_map(_), do: %CodexTotals{}

  defp retry_entry_from_map(value) when is_map(value) do
    issue_id = value["issue_id"]
    identifier = value["issue_identifier"] || value["identifier"]
    due_at_wall = Utils.parse_datetime(value["due_at"] || value["due_at_wall"])

    if issue_id && identifier && due_at_wall do
      delay_ms = max(DateTime.diff(due_at_wall, Utils.now_utc(), :millisecond), 0)

      %RetryEntry{
        issue_id: to_string(issue_id),
        identifier: to_string(identifier),
        attempt: Utils.to_int(value["attempt"]) || 1,
        due_at_monotonic: System.monotonic_time(:millisecond) + delay_ms,
        due_at_wall: due_at_wall,
        error: value["error"],
        timer_ref: nil
      }
    end
  end

  defp retry_entry_from_map(_), do: nil

  defp blocked_entry_from_map(value) when is_map(value) do
    with %Issue{} = issue <- issue_from_map(value["issue"]),
         %DateTime{} = blocked_at <- Utils.parse_datetime(value["blocked_at"]) do
      %BlockedEntry{
        issue: issue,
        reason: to_string(value["reason"] || ""),
        blocked_at: blocked_at,
        workspace_path: value["workspace_path"],
        repo_plan: if(is_map(value["repo_plan"]), do: repo_plan_from_map(value["repo_plan"]))
      }
    else
      _ -> nil
    end
  end

  defp blocked_entry_from_map(_), do: nil

  defp completed_entry_from_map(value) when is_map(value) do
    with %Issue{} = issue <- issue_from_map(value["issue"]),
         %DateTime{} = completed_at <- Utils.parse_datetime(value["completed_at"]) do
      tokens = if is_map(value["tokens"]), do: value["tokens"], else: %{}
      summary = if is_map(value["summary"]), do: value["summary"], else: %{}

      %CompletedEntry{
        issue: issue,
        completed_at: completed_at,
        reason: to_string(value["reason"] || ""),
        workspace_path: value["workspace_path"],
        repo_plan: if(is_map(value["repo_plan"]), do: repo_plan_from_map(value["repo_plan"])),
        duration_seconds: Utils.to_float(value["duration_seconds"]) || 0.0,
        turn_count: Utils.to_int(value["turn_count"]) || 0,
        session_id: value["session_id"],
        thread_id: value["thread_id"],
        turn_id: value["turn_id"],
        codex_input_tokens: Utils.to_int(tokens["input_tokens"]) || 0,
        codex_output_tokens: Utils.to_int(tokens["output_tokens"]) || 0,
        codex_total_tokens: Utils.to_int(tokens["total_tokens"]) || 0,
        summary_text: summary["text"],
        summary_current_step: summary["current_step"],
        summary_needs_human: !!summary["needs_human"],
        summary_human_reason: summary["human_reason"],
        summary_risk: summary["risk"],
        summary_confidence: Utils.to_float(summary["confidence"]),
        summary_updated_at: Utils.parse_datetime(summary["updated_at"]),
        repo_deviations: Enum.map(value["repo_deviations"] || [], &to_string/1),
        recent_activity: Enum.filter(value["recent_activity"] || [], &is_map/1)
      }
    else
      _ -> nil
    end
  end

  defp completed_entry_from_map(_), do: nil

  defp issue_from_map(value) when is_map(value) do
    issue_id = value["id"]
    identifier = value["identifier"]

    if issue_id && identifier do
      %Issue{
        id: to_string(issue_id),
        identifier: to_string(identifier),
        title: to_string(value["title"] || ""),
        description: value["description"],
        priority: Utils.to_int(value["priority"]),
        state: to_string(value["state"] || ""),
        branch_name: value["branch_name"],
        url: value["url"],
        labels: Enum.map(value["labels"] || [], &to_string/1),
        attachments:
          Enum.flat_map(value["attachments"] || [], fn
            raw when is_map(raw) ->
              [
                %IssueAttachment{
                  id: raw["id"],
                  title: raw["title"],
                  subtitle: raw["subtitle"],
                  url: raw["url"]
                }
              ]

            _ ->
              []
          end),
        blocked_by:
          Enum.flat_map(value["blocked_by"] || [], fn
            raw when is_map(raw) ->
              [%BlockerRef{id: raw["id"], identifier: raw["identifier"], state: raw["state"]}]

            _ ->
              []
          end),
        created_at: Utils.parse_datetime(value["created_at"]),
        updated_at: Utils.parse_datetime(value["updated_at"])
      }
    end
  end

  defp issue_from_map(_), do: nil

  defp repo_plan_from_map(data) do
    item = fn
      raw when is_map(raw) ->
        slug = to_string(raw["slug"] || "")

        if slug != "",
          do: %RepoPlanItem{
            slug: slug,
            role: to_string(raw["role"] || ""),
            reason: raw["reason"],
            path_name: raw["path_name"],
            edit_allowed: Map.get(raw, "edit_allowed", true)
          }

      _ ->
        nil
    end

    %RepoPlan{
      issue_identifier: to_string(data["issue_identifier"] || ""),
      coding_task: !!data["coding_task"],
      planner: to_string(data["planner"] || ""),
      source: to_string(data["source"] || ""),
      primary_repo: item.(data["primary_repo"]),
      secondary_repos:
        Enum.flat_map(data["secondary_repos"] || [], fn raw ->
          if parsed = item.(raw), do: [parsed], else: []
        end),
      read_only_context_repos:
        Enum.flat_map(data["read_only_context_repos"] || [], fn raw ->
          if parsed = item.(raw), do: [parsed], else: []
        end),
      confidence: Utils.to_float(data["confidence"]),
      needs_human: !!data["needs_human"],
      human_reason: data["human_reason"],
      notes: data["notes"],
      created_at: Utils.now_utc()
    }
  end
end
