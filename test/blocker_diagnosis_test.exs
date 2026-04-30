defmodule Symphony.BlockerDiagnosisTest do
  use ExUnit.Case, async: true

  alias Symphony.BlockerDiagnosis
  alias Symphony.Config.ServiceConfig
  alias Symphony.Models.Issue

  @tag :tmp_dir
  test "fallback diagnosis names Linear write config and missing npmrc package auth", %{
    tmp_dir: tmp_dir
  } do
    repo_path = Path.join([tmp_dir, "repos", "caretta-webapp"])
    File.mkdir_p!(repo_path)

    File.write!(
      Path.join(repo_path, "package.json"),
      Jason.encode!(%{
        "dependencies" => %{"@CarettaAI/project-n-lambdas" => "1.0.0"}
      })
    )

    issue = %Issue{id: "1", identifier: "CRTTA-285", title: "Rename", state: "Todo"}

    handoff = """
    Linear read calls work, but mutation calls are still rejected.
    npm ci failed on private GitHub Packages auth for @CarettaAI/project-n-lambdas with 401 Unauthorized.
    """

    diagnosis =
      BlockerDiagnosis.diagnose(
        %ServiceConfig{workflow_path: Path.join(tmp_dir, "WORKFLOW.md")},
        issue,
        "unresolved_external_blocker",
        handoff,
        tmp_dir,
        nil,
        runner: fn _config, _payload, _opts -> raise "diagnosis agent unavailable" end
      )

    assert diagnosis["summary"] =~ "Linear handoff failed"
    assert diagnosis["summary"] =~ "private package auth"
    assert diagnosis["fault_domain"] == "credentials"
    assert diagnosis["configuration_issue"]
    assert diagnosis["validation_blocked"]
    assert Enum.any?(diagnosis["evidence"], &String.contains?(&1, "no repo-level `.npmrc`"))
    assert diagnosis["next_action"] =~ "Linear MCP write configuration"
    assert diagnosis["next_action"] =~ ".npmrc"
    assert diagnosis["operator_hint"] =~ "@CarettaAI:registry=https://npm.pkg.github.com"
  end
end
