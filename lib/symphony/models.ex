defmodule Symphony.Models do
  @moduledoc false

  alias Symphony.Utils

  defmodule BlockerRef do
    defstruct id: nil, identifier: nil, state: nil

    def to_map(%__MODULE__{} = blocker) do
      %{"id" => blocker.id, "identifier" => blocker.identifier, "state" => blocker.state}
    end
  end

  defmodule IssueAttachment do
    defstruct id: nil, title: nil, subtitle: nil, url: nil

    def to_map(%__MODULE__{} = attachment) do
      %{
        "id" => attachment.id,
        "title" => attachment.title,
        "subtitle" => attachment.subtitle,
        "url" => attachment.url
      }
    end
  end

  defmodule IssueAssignee do
    defstruct id: nil, name: nil, display_name: nil, email: nil, url: nil, mention: nil

    def to_map(%__MODULE__{} = assignee) do
      %{
        "id" => assignee.id,
        "name" => assignee.name,
        "display_name" => assignee.display_name,
        "email" => assignee.email,
        "url" => assignee.url,
        "mention" => assignee.mention
      }
    end
  end

  defmodule Issue do
    defstruct [
      :id,
      :identifier,
      :title,
      description: nil,
      priority: nil,
      state: "",
      branch_name: nil,
      url: nil,
      assignee: nil,
      labels: [],
      attachments: [],
      blocked_by: [],
      created_at: nil,
      updated_at: nil
    ]

    def to_template_data(%__MODULE__{} = issue) do
      %{
        "id" => issue.id,
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "priority" => issue.priority,
        "state" => issue.state,
        "branch_name" => issue.branch_name,
        "url" => issue.url,
        "assignee" => if(issue.assignee, do: IssueAssignee.to_map(issue.assignee), else: nil),
        "labels" => issue.labels,
        "attachments" => Enum.map(issue.attachments, &IssueAttachment.to_map/1),
        "blocked_by" => Enum.map(issue.blocked_by, &BlockerRef.to_map/1),
        "created_at" => Utils.isoformat_z(issue.created_at),
        "updated_at" => Utils.isoformat_z(issue.updated_at)
      }
    end
  end

  defmodule WorkflowDefinition do
    defstruct config: %{}, prompt_template: "", path: nil, mtime_ns: nil
  end

  defmodule Workspace do
    defstruct path: nil,
              workspace_key: nil,
              created_now: false,
              repo_plan: nil,
              primary_repo_path: nil
  end

  defmodule RepoPlanItem do
    defstruct slug: nil, role: nil, reason: nil, path_name: nil, edit_allowed: true

    def to_map(%__MODULE__{} = item) do
      %{
        "slug" => item.slug,
        "role" => item.role,
        "reason" => item.reason,
        "path_name" => item.path_name,
        "edit_allowed" => item.edit_allowed
      }
    end
  end

  defmodule RepoPlan do
    defstruct [
      :issue_identifier,
      :coding_task,
      :planner,
      :source,
      primary_repo: nil,
      secondary_repos: [],
      read_only_context_repos: [],
      confidence: nil,
      needs_human: false,
      human_reason: nil,
      notes: nil,
      created_at: nil
    ]

    def all_repos(%__MODULE__{} = plan) do
      [plan.primary_repo]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(plan.secondary_repos)
      |> Kernel.++(plan.read_only_context_repos)
    end

    def edit_allowed_slugs(%__MODULE__{} = plan) do
      plan
      |> all_repos()
      |> Enum.filter(&(&1.edit_allowed and &1.role != "read_only_context"))
      |> Enum.map(& &1.slug)
      |> MapSet.new()
    end

    def to_map(%__MODULE__{} = plan) do
      %{
        "issue_identifier" => plan.issue_identifier,
        "coding_task" => plan.coding_task,
        "planner" => plan.planner,
        "source" => plan.source,
        "primary_repo" =>
          if(plan.primary_repo, do: RepoPlanItem.to_map(plan.primary_repo), else: nil),
        "secondary_repos" => Enum.map(plan.secondary_repos, &RepoPlanItem.to_map/1),
        "read_only_context_repos" =>
          Enum.map(plan.read_only_context_repos, &RepoPlanItem.to_map/1),
        "confidence" => plan.confidence,
        "needs_human" => plan.needs_human,
        "human_reason" => plan.human_reason,
        "notes" => plan.notes,
        "created_at" => Utils.isoformat_z(plan.created_at)
      }
    end
  end

  defmodule CodexTotals do
    defstruct input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0

    def to_map(%__MODULE__{} = totals) do
      %{
        "input_tokens" => totals.input_tokens,
        "output_tokens" => totals.output_tokens,
        "total_tokens" => totals.total_tokens,
        "seconds_running" => totals.seconds_running
      }
    end
  end

  defmodule RetryEntry do
    defstruct [
      :issue,
      :issue_id,
      :identifier,
      :attempt,
      :due_at_monotonic,
      :due_at_wall,
      error: nil,
      timer_ref: nil
    ]
  end

  defmodule ReviewFeedbackState do
    defstruct issue_id: nil,
              identifier: nil,
              fingerprint: nil,
              latest_feedback_at: nil,
              last_triggered_at: nil

    def to_map(%__MODULE__{} = state) do
      %{
        "issue_id" => state.issue_id,
        "identifier" => state.identifier,
        "fingerprint" => state.fingerprint,
        "latest_feedback_at" => Utils.isoformat_z(state.latest_feedback_at),
        "last_triggered_at" => Utils.isoformat_z(state.last_triggered_at)
      }
    end
  end

  defmodule BlockedEntry do
    defstruct issue: nil,
              reason: nil,
              diagnosis: nil,
              blocked_at: nil,
              workspace_path: nil,
              repo_plan: nil,
              escalation_comment_id: nil,
              escalation_fingerprint: nil,
              escalation_at: nil,
              escalation_error: nil
  end

  defmodule CompletedEntry do
    defstruct [
      :issue,
      :completed_at,
      :reason,
      workspace_path: nil,
      repo_plan: nil,
      duration_seconds: 0.0,
      turn_count: 0,
      session_id: nil,
      thread_id: nil,
      turn_id: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      summary_text: nil,
      summary_current_step: nil,
      summary_needs_human: false,
      summary_human_reason: nil,
      summary_risk: nil,
      summary_confidence: nil,
      summary_updated_at: nil,
      repo_deviations: [],
      recent_activity: []
    ]
  end

  defmodule RunningEntry do
    defstruct [
      :issue,
      task: nil,
      workspace_path: nil,
      started_at: nil,
      started_monotonic: nil,
      retry_attempt: nil,
      session_id: nil,
      thread_id: nil,
      turn_id: nil,
      codex_app_server_pid: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      repo_plan: nil,
      repo_deviations: [],
      recent_activity: [],
      activity_revision: 0,
      summary_revision: 0,
      summary_pending: false,
      summary_text: nil,
      summary_current_step: nil,
      summary_needs_human: false,
      summary_human_reason: nil,
      summary_risk: nil,
      summary_confidence: nil,
      summary_updated_at: nil,
      summary_error: nil,
      summary_source: nil,
      last_summary_monotonic: 0.0,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      last_reported_input_tokens: 0,
      last_reported_output_tokens: 0,
      last_reported_total_tokens: 0,
      turn_count: 0,
      forced_outcome: nil,
      forced_error: nil,
      cleanup_workspace: false
    ]
  end

  defmodule RuntimeState do
    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      service_status: "starting",
      startup_completed_at: nil,
      last_poll_started_at: nil,
      last_poll_completed_at: nil,
      last_poll_error: nil,
      last_candidate_count: nil,
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      review_feedback: %{},
      blocked: %{},
      completed: %{},
      codex_totals: %CodexTotals{},
      codex_rate_limits: nil
    ]
  end
end
