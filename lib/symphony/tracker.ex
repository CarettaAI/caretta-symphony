defmodule Symphony.Tracker do
  @moduledoc false

  alias Symphony.Config.TrackerConfig
  alias Symphony.Error
  alias Symphony.Models.{BlockerRef, Issue, IssueAssignee, IssueAttachment}
  alias Symphony.Utils

  defmodule LinearClient do
    @linear_timeout_ms 30_000

    defstruct config: nil, transport: nil

    alias Symphony.Error
    alias Symphony.Models.{BlockerRef, Issue}
    alias Symphony.Tracker
    alias Symphony.Utils

    def fetch_candidate_issues(%__MODULE__{} = client),
      do: fetch_by_states(client, client.config.active_states)

    def fetch_issues_by_states(_client, []), do: []

    def fetch_issues_by_states(%__MODULE__{} = client, states),
      do: fetch_by_states(client, states)

    def fetch_issue_states_by_ids(_client, []), do: []

    def fetch_issue_states_by_ids(%__MODULE__{} = client, issue_ids) do
      query = """
      query SymphonyIssueStates($ids: [ID!]) {
        issues(filter: { id: { in: $ids } }, first: 100) {
          nodes {
            id identifier title description priority branchName url createdAt updatedAt
            assignee { id name displayName email }
            state { name }
            labels { nodes { name } }
            attachments { nodes { id title subtitle url } }
            inverseRelations { nodes { type issue { id identifier state { name } } } }
          }
        }
      }
      """

      body = graphql(client, query, %{"ids" => issue_ids})
      nodes = get_in(body, ["data", "issues", "nodes"])

      unless is_list(nodes) do
        raise Error,
          code: :linear_unknown_payload,
          message: "state refresh payload missing issues.nodes"
      end

      Enum.map(nodes, &normalize_issue/1)
    end

    def execute_graphql_once(%__MODULE__{} = client, query, variables \\ %{}) do
      graphql(client, query, variables || %{})
    end

    defp fetch_by_states(%__MODULE__{} = client, states) do
      query = """
      query SymphonyIssuesByState($projectSlug: String!, $stateNames: [String!], $first: Int!, $after: String) {
        issues(
          filter: {
            project: { slugId: { eq: $projectSlug } }
            state: { name: { in: $stateNames } }
          }
          first: $first
          after: $after
        ) {
          nodes {
            id identifier title description priority branchName url createdAt updatedAt
            assignee { id name displayName email }
            state { name }
            labels { nodes { name } }
            attachments { nodes { id title subtitle url } }
            inverseRelations { nodes { type issue { id identifier state { name } } } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
      """

      fetch_page(client, query, states, nil, [])
    end

    defp fetch_page(client, query, states, after_cursor, acc) do
      body =
        graphql(client, query, %{
          "projectSlug" => client.config.project_slug,
          "stateNames" => states,
          "first" => 50,
          "after" => after_cursor
        })

      connection = get_in(body, ["data", "issues"]) || %{}
      nodes = connection["nodes"]
      page_info = connection["pageInfo"]

      unless is_list(nodes) and is_map(page_info) do
        raise Error,
          code: :linear_unknown_payload,
          message: "candidate payload missing issues.nodes/pageInfo"
      end

      issues = acc ++ Enum.map(nodes, &normalize_issue/1)

      if page_info["hasNextPage"] do
        cursor = page_info["endCursor"]

        unless cursor do
          raise Error,
            code: :linear_missing_end_cursor,
            message: "Linear pagination requested another page without endCursor"
        end

        fetch_page(client, query, states, cursor, issues)
      else
        issues
      end
    end

    defp graphql(%__MODULE__{transport: transport}, query, variables)
         when is_function(transport, 2) do
      body = transport.(query, variables)
      validate_graphql_body(body)
    end

    defp graphql(%__MODULE__{} = client, query, variables) do
      unless client.config.endpoint,
        do: raise(Error, code: :linear_api_request, message: "Linear endpoint is missing")

      unless client.config.api_key,
        do: raise(Error, code: :missing_tracker_api_key, message: "Linear API key is missing")

      request_body = Jason.encode!(%{"query" => query, "variables" => variables})

      headers = [
        {~c"authorization", to_charlist(client.config.api_key)},
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"application/json"}
      ]

      request = {to_charlist(client.config.endpoint), headers, ~c"application/json", request_body}

      case :httpc.request(:post, request, [{:timeout, @linear_timeout_ms}], body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          body |> Jason.decode!() |> validate_graphql_body()

        {:ok, {{_, status, _}, _headers, _body}} ->
          raise Error, code: :linear_api_status, message: "Linear HTTP status #{status}"

        {:error, reason} ->
          raise Error,
            code: :linear_api_request,
            message: "Linear request failed: #{inspect(reason)}"
      end
    end

    defp validate_graphql_body(body) when is_map(body) do
      if body["errors"],
        do: raise(Error, code: :linear_graphql_errors, message: "Linear GraphQL returned errors")

      body
    end

    defp validate_graphql_body(_),
      do:
        raise(Error,
          code: :linear_unknown_payload,
          message: "Linear response is not a JSON object"
        )

    defp normalize_issue(node) when is_map(node) do
      state = get_in(node, ["state", "name"])

      labels =
        get_in(node, ["labels", "nodes"])
        |> normalize_label_nodes()

      attachments = Tracker.normalize_attachments(get_in(node, ["attachments", "nodes"]))

      blockers =
        node
        |> get_in(["inverseRelations", "nodes"])
        |> case do
          nodes when is_list(nodes) -> nodes
          _ -> []
        end
        |> Enum.flat_map(fn
          %{"type" => "blocks", "issue" => issue} when is_map(issue) ->
            [
              %BlockerRef{
                id: issue["id"],
                identifier: issue["identifier"],
                state: get_in(issue, ["state", "name"])
              }
            ]

          _ ->
            []
        end)

      priority =
        if is_integer(node["priority"]) and !is_boolean(node["priority"]), do: node["priority"]

      %Issue{
        id:
          to_string(
            node["id"] ||
              raise(Error,
                code: :linear_unknown_payload,
                message: "issue node missing required field id"
              )
          ),
        identifier:
          to_string(
            node["identifier"] ||
              raise(Error,
                code: :linear_unknown_payload,
                message: "issue node missing required field identifier"
              )
          ),
        title:
          to_string(
            node["title"] ||
              raise(Error,
                code: :linear_unknown_payload,
                message: "issue node missing required field title"
              )
          ),
        description: node["description"],
        priority: priority,
        state: to_string(state || ""),
        branch_name: node["branchName"],
        url: node["url"],
        assignee: Tracker.normalize_assignee(node["assignee"]),
        labels: labels,
        attachments: attachments,
        blocked_by: blockers,
        created_at: Utils.parse_datetime(node["createdAt"]),
        updated_at: Utils.parse_datetime(node["updatedAt"])
      }
    end

    defp normalize_issue(_),
      do: raise(Error, code: :linear_unknown_payload, message: "issue node is not an object")

    defp normalize_label_nodes(nodes) when is_list(nodes) do
      nodes
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [String.downcase(name)]
        _ -> []
      end)
    end

    defp normalize_label_nodes(_), do: []
  end

  defmodule LinearMcpClient do
    @linear_page_size 50
    @linear_mcp_tool_list_issues "linear mcp server_list_issues"
    @linear_mcp_tool_get_issue "linear mcp server_get_issue"
    @linear_mcp_tool_list_comments "linear mcp server_list_comments"
    @linear_mcp_tool_save_comment "linear mcp server_save_comment"
    @linear_mcp_tool_save_issue "linear mcp server_save_issue"

    defstruct config: nil, gateway: nil

    alias Symphony.Error
    alias Symphony.Models.{BlockerRef, Issue}
    alias Symphony.Tracker
    alias Symphony.Utils

    def fetch_candidate_issues(%__MODULE__{} = client) do
      client.config.active_states
      |> Enum.flat_map(&list_issues(client, state: &1))
      |> hydrate_todo_blockers(client)
      |> dedupe_issues()
    end

    def fetch_issues_by_states(_client, []), do: []

    def fetch_issues_by_states(%__MODULE__{} = client, states) do
      states |> Enum.flat_map(&list_issues(client, state: &1)) |> dedupe_issues()
    end

    def fetch_issue_states_by_ids(%__MODULE__{} = client, ids) do
      Enum.map(ids, fn id ->
        client
        |> call_gateway(@linear_mcp_tool_get_issue, %{"id" => id, "includeRelations" => true})
        |> normalize_issue()
      end)
    end

    def list_issue_comments(%__MODULE__{} = client, issue_id) do
      body =
        call_gateway(client, @linear_mcp_tool_list_comments, %{
          "issueId" => issue_id,
          "limit" => 250,
          "orderBy" => "createdAt"
        })

      cond do
        is_list(body) ->
          Enum.filter(body, &is_map/1)

        is_map(body) and is_list(body["comments"]) ->
          Enum.filter(body["comments"], &is_map/1)

        is_map(body) and is_list(body["nodes"]) ->
          Enum.filter(body["nodes"], &is_map/1)

        true ->
          raise Error,
            code: :linear_unknown_payload,
            message: "Linear MCP comments payload missing comments list"
      end
    end

    def save_issue_comment(%__MODULE__{} = client, issue_id, body, opts \\ []) do
      args =
        if comment_id = Keyword.get(opts, :comment_id) do
          %{"body" => body, "id" => comment_id}
        else
          %{"body" => body, "issueId" => issue_id}
        end

      response = call_gateway(client, @linear_mcp_tool_save_comment, args)

      unless is_map(response),
        do:
          raise(Error,
            code: :linear_unknown_payload,
            message: "Linear MCP save comment response is not an object"
          )

      response
    end

    def save_issue_state(%__MODULE__{} = client, issue_id, state) do
      response =
        call_gateway(client, @linear_mcp_tool_save_issue, %{"id" => issue_id, "state" => state})

      unless is_map(response),
        do:
          raise(Error,
            code: :linear_unknown_payload,
            message: "Linear MCP save issue response is not an object"
          )

      response
    end

    defp list_issues(client, state: state), do: list_issues_page(client, state, nil, [])

    defp list_issues_page(client, state, cursor, acc) do
      args =
        %{"limit" => min(@linear_page_size, 250), "state" => state, "includeArchived" => false}
        |> put_if("project", client.config.project_slug)
        |> put_if("team", client.config.team)
        |> put_if("label", List.first(client.config.required_labels))
        |> put_if("cursor", cursor)

      body = call_gateway(client, @linear_mcp_tool_list_issues, args)
      nodes = body["issues"]

      unless is_list(nodes) do
        raise Error,
          code: :linear_unknown_payload,
          message: "Linear MCP payload missing issues list"
      end

      issues = acc ++ Enum.map(nodes, &normalize_issue/1)

      if body["hasNextPage"] do
        cursor = body["cursor"]

        unless cursor do
          raise Error,
            code: :linear_missing_end_cursor,
            message: "Linear MCP pagination requested another page without cursor"
        end

        list_issues_page(client, state, cursor, issues)
      else
        issues
      end
    end

    defp hydrate_todo_blockers(issues, client) do
      Enum.map(issues, fn issue ->
        if String.downcase(issue.state) == "todo" do
          client
          |> call_gateway(@linear_mcp_tool_get_issue, %{
            "id" => issue.identifier,
            "includeRelations" => true
          })
          |> normalize_issue()
        else
          issue
        end
      end)
    end

    defp normalize_issue(node) when is_map(node) do
      identifier = to_string(node["id"] || "")

      if identifier == "",
        do:
          raise(Error,
            code: :linear_unknown_payload,
            message: "Linear MCP issue payload missing id"
          )

      priority =
        cond do
          is_map(node["priority"]) and is_integer(node["priority"]["value"]) and
              node["priority"]["value"] > 0 ->
            node["priority"]["value"]

          is_integer(node["priority"]) and node["priority"] > 0 ->
            node["priority"]

          true ->
            nil
        end

      blocked_by =
        get_in(node, ["relations", "blockedBy"])
        |> case do
          blockers when is_list(blockers) -> blockers
          _ -> []
        end
        |> Enum.flat_map(fn
          blocker when is_map(blocker) ->
            blocker_id = blocker["id"] || blocker["identifier"]

            [
              %BlockerRef{
                id: blocker_id && to_string(blocker_id),
                identifier: blocker_id && to_string(blocker_id),
                state: blocker["status"] || blocker["state"]
              }
            ]

          _ ->
            []
        end)

      %Issue{
        id: identifier,
        identifier: identifier,
        title: to_string(node["title"] || ""),
        description: node["description"],
        priority: priority,
        state: to_string(node["status"] || node["state"] || ""),
        branch_name: node["gitBranchName"] || node["branchName"],
        url: node["url"],
        assignee: Tracker.normalize_assignee(node["assignee"] || node["owner"]),
        labels: Enum.map(node["labels"] || [], &(to_string(&1) |> String.downcase())),
        attachments: Tracker.normalize_attachments(node["attachments"]),
        blocked_by: blocked_by,
        created_at: Utils.parse_datetime(node["createdAt"]),
        updated_at: Utils.parse_datetime(node["updatedAt"])
      }
    end

    defp normalize_issue(_),
      do:
        raise(Error,
          code: :linear_unknown_payload,
          message: "Linear MCP issue payload is not an object"
        )

    defp call_gateway(%__MODULE__{gateway: gateway}, tool, args) when is_function(gateway, 2),
      do: gateway.(tool, args)

    defp call_gateway(%__MODULE__{gateway: gateway}, tool, args) when not is_nil(gateway) do
      Symphony.Tracker.CodexMcpGateway.call_tool(gateway, tool, args)
    end

    defp call_gateway(%__MODULE__{} = client, tool, args) do
      gateway =
        struct(Symphony.Tracker.CodexMcpGateway,
          command: client.config.mcp_command,
          server: client.config.mcp_server
        )

      Symphony.Tracker.CodexMcpGateway.call_tool(gateway, tool, args)
    end

    defp dedupe_issues(issues) do
      issues
      |> Enum.reduce({MapSet.new(), []}, fn issue, {seen, acc} ->
        if MapSet.member?(seen, issue.id),
          do: {seen, acc},
          else: {MapSet.put(seen, issue.id), acc ++ [issue]}
      end)
      |> elem(1)
    end

    defp put_if(map, _key, nil), do: map
    defp put_if(map, key, value), do: Map.put(map, key, value)
  end

  defmodule CodexMcpGateway do
    @gateway_attempts 3
    @gateway_read_timeout_ms 30_000

    defstruct command: "codex app-server",
              server: "codex_apps",
              cwd: nil,
              read_timeout_ms: @gateway_read_timeout_ms,
              next_id: 1,
              buffer: "",
              port: nil

    alias Symphony.CodexClient
    alias Symphony.Error
    alias Symphony.Utils

    def call_tool(%__MODULE__{} = gateway, tool, arguments) do
      Enum.reduce_while(1..@gateway_attempts, nil, fn attempt, _last_error ->
        try do
          {:halt, call_tool_once(gateway, tool, arguments)}
        rescue
          error in Error ->
            if retryable?(error) and attempt < @gateway_attempts do
              Process.sleep(min(2 * attempt, 5) * 1000)
              {:cont, error}
            else
              reraise error, __STACKTRACE__
            end
        end
      end)
    end

    defp call_tool_once(gateway, tool, arguments) do
      cwd = Path.expand(gateway.cwd || File.cwd!())

      session =
        CodexClient.start_session(
          %Symphony.Config.CodexConfig{
            command: gateway.command,
            read_timeout_ms: gateway.read_timeout_ms
          },
          cwd,
          on_event: fn _ -> :ok end
        )

      try do
        {response, _session} =
          invoke_mcp_request(
            %{gateway | port: session.port, buffer: session.buffer, next_id: session.next_id},
            session.thread_id,
            tool,
            arguments
          )

        decode_tool_response(response)
      after
        CodexClient.stop_session(session)
      end
    end

    defp invoke_mcp_request(gateway, thread_id, tool, arguments) do
      request_id = gateway.next_id
      gateway = %{gateway | next_id: request_id + 1}

      send_message(gateway, %{
        "method" => "mcpServer/tool/call",
        "id" => request_id,
        "params" => %{
          "threadId" => thread_id,
          "server" => gateway.server,
          "tool" => tool,
          "arguments" => arguments
        }
      })

      receive_gateway_response(gateway, request_id)
    end

    defp receive_gateway_response(gateway, request_id) do
      {msg, gateway} = read_message(gateway)

      cond do
        msg["id"] == request_id and !Map.has_key?(msg, "method") ->
          if msg["error"],
            do: raise(Error, code: :linear_mcp_app_server, message: Jason.encode!(msg["error"]))

          {msg["result"] || %{}, gateway}

        Map.has_key?(msg, "method") and Map.has_key?(msg, "id") ->
          gateway = handle_gateway_server_request(gateway, msg)
          receive_gateway_response(gateway, request_id)

        true ->
          receive_gateway_response(gateway, request_id)
      end
    end

    defp send_message(gateway, message) do
      Port.command(gateway.port, Jason.encode!(message) <> "\n")
      gateway
    end

    defp read_message(gateway) do
      case next_line(gateway.buffer) do
        {line, rest} ->
          {Jason.decode!(line), %{gateway | buffer: rest}}

        :none ->
          receive do
            {port, {:data, data}} when port == gateway.port ->
              read_message(%{gateway | buffer: gateway.buffer <> data})

            {port, {:exit_status, status}} when port == gateway.port ->
              raise Error,
                code: :linear_mcp_app_server,
                message: "app-server exited before MCP response: #{status}"
          after
            30_000 ->
              raise Error,
                code: :linear_mcp_app_server,
                message: "timed out waiting for app-server MCP response"
          end
      end
    end

    defp next_line(buffer) do
      case :binary.match(buffer, "\n") do
        {index, 1} ->
          <<line::binary-size(index), _newline, rest::binary>> = buffer
          {String.trim_trailing(line, "\r"), rest}

        :nomatch ->
          :none
      end
    end

    defp handle_gateway_server_request(gateway, msg) do
      request_id = msg["id"]
      method = to_string(msg["method"])
      params = if is_map(msg["params"]), do: msg["params"], else: %{}

      cond do
        method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] ->
          send_message(gateway, %{
            "id" => request_id,
            "result" => %{"decision" => "acceptForSession"}
          })

        method in ["item/tool/requestUserInput", "tool/requestUserInput"] ->
          answers =
            Utils.tool_request_user_input_approval_answers(params) ||
              Utils.tool_request_user_input_unavailable_answers(params)

          if answers do
            send_message(gateway, %{"id" => request_id, "result" => %{"answers" => answers}})
          else
            send_message(gateway, %{
              "id" => request_id,
              "error" => %{"code" => -32601, "message" => "unsupported server request: #{method}"}
            })
          end

        true ->
          send_message(gateway, %{
            "id" => request_id,
            "error" => %{"code" => -32601, "message" => "unsupported server request: #{method}"}
          })
      end
    end

    defp decode_tool_response(response) when is_map(response) do
      if response["isError"],
        do: raise(Error, code: :linear_mcp_tool_error, message: Jason.encode!(response))

      content = response["content"]

      unless is_list(content),
        do:
          raise(Error,
            code: :linear_mcp_app_server,
            message: "MCP tool response missing content list"
          )

      Enum.find_value(content, fn
        %{"type" => "text", "text" => text} when is_binary(text) -> Jason.decode!(text)
        _ -> nil
      end) ||
        raise(Error,
          code: :linear_mcp_app_server,
          message: "MCP tool response did not contain text JSON"
        )
    end

    defp decode_tool_response(_),
      do:
        raise(Error, code: :linear_mcp_app_server, message: "MCP tool response is not an object")

    defp retryable?(%Error{code: :linear_mcp_app_server}), do: true

    defp retryable?(%Error{code: :linear_mcp_tool_error, message: message}),
      do:
        String.contains?(String.downcase(message), [
          "transport",
          "http request failed",
          "timed out",
          "failed to get client"
        ])

    defp retryable?(_), do: false
  end

  def normalize_attachments(value) when is_list(value) do
    Enum.flat_map(value, fn
      item when is_map(item) ->
        [
          %IssueAttachment{
            id: maybe_string(item["id"]),
            title: maybe_string(item["title"]),
            subtitle: maybe_string(item["subtitle"]),
            url: maybe_string(item["url"])
          }
        ]

      _ ->
        []
    end)
  end

  def normalize_attachments(_), do: []

  def normalize_assignee(nil), do: nil

  def normalize_assignee(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "",
      do: nil,
      else: %IssueAssignee{name: trimmed, display_name: trimmed, mention: mention_text(trimmed)}
  end

  def normalize_assignee(value) when is_map(value) do
    id = maybe_string(map_get(value, "id"))
    name = maybe_string(map_get(value, "name") || map_get(value, "username"))
    display_name = maybe_string(map_get(value, "displayName") || map_get(value, "display_name"))
    email = maybe_string(map_get(value, "email"))
    url = maybe_string(map_get(value, "url"))

    mention =
      maybe_string(map_get(value, "mention")) ||
        mention_text(
          map_get(value, "handle") || map_get(value, "username") || display_name || name
        )

    if Enum.any?([id, name, display_name, email, url, mention], &(!is_nil(&1))) do
      %IssueAssignee{
        id: id,
        name: name,
        display_name: display_name,
        email: email,
        url: url,
        mention: mention
      }
    end
  end

  def normalize_assignee(_), do: nil

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp mention_text(nil), do: nil

  defp mention_text(value) do
    text = String.trim(to_string(value))

    cond do
      text == "" -> nil
      String.starts_with?(text, "@") -> text
      true -> "@#{text}"
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  def make_tracker(%TrackerConfig{kind: "linear_mcp"} = config),
    do: %LinearMcpClient{config: config}

  def make_tracker(%TrackerConfig{kind: "linear"} = config), do: %LinearClient{config: config}

  def make_tracker(%TrackerConfig{} = config) do
    raise Error,
      code: :unsupported_tracker_kind,
      message: "unsupported tracker kind: #{config.kind}"
  end
end
