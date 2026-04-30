defmodule Symphony.Templating do
  @moduledoc false

  alias Symphony.Error
  alias Symphony.Models.Issue

  @default_prompt "You are working on an issue from Linear."
  @var_re ~r/{{\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*}}/

  def render_prompt(template_text, %Issue{} = issue, attempt \\ nil) do
    source =
      template_text
      |> to_string()
      |> String.trim()
      |> then(fn text -> if text == "", do: @default_prompt, else: text end)

    data = %{"issue" => Issue.to_template_data(issue), "attempt" => attempt}

    Regex.replace(@var_re, source, fn _match, path ->
      case fetch_path(data, String.split(path, ".")) do
        {:ok, nil} ->
          ""

        {:ok, value} ->
          to_string(value)

        :error ->
          raise Error, code: :template_render_error, message: "undefined variable: #{path}"
      end
    end)
    |> String.trim()
  end

  def continuation_prompt(%Issue{} = issue, turn_number, max_turns) do
    issue_data = Issue.to_template_data(issue)

    """
    Continue working on the same Linear issue in this existing Codex thread.

    Continuation turn: #{turn_number} of #{max_turns}.

    Current Linear issue snapshot, authoritative for this turn:
    Issue: #{issue.identifier} - #{issue.title}
    URL: #{issue.url || "(none)"}
    State: #{issue.state || "(unknown)"}
    Priority: #{issue.priority || "(none)"}
    Labels: #{format_labels(issue.labels)}
    Updated at: #{issue_data["updated_at"] || "(unknown)"}

    Description:
    #{format_description(issue.description)}

    Do not resend the original task from scratch. Inspect current progress, complete the next needed work, validate the result, and perform the workflow-defined handoff if ready. If this current snapshot differs from earlier assumptions, pause and adapt to the current Linear text before editing more code. Do not choose a repository from sibling issue workspaces; use the injected coding context, repo map, or explicit issue text.
    """
    |> String.trim()
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    if Map.has_key?(map, key), do: fetch_path(Map.get(map, key), rest), else: :error
  end

  defp fetch_path(_value, _path), do: :error

  defp format_labels([]), do: "(none)"
  defp format_labels(labels), do: Enum.join(labels, ", ")

  defp format_description(nil), do: "(none)"

  defp format_description(description) do
    text = String.trim(description)
    if text == "", do: "(none)", else: text
  end
end
