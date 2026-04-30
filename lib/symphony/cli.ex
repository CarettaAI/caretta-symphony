defmodule Symphony.CLI do
  @moduledoc false

  alias Symphony.Config.ConfigManager
  alias Symphony.HTTPServer
  alias Symphony.Orchestrator
  alias Symphony.SelfHeal
  alias Symphony.Watchdog

  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  def run(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv,
        switches: [
          port: :integer,
          log_level: :string,
          once: :boolean,
          watchdog: :boolean,
          self_heal_once: :boolean,
          restart_managed: :boolean,
          reason: :string,
          help: :boolean
        ],
        aliases: [p: :port, h: :help]
      )

    workflow_path = List.first(args)

    if Keyword.get(opts, :help, false) do
      IO.puts(usage())
      0
    else
      try do
        manager = ConfigManager.new(workflow_path)
        {manager, _workflow, config} = ConfigManager.load_startup(manager)
        port = Keyword.get(opts, :port) || config.server.port

        cond do
          Keyword.get(opts, :watchdog, false) ->
            Watchdog.run(manager)

          Keyword.get(opts, :self_heal_once, false) ->
            result =
              SelfHeal.run_once(config,
                reason: Keyword.get(opts, :reason) || "manual self-heal",
                force: true
              )

            IO.puts(Jason.encode!(SelfHeal.result_to_map(result), pretty: true))
            if result.status == :ok, do: 0, else: 1

          Keyword.get(opts, :restart_managed, false) ->
            case SelfHeal.restart_managed(config) do
              {:ok, results} ->
                IO.puts(
                  Jason.encode!(%{"status" => "ok", "commands" => command_results(results)},
                    pretty: true
                  )
                )

                0

              {:error, results} ->
                IO.puts(
                  Jason.encode!(%{"status" => "error", "commands" => command_results(results)},
                    pretty: true
                  )
                )

                1
            end

          Keyword.get(opts, :once, false) ->
            orchestrator =
              manager
              |> Orchestrator.new()
              |> Orchestrator.startup_terminal_workspace_cleanup()
              |> Orchestrator.tick()

            server =
              if port do
                HTTPServer.start(orchestrator, host: config.server.host, port: port)
              end

            if server, do: HTTPServer.stop(server)
            0

          true ->
            {:ok, orchestrator} = Orchestrator.start_link(manager)

            server =
              if port do
                HTTPServer.start(orchestrator, host: config.server.host, port: port)
              end

            IO.puts(
              "Symphony running#{if server, do: " on http://#{server.host}:#{server.bound_port}", else: ""}. Press Ctrl+C to stop."
            )

            Process.sleep(:infinity)
            0
        end
      rescue
        error in Symphony.Error ->
          IO.puts(:stderr, Exception.message(error))
          1
      end
    end
  end

  defp command_results(results) do
    Enum.map(results, fn result ->
      %{
        "command" => result.command,
        "status" => result.status,
        "output" => result.output
      }
    end)
  end

  defp usage do
    """
    Usage:
      symphony [WORKFLOW.md] [--port PORT]
      symphony [WORKFLOW.md] --once
      symphony [WORKFLOW.md] --watchdog
      symphony [WORKFLOW.md] --self-heal-once --reason "reason"
      symphony [WORKFLOW.md] --restart-managed
    """
    |> String.trim()
  end
end
