defmodule Symphony.RepoPlanner do
  @moduledoc false

  alias Symphony.CodingContext.{CodingClassification}
  alias Symphony.CodingContext
  alias Symphony.CodexClient

  alias Symphony.Config.{
    CodexConfig,
    CodingContextConfig,
    RepositoryConfig,
    RepositoryPlanningConfig
  }

  alias Symphony.Models.{Issue, RepoPlan, RepoPlanItem}
  alias Symphony.Utils

  def plan_repositories(
        %Issue{} = issue,
        %RepositoryPlanningConfig{} = config,
        %CodingContextConfig{} = coding_config,
        %CodingClassification{} = classification,
        opts \\ []
      ) do
    cond do
      !config.enabled ->
        nil

      !classification.is_coding_task ->
        %RepoPlan{
          issue_identifier: issue.identifier,
          coding_task: false,
          planner: config.planner,
          source: classification.source,
          confidence: classification.confidence,
          notes: "Issue was not classified as a coding task.",
          created_at: Utils.now_utc()
        }

      config.planner == "llm" ->
        try do
          plan_with_llm(issue, config, coding_config, opts)
        rescue
          error ->
            if config.fallback == "block" do
              %RepoPlan{
                issue_identifier: issue.identifier,
                coding_task: true,
                planner: config.planner,
                source: "fallback:block",
                needs_human: true,
                human_reason:
                  "Repository planner failed and fallback is block: #{Utils.truncate(Exception.message(error), 300)}",
                created_at: Utils.now_utc()
              }
            else
              plan_with_rules(issue, config, "fallback:rules")
            end
        end

      true ->
        plan_with_rules(issue, config, "rules")
    end
  end

  def apply_repo_plan_to_prompt(prompt, nil, _workspace_path), do: prompt

  def apply_repo_plan_to_prompt(prompt, %RepoPlan{coding_task: false}, _workspace_path),
    do: prompt

  def apply_repo_plan_to_prompt(prompt, %RepoPlan{} = repo_plan, workspace_path) do
    plan_json = Jason.encode!(RepoPlan.to_map(repo_plan), pretty: true)
    git_metadata = workspace_git_metadata(workspace_path)

    git_guardrail =
      "Git hygiene guardrail: commit and push only the expected branch recorded for each repo in `.symphony-workspace.json`. Never push an inherited source checkout branch. If `git branch --show-current` differs from the repo's expected branch, stop and report the mismatch. The workspace-local pre-push hook rejects pushes to any other branch.\n"

    git_guardrail =
      if git_metadata == [] do
        git_guardrail
      else
        git_guardrail <> "Prepared git branches:\n#{Jason.encode!(git_metadata, pretty: true)}\n"
      end

    """
    <symphony_repo_plan>
    Symphony prepared an explicit repository plan for this issue. Treat it as a guardrail, not as proof the implementation is already understood.

    Workspace root: #{workspace_path}
    Repositories are checked out under `repos/<path_name>` inside the workspace root.
    Start by inspecting the primary repo. You may read secondary and read-only context repos as needed. Only edit the primary repo and secondary repos whose `edit_allowed` value is true. Do not edit read-only context repos. If the current Linear issue text proves the repo plan is wrong or incomplete, stop and report that instead of patching an unapproved repo.

    #{git_guardrail}
    #{plan_json}
    </symphony_repo_plan>

    #{prompt}
    """
    |> String.trim()
  end

  defp workspace_git_metadata(workspace_path) do
    path = Path.join(workspace_path, ".symphony-workspace.json")

    with {:ok, body} <- File.read(path),
         {:ok, payload} when is_map(payload) <- Jason.decode(body),
         repositories when is_list(repositories) <- payload["repositories"] do
      repositories
      |> Enum.flat_map(fn
        item when is_map(item) ->
          if is_map(item["git"]) do
            [
              %{
                "slug" => item["slug"],
                "path" => item["path"],
                "edit_allowed" => item["edit_allowed"],
                "expected_branch" => item["git"]["expected_branch"],
                "expected_ref" => item["git"]["expected_ref"],
                "base_ref" => item["git"]["base_ref"]
              }
            ]
          else
            []
          end

        _ ->
          []
      end)
    else
      _ -> []
    end
  end

  defp plan_with_llm(issue, config, coding_config, opts) do
    %CodexConfig{} = codex_config = Keyword.fetch!(opts, :codex_config)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    codex_client = Keyword.get(opts, :codex_client, CodexClient)

    planner_codex_config = %{
      codex_config
      | model: config.plan_model || codex_config.model,
        effort: config.plan_effort,
        turn_timeout_ms: config.plan_timeout_ms,
        summary: nil,
        personality: nil
    }

    session =
      apply(codex_client, :start_session, [
        planner_codex_config,
        workspace_path,
        [tracker_config: nil, on_event: fn _event -> :ok end]
      ])

    try do
      {result, _session} =
        apply(codex_client, :run_turn, [
          session,
          planner_prompt(issue, config, coding_config),
          [capture_agent_text: true]
        ])

      result
      |> agent_message_text()
      |> parse_json_object()
      |> normalize_plan(issue, config, planner: "llm", source: "llm")
      |> apply_rules_crosscheck(issue, config)
    after
      apply(codex_client, :stop_session, [session])
    end
  end

  defp planner_prompt(issue, config, coding_config) do
    payload = %{
      "issue" => Issue.to_template_data(issue),
      "repositories" => Enum.map(config.repositories, &RepositoryConfig.to_prompt_data/1),
      "coding_context" =>
        if(coding_config.enabled,
          do: coding_config |> CodingContext.load_coding_context() |> Utils.truncate(30_000),
          else: ""
        )
    }

    """
    You are Symphony's repository planner for a background coding agent.
    Pick the repository set the agent is allowed to use for this Linear issue. Many valid tasks span multiple repos, so return a primary repo plus optional secondary/edit repos and read-only context repos. Prefer the runtime/product repo that owns the behavior as primary. Do not choose a gateway/config repo merely because the issue mentions AI, search, prompts, or suggestions if the runtime/UI/provider adapter lives elsewhere. If the issue requests a specific provider/integration, keep that provider direction in the reason.

    Return only one JSON object, no markdown, no prose, and no tool calls.
    Schema:
    {
      "coding_task": true,
      "primary_repo": {"slug": "owner/name", "reason": "why this repo is the start"},
      "secondary_repos": [{"slug": "owner/name", "reason": "why it may need edits", "edit_allowed": true}],
      "read_only_context_repos": [{"slug": "owner/name", "reason": "why it is useful context"}],
      "confidence": 0.0,
      "needs_human": false,
      "human_reason": null,
      "notes": "short operational note"
    }

    Rules:
    - Use only repository slugs listed in the input catalog.
    - If there is no clear primary repo, set needs_human=true and explain.
    - If a secondary repo might need edits, include it as secondary_repos with edit_allowed=true.
    - If a repo is only background material, include it as read_only_context_repos.
    - If the issue is not a coding/repository task, set coding_task=false and leave repo lists empty.
    - Route post-call, saved-call, call-history, history-detail, history-tab, recap, follow-up email, and template UI work to the web/customer app repository when one exists. Do not route those issues to a desktop/live-runtime repository unless the issue explicitly names desktop overlay, native capture, transcription, or live in-call behavior.

    Planner input JSON:
    #{Jason.encode!(payload)}
    """
  end

  defp plan_with_rules(issue, config, source) do
    text =
      "#{issue.identifier}\n#{issue.title}\n#{issue.description || ""}\n#{Enum.join(issue.labels, " ")}"
      |> String.downcase()

    scored =
      config.repositories
      |> Enum.flat_map(fn repo ->
        {score, strong_score, reasons} = score_repo(repo, text)
        if score > 0, do: [{score, strong_score, repo, Enum.take(reasons, 6)}], else: []
      end)
      |> Enum.sort_by(fn {score, strong_score, repo, _reasons} ->
        {-score, -strong_score, repo.slug}
      end)

    case scored do
      [] ->
        %RepoPlan{
          issue_identifier: issue.identifier,
          coding_task: true,
          planner: config.planner,
          source: source,
          needs_human: true,
          human_reason: "No configured repository matched the issue text.",
          confidence: 0.0,
          created_at: Utils.now_utc()
        }

      [{top_score, top_strong_score, top_repo, top_reasons} | rest] ->
        tied =
          scored
          |> Enum.filter(fn {score, strong_score, _repo, _} ->
            score == top_score and strong_score == top_strong_score
          end)
          |> Enum.map(fn {_, _, repo, _} -> repo.slug end)

        needs_human = length(tied) > 1

        %RepoPlan{
          issue_identifier: issue.identifier,
          coding_task: true,
          planner: config.planner,
          source: source,
          primary_repo:
            item(top_repo, "primary", "Rules matched: #{Enum.join(top_reasons, ", ")}"),
          secondary_repos:
            rest
            |> Enum.take(3)
            |> Enum.map(fn {_score, _strong_score, repo, reasons} ->
              item(repo, "secondary", "Rules also matched: #{Enum.join(reasons, ", ")}")
            end),
          confidence: min(0.85, max(0.2, top_score / 12)),
          needs_human: needs_human,
          human_reason:
            if(needs_human,
              do: "Rules planner found tied primary repositories: #{Enum.join(tied, ", ")}"
            ),
          created_at: Utils.now_utc()
        }
    end
  end

  defp apply_rules_crosscheck(
         %RepoPlan{coding_task: true, primary_repo: %RepoPlanItem{} = llm_primary} = plan,
         %Issue{} = issue,
         %RepositoryPlanningConfig{} = config
       ) do
    rules_plan = plan_with_rules(issue, config, "llm:rules_crosscheck")
    rules_primary = rules_plan.primary_repo

    cond do
      rules_plan.needs_human or is_nil(rules_primary) ->
        plan

      rules_primary.slug == llm_primary.slug ->
        plan

      not Enum.any?(plan.read_only_context_repos, &(&1.slug == rules_primary.slug)) ->
        plan

      true ->
        promote_rules_primary(plan, rules_primary, llm_primary)
    end
  end

  defp apply_rules_crosscheck(plan, _issue, _config), do: plan

  defp promote_rules_primary(%RepoPlan{} = plan, %RepoPlanItem{} = rules_primary, llm_primary) do
    promoted =
      rules_primary
      |> retag_plan_item("primary", true)
      |> Map.put(
        :reason,
        "#{rules_primary.reason}; promoted over LLM primary #{llm_primary.slug} because the LLM marked this rules-matched repo as read-only context."
      )

    demoted =
      llm_primary
      |> retag_plan_item("read_only_context", false)
      |> Map.put(
        :reason,
        "LLM initially selected this as primary, but rules cross-check promoted #{rules_primary.slug}."
      )

    secondary =
      plan.secondary_repos
      |> Enum.reject(&(&1.slug in [rules_primary.slug, llm_primary.slug]))

    read_only =
      [demoted | plan.read_only_context_repos]
      |> Enum.reject(&(&1.slug == rules_primary.slug))
      |> dedupe_items()

    %{
      plan
      | primary_repo: promoted,
        secondary_repos: secondary,
        read_only_context_repos: read_only,
        source: "llm+rules_crosscheck",
        notes:
          [
            plan.notes,
            "Rules cross-check promoted #{rules_primary.slug} over #{llm_primary.slug}."
          ]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" ")
    }
  end

  defp retag_plan_item(%RepoPlanItem{} = item, role, edit_allowed) do
    %{item | role: role, edit_allowed: edit_allowed}
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp score_repo(%RepositoryConfig{} = repo, text) do
    candidates =
      [
        {String.downcase(repo.slug), 4},
        {String.downcase(RepositoryConfig.path_name(repo)), 4}
        | Enum.map(repo.aliases, &{String.downcase(&1), 3})
      ]
      |> Enum.uniq_by(fn {candidate, _weight} -> candidate end)

    {score, strong_score, reasons} =
      candidates
      |> Enum.reject(fn {candidate, _weight} -> candidate == "" end)
      |> Enum.reduce({0, 0, []}, fn {candidate, weight}, {score, strong_score, reasons} ->
        if term_matches?(text, candidate) do
          {score + weight, strong_score + weight, append_reason(reasons, candidate)}
        else
          {score, strong_score, reasons}
        end
      end)

    if repo.description do
      repo.description
      |> keyword_terms()
      |> Enum.reduce({score, strong_score, reasons}, fn word, {score, strong_score, reasons} ->
        if term_matches?(text, word),
          do: {score + 1, strong_score, append_reason(reasons, word)},
          else: {score, strong_score, reasons}
      end)
    else
      {score, strong_score, reasons}
    end
  end

  defp term_matches?(_text, ""), do: false

  defp term_matches?(text, term) do
    term = String.trim(term)

    if term == "" do
      false
    else
      pattern = "(^|[^[:alnum:]])" <> Regex.escape(term) <> "($|[^[:alnum:]])"
      Regex.match?(Regex.compile!(pattern, "u"), text)
    end
  end

  defp append_reason(reasons, reason) do
    if reason in reasons, do: reasons, else: reasons ++ [reason]
  end

  defp item(%RepositoryConfig{} = repo, role, reason, opts \\ []) do
    edit_allowed =
      Keyword.get(opts, :edit_allowed, role != "read_only_context") and
        role != "read_only_context"

    %RepoPlanItem{
      slug: repo.slug,
      role: role,
      reason: reason,
      path_name: Utils.sanitize_workspace_key(RepositoryConfig.path_name(repo)),
      edit_allowed: edit_allowed
    }
  end

  defp normalize_plan(data, issue, config, opts) do
    known = RepositoryPlanningConfig.repository_by_slug(config)
    unknown = []

    {primary, unknown} =
      parse_plan_item(Utils.map_get(data, "primary_repo"), "primary", known, unknown)

    {secondary, unknown} =
      data
      |> Utils.map_get("secondary_repos")
      |> list_value()
      |> Enum.reduce({[], unknown}, fn raw, {items, unknown_acc} ->
        case parse_plan_item(raw, "secondary", known, unknown_acc) do
          {nil, next_unknown} -> {items, next_unknown}
          {item, next_unknown} -> {items ++ [item], next_unknown}
        end
      end)

    {read_only, unknown} =
      data
      |> Utils.map_get("read_only_context_repos")
      |> list_value()
      |> Enum.reduce({[], unknown}, fn raw, {items, unknown_acc} ->
        case parse_plan_item(raw, "read_only_context", known, unknown_acc) do
          {nil, next_unknown} -> {items, next_unknown}
          {item, next_unknown} -> {items ++ [item], next_unknown}
        end
      end)

    secondary = dedupe_items(secondary)
    read_only = dedupe_items(read_only)

    secondary =
      if primary,
        do: Enum.reject(secondary, &(&1.slug == primary.slug)),
        else: secondary

    read_only =
      if primary,
        do: Enum.reject(read_only, &(&1.slug == primary.slug)),
        else: read_only

    coding_task =
      truthy?(Utils.map_get(data, "coding_task", Utils.map_get(data, "is_coding_task", true)))

    needs_human = truthy?(Utils.map_get(data, "needs_human"))
    human_reason = clean_truncated(Utils.map_get(data, "human_reason"), 500)

    {needs_human, human_reason} =
      if coding_task and is_nil(primary) do
        {true, human_reason || "Repository planner did not return a primary repo."}
      else
        {needs_human, human_reason}
      end

    {needs_human, human_reason} =
      if unknown != [] do
        suffix =
          "Planner returned unknown repositories: #{unknown |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")}."

        {true,
         [human_reason, suffix] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.trim()}
      else
        {needs_human, human_reason}
      end

    %RepoPlan{
      issue_identifier: issue.identifier,
      coding_task: coding_task,
      planner: Keyword.fetch!(opts, :planner),
      source: Keyword.fetch!(opts, :source),
      primary_repo: primary,
      secondary_repos: secondary,
      read_only_context_repos: read_only,
      confidence: confidence(Utils.map_get(data, "confidence")),
      needs_human: needs_human,
      human_reason: if(human_reason == "", do: nil, else: human_reason),
      notes: clean_truncated(Utils.map_get(data, "notes"), 500),
      created_at: Utils.now_utc()
    }
  end

  defp parse_plan_item(raw, role, known, unknown) when is_map(raw) do
    slug = raw |> Utils.map_get("slug") |> to_string() |> String.trim()

    cond do
      slug == "" ->
        {nil, unknown}

      repo = known[slug] ->
        edit_allowed = truthy?(Utils.map_get(raw, "edit_allowed", role != "read_only_context"))

        {item(repo, role, clean_truncated(Utils.map_get(raw, "reason"), 500),
           edit_allowed: edit_allowed
         ), unknown}

      true ->
        {nil, unknown ++ [slug]}
    end
  end

  defp parse_plan_item(_raw, _role, _known, unknown), do: {nil, unknown}

  defp dedupe_items(items) do
    {deduped, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, seen} ->
        if MapSet.member?(seen, item.slug),
          do: {acc, seen},
          else: {acc ++ [item], MapSet.put(seen, item.slug)}
      end)

    deduped
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp confidence(value) do
    case Utils.to_float(value) do
      nil -> nil
      float -> float |> max(0.0) |> min(1.0)
    end
  end

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp clean_truncated(nil, _limit), do: nil

  defp clean_truncated(value, limit) do
    text = value |> to_string() |> Utils.truncate(limit) |> String.trim()
    if text == "", do: nil, else: text
  end

  defp agent_message_text(result) when is_map(result) do
    Map.get(result, :agent_message_text) || Map.get(result, "agent_message_text") || ""
  end

  defp agent_message_text(_), do: ""

  defp parse_json_object(text) do
    stripped = String.trim(to_string(text || ""))

    if stripped == "" do
      raise ArgumentError, message: "repo planner returned empty text"
    end

    value =
      case Jason.decode(stripped) do
        {:ok, decoded} ->
          decoded

        {:error, _reason} ->
          stripped |> extract_json_object() |> Jason.decode!()
      end

    unless is_map(value) do
      raise ArgumentError, message: "repo planner JSON is not an object"
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
        raise ArgumentError, message: "repo planner output did not contain a JSON object"
    end
  end

  defp keyword_terms(text) do
    stop =
      MapSet.new([
        "the",
        "and",
        "for",
        "with",
        "from",
        "that",
        "this",
        "repo",
        "choose",
        "validation",
        "local",
        "path"
      ])

    text
    |> String.downcase()
    |> String.replace(~r/[\/-]/, " ")
    |> String.split()
    |> Enum.map(&String.replace(&1, ~r/[^[:alnum:]]/, ""))
    |> Enum.filter(&(String.length(&1) >= 5 and !MapSet.member?(stop, &1)))
    |> Enum.take(40)
  end
end
