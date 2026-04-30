defmodule Symphony.WatchdogTest do
  use ExUnit.Case, async: true

  alias Symphony.Config.{PollingConfig, SelfHealingConfig, ServiceConfig, TrackerConfig}
  alias Symphony.SelfHeal.RunResult
  alias Symphony.Tracker.LinearMcpClient
  alias Symphony.Watchdog
  alias Symphony.WatchdogEscalation
  alias Symphony.WatchdogTriage.Decision

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

  test "routes repeated retry failures to an agent triage payload" do
    config = config(stale_poll_ms: 120_000)

    assert {:triage, payload} =
             Watchdog.classify_state(
               %{
                 "service" => %{
                   "status" => "running",
                   "last_poll_completed_at" => "2026-04-30T11:59:30Z"
                 },
                 "retrying" => [
                   %{
                     "issue_identifier" => "CRTTA-284",
                     "title" => "Keep the force-insight button in the notch",
                     "kind" => "retry",
                     "attempt" => 4,
                     "error" => "response_error: user rejected MCP tool call"
                   }
                 ]
               },
               config,
               now()
             )

    assert [%{"issue_identifier" => "CRTTA-284"}] = payload["retrying"]
  end

  test "does not decide target-repo validation failures without agent triage" do
    config = config(stale_poll_ms: 120_000)

    assert {:triage, payload} =
             Watchdog.classify_state(
               %{
                 "service" => %{
                   "status" => "running",
                   "last_poll_completed_at" => "2026-04-30T11:59:30Z"
                 },
                 "retrying" => [
                   %{
                     "issue_identifier" => "CRTTA-999",
                     "title" => "Fix product test",
                     "kind" => "retry",
                     "attempt" => 8,
                     "error" => "validation failed: npm test failed"
                   }
                 ]
               },
               config,
               now()
             )

    assert [%{"issue_identifier" => "CRTTA-999"}] = payload["retrying"]
  end

  test "run_once self-heals when the triage agent approves service scope" do
    config = config(stale_poll_ms: 120_000)
    test_pid = self()

    triage_fun = fn _config, payload, _opts ->
      send(test_pid, {:triage_payload, payload})

      %Decision{
        decision: :self_heal,
        service_problem: true,
        in_scope: true,
        reason: "agent determined Linear MCP handoff is a Symphony control-plane failure",
        confidence: 0.91,
        issue_identifier: "CRTTA-284"
      }
    end

    self_heal_fun = fn _config, opts ->
      send(test_pid, {:self_heal, opts[:reason]})
      %RunResult{status: :ok, reason: opts[:reason]}
    end

    assert {:triggered, %RunResult{status: :ok}} =
             Watchdog.run_once(config,
               state: retry_state("CRTTA-284", "response_error: user rejected MCP tool call"),
               now: now(),
               triage_fun: triage_fun,
               self_heal_fun: self_heal_fun
             )

    assert_received {:triage_payload, %{"retrying" => [%{"issue_identifier" => "CRTTA-284"}]}}
    assert_received {:self_heal, reason}
    assert reason =~ "Linear MCP handoff"
  end

  test "run_once escalates when the triage agent rejects self-heal scope" do
    config = config(stale_poll_ms: 120_000)
    test_pid = self()

    triage_fun = fn _config, _payload, _opts ->
      %Decision{
        decision: :reject,
        service_problem: false,
        in_scope: false,
        reason: "agent determined the failure belongs to the target repo"
      }
    end

    escalation_fun = fn _config, payload, opts ->
      send(test_pid, {:escalate, payload, opts})
      {:ok, %{comment_id: "comment-1"}}
    end

    assert {:ok, {:triage_rejected, reason}} =
             Watchdog.run_once(config,
               state: retry_state("CRTTA-999", "validation failed: npm test failed"),
               now: now(),
               triage_fun: triage_fun,
               escalation_fun: escalation_fun,
               self_heal_fun: fn _, _ -> flunk("should not self-heal") end
             )

    assert reason =~ "target repo"
    assert_received {:escalate, %{"retrying" => [%{"issue_identifier" => "CRTTA-999"}]}, opts}
    assert Keyword.fetch!(opts, :source) == "triage_rejected"
    assert Keyword.fetch!(opts, :reason) =~ "target repo"
  end

  test "run_once escalates when self-heal fails after agent approval" do
    config = config(stale_poll_ms: 120_000)
    test_pid = self()

    triage_fun = fn _config, _payload, _opts ->
      %Decision{
        decision: :self_heal,
        service_problem: true,
        in_scope: true,
        reason: "agent approved Symphony repair"
      }
    end

    self_heal_fun = fn _config, _opts ->
      %RunResult{
        status: :error,
        reason: "agent approved Symphony repair",
        error: "mix test failed"
      }
    end

    escalation_fun = fn _config, payload, opts ->
      send(test_pid, {:escalate, payload, opts})
      {:ok, %{comment_id: "comment-1"}}
    end

    assert {:triggered, %RunResult{status: :error}} =
             Watchdog.run_once(config,
               state: retry_state("CRTTA-284", "response_error"),
               now: now(),
               triage_fun: triage_fun,
               self_heal_fun: self_heal_fun,
               escalation_fun: escalation_fun
             )

    assert_received {:escalate, %{"retrying" => [%{"issue_identifier" => "CRTTA-284"}]}, opts}
    assert Keyword.fetch!(opts, :source) == "self_heal_failed"
    assert Keyword.fetch!(opts, :reason) =~ "mix test failed"
  end

  test "run_once escalates when self-heal is skipped after agent approval" do
    config = config(stale_poll_ms: 120_000)
    test_pid = self()

    triage_fun = fn _config, _payload, _opts ->
      %Decision{
        decision: :self_heal,
        service_problem: true,
        in_scope: true,
        reason: "agent approved Symphony repair"
      }
    end

    self_heal_fun = fn _config, _opts ->
      %RunResult{
        status: :skipped,
        reason: "agent approved Symphony repair",
        error: "self-heal cooldown is active"
      }
    end

    escalation_fun = fn _config, payload, opts ->
      send(test_pid, {:escalate, payload, opts})
      {:ok, %{comment_id: "comment-1"}}
    end

    assert {:triggered, %RunResult{status: :skipped}} =
             Watchdog.run_once(config,
               state: retry_state("CRTTA-284", "response_error"),
               now: now(),
               triage_fun: triage_fun,
               self_heal_fun: self_heal_fun,
               escalation_fun: escalation_fun
             )

    assert_received {:escalate, %{"retrying" => [%{"issue_identifier" => "CRTTA-284"}]}, opts}
    assert Keyword.fetch!(opts, :source) == "self_heal_failed"
    assert Keyword.fetch!(opts, :reason) =~ "cooldown"
  end

  test "watchdog escalation upserts a Linear comment with a mention" do
    config = config(blocked_escalation_mentions: ["@operator"])
    test_pid = self()

    tracker = %LinearMcpClient{
      config: %TrackerConfig{kind: "linear_mcp"},
      gateway: fn tool, arguments ->
        send(test_pid, {:gateway, tool, arguments})

        cond do
          String.ends_with?(tool, "list_comments") ->
            %{
              "comments" => [
                %{"id" => "comment-1", "body" => "## Symphony Watchdog Escalation\nold"}
              ]
            }

          String.ends_with?(tool, "list_users") ->
            %{"users" => [%{"id" => "user-1", "displayName" => "owner", "isActive" => true}]}

          String.ends_with?(tool, "save_comment") ->
            %{"id" => arguments["id"] || "comment-2"}
        end
      end
    }

    payload = retry_state("CRTTA-284", "validation failed")
    payload = put_in(payload, ["retrying", Access.at(0), "assignee"], %{"mention" => "@owner"})

    assert {:ok, %{issue_identifier: "CRTTA-284", comment_id: "comment-1"}} =
             WatchdogEscalation.escalate(config, payload,
               tracker: tracker,
               reason: "agent rejected self-heal as out of scope",
               source: "triage_rejected"
             )

    assert_received {:gateway, "linear mcp server_list_comments", %{"issueId" => "CRTTA-284"}}
    assert_received {:gateway, "linear mcp server_list_users", %{"query" => "owner"}}

    assert_received {:gateway, "linear mcp server_save_comment",
                     %{"body" => body, "id" => "comment-1"}}

    assert body =~ "## Symphony Watchdog Escalation"
    assert body =~ "@owner"
    assert body =~ "agent rejected self-heal"
    assert body =~ "triage_rejected"
  end

  test "watchdog escalation does not use unresolved raw mention text" do
    config = config(blocked_escalation_mentions: ["@operator"])
    test_pid = self()

    tracker = %{
      list_issue_comments: fn "CRTTA-284" -> [] end,
      list_users: fn opts ->
        send(test_pid, {:list_users, opts})
        []
      end,
      save_issue_comment: fn "CRTTA-284", body, opts ->
        send(test_pid, {:save_comment, body, opts})
        %{"id" => "comment-1"}
      end
    }

    assert {:ok, %{issue_identifier: "CRTTA-284"}} =
             WatchdogEscalation.escalate(config, retry_state("CRTTA-284", "validation failed"),
               tracker: tracker,
               reason: "agent rejected self-heal as out of scope",
               source: "triage_rejected"
             )

    assert_received {:list_users, [query: "operator", limit: 10]}
    assert_received {:save_comment, body, []}
    refute body =~ "@operator"
    assert body =~ "Symphony watchdog could not safely resolve"
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

  defp retry_state(issue_identifier, error) do
    %{
      "service" => %{
        "status" => "running",
        "last_poll_completed_at" => "2026-04-30T11:59:30Z"
      },
      "retrying" => [
        %{
          "issue_identifier" => issue_identifier,
          "title" => "Example issue",
          "kind" => "retry",
          "attempt" => 4,
          "error" => error
        }
      ]
    }
  end

  defp config(opts \\ []) do
    self_healing = %SelfHealingConfig{
      enabled: Keyword.get(opts, :enabled, true),
      restart_port: 8765,
      stale_poll_ms: Keyword.get(opts, :stale_poll_ms, 120_000),
      workspace_root: "/tmp/symphony-watchdog-test"
    }

    %ServiceConfig{
      tracker: %TrackerConfig{
        blocked_escalation_enabled: Keyword.get(opts, :blocked_escalation_enabled, true),
        blocked_escalation_mentions: Keyword.get(opts, :blocked_escalation_mentions, [])
      },
      polling: %PollingConfig{interval_ms: 30_000},
      self_healing: self_healing
    }
  end

  defp now, do: ~U[2026-04-30 12:00:00Z]
end
