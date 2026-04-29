defmodule Symphony.CLI do
  @moduledoc false

  alias Symphony.Config.ConfigManager
  alias Symphony.HTTPServer
  alias Symphony.Orchestrator

  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  def run(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv,
        switches: [port: :integer, log_level: :string, once: :boolean],
        aliases: [p: :port]
      )

    workflow_path = List.first(args)

    try do
      manager = ConfigManager.new(workflow_path)
      {manager, _workflow, config} = ConfigManager.load_startup(manager)
      port = Keyword.get(opts, :port) || config.server.port

      if Keyword.get(opts, :once, false) do
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
      else
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
