defmodule Symphony.CodingContext do
  @moduledoc false

  alias Symphony.CodexClient
  alias Symphony.Config.{CodexConfig, CodingContextConfig}
  alias Symphony.Models.Issue
  alias Symphony.Utils

  defmodule CodingClassification do
    defstruct is_coding_task: false, source: nil, confidence: nil, reason: nil
  end

  def is_coding_issue(%Issue{} = issue, %CodingContextConfig{} = config),
    do: rules_classify(issue, config)

  def classify_coding_issue(%Issue{} = issue, %CodingContextConfig{} = config, opts \\ []) do
    cond do
      !config.enabled ->
        %CodingClassification{is_coding_task: false, source: "disabled"}

      config.classifier == "always" ->
        %CodingClassification{
          is_coding_task: true,
          source: "always",
          confidence: 1.0,
          reason: "Configured to always inject coding context."
        }

      config.classifier == "rules" ->
        %CodingClassification{is_coding_task: rules_classify(issue, config), source: "rules"}

      true ->
        codex_config = Keyword.get(opts, :codex_config)
        workspace_path = Keyword.get(opts, :workspace_path)

        if is_nil(codex_config) or is_nil(workspace_path) do
          fallback_classification(
            issue,
            config,
            "LLM classifier unavailable: missing codex config or workspace."
          )
        else
          try do
            classify_with_llm(issue, config, codex_config, workspace_path)
          rescue
            error ->
              fallback_classification(
                issue,
                config,
                "LLM classifier failed: #{Exception.message(error)}"
              )
          end
        end
    end
  end

  def augment_prompt_with_coding_context(
        prompt,
        %Issue{} = issue,
        %CodingContextConfig{} = config,
        opts \\ []
      ) do
    classification =
      Keyword.get_lazy(opts, :classification, fn ->
        classify_coding_issue(issue, config,
          codex_config: Keyword.get(opts, :codex_config),
          workspace_path: Keyword.get(opts, :workspace_path)
        )
      end)

    if on_event = Keyword.get(opts, :on_event) do
      on_event.(%{
        "event" => "coding_context_classified",
        "coding_context_injected" => classification.is_coding_task,
        "classification_source" => classification.source,
        "classification_confidence" => classification.confidence,
        "classification_reason" => classification.reason
      })
    end

    if classification.is_coding_task do
      context = load_coding_context(config)

      if String.trim(context) == "" do
        prompt
      else
        """
        <symphony_coding_context>
        This Linear issue is classified as a coding task. Read this context before choosing a repo or editing files. If this context conflicts with older assumptions, this context and the current Linear issue text win.

        Classification source: #{classification.source}
        Classification reason: #{classification.reason || "(none)"}

        #{context}
        </symphony_coding_context>

        #{prompt}
        """
        |> String.trim()
      end
    else
      prompt
    end
  end

  def load_coding_context(%CodingContextConfig{} = config) do
    {chunks, _remaining} =
      config.skill_paths
      |> Enum.flat_map(&context_files/1)
      |> Enum.reduce({[], config.max_chars}, fn file_path, {chunks, remaining} ->
        if remaining <= 0 do
          {chunks, remaining}
        else
          case File.read(file_path) do
            {:ok, text} ->
              chunk = "## #{file_path}\n#{String.trim(text)}\n"

              chunk =
                if String.length(chunk) > remaining do
                  String.slice(chunk, 0, remaining)
                  |> String.trim_trailing()
                  |> Kernel.<>("\n[truncated]\n")
                else
                  chunk
                end

              {chunks ++ [chunk], remaining - String.length(chunk)}

            _ ->
              {chunks, remaining}
          end
        end
      end)

    chunks |> Enum.join("\n") |> String.trim()
  end

  defp rules_classify(%Issue{} = issue, %CodingContextConfig{} = config) do
    issue_labels = issue.labels |> Enum.map(&String.downcase/1) |> MapSet.new()

    cond do
      MapSet.size(CodingContextConfig.label_trigger_set(config)) > 0 and
          !MapSet.disjoint?(CodingContextConfig.label_trigger_set(config), issue_labels) ->
        true

      true ->
        haystack = "#{issue.title}\n#{issue.description || ""}" |> String.downcase()
        Enum.any?(config.keyword_triggers, &String.contains?(haystack, String.downcase(&1)))
    end
  end

  defp fallback_classification(issue, config, reason) do
    case config.classification_fallback do
      "inject" ->
        %CodingClassification{
          is_coding_task: true,
          source: "fallback:inject",
          confidence: 0.0,
          reason: reason
        }

      "skip" ->
        %CodingClassification{
          is_coding_task: false,
          source: "fallback:skip",
          confidence: 0.0,
          reason: reason
        }

      _ ->
        %CodingClassification{
          is_coding_task: rules_classify(issue, config),
          source: "fallback:rules",
          confidence: 0.0,
          reason: reason
        }
    end
  end

  defp classify_with_llm(issue, config, %CodexConfig{} = codex_config, workspace_path) do
    classifier_codex_config = %{
      codex_config
      | model: config.classifier_model || codex_config.model,
        effort: config.classifier_effort,
        turn_timeout_ms: config.classification_timeout_ms,
        summary: nil,
        personality: nil
    }

    session =
      CodexClient.start_session(classifier_codex_config, workspace_path,
        tracker_config: nil,
        on_event: fn _ -> :ok end
      )

    try do
      {result, session} =
        CodexClient.run_turn(session, classification_prompt(issue), capture_agent_text: true)

      CodexClient.stop_session(session)
      data = parse_classifier_json(result.agent_message_text)
      needed = data["coding_context_needed"] || data["is_coding_task"]

      unless is_boolean(needed) do
        raise ArgumentError, "classifier JSON missing boolean coding_context_needed"
      end

      confidence =
        case Utils.to_float(data["confidence"]) do
          nil -> nil
          value -> value |> max(0.0) |> min(1.0)
        end

      reason = if data["reason"], do: Utils.truncate(data["reason"], 500)

      %CodingClassification{
        is_coding_task: needed,
        source: "llm",
        confidence: confidence,
        reason: reason
      }
    after
      CodexClient.stop_session(session)
    end
  end

  defp classification_prompt(%Issue{} = issue) do
    issue_json = Jason.encode!(Issue.to_template_data(issue))

    """
    You are a classifier for Symphony, a background coding agent runner.
    Decide whether the current Linear issue is a coding/repository task that should receive architecture and repo-map context before the agent edits files.

    Return only a single JSON object, no markdown, no prose, no tool calls.
    Schema:
    {
      "coding_context_needed": boolean,
      "confidence": number,
      "reason": "short reason"
    }

    Use true for tasks that likely require code, config, scripts, repository changes, debugging, tests, provider integration, product implementation, or repo selection.
    Use false for pure Linear/project-management actions, status checks, tagging, prioritization, or discussion with no likely repo changes.
    If ambiguous, choose true. False negatives are more harmful than extra context.

    Linear issue JSON:
    #{issue_json}
    """
  end

  defp parse_classifier_json(text) do
    stripped = String.trim(text || "")
    if stripped == "", do: raise(ArgumentError, "classifier returned empty text")

    case Jason.decode(stripped) do
      {:ok, %{} = value} ->
        value

      _ ->
        stripped |> extract_json_object() |> Jason.decode!()
    end
  end

  defp extract_json_object(text) do
    start = :binary.match(text, "{")
    finish = :binary.matches(text, "}") |> List.last()

    case {start, finish} do
      {{start_index, 1}, {end_index, 1}} when end_index > start_index ->
        binary_part(text, start_index, end_index - start_index + 1)

      _ ->
        raise ArgumentError, "classifier output did not contain a JSON object"
    end
  end

  defp context_files(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        skill_file = Path.join(path, "SKILL.md")
        references = Path.join(path, "references")
        files = if File.regular?(skill_file), do: [skill_file], else: []

        files ++
          if File.dir?(references),
            do: references |> Path.join("*.md") |> Path.wildcard() |> Enum.sort(),
            else: []

      true ->
        []
    end
  end
end
