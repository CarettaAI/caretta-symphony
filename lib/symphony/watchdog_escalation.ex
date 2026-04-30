defmodule Symphony.WatchdogEscalation do
  @moduledoc false

  alias Symphony.Config.ServiceConfig
  alias Symphony.Logging
  alias Symphony.Tracker
  alias Symphony.Utils

  @header "## Symphony Watchdog Escalation"

  def escalate(%ServiceConfig{} = config, payload, opts \\ []) when is_map(payload) do
    reason = Keyword.get(opts, :reason, "watchdog could not fix the issue")
    source = Keyword.get(opts, :source, "watchdog")
    issue_identifier = Keyword.get(opts, :issue_identifier) || issue_identifier(payload)

    cond do
      !config.tracker.blocked_escalation_enabled ->
        {:skipped, "watchdog escalation is disabled"}

      blank?(issue_identifier) ->
        {:skipped, "watchdog escalation has no Linear issue identifier"}

      true ->
        tracker = Keyword.get_lazy(opts, :tracker, fn -> Tracker.make_tracker(config.tracker) end)

        if tracker_supports?(tracker, :save_issue_comment) do
          do_escalate(tracker, config, payload, issue_identifier, reason, source)
        else
          {:skipped, "tracker does not support Linear comments"}
        end
    end
  rescue
    error ->
      {:error, Utils.truncate(Exception.message(error), 1000)}
  end

  defp do_escalate(tracker, config, payload, issue_identifier, reason, source) do
    body = body(tracker, config, payload, issue_identifier, reason, source)

    comments =
      if tracker_supports?(tracker, :list_issue_comments),
        do: list_comments(tracker, issue_identifier),
        else: []

    comment_id = find_escalation_comment_id(comments)

    args = [issue_identifier, body, if(comment_id, do: [comment_id: comment_id], else: [])]
    response = call_tracker(tracker, :save_issue_comment, args)
    saved_comment_id = comment_id || comment_id_from_response(response)

    Logging.log_event(:info, "watchdog_issue_escalated",
      issue_identifier: issue_identifier,
      comment_id: saved_comment_id,
      source: source
    )

    {:ok, %{issue_identifier: issue_identifier, comment_id: saved_comment_id}}
  end

  defp body(tracker, %ServiceConfig{} = config, payload, issue_identifier, reason, source) do
    mention = mention(tracker, payload, config)
    mention_line = if mention, do: "#{mention} ", else: ""
    retry = primary_retry(payload)
    error = retry_error(retry)

    retry_text =
      if retry == %{} do
        "I do not have a specific retry record attached to this escalation."
      else
        """
        The job that triggered this was #{retry["issue_identifier"] || issue_identifier}#{retry_title_phrase(retry)}, on attempt #{retry["attempt"] || "n/a"}. The last failure I saw was: #{Utils.truncate(error || "n/a", 1600)}
        """
      end

    """
    #{@header}

    #{mention_line}Symphony watchdog tried to recover this issue, but it did not get to a clean finish.

    Here is what it found: #{reason}

    #{automation_status(source)} This escalation came from `#{source}`.

    #{String.trim(retry_text)}

    The practical next step is: #{action_needed(source)}
    """
    |> String.trim()
  end

  defp retry_title_phrase(retry) do
    case retry["title"] do
      title when is_binary(title) and title != "" -> " (#{title})"
      _ -> ""
    end
  end

  defp automation_status("self_heal_failed") do
    "A triage agent approved self-heal, but the self-heal run did not complete successfully. This is a Symphony control-plane escalation, not a request for the product issue owner to guess what happened."
  end

  defp automation_status("triage_rejected") do
    "A triage agent reviewed the failure and rejected autonomous repair. Watchdog is asking for a human because it judged the item outside its fix scope."
  end

  defp automation_status("manual_repair_applied") do
    "The generated repair has been applied to the local Symphony tree and service artifact. This comment is a corrected status update for the earlier escalation."
  end

  defp automation_status(source) do
    "Watchdog escalated from source=#{source} after its guardrails did not allow a completed repair."
  end

  defp action_needed("self_heal_failed") do
    "Review the self-heal run result and deploy or repair the generated Symphony fix. If self-heal was skipped by cooldown or another guardrail, clear that control-plane blocker and rerun the watchdog path."
  end

  defp action_needed("triage_rejected") do
    "Use the diagnosis and last failure above to route the issue to the right owner. If this is actually a Symphony service problem, re-run watchdog after adjusting the scope or config."
  end

  defp action_needed("manual_repair_applied") do
    "No vague product-owner input is needed for this failure. Let Symphony continue, and if the same signature returns, inspect the Codex app-server protocol handling before retrying product work."
  end

  defp action_needed(_source) do
    "Use the diagnosis and last failure above to route the issue to the concrete owner: Symphony control-plane, repo/product work, credentials, or a human product decision."
  end

  defp issue_identifier(payload) do
    payload
    |> primary_retry()
    |> Map.get("issue_identifier")
  end

  defp primary_retry(%{"retrying" => [first | _]}) when is_map(first), do: first
  defp primary_retry(%{retrying: [first | _]}) when is_map(first), do: first
  defp primary_retry(_payload), do: %{}

  defp retry_error(retry) when is_map(retry),
    do: Utils.map_get(retry, "error") || Utils.map_get(retry, :error)

  defp retry_error(_retry), do: nil

  defp mention(tracker, payload, config) do
    retry = primary_retry(payload)

    verified_assignee_mention(retry) ||
      resolve_user_mention(tracker, assignee_queries(retry)) ||
      resolve_user_mention(tracker, fallback_queries(config))
  end

  defp verified_assignee_mention(%{"assignee" => assignee}) when is_map(assignee) do
    assignee_id = Utils.map_get(assignee, "id")

    if present?(assignee_id) do
      handle_mention(Utils.map_get(assignee, "mention")) ||
        handle_mention(Utils.map_get(assignee, "display_name")) ||
        handle_mention(Utils.map_get(assignee, "displayName")) ||
        handle_mention(Utils.map_get(assignee, "name"))
    end
  end

  defp verified_assignee_mention(%{assignee: assignee}) when is_map(assignee),
    do: verified_assignee_mention(%{"assignee" => assignee})

  defp verified_assignee_mention(_), do: nil

  defp assignee_queries(%{"assignee" => assignee}) when is_map(assignee) do
    [
      Utils.map_get(assignee, "mention"),
      Utils.map_get(assignee, "display_name"),
      Utils.map_get(assignee, "displayName"),
      Utils.map_get(assignee, "name"),
      Utils.map_get(assignee, "email"),
      Utils.map_get(assignee, "id")
    ]
    |> clean_queries()
  end

  defp assignee_queries(%{assignee: assignee}) when is_map(assignee),
    do: assignee_queries(%{"assignee" => assignee})

  defp assignee_queries(_), do: []

  defp fallback_queries(%ServiceConfig{} = config) do
    config.tracker.blocked_escalation_mentions
    |> clean_queries()
  end

  defp clean_queries(values) do
    values
    |> Enum.map(&clean_query/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp clean_query(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.trim()
  end

  defp resolve_user_mention(_tracker, []), do: nil

  defp resolve_user_mention(tracker, queries) do
    if tracker_supports?(tracker, :list_users) do
      Enum.find_value(queries, &query_user_mention(tracker, &1))
    end
  end

  defp query_user_mention(tracker, query) do
    tracker
    |> call_tracker(:list_users, [[query: query, limit: 10]])
    |> matching_user(query)
    |> user_mention()
  rescue
    _ -> nil
  end

  defp matching_user(users, query) when is_list(users) do
    normalized = normalize(query)
    active_users = Enum.filter(users, &active_user?/1)

    Enum.find(active_users, &user_matches?(&1, normalized)) ||
      if(length(active_users) == 1, do: hd(active_users))
  end

  defp matching_user(_users, _query), do: nil

  defp active_user?(user) when is_map(user), do: Utils.map_get(user, "isActive", true) != false
  defp active_user?(_user), do: false

  defp user_matches?(user, normalized_query) when is_map(user) do
    [
      Utils.map_get(user, "id"),
      Utils.map_get(user, "displayName"),
      Utils.map_get(user, "display_name"),
      Utils.map_get(user, "name"),
      Utils.map_get(user, "email"),
      Utils.map_get(user, "username"),
      Utils.map_get(user, "handle")
    ]
    |> Enum.any?(&(normalize(&1) == normalized_query))
  end

  defp user_matches?(_user, _query), do: false

  defp user_mention(user) when is_map(user) do
    handle_mention(Utils.map_get(user, "displayName")) ||
      handle_mention(Utils.map_get(user, "display_name")) ||
      handle_mention(Utils.map_get(user, "username")) ||
      handle_mention(Utils.map_get(user, "handle")) ||
      handle_mention(Utils.map_get(user, "name"))
  end

  defp user_mention(_user), do: nil

  defp handle_mention(value) do
    text = clean_query(value)

    cond do
      text == "" -> nil
      String.contains?(text, "@") -> nil
      true -> "@#{text}"
    end
  end

  defp normalize(value) do
    value
    |> clean_query()
    |> String.downcase()
  end

  defp find_escalation_comment_id(comments) do
    Enum.find_value(comments, fn comment ->
      body = Utils.map_get(comment, "body") || Utils.map_get(comment, "text") || ""

      if String.contains?(to_string(body), @header) do
        Utils.map_get(comment, "id")
      end
    end)
  end

  defp list_comments(tracker, issue_identifier) do
    call_tracker(tracker, :list_issue_comments, [issue_identifier])
  rescue
    _ -> []
  end

  defp tracker_supports?(%{__struct__: module}, function) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> Enum.any?(1..4, &function_exported?(module, function, &1))
      _ -> false
    end
  end

  defp tracker_supports?(tracker, function) when is_atom(tracker) do
    case Code.ensure_loaded(tracker) do
      {:module, ^tracker} -> Enum.any?(1..4, &function_exported?(tracker, function, &1))
      _ -> false
    end
  end

  defp tracker_supports?(tracker, function) when is_map(tracker),
    do: Map.has_key?(tracker, function)

  defp tracker_supports?(_tracker, _function), do: false

  defp call_tracker(%{__struct__: module} = tracker, function, args),
    do: apply(module, function, [tracker | args])

  defp call_tracker(tracker, function, args) when is_atom(tracker),
    do: apply(tracker, function, args)

  defp call_tracker(tracker, function, args) when is_map(tracker),
    do: apply(Map.fetch!(tracker, function), args)

  defp comment_id_from_response(response) when is_map(response) do
    Utils.map_get(response, "id") || get_in(response, ["comment", "id"])
  end

  defp comment_id_from_response(_), do: nil

  defp present?(value), do: !blank?(value)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
