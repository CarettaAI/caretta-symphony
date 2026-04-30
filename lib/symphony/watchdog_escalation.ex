defmodule Symphony.WatchdogEscalation do
  @moduledoc false

  alias Symphony.Config.ServiceConfig
  alias Symphony.Tracker
  alias Symphony.Tracker.LinearMcpClient
  alias Symphony.Utils

  @heading "## Symphony Watchdog Escalation"

  def escalate(%ServiceConfig{} = config, payload, opts \\ []) when is_map(payload) do
    if config.tracker.blocked_escalation_enabled do
      issue = primary_issue(payload)
      issue_identifier = issue_identifier(issue)
      tracker = Keyword.get(opts, :tracker) || Tracker.make_tracker(config.tracker)
      reason = Keyword.get(opts, :reason, "watchdog triage requested human escalation")
      source = Keyword.get(opts, :source, "watchdog")

      comments = list_issue_comments(tracker, issue_identifier)
      existing = Enum.find(comments, &watchdog_comment?/1)
      mentions = resolve_mentions(tracker, config.tracker.blocked_escalation_mentions, issue)
      body = comment_body(payload, issue, reason, source, mentions)
      save_opts = if existing, do: [comment_id: existing["id"]], else: []

      response = save_issue_comment(tracker, issue_identifier, body, save_opts)

      {:ok,
       %{
         issue_identifier: issue_identifier,
         comment_id: response["id"] || if(existing, do: existing["id"])
       }}
    else
      {:ok, :disabled}
    end
  end

  defp primary_issue(%{"retrying" => [first | _]}) when is_map(first), do: first
  defp primary_issue(%{"blocked" => [first | _]}) when is_map(first), do: first
  defp primary_issue(%{"running" => [first | _]}) when is_map(first), do: first
  defp primary_issue(_payload), do: %{}

  defp issue_identifier(issue) do
    value =
      Utils.map_get(issue, "issue_identifier") ||
        Utils.map_get(issue, "issue_id") ||
        Utils.map_get(issue, "id")

    text = String.trim(to_string(value || ""))

    if text == "" do
      raise ArgumentError, message: "watchdog escalation payload does not identify an issue"
    end

    text
  end

  defp watchdog_comment?(comment) when is_map(comment) do
    comment |> Utils.map_get("body") |> to_string() |> String.contains?(@heading)
  end

  defp watchdog_comment?(_), do: false

  defp resolve_mentions(tracker, configured_mentions, issue) do
    candidates =
      configured_mentions
      |> List.wrap()
      |> Kernel.++(issue_assignee_mentions(issue))
      |> Enum.map(&mention_query/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {resolved, unresolved} =
      Enum.reduce(candidates, {[], []}, fn query, {resolved, unresolved} ->
        case resolve_user(tracker, query) do
          nil -> {resolved, unresolved ++ [query]}
          mention -> {resolved ++ [mention], unresolved}
        end
      end)

    %{resolved: Enum.uniq(resolved), unresolved: unresolved}
  end

  defp issue_assignee_mentions(issue) do
    assignee = Utils.map_get(issue, "assignee")
    mention = Utils.map_get(assignee, "mention")
    if mention, do: [mention], else: []
  end

  defp mention_query(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp resolve_user(tracker, query) do
    tracker
    |> list_users(query: query, limit: 10)
    |> Enum.find(&active_user?/1)
    |> user_mention(query)
  end

  defp active_user?(user) when is_map(user), do: Utils.map_get(user, "isActive", true) != false
  defp active_user?(_), do: false

  defp user_mention(nil, _query), do: nil

  defp user_mention(user, query) do
    name =
      Utils.map_get(user, "displayName") ||
        Utils.map_get(user, "name") ||
        Utils.map_get(user, "email") ||
        query

    "@#{mention_query(name)}"
  end

  defp comment_body(payload, issue, reason, source, mentions) do
    issue_identifier = issue_identifier(issue)
    error = issue |> Utils.map_get("error") |> to_string() |> Utils.truncate(1000)
    retry_count = length(if is_list(payload["retrying"]), do: payload["retrying"], else: [])
    completed_count = length(if is_list(payload["completed"]), do: payload["completed"], else: [])
    mention_lines = mention_lines(mentions)

    """
    #{@heading}

    #{Enum.join(mention_lines, "\n")}

    Issue: #{issue_identifier}
    Source: #{source}
    Reason: #{reason}
    Retry candidates: #{retry_count}
    Related completed entries: #{completed_count}

    Latest retry error:
    #{error}
    """
    |> String.trim()
  end

  defp mention_lines(%{resolved: [], unresolved: []}), do: []

  defp mention_lines(%{resolved: resolved, unresolved: unresolved}) do
    resolved_lines =
      if resolved == [] do
        []
      else
        ["Attention: #{Enum.join(resolved, " ")}"]
      end

    unresolved_lines =
      if unresolved == [] do
        []
      else
        [
          "Symphony watchdog could not safely resolve #{length(unresolved)} configured mention(s); leaving raw mention text out of this comment."
        ]
      end

    resolved_lines ++ unresolved_lines
  end

  defp list_issue_comments(%LinearMcpClient{} = tracker, issue_identifier),
    do: LinearMcpClient.list_issue_comments(tracker, issue_identifier)

  defp list_issue_comments(%{} = tracker, issue_identifier) do
    case Map.fetch(tracker, :list_issue_comments) do
      {:ok, fun} when is_function(fun, 1) -> fun.(issue_identifier)
      _ -> []
    end
  end

  defp save_issue_comment(%LinearMcpClient{} = tracker, issue_identifier, body, opts),
    do: LinearMcpClient.save_issue_comment(tracker, issue_identifier, body, opts)

  defp save_issue_comment(%{} = tracker, issue_identifier, body, opts) do
    case Map.fetch(tracker, :save_issue_comment) do
      {:ok, fun} when is_function(fun, 3) -> fun.(issue_identifier, body, opts)
      _ -> %{}
    end
  end

  defp list_users(%LinearMcpClient{} = tracker, opts),
    do: LinearMcpClient.list_users(tracker, opts)

  defp list_users(%{} = tracker, opts) do
    case Map.fetch(tracker, :list_users) do
      {:ok, fun} when is_function(fun, 1) -> fun.(opts)
      _ -> []
    end
  end
end
