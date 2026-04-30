defmodule Symphony.WatchdogTriage do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.Config.ServiceConfig
  alias Symphony.Utils

  @triage_max_attempts 2
  @minimum_evidence_points 2

  defmodule Decision do
    defstruct decision: :reject,
              service_problem: false,
              in_scope: false,
              reason: "triage did not approve self-heal",
              confidence: nil,
              issue_identifier: nil,
              evidence: [],
              failure_signature: nil,
              fault_domain: nil,
              inspected: [],
              scope_rationale: nil,
              unknowns: [],
              next_action: nil,
              raw: %{}
  end

  def triage(%ServiceConfig{} = config, payload, opts \\ []) when is_map(payload) do
    runner = Keyword.get(opts, :runner, &run_agent_triage/3)
    max_attempts = Keyword.get(opts, :max_attempts, @triage_max_attempts)

    do_triage(runner, config, payload, opts, 1, max_attempts)
  rescue
    error ->
      %Decision{
        decision: :self_heal,
        service_problem: true,
        in_scope: true,
        reason:
          "Watchdog triage agent failed while evaluating job health: #{Exception.message(error)}",
        confidence: 1.0
      }
  end

  def self_heal?(%Decision{} = decision) do
    decision.decision == :self_heal and decision.service_problem and decision.in_scope
  end

  def self_heal?(%{} = value), do: value |> decision_from_map() |> self_heal?()
  def self_heal?(_value), do: false

  def reason(%Decision{} = decision) do
    [
      "Agent diagnosis: #{decision.reason || "triage did not approve self-heal"}",
      field_line("Failure signature", decision.failure_signature),
      field_line("Likely fault domain", decision.fault_domain),
      field_line("Scope rationale", decision.scope_rationale),
      field_line("Next action", decision.next_action),
      list_section("Inspected", decision.inspected),
      list_section("Evidence", decision.evidence),
      list_section("Unknowns", decision.unknowns)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> Utils.truncate(2500)
  end

  def reason(%{} = value), do: value |> decision_from_map() |> reason()
  def reason(_value), do: "triage did not approve self-heal"

  def decision_from_map(value) when is_map(value) do
    investigation = investigation_map(value)

    raw_decision =
      value
      |> Map.get("decision", Map.get(value, :decision, "reject"))
      |> to_string()
      |> String.trim()
      |> String.downcase()

    service_problem = truthy?(Map.get(value, "service_problem", Map.get(value, :service_problem)))
    in_scope = truthy?(Map.get(value, "in_scope", Map.get(value, :in_scope)))
    evidence = list_value(Map.get(value, "evidence", Map.get(value, :evidence, [])), 8)
    inspected = list_value(map_get(investigation, "inspected", []), 8)
    unknowns = list_value(map_get(investigation, "unknowns", []), 6)

    decision =
      if raw_decision == "self_heal" and service_problem and in_scope,
        do: :self_heal,
        else: :reject

    %Decision{
      decision: decision,
      service_problem: service_problem,
      in_scope: in_scope,
      reason:
        Utils.truncate(
          to_string(Map.get(value, "reason", Map.get(value, :reason, "triage rejected"))),
          1000
        ),
      confidence:
        Utils.to_float(Map.get(value, "confidence", Map.get(value, :confidence))) ||
          if(decision == :self_heal, do: 1.0, else: nil),
      issue_identifier: Map.get(value, "issue_identifier", Map.get(value, :issue_identifier)),
      evidence: evidence,
      failure_signature: string_value(map_get(investigation, "failure_signature")),
      fault_domain:
        string_value(
          map_get(investigation, "likely_fault_domain") || map_get(investigation, "fault_domain")
        ),
      inspected: inspected,
      scope_rationale: string_value(map_get(investigation, "scope_rationale")),
      unknowns: unknowns,
      next_action: string_value(map_get(investigation, "next_action")),
      raw: value
    }
  end

  def decision_from_map(_value), do: %Decision{}

  def build_prompt(payload, opts \\ []) when is_map(payload) do
    payload_json =
      payload
      |> Jason.encode!(pretty: false)
      |> Utils.truncate(30_000)

    retry_feedback =
      case Keyword.get(opts, :triage_retry_feedback) do
        nil ->
          ""

        feedback ->
          """

          Previous triage attempt was incomplete:
          #{feedback}

          Re-run the investigation and return the full schema. Do not repeat the incomplete answer.
          """
      end

    """
    You are the Caretta Symphony watchdog triage agent.

    Mission:
    - Investigate the repeated failing Symphony job evidence below before making a decision.
    - Decide whether the failure is a Symphony service/control-plane problem.
    - Decide whether it is within self-healing scope for this repository.
    - You may reject the issue if it is a target product repository problem, a product decision, a normal validation failure, missing customer/product credentials, insufficient evidence, or anything outside Symphony control-plane repair.
    - Do not use keyword or text matching as the decision method. Reason from the issue context, retry history, recent activity, and whether the failure belongs to Symphony orchestration, Codex/app-server integration, Linear MCP handoff, retry state, watchdog behavior, deploy/restart behavior, or local service health.
    - You may inspect the Linear issue through available tools if needed. Do not edit files, commit, push, restart services, or repair anything. This turn is classification only.
    - Do not produce a lazy handoff. Never ask a human to "take a look and tell me what to do". If you reject or escalate, name the concrete failure, likely owner, and next action.

    Required investigation:
    - Identify the latest concrete failure signature, not just the broad symptom.
    - Inspect at least two evidence sources from the payload, such as retry metadata, error text, issue state/title/labels/assignee, recent activity, service health, blocked/running/completed context, or Linear issue details if you use tools.
    - Distinguish the root cause or likely fault domain from downstream symptoms.
    - Explain why the issue is or is not in Symphony self-heal scope.
    - State unknowns explicitly when evidence is insufficient.

    Return only one JSON object and no markdown.
    Schema:
    {
      "decision": "self_heal|reject",
      "service_problem": boolean,
      "in_scope": boolean,
      "issue_identifier": "issue id or null",
      "reason": "specific diagnosis for the watchdog log; no vague handoff language",
      "confidence": number,
      "investigation": {
        "failure_signature": "exact error/mechanism observed",
        "likely_fault_domain": "symphony|codex_app_server|linear_mcp|target_repo|credentials|product_decision|unknown",
        "inspected": ["specific evidence sources inspected"],
        "scope_rationale": "why this is or is not in Symphony self-heal scope",
        "unknowns": ["specific unknowns, or empty array"],
        "next_action": "specific next action and owner"
      },
      "evidence": ["short evidence points"]
    }

    Choose "self_heal" only when service_problem=true and in_scope=true. If evidence is ambiguous, choose "reject" and use investigation.unknowns plus investigation.next_action to make the escalation actionable.
    Watchdog will reject incomplete triage that omits investigation.failure_signature, investigation.scope_rationale, investigation.next_action, two inspected sources, or two evidence points.
    #{retry_feedback}

    Watchdog evidence JSON:
    #{payload_json}
    """
    |> String.trim()
  end

  defp run_agent_triage(%ServiceConfig{} = config, payload, opts) do
    workspace_path = Keyword.get(opts, :workspace_path, repo_root(config))

    session =
      CodexClient.start_session(config.self_healing.repair_codex, workspace_path,
        tracker_config: config.tracker,
        on_event: Keyword.get(opts, :on_event, fn _event -> :ok end)
      )

    try do
      {result, _session} =
        CodexClient.run_turn(session, build_prompt(payload, opts), capture_agent_text: true)

      result.agent_message_text
    after
      CodexClient.stop_session(session)
    end
  end

  defp do_triage(runner, config, payload, opts, attempt, max_attempts) do
    decision =
      runner.(config, payload, opts)
      |> parse_decision_json()
      |> decision_from_map()

    missing = missing_investigation(decision)

    cond do
      missing == [] ->
        decision

      attempt < max_attempts ->
        retry_feedback =
          "Missing required investigation fields: #{Enum.join(missing, ", ")}. Previous reason: #{decision.reason}"

        opts = Keyword.put(opts, :triage_retry_feedback, retry_feedback)
        do_triage(runner, config, payload, opts, attempt + 1, max_attempts)

      true ->
        incomplete_investigation_decision(decision, missing)
    end
  end

  defp missing_investigation(%Decision{} = decision) do
    []
    |> missing_if("investigation.failure_signature", blank?(decision.failure_signature))
    |> missing_if("investigation.scope_rationale", blank?(decision.scope_rationale))
    |> missing_if("investigation.next_action", blank?(decision.next_action))
    |> missing_if(
      "investigation.inspected",
      length(decision.inspected) < @minimum_evidence_points
    )
    |> missing_if("evidence", length(decision.evidence) < @minimum_evidence_points)
  end

  defp missing_if(missing, _field, false), do: missing
  defp missing_if(missing, field, true), do: missing ++ [field]

  defp incomplete_investigation_decision(%Decision{} = decision, missing) do
    %Decision{
      decision: :reject,
      service_problem: false,
      in_scope: false,
      reason:
        "Watchdog triage agent returned an incomplete investigation; missing #{Enum.join(missing, ", ")}. Last agent diagnosis: #{decision.reason}",
      confidence: 1.0,
      issue_identifier: decision.issue_identifier,
      evidence: decision.evidence,
      failure_signature: decision.failure_signature,
      fault_domain: "symphony",
      inspected: decision.inspected,
      scope_rationale:
        decision.scope_rationale ||
          "The watchdog cannot safely self-heal without a complete agent investigation.",
      unknowns: missing,
      next_action:
        "Fix or re-run the Symphony watchdog triage path so it produces a concrete failure signature, evidence, scope rationale, and owner action.",
      raw: decision.raw
    }
  end

  defp parse_decision_json(text) do
    stripped = String.trim(to_string(text || ""))

    if stripped == "" do
      raise ArgumentError, message: "triage agent returned empty text"
    end

    value =
      case Jason.decode(stripped) do
        {:ok, decoded} ->
          decoded

        {:error, _reason} ->
          stripped |> extract_json_object() |> Jason.decode!()
      end

    unless is_map(value) do
      raise ArgumentError, message: "triage JSON is not an object"
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
        raise ArgumentError, message: "triage output did not contain a JSON object"
    end
  end

  defp repo_root(%ServiceConfig{} = config),
    do: config.workflow_path |> Path.dirname() |> Path.expand()

  defp investigation_map(value) do
    case Map.get(value, "investigation", Map.get(value, :investigation, %{})) do
      investigation when is_map(investigation) -> investigation
      _ -> %{}
    end
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) do
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

  defp map_get(_map, _key, default), do: default

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp list_value(value, limit) when is_list(value) do
    value
    |> Enum.map(&string_value/1)
    |> Enum.reject(&blank?/1)
    |> Enum.take(limit)
  end

  defp list_value(_value, _limit), do: []

  defp string_value(nil), do: nil

  defp string_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> Utils.truncate(600)
    |> then(fn text -> if text == "", do: nil, else: text end)
  end

  defp field_line(_label, value) when value in [nil, ""], do: nil
  defp field_line(label, value), do: "#{label}: #{value}"

  defp list_section(_label, []), do: nil

  defp list_section(label, values) do
    body =
      values
      |> Enum.reject(&blank?/1)
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    if body == "", do: nil, else: "#{label}:\n#{body}"
  end

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() == "true"
  end

  defp truthy?(_value), do: false

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
