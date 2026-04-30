defmodule Symphony.WatchdogTest do
  use ExUnit.Case, async: true

  alias Symphony.Config.{PollingConfig, SelfHealingConfig, ServiceConfig}
  alias Symphony.SelfHeal.RunResult
  alias Symphony.Watchdog

  test "classifies unreachable API as a self-heal trigger" do
    config = config()

    assert {:trigger, reason} =
             Watchdog.classify_state(%{"error" => ":econnrefused"}, config, now())

    assert reason =~ "unreachable"
    assert reason =~ "8765"
  end

  test "classifies degraded runtime as a self-heal trigger" do
    config = config()

    assert {:trigger, reason} =
             Watchdog.classify_state(
               %{"service" => %{"status" => "degraded", "last_poll_error" => "Linear failed"}},
               config,
               now()
             )

    assert reason =~ "degraded"
    assert reason =~ "Linear failed"
  end

  test "classifies stale poll completion as a self-heal trigger" do
    config = config(stale_poll_ms: 120_000)

    assert {:trigger, reason} =
             Watchdog.classify_state(
               %{
                 "service" => %{
                   "status" => "running",
                   "last_poll_completed_at" => "2026-04-30T11:55:00Z"
                 }
               },
               config,
               now()
             )

    assert reason =~ "stale"
    assert reason =~ "120000"
  end

  test "healthy current state is a no-op" do
    config = config(stale_poll_ms: 120_000)

    assert :healthy =
             Watchdog.classify_state(
               %{
                 "service" => %{
                   "status" => "running",
                   "last_poll_completed_at" => "2026-04-30T11:59:30Z"
                 }
               },
               config,
               now()
             )
  end

  test "run_once dispatches self-heal with trigger reason" do
    config = config(stale_poll_ms: 120_000)
    test_pid = self()

    self_heal_fun = fn _config, opts ->
      send(test_pid, {:self_heal, opts[:reason]})
      %RunResult{status: :skipped, reason: opts[:reason]}
    end

    assert {:triggered, %RunResult{status: :skipped}} =
             Watchdog.run_once(config,
               state: %{"error" => ":econnrefused"},
               now: now(),
               self_heal_fun: self_heal_fun
             )

    assert_received {:self_heal, reason}
    assert reason =~ "unreachable"
  end

  test "run_once is disabled when self_healing is disabled" do
    config = config(enabled: false)

    assert {:ok, :disabled} =
             Watchdog.run_once(config,
               state: %{"error" => ":econnrefused"},
               now: now(),
               self_heal_fun: fn _, _ -> flunk("should not run") end
             )
  end

  defp config(opts \\ []) do
    self_healing = %SelfHealingConfig{
      enabled: Keyword.get(opts, :enabled, true),
      restart_port: 8765,
      stale_poll_ms: Keyword.get(opts, :stale_poll_ms, 120_000),
      workspace_root: "/tmp/symphony-watchdog-test"
    }

    %ServiceConfig{
      polling: %PollingConfig{interval_ms: 30_000},
      self_healing: self_healing
    }
  end

  defp now, do: ~U[2026-04-30 12:00:00Z]
end
