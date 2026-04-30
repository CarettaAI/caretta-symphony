defmodule Symphony.WatchdogTriage do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.Config.ServiceConfig
  alias Symphony.Utils

  defmodule Decision do
    defstruct decision: :reject,
              service_problem: false,
              in_scope: false,
              issue_identifier: nil,
              reason: nil,
              confidence: nil,
              evidence: []
  end

  def triage(%ServiceConfig{} = config, payload, opts \\ []) when is_map(payload) do
    codex_client = Keyword.get(opts, :codex_client, CodexClient)

    workspace_path =
      Keyword.get(opts, :workspace_path) || config.self_healing.workspace_root || File.cwd!()

    session =
      apply(codex_client, :start_session, [
        config.self_healing.repair_codex,
        workspace_path,
        [tracker_config: config.tracker, on_event: fn _event -> :ok end]
      ])

    try do
      {result, _session} =
        apply(codex_client, :run_turn, [
          session,
          triage_prompt(payload),
          [capture_agent_text: true]
        ])

      result
      |> agent_message_text()
      |> parse_decision()
    after
      apply(codex_client, :stop_session, [session])
    end
  end

  def self_heal?(%Decision{} = decision) do
    decision.decision == :self_heal and decision.service_problem and decision.in_scope
  end

  def self_heal?(_), do: false

  def reason(%Decision{reason: reason}) when is_binary(reason) and reason != "", do: reason
  def reason(%Decision{decision: decision}), do: "watchdog triage decision=#{decision}"
  def reason(_), do: "watchdog triage did not return a decision"

  def parse_decision(text) do
    data = parse_json_object(text)

    %Decision{
      decision: normalize_decision(data["decision"]),
      service_problem: truthy?(data["service_problem"]),
      in_scope: truthy?(data["in_scope"]),
      issue_identifier: string_or_nil(data["issue_identifier"]),
      reason: Utils.truncate(to_string(data["reason"] || ""), 1000),
      confidence: normalize_confidence(data["confidence"]),
      evidence: normalize_evidence(data["evidence"])
    }
  end

  defp triage_prompt(payload) do
    payload_json = Jason.encode!(payload)

    """
    You are the Caretta Symphony watchdog triage agent.

    Decide whether repeated job failures are caused by Symphony orchestration, Codex/app-server integration, Linear MCP handoff, retry state, watchdog behavior, deploy/restart behavior, or local service health.
    Reject failures that belong to target product repositories, normal validation failures, product decisions, missing customer/product credentials, or insufficient evidence.

    Return only one JSON object and no markdown.
    Schema:
    {
      "decision": "self_heal|reject",
      "service_problem": boolean,
      "in_scope": boolean,
      "issue_identifier": "issue id or null",
      "reason": "short explanation for the watchdog log",
      "confidence": number,
      "evidence": ["short evidence points"]
    }

    Choose "self_heal" only when service_problem=true and in_scope=true.

    Watchdog evidence JSON:
    #{payload_json}
    """
  end

  defp agent_message_text(result) when is_map(result) do
    Map.get(result, :agent_message_text) || Map.get(result, "agent_message_text") || ""
  end

  defp agent_message_text(_), do: ""

  defp parse_json_object(text) do
    stripped = String.trim(to_string(text || ""))

    value =
      case Jason.decode(stripped) do
        {:ok, decoded} ->
          decoded

        {:error, _reason} ->
          stripped |> extract_json_object() |> Jason.decode!()
      end

    unless is_map(value) do
      raise ArgumentError, message: "watchdog triage JSON is not an object"
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
        raise ArgumentError, message: "watchdog triage output did not contain a JSON object"
    end
  end

  defp normalize_decision(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "self_heal" -> :self_heal
      _ -> :reject
    end
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp string_or_nil(nil), do: nil

  defp string_or_nil(value) do
    text = String.trim(to_string(value))
    if text == "" or text == "null", do: nil, else: text
  end

  defp normalize_confidence(value) do
    case Utils.to_float(value) do
      nil -> nil
      confidence -> confidence |> max(0.0) |> min(1.0)
    end
  end

  defp normalize_evidence(value) when is_list(value) do
    value
    |> Enum.map(&(to_string(&1) |> Utils.truncate(300)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(10)
  end

  defp normalize_evidence(_), do: []
end
