defmodule Symphony.BlockerDiagnosis do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.Config.ServiceConfig
  alias Symphony.Models.{Issue, RepoPlan}
  alias Symphony.Utils

  @fallback_text_limit 8_000

  def diagnose(
        %ServiceConfig{} = config,
        %Issue{} = issue,
        reason,
        agent_handoff,
        workspace_path,
        repo_plan,
        opts \\ []
      ) do
    payload = payload(issue, reason, agent_handoff, workspace_path, repo_plan)
    runner = Keyword.get(opts, :runner, &run_agent_diagnosis/3)

    try do
      runner.(config, payload, opts)
      |> parse_json_object()
      |> normalize(payload)
    rescue
      _error -> fallback(payload)
    end
  end

  def payload(%Issue{} = issue, reason, agent_handoff, workspace_path, repo_plan) do
    %{
      "issue" => Issue.to_template_data(issue),
      "reason" => to_string(reason || ""),
      "agent_handoff" => Utils.truncate(agent_handoff || "", @fallback_text_limit),
      "workspace_path" => workspace_path && to_string(workspace_path),
      "repo_plan" => repo_plan_to_map(repo_plan),
      "workspace_facts" => workspace_facts(workspace_path)
    }
  end

  def build_prompt(payload) when is_map(payload) do
    payload_json =
      payload
      |> Jason.encode!(pretty: false)
      |> Utils.truncate(30_000)

    """
    You are Symphony's blocked-issue diagnosis agent.

    Mission:
    - Diagnose why a completed or partially completed Symphony job is blocked before Symphony escalates to Linear.
    - Use the final agent handoff, issue context, repo plan, and workspace facts. You may inspect local files if the handoff leaves a concrete question open.
    - Do not edit files, commit, push, restart services, or mutate Linear. This is diagnosis only.
    - Do not produce a lazy handoff. Do not say "take a look and tell me what to do." Name the concrete failing subsystem, evidence, likely owner, and next action.
    - Distinguish the Codex in-agent Linear MCP from Symphony's tracker-owned Linear writer. If the agent can read Linear but write mutations fail, call that a Linear MCP write configuration or permission problem, not a generic Linear outage.
    - For npm/GitHub Packages 401 or private package auth failures, inspect whether the repo/workspace has a `.npmrc` before recommending the fix. If `.npmrc` is missing for an `@CarettaAI` package, say that explicitly.

    Return only one JSON object and no markdown.
    Schema:
    {
      "summary": "specific one-sentence diagnosis",
      "fault_domain": "linear_mcp|package_auth|repo_plan|credentials|target_repo|product_decision|symphony|unknown",
      "configuration_issue": boolean,
      "validation_blocked": boolean,
      "evidence": ["specific evidence points"],
      "next_action": "specific owner action",
      "operator_hint": "optional concise hint for the human operator",
      "raw_failure": "short exact failure signature"
    }

    Blocked job payload JSON:
    #{payload_json}
    """
    |> String.trim()
  end

  defp run_agent_diagnosis(%ServiceConfig{} = config, payload, opts) do
    workspace_path = payload["workspace_path"] || Path.dirname(config.workflow_path)
    diagnosis_config = diagnosis_codex_config(config)

    session =
      CodexClient.start_session(diagnosis_config, workspace_path,
        tracker_config: nil,
        on_event: Keyword.get(opts, :on_event, fn _event -> :ok end)
      )

    try do
      {result, _session} =
        CodexClient.run_turn(session, build_prompt(payload), capture_agent_text: true)

      result.agent_message_text
    after
      CodexClient.stop_session(session)
    end
  end

  defp diagnosis_codex_config(%ServiceConfig{} = config) do
    %{
      config.codex
      | effort: config.dashboard.summary_effort || config.codex.effort || "low",
        model: config.dashboard.summary_model || config.codex.model,
        turn_timeout_ms: config.dashboard.summary_timeout_ms || 120_000,
        summary: nil,
        personality: nil
    }
  end

  defp normalize(value, payload) when is_map(value) do
    fallback = fallback(payload)

    %{
      "summary" => string_value(value["summary"]) || fallback["summary"],
      "fault_domain" => normalize_fault_domain(value["fault_domain"]) || fallback["fault_domain"],
      "configuration_issue" =>
        boolean_value(value["configuration_issue"], fallback["configuration_issue"]),
      "validation_blocked" =>
        boolean_value(value["validation_blocked"], fallback["validation_blocked"]),
      "evidence" => list_value(value["evidence"], 8, fallback["evidence"]),
      "next_action" => string_value(value["next_action"]) || fallback["next_action"],
      "operator_hint" => string_value(value["operator_hint"]) || fallback["operator_hint"],
      "raw_failure" => string_value(value["raw_failure"]) || fallback["raw_failure"],
      "agent_handoff_excerpt" => fallback["agent_handoff_excerpt"]
    }
  end

  defp normalize(_value, payload), do: fallback(payload)

  def fallback(payload) when is_map(payload) do
    handoff = to_string(payload["agent_handoff"] || "")
    workspace_facts = payload["workspace_facts"] || %{}

    issues = []
    issues = maybe_add_linear_issue(issues, handoff)
    issues = maybe_add_package_auth_issue(issues, handoff, workspace_facts)

    evidence =
      issues
      |> Enum.flat_map(& &1.evidence)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.take(8)

    next_action =
      issues
      |> Enum.map(& &1.next_action)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.join(" ")

    summary =
      issues
      |> Enum.map(& &1.summary)
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")

    fault_domain =
      cond do
        Enum.any?(issues, &(&1.fault_domain == "linear_mcp")) and
            Enum.any?(issues, &(&1.fault_domain == "package_auth")) ->
          "credentials"

        issues != [] ->
          issues |> hd() |> Map.fetch!(:fault_domain)

        true ->
          "unknown"
      end

    %{
      "summary" =>
        if(blank?(summary),
          do:
            "Symphony blocked this issue but the agent handoff did not include a concrete diagnosis.",
          else: summary
        ),
      "fault_domain" => fault_domain,
      "configuration_issue" => Enum.any?(issues, & &1.configuration_issue),
      "validation_blocked" => Enum.any?(issues, & &1.validation_blocked),
      "evidence" =>
        if(evidence == [],
          do: ["Blocked reason: #{payload["reason"] || "n/a"}"],
          else: evidence
        ),
      "next_action" =>
        if(blank?(next_action),
          do:
            "Inspect the final agent handoff and update Symphony's blocker diagnosis if this repeats.",
          else: next_action
        ),
      "operator_hint" => operator_hint(issues),
      "raw_failure" => raw_failure(handoff, payload["reason"]),
      "agent_handoff_excerpt" => Utils.truncate(handoff, 2_500)
    }
  end

  defp maybe_add_linear_issue(issues, handoff) do
    normalized = String.downcase(handoff)

    if String.contains?(normalized, "linear") and
         (String.contains?(normalized, "mutation") or String.contains?(normalized, "write") or
            String.contains?(normalized, "rejected")) do
      issue = %{
        fault_domain: "linear_mcp",
        configuration_issue: true,
        validation_blocked: false,
        summary:
          "Linear handoff failed inside the Codex agent: reads may work, but comment/state write mutations are being rejected.",
        evidence: [
          "Final agent handoff reports Linear write/mutation rejection.",
          "The blocked escalation path can still use Symphony's tracker writer, so the failure is likely the in-agent Linear MCP write configuration or permissions."
        ],
        next_action:
          "Fix the Linear MCP write configuration used by Codex agent sessions for `save_comment`/state mutations, then retry the issue handoff."
      }

      [issue | issues]
    else
      issues
    end
  end

  defp maybe_add_package_auth_issue(issues, handoff, workspace_facts) do
    normalized = String.downcase(handoff)

    if String.contains?(normalized, "npm") or String.contains?(normalized, "401") or
         String.contains?(normalized, "@carettaai/") or
         String.contains?(normalized, "github package") do
      npmrc_evidence = npmrc_evidence(workspace_facts)

      issue = %{
        fault_domain: "package_auth",
        configuration_issue: true,
        validation_blocked: true,
        summary:
          "Validation is blocked by private package auth for GitHub Packages, most likely missing or invalid `.npmrc` configuration for the `@CarettaAI` scope.",
        evidence:
          [
            "Final agent handoff reports npm/private package auth failure.",
            npmrc_evidence
          ]
          |> Enum.reject(&blank?/1),
        next_action:
          "Add or repair repo/user `.npmrc` auth for GitHub Packages `@CarettaAI` packages, then rerun `npm ci` and the focused tests."
      }

      [issue | issues]
    else
      issues
    end
  end

  defp npmrc_evidence(%{"repos" => repos} = facts) when is_list(repos) do
    repo_without_npmrc =
      Enum.find(repos, fn repo ->
        repo["has_package_json"] and !repo["has_repo_npmrc"]
      end)

    cond do
      repo_without_npmrc ->
        "Repo `#{repo_without_npmrc["name"]}` has `package.json` but no repo-level `.npmrc`."

      facts["has_workspace_npmrc"] == false and facts["has_home_npmrc"] == false ->
        "No workspace-level or home `.npmrc` was detected."

      true ->
        "Workspace npm auth config may be missing or invalid for private packages."
    end
  end

  defp npmrc_evidence(_facts), do: "Workspace npm auth config was not available."

  defp operator_hint(issues) do
    hints =
      issues
      |> Enum.map(fn
        %{fault_domain: "linear_mcp"} ->
          "Linear: compare the Codex app Linear MCP write config with the Symphony tracker config."

        %{fault_domain: "package_auth"} ->
          "npm: check `.npmrc` for `@CarettaAI:registry=https://npm.pkg.github.com` and a valid GitHub Packages token."

        _ ->
          nil
      end)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    if hints == [], do: nil, else: Enum.join(hints, " ")
  end

  defp raw_failure(handoff, reason) do
    line =
      handoff
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find(
        &(String.contains?(String.downcase(&1), "fail") or String.contains?(&1, "401"))
      )

    (line || to_string(reason || ""))
    |> Utils.truncate(500)
  end

  defp workspace_facts(nil), do: %{}

  defp workspace_facts(workspace_path) do
    workspace_path = Path.expand(workspace_path)
    repos_path = Path.join(workspace_path, "repos")

    repos =
      if File.dir?(repos_path) do
        repos_path
        |> File.ls!()
        |> Enum.map(&Path.join(repos_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&repo_facts/1)
      else
        []
      end

    %{
      "has_workspace_npmrc" => File.exists?(Path.join(workspace_path, ".npmrc")),
      "has_home_npmrc" => File.exists?(Path.expand("~/.npmrc")),
      "repos" => repos
    }
  rescue
    _ -> %{}
  end

  defp repo_facts(path) do
    %{
      "name" => Path.basename(path),
      "has_package_json" => File.exists?(Path.join(path, "package.json")),
      "has_repo_npmrc" => File.exists?(Path.join(path, ".npmrc")),
      "private_packages" => private_packages(path)
    }
  end

  defp private_packages(path) do
    package_json = Path.join(path, "package.json")

    with {:ok, body} <- File.read(package_json),
         {:ok, payload} when is_map(payload) <- Jason.decode(body) do
      ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]
      |> Enum.flat_map(fn key ->
        case payload[key] do
          deps when is_map(deps) -> Map.keys(deps)
          _ -> []
        end
      end)
      |> Enum.filter(&String.starts_with?(&1, "@CarettaAI/"))
      |> Enum.uniq()
      |> Enum.take(20)
    else
      _ -> []
    end
  end

  defp repo_plan_to_map(%RepoPlan{} = repo_plan), do: RepoPlan.to_map(repo_plan)
  defp repo_plan_to_map(_), do: nil

  defp parse_json_object(text) do
    stripped = String.trim(to_string(text || ""))

    if stripped == "" do
      raise ArgumentError, message: "blocker diagnosis agent returned empty text"
    end

    value =
      case Jason.decode(stripped) do
        {:ok, decoded} ->
          decoded

        {:error, _reason} ->
          stripped |> extract_json_object() |> Jason.decode!()
      end

    unless is_map(value) do
      raise ArgumentError, message: "blocker diagnosis JSON is not an object"
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
        raise ArgumentError, message: "blocker diagnosis output did not contain a JSON object"
    end
  end

  defp string_value(nil), do: nil

  defp string_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> Utils.truncate(text, 1_000)
    end
  end

  defp normalize_fault_domain(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()

    if value in [
         "linear_mcp",
         "package_auth",
         "repo_plan",
         "credentials",
         "target_repo",
         "product_decision",
         "symphony",
         "unknown"
       ],
       do: value
  end

  defp boolean_value(value, fallback)
  defp boolean_value(value, _fallback) when is_boolean(value), do: value
  defp boolean_value(nil, fallback), do: fallback

  defp boolean_value(value, _fallback),
    do: String.downcase(to_string(value)) in ["true", "1", "yes"]

  defp list_value(value, limit, fallback)

  defp list_value(value, limit, _fallback) when is_list(value) do
    value
    |> Enum.map(&string_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  defp list_value(_value, _limit, fallback), do: fallback

  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
