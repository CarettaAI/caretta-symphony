defmodule Symphony.Watchdog do
  @moduledoc false

  alias Symphony.Config.{ConfigManager, ServiceConfig}
  alias Symphony.SelfHeal
  alias Symphony.Utils

  def run(manager_or_config, opts \\ [])

  def run(%ConfigManager{} = manager, opts) do
    {_manager, _workflow, config} = ConfigManager.current(manager)

    if config.self_healing.enabled do
      loop(manager, opts)
    else
      IO.puts("Symphony watchdog is disabled by self_healing.enabled=false")
      0
    end
  end

  def run(%ServiceConfig{} = config, opts) do
    if config.self_healing.enabled do
      loop_config(config, opts)
    else
      IO.puts("Symphony watchdog is disabled by self_healing.enabled=false")
      0
    end
  end

  def run_once(manager_or_config, opts \\ [])

  def run_once(%ConfigManager{} = manager, opts) do
    {_manager, _workflow, config} = ConfigManager.current(manager)
    run_once(config, opts)
  end

  def run_once(%ServiceConfig{} = config, opts) do
    if config.self_healing.enabled do
      state =
        Keyword.get_lazy(opts, :state, fn -> fetch_state(config.self_healing.restart_port) end)

      now = Keyword.get(opts, :now, Utils.now_utc())

      case classify_state(state, config, now) do
        :healthy ->
          {:ok, :healthy}

        {:trigger, reason} ->
          self_heal_fun = Keyword.get(opts, :self_heal_fun, &SelfHeal.run_once/2)

          self_heal_opts =
            opts
            |> Keyword.drop([:state, :now, :self_heal_fun])
            |> Keyword.put(:reason, reason)

          {:triggered, self_heal_fun.(config, self_heal_opts)}
      end
    else
      {:ok, :disabled}
    end
  end

  def classify_state(snapshot, config, now \\ Utils.now_utc())

  def classify_state(%{"error" => error}, %ServiceConfig{} = config, _now) do
    {:trigger,
     "Symphony API is unreachable on port #{config.self_healing.restart_port}: #{error}"}
  end

  def classify_state(snapshot, %ServiceConfig{} = config, now)
      when is_map(snapshot) do
    service = if is_map(snapshot["service"]), do: snapshot["service"], else: %{}
    status = service["status"] |> to_string() |> String.downcase()

    cond do
      status in ["degraded", "failed", "error"] ->
        {:trigger, degraded_reason(service)}

      stale_poll?(service, config.self_healing.stale_poll_ms, now) ->
        {:trigger, stale_reason(service, config.self_healing.stale_poll_ms)}

      true ->
        :healthy
    end
  end

  def classify_state(_snapshot, %ServiceConfig{} = config, _now) do
    {:trigger,
     "Symphony API returned an invalid state payload on port #{config.self_healing.restart_port}"}
  end

  def fetch_state(port) do
    url = String.to_charlist("http://127.0.0.1:#{port}/api/v1/state")

    with {:ok, {{_, 200, _}, _headers, body}} <-
           :httpc.request(:get, {url, []}, [{:timeout, 5_000}], body_format: :binary),
         {:ok, json} when is_map(json) <- Jason.decode(body) do
      json
    else
      error -> %{"error" => inspect(error)}
    end
  end

  defp loop(manager, opts) do
    {manager, _changed} = ConfigManager.reload_if_changed(manager)
    {_manager, _workflow, config} = ConfigManager.current(manager)
    log_once(run_once(config, opts))
    Process.sleep(watchdog_interval(config))
    loop(manager, opts)
  rescue
    error ->
      IO.puts(:stderr, "Symphony watchdog poll failed: #{Exception.message(error)}")
      Process.sleep(30_000)
      loop(manager, opts)
  end

  defp loop_config(config, opts) do
    log_once(run_once(config, opts))
    Process.sleep(watchdog_interval(config))
    loop_config(config, opts)
  rescue
    error ->
      IO.puts(:stderr, "Symphony watchdog poll failed: #{Exception.message(error)}")
      Process.sleep(30_000)
      loop_config(config, opts)
  end

  defp log_once({:ok, :healthy}), do: :ok
  defp log_once({:ok, :disabled}), do: IO.puts("Symphony watchdog is disabled")

  defp log_once({:triggered, %SelfHeal.RunResult{} = result}) do
    IO.puts(
      "Symphony watchdog triggered self-heal status=#{result.status} reason=#{inspect(result.reason)}"
    )
  end

  defp degraded_reason(service) do
    case service["last_poll_error"] do
      value when is_binary(value) and value != "" ->
        "Symphony is degraded after a poll/reconciliation failure: #{value}"

      _ ->
        "Symphony is degraded"
    end
  end

  defp stale_poll?(service, stale_poll_ms, now) do
    last_completed = Utils.parse_datetime(service["last_poll_completed_at"])
    last_started = Utils.parse_datetime(service["last_poll_started_at"])
    startup_completed = Utils.parse_datetime(service["startup_completed_at"])

    cond do
      last_completed ->
        age_ms(last_completed, now) > stale_poll_ms

      last_started ->
        age_ms(last_started, now) > stale_poll_ms

      startup_completed ->
        age_ms(startup_completed, now) > stale_poll_ms

      true ->
        false
    end
  end

  defp stale_reason(service, stale_poll_ms) do
    observed_at =
      service["last_poll_completed_at"] ||
        service["last_poll_started_at"] ||
        service["startup_completed_at"] ||
        "unknown"

    "Symphony poll state is stale for more than #{stale_poll_ms} ms; last observed poll timestamp=#{observed_at}"
  end

  defp age_ms(%DateTime{} = timestamp, %DateTime{} = now),
    do: DateTime.diff(now, timestamp, :second) * 1000

  defp watchdog_interval(%ServiceConfig{} = config) do
    config.polling.interval_ms
    |> min(config.self_healing.stale_poll_ms)
    |> max(1_000)
  end
end
