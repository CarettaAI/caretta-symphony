defmodule Symphony.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Symphony.AgentRunner.AgentRunResult
  alias Symphony.Config.ConfigManager
  alias Symphony.DashboardSummary
  alias Symphony.HTTPServer

  alias Symphony.Models.{
    BlockedEntry,
    BlockerRef,
    CompletedEntry,
    Issue,
    IssueAttachment,
    RepoPlan,
    RepoPlanItem,
    RetryEntry,
    RunningEntry
  }

  alias Symphony.Orchestrator
  alias Symphony.Review.{PullRequestInfo, PullRequestRef, ReviewMergeResult}
  alias Symphony.Utils

  defmodule StructTracker do
    defstruct parent: nil

    def fetch_issues_by_states(%__MODULE__{parent: parent}, states) do
      send(parent, {:struct_tracker_fetch_issues_by_states, states})
      []
    end

    def save_issue_state(%__MODULE__{}, _issue_id, _state), do: %{}
  end

  defmodule FakeSummary do
    def summarize_activity(opts) do
      send(Application.fetch_env!(:caretta_symphony, :summary_parent), {:summary_called, opts})

      %DashboardSummary{
        summary: "The agent is searching the codebase.",
        current_step: "Inspect matching files",
        needs_human: false,
        risk: "low",
        confidence: 0.9
      }
    end
  end

  defmodule HangingSummary do
    def summarize_activity(_opts) do
      Process.sleep(5_000)
    end
  end

  defp make_manager(tmp_dir) do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: $LINEAR_API_KEY
      project_slug: demo
      required_labels: ["codex"]
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    agent:
      max_concurrent_agents: 2
      max_retry_backoff_ms: 15000
      max_concurrent_agents_by_state:
        Todo: 1
    codex:
      command: fake
    ---
    body
    """)

    manager = ConfigManager.new(workflow_path, environ: %{"LINEAR_API_KEY" => "key"})
    {manager, _, _} = ConfigManager.load_startup(manager)
    manager
  end

  defp make_summary_manager(tmp_dir, timeout_ms \\ 250) do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: key
      project_slug: demo
      required_labels: ["codex"]
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    polling:
      interval_ms: 60000
    dashboard:
      summaries:
        enabled: true
        update_interval_ms: 1
        timeout_ms: #{timeout_ms}
        max_events: 10
    codex:
      command: fake
    ---
    body
    """)

    manager = ConfigManager.new(workflow_path, environ: %{})
    {manager, _, _} = ConfigManager.load_startup(manager)
    manager
  end

  defp make_repo_manager(tmp_dir) do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: key
      project_slug: demo
      required_labels: ["codex"]
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    codex:
      command: fake
    repositories:
      enabled: true
      planner: rules
      known:
        - slug: CarettaAI/caretta-metrics
          local_path: #{tmp_dir}
          aliases: ["metrics"]
          description: Metrics console and telemetry inspection.
        - slug: CarettaAI/caretta-webapp
          local_path: #{tmp_dir}
          aliases: ["calendar", "web app"]
          description: Customer-facing web app, authenticated routes, product UI, calendar, CRM.
    ---
    body
    """)

    manager = ConfigManager.new(workflow_path, environ: %{})
    {manager, _, _} = ConfigManager.load_startup(manager)
    manager
  end

  @tag :tmp_dir
  test "sort and blocker eligibility", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    blocked = %Issue{
      id: "2",
      identifier: "ABC-2",
      title: "Blocked",
      priority: 1,
      state: "Todo",
      blocked_by: [%BlockerRef{identifier: "ABC-1", state: "In Progress"}]
    }

    unblocked = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Ready",
      priority: 2,
      state: "Todo",
      labels: ["codex"],
      blocked_by: [%BlockerRef{identifier: "ABC-0", state: "Done"}]
    }

    assert hd(Orchestrator.sort_for_dispatch([unblocked, blocked])) == blocked
    refute Orchestrator.is_dispatch_eligible(orchestrator, blocked, config)
    assert Orchestrator.is_dispatch_eligible(orchestrator, unblocked, config)
  end

  @tag :tmp_dir
  test "required label gate", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    missing_label = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Ready",
      state: "In Progress",
      labels: ["backend"]
    }

    matching = %Issue{
      id: "2",
      identifier: "ABC-2",
      title: "Ready",
      state: "In Progress",
      labels: ["Codex", "backend"]
    }

    refute Orchestrator.is_dispatch_eligible(orchestrator, missing_label, config)
    assert Orchestrator.is_dispatch_eligible(orchestrator, matching, config)
  end

  @tag :tmp_dir
  test "rules planner tie blocks are released when current rules resolve cleanly", %{
    tmp_dir: tmp_dir
  } do
    orchestrator = Orchestrator.new(make_repo_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    issue = %Issue{
      id: "CRTTA-262",
      identifier: "CRTTA-262",
      title: ~s(Calendar sync: 403 "insufficient auth scopes" in prod + breaks on refresh in dev),
      description:
        "Google Calendar APIs return insufficient scopes. Add telemetry and compare Google Cloud Console OAuth scopes.",
      state: "Todo",
      labels: ["codex", "auth", "bug"]
    }

    blocked = %BlockedEntry{
      issue: issue,
      reason:
        "Rules planner found tied primary repositories: CarettaAI/caretta-metrics, CarettaAI/caretta-webapp",
      blocked_at: Utils.now_utc(),
      repo_plan: %RepoPlan{
        issue_identifier: issue.identifier,
        coding_task: true,
        planner: "llm",
        source: "fallback:rules",
        needs_human: true,
        human_reason:
          "Rules planner found tied primary repositories: CarettaAI/caretta-metrics, CarettaAI/caretta-webapp",
        primary_repo: %RepoPlanItem{slug: "CarettaAI/caretta-metrics", role: "primary"}
      }
    }

    orchestrator = %{
      orchestrator
      | state: %{
          orchestrator.state
          | blocked: %{issue.id => blocked},
            claimed: MapSet.new([issue.id])
        }
    }

    orchestrator = Orchestrator.reconcile_blocked_issues(orchestrator, [issue], config)

    refute Map.has_key?(orchestrator.state.blocked, issue.id)
    refute MapSet.member?(orchestrator.state.claimed, issue.id)
    assert Orchestrator.is_dispatch_eligible(orchestrator, issue, config)
  end

  @tag :tmp_dir
  test "blocked issues are released when Linear state leaves active states", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_repo_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    issue = %Issue{
      id: "CRTTA-277",
      identifier: "CRTTA-277",
      title: "Data migration",
      state: "In Review",
      labels: ["codex"]
    }

    blocked = %BlockedEntry{
      issue: issue,
      reason: "unresolved_external_blocker",
      blocked_at: Utils.now_utc(),
      repo_plan: %RepoPlan{
        issue_identifier: issue.identifier,
        coding_task: true,
        source: "llm",
        needs_human: false,
        primary_repo: %RepoPlanItem{slug: "CarettaAI/kb-service", role: "primary"}
      }
    }

    orchestrator = %{
      orchestrator
      | state: %{
          orchestrator.state
          | blocked: %{issue.id => blocked},
            claimed: MapSet.new([issue.id])
        }
    }

    orchestrator = Orchestrator.reconcile_blocked_issues(orchestrator, [issue], config)

    refute Map.has_key?(orchestrator.state.blocked, issue.id)
    refute MapSet.member?(orchestrator.state.claimed, issue.id)
  end

  @tag :tmp_dir
  test "blocked issues are released when absent from active candidates", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_repo_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    issue = %Issue{
      id: "CRTTA-277",
      identifier: "CRTTA-277",
      title: "Data migration",
      state: "In Progress",
      labels: ["codex"]
    }

    blocked = %BlockedEntry{
      issue: issue,
      reason: "unresolved_external_blocker",
      blocked_at: Utils.now_utc()
    }

    orchestrator = %{
      orchestrator
      | state: %{
          orchestrator.state
          | blocked: %{issue.id => blocked},
            claimed: MapSet.new([issue.id])
        }
    }

    orchestrator =
      Orchestrator.reconcile_blocked_issues(orchestrator, [], config,
        candidate_snapshot_complete: true
      )

    refute Map.has_key?(orchestrator.state.blocked, issue.id)
    refute MapSet.member?(orchestrator.state.claimed, issue.id)
  end

  @tag :tmp_dir
  test "review reconciliation moves done only after all PRs merged", %{tmp_dir: tmp_dir} do
    parent = self()

    tracker = %{
      fetch_issues_by_states: fn ["In Review", "Merging"] ->
        [
          %Issue{
            id: "ABC-1",
            identifier: "ABC-1",
            title: "Ready",
            state: "In Review",
            labels: ["codex"],
            attachments: [%IssueAttachment{url: "https://github.com/ExampleOrg/app/pull/1"}]
          }
        ]
      end,
      fetch_issue_states_by_ids: fn ["ABC-1"] ->
        [
          %Issue{
            id: "ABC-1",
            identifier: "ABC-1",
            title: "Ready",
            state: "In Review",
            labels: ["codex"],
            attachments: [%IssueAttachment{url: "https://github.com/ExampleOrg/app/pull/1"}]
          }
        ]
      end,
      list_issue_comments: fn "ABC-1" ->
        [%{"body" => "## Codex Workpad\nhttps://github.com/ExampleOrg/api/pull/2"}]
      end,
      save_issue_state: fn issue_id, state ->
        send(parent, {:saved_state, issue_id, state})
        %{"id" => issue_id, "state" => state}
      end
    }

    resolver = %{
      evaluate: fn issue, opts ->
        assert issue.identifier == "ABC-1"
        assert Keyword.fetch!(opts, :base_branch) == "dev"
        assert Keyword.fetch!(opts, :comments) != []

        %ReviewMergeResult{
          ready: true,
          required_prs: [
            %PullRequestInfo{
              ref: %PullRequestRef{owner: "ExampleOrg", repo: "app", number: 1},
              url: "https://github.com/ExampleOrg/app/pull/1",
              state: "MERGED",
              base_ref_name: "dev"
            },
            %PullRequestInfo{
              ref: %PullRequestRef{owner: "ExampleOrg", repo: "api", number: 2},
              url: "https://github.com/ExampleOrg/api/pull/2",
              state: "MERGED",
              base_ref_name: "dev"
            }
          ]
        }
      end
    }

    orchestrator = Orchestrator.new(make_manager(tmp_dir), review_resolver: resolver)
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)
    Orchestrator.reconcile_review_issues(orchestrator, tracker, config)

    assert_received {:saved_state, "ABC-1", "Done"}
  end

  @tag :tmp_dir
  test "review reconciliation dispatches through tracker structs", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    Orchestrator.reconcile_review_issues(orchestrator, %StructTracker{parent: self()}, config)

    assert_received {:struct_tracker_fetch_issues_by_states, ["In Review", "Merging"]}
  end

  @tag :tmp_dir
  test "retry backoff is capped", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    orchestrator = Orchestrator.schedule_retry(orchestrator, issue, 3, error: "boom")
    retry = orchestrator.state.retry_attempts["1"]

    assert retry.attempt == 3
    assert retry.error == "boom"
    assert retry.due_at_monotonic - System.monotonic_time(:millisecond) < 20_000

    state = Orchestrator.snapshot(orchestrator)
    assert hd(state["retrying"])["kind"] == "retry"
    assert state["counts"]["retrying"] == 1
    assert state["counts"]["continuing"] == 0
  end

  @tag :tmp_dir
  test "due retries are cleared when the issue left active states", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}
    orchestrator = Orchestrator.schedule_retry(orchestrator, issue, 1, delay_ms: 0)

    tracker = %{
      fetch_issue_states_by_ids: fn ["1"] ->
        [%Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "Done"}]
      end
    }

    orchestrator = Orchestrator.process_due_retries(orchestrator, tracker, config)

    refute Map.has_key?(orchestrator.state.retry_attempts, issue.id)
  end

  @tag :tmp_dir
  test "normal worker completion schedules continuation", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))

    issue = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Ready",
      state: "In Progress",
      labels: ["codex"]
    }

    entry = %RunningEntry{
      issue: issue,
      workspace_path: tmp_dir,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond)
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      put_in(orchestrator.state.claimed, MapSet.put(orchestrator.state.claimed, issue.id))

    result = %AgentRunResult{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      normal: true,
      reason: "issue_left_active_state"
    }

    orchestrator = Orchestrator.handle_worker_done(orchestrator, issue.id, result)
    {_, _, config} = ConfigManager.current(orchestrator.config_manager)

    assert Map.has_key?(orchestrator.state.completed, issue.id)
    assert Map.has_key?(orchestrator.state.retry_attempts, issue.id)
    retry = orchestrator.state.retry_attempts[issue.id]
    assert retry.attempt == 1
    assert retry.error == nil
    assert retry.due_at_monotonic - System.monotonic_time(:millisecond) < 2_000

    assert Orchestrator.is_dispatch_eligible(orchestrator, issue, config,
             ignore_claimed_issue_id: issue.id
           )

    state = Orchestrator.snapshot(orchestrator)
    assert hd(state["retrying"])["kind"] == "continuation"
    assert state["counts"]["continuing"] == 1
    assert state["counts"]["retrying"] == 0
    assert state["counts"]["completed"] == 1
    assert hd(state["completed"])["issue_identifier"] == "ABC-1"
  end

  @tag :tmp_dir
  test "token usage absolute deltas are aggregated", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    entry = %RunningEntry{
      issue: issue,
      workspace_path: nil,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond)
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, "1", %{
        "event" => "thread_tokenUsage_updated",
        "usage_absolute" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
      })

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, "1", %{
        "event" => "thread_tokenUsage_updated",
        "usage_absolute" => %{"input_tokens" => 12, "output_tokens" => 7, "total_tokens" => 19}
      })

    assert orchestrator.state.codex_totals.input_tokens == 12
    assert orchestrator.state.codex_totals.output_tokens == 7
    assert orchestrator.state.codex_totals.total_tokens == 19
  end

  @tag :tmp_dir
  test "agent message delta fragments do not inflate recent activity", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))
    issue = %Issue{id: "1", identifier: "ABC-1", title: "Ready", state: "In Progress"}

    entry = %RunningEntry{
      issue: issue,
      workspace_path: nil,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond)
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, issue.id, %{
        "event" => "item_agentMessage_delta",
        "message" => "Care"
      })

    entry = orchestrator.state.running[issue.id]
    assert entry.recent_activity == []
    assert entry.activity_revision == 0
    assert entry.last_codex_event == "item_agentMessage_delta"
  end

  @tag :tmp_dir
  test "runtime state persists across orchestrator restart", %{tmp_dir: tmp_dir} do
    manager = make_manager(tmp_dir)
    orchestrator = Orchestrator.new(manager)

    issue = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Ready",
      state: "In Progress",
      labels: ["codex"]
    }

    entry = %RunningEntry{
      issue: issue,
      workspace_path: tmp_dir,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond),
      summary_text: "Implementation complete.",
      turn_count: 2
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, issue.id, %{
        "event" => "thread_tokenUsage_updated",
        "usage_absolute" => %{"input_tokens" => 7, "output_tokens" => 8, "total_tokens" => 15}
      })

    _orchestrator =
      Orchestrator.handle_worker_done(orchestrator, issue.id, %AgentRunResult{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        normal: true,
        reason: "issue_left_active_state"
      })

    reloaded = Orchestrator.new(manager)
    state = Orchestrator.snapshot(reloaded)

    assert state["codex_totals"]["input_tokens"] == 7
    assert state["codex_totals"]["output_tokens"] == 8
    assert state["codex_totals"]["total_tokens"] == 15
    assert state["counts"]["completed"] == 1
    assert hd(state["completed"])["issue_identifier"] == "ABC-1"
    assert get_in(hd(state["completed"]), ["summary", "text"]) == "Implementation complete."
    assert hd(state["retrying"])["kind"] == "continuation"
  end

  @tag :tmp_dir
  test "snapshot includes activity and dashboard summary", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))

    issue = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Ready",
      state: "In Progress",
      labels: ["codex"]
    }

    entry = %RunningEntry{
      issue: issue,
      workspace_path: tmp_dir,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond),
      summary_text: "The agent is inspecting the repo.",
      summary_current_step: "Inspect architecture",
      summary_needs_human: true,
      summary_human_reason: "Repo choice is ambiguous.",
      summary_risk: "high",
      summary_confidence: 0.82,
      summary_source: "llm"
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, "1", %{
        "event" => "item_completed",
        "payload" => %{
          "item" => %{
            "type" => "commandExecution",
            "command" => "rg provider",
            "status" => "completed"
          }
        },
        "message" => "command=rg provider status=completed"
      })

    state = Orchestrator.snapshot(orchestrator)
    running = hd(state["running"])

    assert running["title"] == "Ready"
    assert get_in(running, ["summary", "text"]) == "The agent is inspecting the repo."
    assert get_in(running, ["summary", "needs_human"])
    assert hd(running["activity"])["message"] == "Command completed: rg provider"
  end

  @tag :tmp_dir
  test "snapshot flags possible repo boundary mismatch", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))

    issue = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Screen capture for live call answers",
      state: "In Progress",
      labels: ["codex"]
    }

    entry = %RunningEntry{
      issue: issue,
      workspace_path: tmp_dir,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond)
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, "1", %{
        "event" => "item_completed",
        "payload" => %{
          "item" => %{
            "type" => "commandExecution",
            "command" =>
              "git diff -- infrastructure/config/schemas/functions/analyze_transcript/system_template.minijinja",
            "status" => "completed"
          }
        },
        "message" => "command=git diff status=completed"
      })

    summary = Orchestrator.snapshot(orchestrator)["running"] |> hd() |> Map.fetch!("summary")
    assert summary["needs_human"]
    assert summary["risk"] == "high"
    assert summary["human_reason"] =~ "repo boundary"
  end

  @tag :tmp_dir
  test "snapshot flags file changes outside repo plan", %{tmp_dir: tmp_dir} do
    orchestrator = Orchestrator.new(make_manager(tmp_dir))

    issue = %Issue{
      id: "1",
      identifier: "ABC-1",
      title: "Live suggestions",
      state: "In Progress",
      labels: ["codex"]
    }

    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir!(workspace)

    entry = %RunningEntry{
      issue: issue,
      workspace_path: workspace,
      started_at: Utils.now_utc(),
      started_monotonic: System.monotonic_time(:millisecond),
      repo_plan: %RepoPlan{
        issue_identifier: "ABC-1",
        coding_task: true,
        planner: "llm",
        source: "llm",
        primary_repo: %RepoPlanItem{
          slug: "ExampleOrg/desktop-runtime",
          role: "primary",
          path_name: "desktop-runtime"
        },
        read_only_context_repos: [
          %RepoPlanItem{
            slug: "ExampleOrg/knowledge-docs",
            role: "read_only_context",
            path_name: "knowledge-docs",
            edit_allowed: false
          }
        ]
      }
    }

    orchestrator = put_in(orchestrator.state.running[issue.id], entry)

    orchestrator =
      Orchestrator.handle_codex_event(orchestrator, "1", %{
        "event" => "item_completed",
        "payload" => %{
          "item" => %{
            "type" => "fileChange",
            "path" => Path.join([workspace, "repos", "knowledge-docs", "README.md"]),
            "status" => "updated"
          }
        },
        "message" => "file changed"
      })

    running = Orchestrator.snapshot(orchestrator)["running"] |> hd()
    assert get_in(running, ["summary", "needs_human"])
    assert get_in(running, ["summary", "human_reason"]) =~ "read-only repo"
    assert running["repo_deviations"] != []
  end

  @tag :tmp_dir
  test "genserver schedules dashboard summary on useful activity", %{tmp_dir: tmp_dir} do
    Application.put_env(:caretta_symphony, :summary_parent, self())
    on_exit(fn -> Application.delete_env(:caretta_symphony, :summary_parent) end)

    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir),
        dashboard_summary: FakeSummary,
        tracker_factory: fn _config -> empty_tracker() end
      )

    try do
      issue = %Issue{
        id: "1",
        identifier: "ABC-1",
        title: "Ready",
        state: "In Progress",
        labels: ["codex"]
      }

      :sys.replace_state(pid, fn orchestrator ->
        entry = %RunningEntry{
          issue: issue,
          workspace_path: tmp_dir,
          started_at: Utils.now_utc(),
          started_monotonic: System.monotonic_time(:millisecond)
        }

        put_in(orchestrator.state.running[issue.id], entry)
      end)

      GenServer.cast(pid, {:codex_event, issue.id, command_event()})

      assert_receive {:summary_called, opts}, 1_000
      assert Keyword.fetch!(opts, :issue).identifier == "ABC-1"

      assert eventually(fn ->
               summary = Orchestrator.snapshot(pid)["running"] |> hd() |> Map.fetch!("summary")

               summary["text"] == "The agent is searching the codebase." and
                 summary["current_step"] == "Inspect matching files" and
                 summary["pending"] == false
             end)
    after
      Orchestrator.stop(pid)
    end
  end

  @tag :tmp_dir
  test "genserver applies dashboard summary timeout as error state", %{tmp_dir: tmp_dir} do
    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir, 10),
        dashboard_summary: HangingSummary,
        tracker_factory: fn _config -> empty_tracker() end
      )

    try do
      issue = %Issue{
        id: "1",
        identifier: "ABC-1",
        title: "Ready",
        state: "In Progress",
        labels: ["codex"]
      }

      :sys.replace_state(pid, fn orchestrator ->
        entry = %RunningEntry{
          issue: issue,
          workspace_path: tmp_dir,
          started_at: Utils.now_utc(),
          started_monotonic: System.monotonic_time(:millisecond)
        }

        put_in(orchestrator.state.running[issue.id], entry)
      end)

      GenServer.cast(pid, {:codex_event, issue.id, command_event()})

      assert eventually(fn ->
               summary = Orchestrator.snapshot(pid)["running"] |> hd() |> Map.fetch!("summary")
               summary["pending"] == false and to_string(summary["error"]) =~ "summary timed out"
             end)
    after
      Orchestrator.stop(pid)
    end
  end

  @tag :tmp_dir
  test "genserver ignores normal linked process exit messages", %{tmp_dir: tmp_dir} do
    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir),
        tracker_factory: fn _config -> empty_tracker() end
      )

    try do
      send(pid, {:EXIT, make_ref(), :normal})
      Process.sleep(25)
      assert Process.alive?(pid)
    after
      Orchestrator.stop(pid)
    end
  end

  @tag :tmp_dir
  test "HTTP state reads live cache while orchestrator mailbox is busy", %{tmp_dir: tmp_dir} do
    parent = self()

    tracker = %{
      fetch_issues_by_states: fn _states -> [] end,
      fetch_issue_states_by_ids: fn _ids -> [] end,
      fetch_candidate_issues: fn ->
        send(parent, :slow_candidate_fetch_started)
        Process.sleep(750)
        []
      end
    }

    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir),
        tracker_factory: fn _config -> tracker end
      )

    server = HTTPServer.start(pid, port: 0)

    try do
      assert_receive :slow_candidate_fetch_started, 1_000

      {:ok, {{_, 200, _}, _headers, body}} =
        :httpc.request(
          :get,
          {~c"http://127.0.0.1:#{server.bound_port}/api/v1/state", []},
          [],
          body_format: :binary
        )

      state = Jason.decode!(body)
      assert get_in(state, ["service", "snapshot_source"]) == "live_cache"
      refute get_in(state, ["service", "status"]) == "busy"
    after
      HTTPServer.stop(server)
      Orchestrator.stop(pid)
    end
  end

  @tag :tmp_dir
  test "HTTP state reads starting live cache while startup cleanup is busy", %{tmp_dir: tmp_dir} do
    parent = self()

    tracker = %{
      fetch_issues_by_states: fn _states ->
        send(parent, :slow_startup_cleanup_started)
        Process.sleep(750)
        []
      end,
      fetch_issue_states_by_ids: fn _ids -> [] end,
      fetch_candidate_issues: fn -> [] end
    }

    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir),
        tracker_factory: fn _config -> tracker end
      )

    server = HTTPServer.start(pid, port: 0)

    try do
      assert_receive :slow_startup_cleanup_started, 1_000

      {:ok, {{_, 200, _}, _headers, body}} =
        :httpc.request(
          :get,
          {~c"http://127.0.0.1:#{server.bound_port}/api/v1/state", []},
          [],
          body_format: :binary
        )

      state = Jason.decode!(body)
      assert get_in(state, ["service", "snapshot_source"]) == "live_cache"
      refute get_in(state, ["service", "status"]) == "busy"
    after
      HTTPServer.stop(server)
      Orchestrator.stop(pid)
    end
  end

  @tag :tmp_dir
  test "cached issue snapshot covers running retrying blocked and completed entries", %{
    tmp_dir: tmp_dir
  } do
    {:ok, pid} =
      Orchestrator.start_link(make_summary_manager(tmp_dir),
        tracker_factory: fn _config -> empty_tracker() end
      )

    try do
      assert eventually(fn ->
               get_in(Orchestrator.snapshot(pid), ["service", "last_poll_completed_at"])
             end)

      now = Utils.now_utc()

      running_issue = %Issue{
        id: "running",
        identifier: "ABC-1",
        title: "Running",
        state: "In Progress",
        labels: ["codex"]
      }

      retry_issue = %Issue{
        id: "retry",
        identifier: "ABC-2",
        title: "Retrying",
        state: "In Progress",
        labels: ["codex"]
      }

      blocked_issue = %Issue{
        id: "blocked",
        identifier: "ABC-3",
        title: "Blocked",
        state: "In Progress",
        labels: ["codex"]
      }

      completed_issue = %Issue{
        id: "completed",
        identifier: "ABC-4",
        title: "Completed",
        state: "In Review",
        labels: ["codex"]
      }

      :sys.replace_state(pid, fn orchestrator ->
        running_entry = %RunningEntry{
          issue: running_issue,
          workspace_path: tmp_dir,
          started_at: now,
          started_monotonic: System.monotonic_time(:millisecond)
        }

        retry = %RetryEntry{
          issue_id: retry_issue.id,
          identifier: retry_issue.identifier,
          attempt: 2,
          due_at_monotonic: System.monotonic_time(:millisecond) + 60_000,
          due_at_wall: DateTime.add(now, 60, :second),
          error: "boom"
        }

        blocked = %BlockedEntry{
          issue: blocked_issue,
          reason: "needs human",
          blocked_at: now,
          workspace_path: tmp_dir
        }

        completed = %CompletedEntry{
          issue: completed_issue,
          completed_at: now,
          reason: "done",
          workspace_path: tmp_dir
        }

        %{
          orchestrator
          | state: %{
              orchestrator.state
              | running: %{running_issue.id => running_entry},
                retry_attempts: %{retry_issue.id => retry},
                blocked: %{blocked_issue.id => blocked},
                completed: %{completed_issue.id => completed}
            }
        }
      end)

      GenServer.cast(pid, {:codex_event, running_issue.id, command_event()})

      assert eventually(fn ->
               Orchestrator.cached_issue_snapshot(pid, "ABC-1")["status"] == "running"
             end)

      assert Orchestrator.cached_issue_snapshot(pid, "ABC-2")["status"] == "retrying"
      assert Orchestrator.cached_issue_snapshot(pid, "ABC-3")["status"] == "blocked"
      assert Orchestrator.cached_issue_snapshot(pid, "ABC-4")["status"] == "completed"
    after
      Orchestrator.stop(pid)
    end
  end

  defp command_event do
    %{
      "event" => "item_completed",
      "payload" => %{
        "item" => %{
          "type" => "commandExecution",
          "command" => "rg provider",
          "status" => "completed"
        }
      },
      "message" => "command=rg provider status=completed"
    }
  end

  defp empty_tracker do
    %{
      fetch_issues_by_states: fn _states -> [] end,
      fetch_issue_states_by_ids: fn _ids -> [] end,
      fetch_candidate_issues: fn -> [] end
    }
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
