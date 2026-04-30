defmodule Symphony.DashboardSummary do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.Config.{CodexConfig, DashboardConfig}
  alias Symphony.Models.Issue
  alias Symphony.Utils

  defstruct summary: nil,
            current_step: nil,
            needs_human: false,
            human_reason: nil,
            risk: "unknown",
            confidence: nil

  def summarize_activity(opts) do
    %Issue{} = issue = Keyword.fetch!(opts, :issue)
    activity = Keyword.fetch!(opts, :activity)
    previous_summary = Keyword.get(opts, :previous_summary)
    %CodexConfig{} = codex_config = Keyword.fetch!(opts, :codex_config)
    %DashboardConfig{} = dashboard_config = Keyword.fetch!(opts, :dashboard_config)
    workspace_path = Keyword.fetch!(opts, :workspace_path)

    summary_config = %{
      codex_config
      | model: dashboard_config.summary_model || codex_config.model,
        effort: dashboard_config.summary_effort,
        turn_timeout_ms: dashboard_config.summary_timeout_ms,
        summary: nil,
        personality: nil
    }

    session =
      CodexClient.start_session(summary_config, workspace_path,
        tracker_config: nil,
        on_event: fn _event -> :ok end
      )

    try do
      {result, _session} =
        CodexClient.run_turn(
          session,
          summary_prompt(issue, activity, previous_summary, dashboard_config),
          capture_agent_text: true
        )

      data = parse_summary_json(result.agent_message_text)

      %__MODULE__{
        summary:
          Utils.truncate(
            to_string(data["summary"] || "No substantive activity has been summarized yet."),
            800
          ),
        current_step: Utils.truncate(to_string(data["current_step"] || "Unknown."), 300),
        needs_human: !!data["needs_human"],
        human_reason:
          if(data["human_reason"], do: Utils.truncate(to_string(data["human_reason"]), 500)),
        risk: normalize_risk(data["risk"]),
        confidence: normalize_confidence(data["confidence"])
      }
    after
      CodexClient.stop_session(session)
    end
  end

  def normalize_risk(value) do
    risk = value |> to_string() |> String.trim() |> String.downcase()
    if risk in ["low", "medium", "high", "unknown"], do: risk, else: "unknown"
  end

  def normalize_confidence(value) do
    case Utils.to_float(value) do
      nil -> nil
      float -> float |> max(0.0) |> min(1.0)
    end
  end

  defp summary_prompt(%Issue{} = issue, activity, previous_summary, %DashboardConfig{} = config) do
    payload = %{
      "issue" => Issue.to_template_data(issue),
      "previous_summary" => previous_summary,
      "recent_activity" => activity
    }

    payload_json =
      payload |> Jason.encode!(pretty: false) |> Utils.truncate(config.summary_max_chars)

    """
    You summarize a running background coding agent for a human dashboard.
    Use only the visible activity events. Do not claim completion unless the events show it. Flag human attention if the agent appears blocked, confused, repeatedly failing, using the wrong repo, waiting for credentials/decisions, asking for input, or operating with high uncertainty. Also flag human attention if the issue reads like product/runtime/UI work but the activity shows the agent working mostly in unrelated infrastructure, gateway, prompt/config, or deployment files.

    Return only one JSON object, no markdown and no prose.
    Schema:
    {
      "summary": "1-2 sentence present-tense summary of what the agent is doing",
      "current_step": "short phrase for the current/next step",
      "needs_human": boolean,
      "human_reason": "why a human should step in, or null",
      "risk": "low|medium|high|unknown",
      "confidence": number
    }

    Dashboard input JSON:
    #{payload_json}
    """
  end

  defp parse_summary_json(text) do
    stripped = String.trim(to_string(text || ""))

    if stripped == "" do
      raise ArgumentError, message: "summary model returned empty text"
    end

    value =
      case Jason.decode(stripped) do
        {:ok, decoded} ->
          decoded

        {:error, _reason} ->
          stripped |> extract_json_object() |> Jason.decode!()
      end

    unless is_map(value) do
      raise ArgumentError, message: "summary JSON is not an object"
    end

    value
  end

  defp extract_json_object(text) do
    start = :binary.match(text, "{")
    finish = :binary.matches(text, "}") |> List.last()

    case {start, finish} do
      {{start_index, 1}, {end_index, 1}} when end_index > start_index ->
        binary_part(text, start_index, end_index - start_index + 1)

      _ ->
        raise ArgumentError, message: "summary output did not contain a JSON object"
    end
  end
end
