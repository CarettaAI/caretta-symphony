defmodule Symphony.CodexClient do
  @moduledoc false

  alias Symphony.Config.{CodexConfig, TrackerConfig}
  alias Symphony.Error
  alias Symphony.Tracker.LinearClient
  alias Symphony.Utils

  defmodule TurnResult do
    defstruct thread_id: nil, turn_id: nil, status: nil, agent_message_text: ""
  end

  defmodule Session do
    defstruct [
      :config,
      :workspace_path,
      :tracker_config,
      :on_event,
      :port,
      :os_pid,
      :thread_id,
      next_id: 1,
      buffer: "",
      agent_text_capture: nil
    ]
  end

  def start_session(%CodexConfig{} = config, workspace_path, opts \\ []) do
    workspace_path = Path.expand(workspace_path)

    unless File.dir?(workspace_path) do
      raise Error,
        code: :invalid_workspace_cwd,
        message: "workspace cwd does not exist: #{workspace_path}"
    end

    port = open_command_port(config.command, workspace_path)
    os_pid = port_os_pid(port)

    session = %Session{
      config: config,
      workspace_path: workspace_path,
      tracker_config: Keyword.get(opts, :tracker_config),
      on_event: Keyword.get(opts, :on_event, fn _event -> :ok end),
      port: port,
      os_pid: os_pid
    }

    emit(session, %{"event" => "app_server_started", "codex_app_server_pid" => to_string(os_pid)})

    try do
      {_, session} =
        request(
          session,
          "initialize",
          %{
            "clientInfo" => %{
              "name" => "symphony_runner",
              "title" => "Symphony Runner",
              "version" => Symphony.version()
            },
            "capabilities" => %{"experimentalApi" => true}
          },
          config.read_timeout_ms
        )

      session = notify(session, "initialized", %{})

      thread_params =
        %{
          "cwd" => workspace_path,
          "approvalPolicy" => config.approval_policy,
          "sandbox" => config.thread_sandbox,
          "serviceName" => "symphony_runner",
          "sessionStartSource" => "startup"
        }
        |> put_if("model", config.model)
        |> put_if("personality", config.personality)

      {response, session} =
        request(session, "thread/start", thread_params, config.read_timeout_ms)

      thread_id = get_in(response, ["thread", "id"])

      unless thread_id do
        raise Error,
          code: :response_error,
          message: "thread/start response did not include thread.id"
      end

      %{session | thread_id: to_string(thread_id)}
    rescue
      error ->
        stop_session(session)
        reraise error, __STACKTRACE__
    end
  end

  def stop_session(nil), do: :ok

  def stop_session(%Session{port: nil}), do: :ok

  def stop_session(%Session{} = session) do
    if Port.info(session.port) do
      Port.close(session.port)
    end

    kill_os_pid(session.os_pid)

    emit(session, %{
      "event" => "app_server_stopped",
      "codex_app_server_pid" => to_string(session.os_pid),
      "returncode" => nil
    })

    :ok
  catch
    _, _ -> :ok
  end

  defp kill_os_pid(nil), do: :ok

  defp kill_os_pid(pid) do
    pid = to_string(pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
    Process.sleep(100)
    {_out, status} = System.cmd("ps", ["-p", pid], stderr_to_stdout: true)
    if status == 0, do: System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  def run_turn(%Session{thread_id: nil}) do
    raise Error, code: :response_error, message: "thread has not been started"
  end

  def run_turn(%Session{} = session, prompt, opts \\ []) do
    config = session.config

    params =
      %{
        "threadId" => session.thread_id,
        "input" => [%{"type" => "text", "text" => prompt}],
        "cwd" => session.workspace_path,
        "approvalPolicy" => config.approval_policy,
        "sandboxPolicy" => turn_sandbox_policy(session)
      }
      |> put_if("model", config.model)
      |> put_if("effort", config.effort)
      |> put_if("summary", config.summary)
      |> put_if("personality", config.personality)

    {response, session} = request(session, "turn/start", params, config.read_timeout_ms)
    turn_id = get_in(response, ["turn", "id"])

    unless turn_id do
      raise Error, code: :response_error, message: "turn/start response did not include turn.id"
    end

    session_id = "#{session.thread_id}-#{turn_id}"

    emit(session, %{
      "event" => "session_started",
      "thread_id" => session.thread_id,
      "turn_id" => to_string(turn_id),
      "session_id" => session_id,
      "codex_app_server_pid" => to_string(session.os_pid)
    })

    capture? = Keyword.get(opts, :capture_agent_text, false)
    session = %{session | agent_text_capture: if(capture?, do: [], else: nil)}
    {status, session} = wait_for_turn(session, to_string(turn_id))
    agent_text = Enum.join(session.agent_text_capture || [], "")

    {%TurnResult{
       thread_id: session.thread_id,
       turn_id: to_string(turn_id),
       status: status,
       agent_message_text: agent_text
     }, %{session | agent_text_capture: nil}}
  end

  defp open_command_port(command, cwd) do
    bash = System.find_executable("bash") || "/bin/bash"

    Port.open({:spawn_executable, bash}, [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, ["-lc", "exec " <> command]},
      {:cd, cwd}
    ])
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp request(%Session{} = session, method, params, timeout_ms) do
    request_id = session.next_id
    session = %{session | next_id: request_id + 1}

    session =
      send_message(session, %{"method" => method, "id" => request_id, "params" => params || %{}})

    receive_response(session, request_id, timeout_ms)
  end

  defp notify(%Session{} = session, method, params) do
    send_message(session, %{"method" => method, "params" => params || %{}})
  end

  defp receive_response(session, request_id, timeout_ms) do
    {msg, session} = read_message(session, timeout_ms)

    cond do
      Map.get(msg, "id") == request_id and !Map.has_key?(msg, "method") ->
        if Map.has_key?(msg, "error") do
          raise Error, code: :response_error, message: Jason.encode!(msg["error"])
        end

        {Map.get(msg, "result", %{}), session}

      Map.has_key?(msg, "method") and Map.has_key?(msg, "id") ->
        session = handle_server_request(session, msg)
        receive_response(session, request_id, timeout_ms)

      Map.has_key?(msg, "method") ->
        session = handle_notification(session, msg)
        receive_response(session, request_id, timeout_ms)

      true ->
        receive_response(session, request_id, timeout_ms)
    end
  end

  defp wait_for_turn(%Session{} = session, turn_id) do
    deadline = System.monotonic_time(:millisecond) + session.config.turn_timeout_ms
    do_wait_for_turn(session, turn_id, deadline)
  end

  defp do_wait_for_turn(session, turn_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise Error,
        code: :turn_timeout,
        message: "turn timed out after #{session.config.turn_timeout_ms} ms"
    end

    {msg, session} = read_message(session, remaining)

    cond do
      Map.has_key?(msg, "method") and Map.has_key?(msg, "id") ->
        session = handle_server_request(session, msg)
        do_wait_for_turn(session, turn_id, deadline)

      !Map.has_key?(msg, "method") ->
        do_wait_for_turn(session, turn_id, deadline)

      true ->
        session = handle_notification(session, msg)

        if msg["method"] == "turn/completed" do
          turn = get_in(msg, ["params", "turn"]) || %{}
          completed_id = turn["id"]

          if completed_id && to_string(completed_id) != turn_id do
            do_wait_for_turn(session, turn_id, deadline)
          else
            case to_string(turn["status"] || "") do
              "completed" ->
                {"completed", session}

              "interrupted" ->
                raise Error, code: :turn_cancelled, message: "turn was interrupted"

              _ ->
                raise Error,
                  code: :turn_failed,
                  message:
                    Utils.truncate(
                      Jason.encode!(turn["error"] || msg["params"]["error"] || %{}),
                      1000
                    )
            end
          end
        else
          do_wait_for_turn(session, turn_id, deadline)
        end
    end
  end

  defp send_message(%Session{} = session, message) do
    unless Port.info(session.port) do
      raise Error, code: :port_exit, message: "app-server stdin is closed"
    end

    Port.command(session.port, Jason.encode!(message) <> "\n")
    session
  end

  defp read_message(%Session{} = session, timeout_ms) do
    case next_line(session.buffer) do
      {line, rest} ->
        {decode_line(line), %{session | buffer: rest}}

      :none ->
        receive do
          {port, {:data, data}} when port == session.port ->
            if byte_size(data) > Utils.jsonl_read_limit_bytes() do
              raise Error,
                code: :response_error,
                message: "app-server JSONL message exceeded reader limit"
            end

            read_message(%{session | buffer: session.buffer <> data}, timeout_ms)

          {port, {:exit_status, status}} when port == session.port ->
            raise Error, code: :port_exit, message: "app-server exited before response: #{status}"
        after
          max(timeout_ms, 1) ->
            raise Error,
              code: :response_timeout,
              message: "timed out waiting for app-server response after #{timeout_ms} ms"
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

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = msg} ->
        msg

      {:ok, _} ->
        raise Error, code: :response_error, message: "app-server message is not an object"

      {:error, reason} ->
        raise Error,
          code: :response_error,
          message: "malformed app-server JSON: #{inspect(reason)}"
    end
  end

  defp handle_notification(%Session{} = session, msg) do
    method = to_string(msg["method"])
    params = if is_map(msg["params"]), do: msg["params"], else: %{}
    turn = if is_map(params["turn"]), do: params["turn"], else: %{}
    thread_id = params["threadId"] || params["thread_id"]
    turn_id = params["turnId"] || params["turn_id"] || turn["id"]

    event =
      %{
        "event" => event_name(method),
        "method" => method,
        "payload" => params,
        "codex_app_server_pid" => to_string(session.os_pid),
        "message" => summarize(method, params)
      }
      |> put_if("thread_id", thread_id)
      |> put_if("turn_id", turn_id)

    event =
      if thread_id && turn_id do
        Map.put(event, "session_id", "#{thread_id}-#{turn_id}")
      else
        event
      end

    event =
      if method == "thread/tokenUsage/updated" do
        total = get_in(params, ["tokenUsage", "total"]) || %{}

        Map.put(event, "usage_absolute", %{
          "input_tokens" => total["inputTokens"],
          "output_tokens" => total["outputTokens"],
          "total_tokens" => total["totalTokens"]
        })
      else
        event
      end

    event =
      if method in ["account/rateLimits/updated", "account/rateLimitsUpdated"] do
        Map.put(event, "rate_limits", params)
      else
        event
      end

    agent_text = agent_text_from_notification(method, params, session.agent_text_capture)

    session =
      if agent_text && session.agent_text_capture,
        do: %{session | agent_text_capture: session.agent_text_capture ++ [agent_text]},
        else: session

    emit(session, event)
    session
  end

  defp handle_server_request(%Session{} = session, msg) do
    request_id = msg["id"]
    method = to_string(msg["method"])
    params = if is_map(msg["params"]), do: msg["params"], else: %{}

    cond do
      method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] ->
        session =
          send_message(session, %{
            "id" => request_id,
            "result" => %{"decision" => "acceptForSession"}
          })

        emit(session, %{
          "event" => "approval_auto_approved",
          "method" => method,
          "payload" => params
        })

        session

      method == "item/tool/requestUserInput" ->
        auto_answer_tool_user_input(session, request_id, method, params)

      method == "mcpServer/elicitation/request" ->
        decline_mcp_elicitation(session, request_id, method, params)

      method == "item/tool/call" ->
        result = handle_dynamic_tool(session, params)
        send_message(session, %{"id" => request_id, "result" => result})

      true ->
        send_message(session, %{
          "id" => request_id,
          "error" => %{"code" => -32601, "message" => "unsupported server request: #{method}"}
        })
    end
  end

  defp decline_mcp_elicitation(session, request_id, method, params) do
    session =
      send_message(session, %{
        "id" => request_id,
        "result" => Utils.non_interactive_mcp_elicitation_response()
      })

    emit(session, %{
      "event" => "mcp_elicitation_declined",
      "method" => method,
      "payload" => params,
      "decision" => "decline"
    })

    session
  end

  defp auto_answer_tool_user_input(session, request_id, method, params) do
    cond do
      answers = Utils.tool_request_user_input_approval_answers(params) ->
        session =
          send_message(session, %{"id" => request_id, "result" => %{"answers" => answers}})

        emit(session, %{
          "event" => "approval_auto_approved",
          "method" => method,
          "payload" => params,
          "decision" => "Approve this Session"
        })

        session

      answers = Utils.tool_request_user_input_unavailable_answers(params) ->
        session =
          send_message(session, %{"id" => request_id, "result" => %{"answers" => answers}})

        emit(session, %{
          "event" => "tool_input_auto_answered",
          "method" => method,
          "payload" => params,
          "answer" => Utils.non_interactive_tool_input_answer()
        })

        session

      true ->
        session = send_message(session, %{"id" => request_id, "result" => %{"answers" => %{}}})

        emit(session, %{"event" => "turn_input_required", "method" => method, "payload" => params})

        raise Error, code: :turn_input_required, message: "app-server requested user input"
    end
  end

  defp handle_dynamic_tool(
         %Session{
           tracker_config: %TrackerConfig{kind: "linear", api_key: api_key} = tracker_config
         },
         params
       )
       when is_binary(api_key) do
    tool = params["tool"] || params["name"]

    if tool != "linear_graphql" do
      tool_text(false, %{
        "error" => %{"code" => "unsupported_tool", "message" => "unsupported tool: #{tool}"}
      })
    else
      arguments = params["arguments"]
      {query, variables} = graphql_arguments(arguments)

      cond do
        !is_binary(query) or String.trim(query) == "" ->
          tool_text(false, %{
            "error" => %{
              "code" => "invalid_input",
              "message" => "query must be a non-empty string"
            }
          })

        !is_map(variables) ->
          tool_text(false, %{
            "error" => %{"code" => "invalid_input", "message" => "variables must be an object"}
          })

        looks_like_multiple_graphql_operations?(query) ->
          tool_text(false, %{
            "error" => %{
              "code" => "invalid_input",
              "message" => "query must contain exactly one operation"
            }
          })

        true ->
          try do
            body =
              LinearClient.execute_graphql_once(
                struct(LinearClient, config: tracker_config),
                query,
                variables
              )

            tool_text(true, body)
          rescue
            error ->
              tool_text(false, %{
                "error" => %{"code" => "linear_graphql", "message" => Exception.message(error)}
              })
          end
      end
    end
  end

  defp handle_dynamic_tool(_session, _params) do
    tool_text(false, %{
      "error" => %{"code" => "missing_auth", "message" => "Linear auth is not configured"}
    })
  end

  defp graphql_arguments(arguments) when is_binary(arguments), do: {arguments, %{}}

  defp graphql_arguments(arguments) when is_map(arguments),
    do: {arguments["query"], arguments["variables"] || %{}}

  defp graphql_arguments(_), do: {nil, nil}

  defp tool_text(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp emit(%Session{} = session, event) do
    event = Map.put_new(event, "timestamp", Utils.now_utc())
    session.on_event.(event)
    :ok
  end

  defp event_name("turn/completed"), do: "turn_completed"
  defp event_name("turn/started"), do: "turn_started"
  defp event_name("item/tool/requestUserInput"), do: "turn_input_required"
  defp event_name(method), do: String.replace(method, "/", "_")

  defp summarize("item/agentMessage/delta", params),
    do: Utils.truncate(to_string(params["delta"] || params["text"] || ""), 500)

  defp summarize(method, params) do
    item = params["item"]

    cond do
      is_map(item) and item["type"] == "agentMessage" ->
        Utils.truncate(to_string(item["text"] || ""), 500)

      is_map(item) and item["type"] == "commandExecution" ->
        Utils.truncate("command=#{item["command"]} status=#{item["status"]}", 500)

      is_map(item) ->
        Utils.truncate("item_type=#{item["type"]} status=#{item["status"]}", 500)

      method == "turn/completed" ->
        "status=#{get_in(params, ["turn", "status"])}"

      true ->
        Utils.truncate(Jason.encode!(params), 500)
    end
  end

  defp agent_text_from_notification("item/agentMessage/delta", params, _capture),
    do: to_string(params["delta"] || params["text"] || "")

  defp agent_text_from_notification(_method, _params, _capture), do: nil

  defp turn_sandbox_policy(%Session{
         config: %CodexConfig{turn_sandbox_policy: nil},
         workspace_path: workspace_path
       }) do
    %{"type" => "workspaceWrite", "writableRoots" => [workspace_path], "networkAccess" => true}
  end

  defp turn_sandbox_policy(%Session{config: %CodexConfig{turn_sandbox_policy: policy}}),
    do: policy

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp looks_like_multiple_graphql_operations?(query) do
    cleaned =
      query
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.split("#", parts: 2) |> hd()))
      |> Enum.join(" ")

    Enum.reduce(["query", "mutation", "subscription"], 0, fn word, count ->
      count + length(String.split(cleaned, word)) - 1
    end) > 1
  end
end
