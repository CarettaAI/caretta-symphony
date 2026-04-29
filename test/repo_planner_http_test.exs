defmodule Symphony.RepoPlannerHttpTest do
  use ExUnit.Case, async: true

  alias Symphony.CodingContext.CodingClassification

  alias Symphony.Config.{
    CodexConfig,
    CodingContextConfig,
    RepositoryConfig,
    RepositoryPlanningConfig
  }

  alias Symphony.HTTPServer
  alias Symphony.Models.Issue
  alias Symphony.Orchestrator
  alias Symphony.RepoPlanner

  defmodule FakePlannerCodexClient do
    def start_session(config, workspace_path, _opts) do
      send(Process.get(:repo_planner_parent), {:planner_session_started, config, workspace_path})
      :fake_session
    end

    def run_turn(:fake_session, prompt, opts) do
      send(Process.get(:repo_planner_parent), {:planner_prompt, prompt, opts})

      case Process.get(:repo_planner_response) do
        {:raise, reason} ->
          raise reason

        response ->
          {%Symphony.CodexClient.TurnResult{agent_message_text: response}, :fake_session}
      end
    end

    def stop_session(:fake_session), do: send(Process.get(:repo_planner_parent), :planner_stopped)
  end

  @tag :tmp_dir
  test "rules planner picks a primary repo and injects guardrails", %{tmp_dir: tmp_dir} do
    config = %RepositoryPlanningConfig{
      enabled: true,
      planner: "rules",
      repositories: [
        %RepositoryConfig{
          slug: "ExampleOrg/desktop-runtime",
          aliases: ["desktop"],
          description: "Desktop app runtime"
        },
        %RepositoryConfig{
          slug: "ExampleOrg/model-gateway",
          aliases: ["gateway"],
          description: "Provider routing"
        }
      ]
    }

    issue = %Issue{
      id: "1",
      identifier: "ENG-1",
      title: "Fix desktop overlay",
      description: "The desktop runtime needs a provider integration.",
      state: "Todo"
    }

    classification = %CodingClassification{is_coding_task: true, source: "rules"}
    plan = RepoPlanner.plan_repositories(issue, config, %CodingContextConfig{}, classification)

    assert plan.primary_repo.slug == "ExampleOrg/desktop-runtime"
    assert plan.confidence > 0

    prompt = RepoPlanner.apply_repo_plan_to_prompt("Original", plan, tmp_dir)
    assert prompt =~ "<symphony_repo_plan>"
    assert prompt =~ "Git hygiene guardrail"
    assert prompt =~ "ExampleOrg/desktop-runtime"
    assert String.ends_with?(prompt, "Original")
  end

  test "rules planner prefers explicit aliases over weak description keyword ties" do
    config = %RepositoryPlanningConfig{
      enabled: true,
      planner: "rules",
      repositories: [
        %RepositoryConfig{
          slug: "CarettaAI/caretta-metrics",
          aliases: ["metrics"],
          description: "Metrics console and telemetry inspection."
        },
        %RepositoryConfig{
          slug: "CarettaAI/caretta-webapp",
          aliases: ["calendar", "web app"],
          description: "Customer-facing web app, authenticated routes, product UI, calendar, CRM."
        }
      ]
    }

    issue = %Issue{
      id: "CRTTA-262",
      identifier: "CRTTA-262",
      title: ~s(Calendar sync: 403 "insufficient auth scopes" in prod + breaks on refresh in dev),
      description:
        "Google Calendar APIs return insufficient scopes. Add telemetry and compare Google Cloud Console OAuth scopes.",
      state: "Todo",
      labels: ["codex", "auth", "bug"]
    }

    plan =
      RepoPlanner.plan_repositories(
        issue,
        config,
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"}
      )

    assert plan.primary_repo.slug == "CarettaAI/caretta-webapp"
    refute plan.needs_human
    assert plan.human_reason == nil
  end

  test "rules planner does not match description keywords inside larger words" do
    config = %RepositoryPlanningConfig{
      enabled: true,
      planner: "rules",
      repositories: [
        %RepositoryConfig{
          slug: "CarettaAI/caretta-webapp",
          aliases: ["webapp"],
          description: "Customer-facing product UI and post-call surfaces."
        },
        %RepositoryConfig{
          slug: "VoysCoders/llm-gateway",
          aliases: ["llm-gateway"],
          description: "Alternate or older model gateway work when explicitly named."
        }
      ]
    }

    issue = %Issue{
      id: "CRTTA-283",
      identifier: "CRTTA-283",
      title: "Drafted follow-up email tab",
      description:
        "A new tab after the call with a pre-drafted email recap using bracketed placeholders for customer questions.",
      state: "Todo",
      labels: ["codex"]
    }

    plan =
      RepoPlanner.plan_repositories(
        issue,
        config,
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"}
      )

    assert plan.primary_repo.slug == "CarettaAI/caretta-webapp"
    refute Enum.any?(plan.secondary_repos, &(&1.slug == "VoysCoders/llm-gateway"))
    refute plan.needs_human
  end

  test "rules planner routes post-call history tab work to webapp over live desktop runtime" do
    config = %RepositoryPlanningConfig{
      enabled: true,
      planner: "rules",
      repositories: [
        %RepositoryConfig{
          slug: "CarettaAI/Project-N",
          aliases: ["Project-N", "desktop", "electron", "overlay", "live runtime"],
          description:
            "Desktop app and live in-call runtime; not saved-call history pages or post-call detail tabs."
        },
        %RepositoryConfig{
          slug: "CarettaAI/caretta-webapp",
          aliases: ["webapp", "history", "history tab", "post-call", "follow-up email"],
          description:
            "Customer-facing web app, saved-call history, post-call detail tabs, and follow-up email drafts."
        }
      ]
    }

    issue = %Issue{
      id: "CRTTA-283",
      identifier: "CRTTA-283",
      title: "Drafted follow-up email tab",
      description: "A new tab after the call with a pre-drafted email recap in the post-call UI.",
      state: "Todo",
      labels: ["codex"]
    }

    plan =
      RepoPlanner.plan_repositories(
        issue,
        config,
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"}
      )

    assert plan.primary_repo.slug == "CarettaAI/caretta-webapp"
    refute plan.needs_human
  end

  @tag :tmp_dir
  test "llm planner normalizes primary secondary and read-only repos", %{tmp_dir: tmp_dir} do
    Process.put(:repo_planner_parent, self())

    Process.put(
      :repo_planner_response,
      Jason.encode!(%{
        "coding_task" => true,
        "primary_repo" => %{
          "slug" => "ExampleOrg/desktop-runtime",
          "reason" => "Owns the visible desktop behavior."
        },
        "secondary_repos" => [
          %{
            "slug" => "ExampleOrg/model-gateway",
            "reason" => "Provider adapter",
            "edit_allowed" => true
          }
        ],
        "read_only_context_repos" => [
          %{"slug" => "ExampleOrg/knowledge-docs", "reason" => "Background docs"}
        ],
        "confidence" => 0.74,
        "needs_human" => false,
        "notes" => "Start in desktop."
      })
    )

    plan =
      RepoPlanner.plan_repositories(
        issue("Live desktop provider suggestions"),
        llm_repo_config(),
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"},
        codex_config: %CodexConfig{command: "fake"},
        workspace_path: tmp_dir,
        codex_client: FakePlannerCodexClient
      )

    assert plan.source == "llm"
    assert plan.primary_repo.slug == "ExampleOrg/desktop-runtime"
    assert hd(plan.secondary_repos).slug == "ExampleOrg/model-gateway"
    assert hd(plan.read_only_context_repos).edit_allowed == false
    assert plan.confidence == 0.74
    refute plan.needs_human
    assert_receive {:planner_session_started, %CodexConfig{effort: "low"}, ^tmp_dir}
    assert_receive {:planner_prompt, prompt, [capture_agent_text: true]}
    assert prompt =~ "Use only repository slugs listed in the input catalog"
    assert prompt =~ "Route post-call, saved-call, call-history"
    assert_receive :planner_stopped
  end

  @tag :tmp_dir
  test "llm planner promotes rules-matched read-only repo when llm chose wrong primary", %{
    tmp_dir: tmp_dir
  } do
    Process.put(:repo_planner_parent, self())

    Process.put(
      :repo_planner_response,
      Jason.encode!(%{
        "coding_task" => true,
        "primary_repo" => %{
          "slug" => "CarettaAI/Project-N",
          "reason" => "The issue says post-call and call summary."
        },
        "read_only_context_repos" => [
          %{"slug" => "CarettaAI/caretta-webapp", "reason" => "Contains history tabs."}
        ],
        "confidence" => 0.86,
        "needs_human" => false,
        "notes" => "Start in desktop."
      })
    )

    config = %RepositoryPlanningConfig{
      enabled: true,
      planner: "llm",
      repositories: [
        %RepositoryConfig{
          slug: "CarettaAI/Project-N",
          aliases: ["Project-N", "desktop", "electron", "overlay", "live runtime"],
          description: "Desktop app and live in-call runtime."
        },
        %RepositoryConfig{
          slug: "CarettaAI/caretta-webapp",
          aliases: ["webapp", "history", "history tab", "post-call", "follow-up email"],
          description:
            "Customer-facing web app, saved-call history, post-call detail tabs, and follow-up email drafts."
        }
      ]
    }

    issue = %Issue{
      id: "CRTTA-283",
      identifier: "CRTTA-283",
      title: "Drafted follow-up email tab",
      description: "A new tab after the call with a pre-drafted email recap in the post-call UI.",
      state: "Todo",
      labels: ["codex"]
    }

    plan =
      RepoPlanner.plan_repositories(
        issue,
        config,
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"},
        codex_config: %CodexConfig{command: "fake"},
        workspace_path: tmp_dir,
        codex_client: FakePlannerCodexClient
      )

    assert plan.source == "llm+rules_crosscheck"
    assert plan.primary_repo.slug == "CarettaAI/caretta-webapp"
    assert plan.primary_repo.edit_allowed
    assert hd(plan.read_only_context_repos).slug == "CarettaAI/Project-N"
    refute hd(plan.read_only_context_repos).edit_allowed
  end

  @tag :tmp_dir
  test "llm planner flags unknown repos and missing primary", %{tmp_dir: tmp_dir} do
    Process.put(:repo_planner_parent, self())

    Process.put(
      :repo_planner_response,
      Jason.encode!(%{
        "coding_task" => true,
        "secondary_repos" => [%{"slug" => "ExampleOrg/unknown", "reason" => "Maybe this"}],
        "confidence" => 0.4
      })
    )

    plan =
      RepoPlanner.plan_repositories(
        issue("Ambiguous repo work"),
        llm_repo_config(),
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"},
        codex_config: %CodexConfig{command: "fake"},
        workspace_path: tmp_dir,
        codex_client: FakePlannerCodexClient
      )

    assert plan.needs_human
    assert plan.primary_repo == nil
    assert plan.human_reason =~ "did not return a primary repo"
    assert plan.human_reason =~ "ExampleOrg/unknown"
  end

  @tag :tmp_dir
  test "llm planner can fallback to block or rules", %{tmp_dir: tmp_dir} do
    Process.put(:repo_planner_parent, self())
    Process.put(:repo_planner_response, {:raise, "planner unavailable"})

    block_plan =
      RepoPlanner.plan_repositories(
        issue("Fix desktop runtime"),
        %{llm_repo_config() | fallback: "block"},
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"},
        codex_config: %CodexConfig{command: "fake"},
        workspace_path: tmp_dir,
        codex_client: FakePlannerCodexClient
      )

    assert block_plan.source == "fallback:block"
    assert block_plan.needs_human
    assert block_plan.human_reason =~ "planner unavailable"

    rules_plan =
      RepoPlanner.plan_repositories(
        issue("Fix desktop runtime"),
        %{llm_repo_config() | fallback: "rules"},
        %CodingContextConfig{},
        %CodingClassification{is_coding_task: true, source: "rules"},
        codex_config: %CodexConfig{command: "fake"},
        workspace_path: tmp_dir,
        codex_client: FakePlannerCodexClient
      )

    assert rules_plan.source == "fallback:rules"
    assert rules_plan.primary_repo.slug == "ExampleOrg/desktop-runtime"
  end

  @tag :tmp_dir
  test "HTTP server exposes state and issue detail", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
      api_key: key
      project_slug: demo
    workspace:
      root: #{Path.join(tmp_dir, "workspaces")}
    codex:
      command: fake
    ---
    body
    """)

    config_manager = Symphony.Config.ConfigManager.new(workflow_path, environ: %{})
    {config_manager, _, _} = Symphony.Config.ConfigManager.load_startup(config_manager)
    orchestrator = Orchestrator.new(config_manager)
    server = HTTPServer.start(orchestrator, port: 0)

    try do
      {:ok, {{_, 200, _}, _headers, body}} =
        :httpc.request(:get, {~c"http://127.0.0.1:#{server.bound_port}/api/v1/state", []}, [],
          body_format: :binary
        )

      assert Jason.decode!(body)["counts"]["running"] == 0

      {:ok, {{_, 404, _}, _headers, body}} =
        :httpc.request(:get, {~c"http://127.0.0.1:#{server.bound_port}/api/v1/ABC-404", []}, [],
          body_format: :binary
        )

      assert Jason.decode!(body)["error"]["code"] == "issue_not_found"

      {:ok, {{_, 200, _}, _headers, html}} =
        :httpc.request(:get, {~c"http://127.0.0.1:#{server.bound_port}/", []}, [],
          body_format: :binary
        )

      assert html =~ "Running Agents"
      assert html =~ "Continuing / Retrying"
      assert html =~ "Repo plan"
      assert html =~ "setInterval"
      assert html =~ "/api/v1/refresh"
    after
      HTTPServer.stop(server)
    end
  end

  defp issue(title) do
    %Issue{
      id: "1",
      identifier: "ENG-1",
      title: title,
      description: "The desktop runtime needs provider work.",
      state: "Todo",
      labels: ["codex"]
    }
  end

  defp llm_repo_config do
    %RepositoryPlanningConfig{
      enabled: true,
      planner: "llm",
      repositories: [
        %RepositoryConfig{
          slug: "ExampleOrg/desktop-runtime",
          aliases: ["desktop"],
          description: "Desktop app runtime"
        },
        %RepositoryConfig{
          slug: "ExampleOrg/model-gateway",
          aliases: ["gateway"],
          description: "Provider routing"
        },
        %RepositoryConfig{
          slug: "ExampleOrg/knowledge-docs",
          aliases: ["docs"],
          description: "Documentation and context"
        }
      ]
    }
  end
end
