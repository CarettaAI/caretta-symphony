defmodule Symphony.WatchdogTriageTest do
  use ExUnit.Case, async: true

  alias Symphony.Config.ServiceConfig
  alias Symphony.WatchdogTriage

  test "prompt requires a concrete investigation instead of a vague handoff" do
    prompt =
      WatchdogTriage.build_prompt(%{
        "retrying" => [
          %{
            "issue_identifier" => "CRTTA-284",
            "attempt" => 4,
            "error" => "response_error"
          }
        ]
      })

    assert prompt =~ "Required investigation"
    assert prompt =~ "failure_signature"
    assert prompt =~ "at least two evidence sources"
    assert prompt =~ "Never ask a human to \"take a look and tell me what to do\""
    assert prompt =~ "Watchdog will reject incomplete triage"
  end

  test "triage retries when the agent returns an incomplete investigation" do
    test_pid = self()

    runner = fn _config, _payload, opts ->
      retry? = Keyword.has_key?(opts, :triage_retry_feedback)
      send(test_pid, {:triage_attempt, retry?})

      if retry? do
        Jason.encode!(%{
          "decision" => "self_heal",
          "service_problem" => true,
          "in_scope" => true,
          "issue_identifier" => "CRTTA-284",
          "reason" => "Codex app-server protocol handling is breaking Symphony jobs.",
          "confidence" => 0.92,
          "investigation" => %{
            "failure_signature" =>
              "unsupported mcpServer/elicitation/request followed by malformed JSONL",
            "likely_fault_domain" => "codex_app_server",
            "inspected" => ["retry error text", "retry attempt metadata"],
            "scope_rationale" =>
              "The failure occurs before target repo validation and belongs to Symphony's Codex integration.",
            "unknowns" => [],
            "next_action" =>
              "Repair Symphony CodexClient protocol handling and redeploy the local service artifact."
          },
          "evidence" => [
            "Retry attempts fail with malformed app-server JSON.",
            "The error mentions unsupported mcpServer/elicitation/request."
          ]
        })
      else
        Jason.encode!(%{
          "decision" => "self_heal",
          "service_problem" => true,
          "in_scope" => true,
          "issue_identifier" => "CRTTA-284",
          "reason" => "Codex broke.",
          "confidence" => 0.7,
          "evidence" => ["one point only"]
        })
      end
    end

    decision =
      WatchdogTriage.triage(%ServiceConfig{}, %{"retrying" => []},
        runner: runner,
        max_attempts: 2
      )

    assert_receive {:triage_attempt, false}
    assert_receive {:triage_attempt, true}
    assert WatchdogTriage.self_heal?(decision)
    assert decision.failure_signature =~ "mcpServer/elicitation/request"
    assert decision.scope_rationale =~ "before target repo validation"
    assert WatchdogTriage.reason(decision) =~ "Failure signature:"
    assert WatchdogTriage.reason(decision) =~ "Evidence:"
  end

  test "triage rejects incomplete investigation after retry budget" do
    runner = fn _config, _payload, _opts ->
      Jason.encode!(%{
        "decision" => "self_heal",
        "service_problem" => true,
        "in_scope" => true,
        "issue_identifier" => "CRTTA-284",
        "reason" => "look into it",
        "confidence" => 0.4,
        "evidence" => []
      })
    end

    decision =
      WatchdogTriage.triage(%ServiceConfig{}, %{"retrying" => []},
        runner: runner,
        max_attempts: 1
      )

    refute WatchdogTriage.self_heal?(decision)
    assert decision.reason =~ "incomplete investigation"
    assert decision.next_action =~ "concrete failure signature"
    assert WatchdogTriage.reason(decision) =~ "Unknowns:"
    assert WatchdogTriage.reason(decision) =~ "investigation.failure_signature"
  end
end
