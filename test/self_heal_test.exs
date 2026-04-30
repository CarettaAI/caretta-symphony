defmodule Symphony.SelfHealTest do
  use ExUnit.Case, async: true

  alias Symphony.Config.{PollingConfig, SelfHealingConfig, ServiceConfig}
  alias Symphony.SelfHeal
  alias Symphony.SelfHeal.{CommandResult, RunResult}

  test "run_id is stable and branch-safe" do
    now = ~U[2026-04-30 12:00:00Z]
    run_id = SelfHeal.run_id("Broken API / bad poll!!!", now)

    assert run_id == "20260430T120000-broken-api-bad-poll"
    assert String.length(SelfHeal.run_id(String.duplicate("failure ", 40), now)) <= 80
    refute SelfHeal.run_id(String.duplicate("failure ", 40), now) =~ "truncated"
  end

  test "github sync classification distinguishes blocked auto-merge" do
    assert {:ok, "auto-merge enabled"} =
             SelfHeal.classify_github_sync(
               %CommandResult{status: 0, output: "https://github.com/org/repo/pull/1"},
               %CommandResult{status: 0, output: ""}
             )

    assert {:blocked, message} =
             SelfHeal.classify_github_sync(
               %CommandResult{status: 0, output: "https://github.com/org/repo/pull/1"},
               %CommandResult{status: 1, output: "reviews required"}
             )

    assert message == "reviews required"

    assert {:error, "failed"} =
             SelfHeal.classify_github_sync(
               %CommandResult{status: 1, output: "failed"},
               %CommandResult{status: 0, output: ""}
             )
  end

  @tag :tmp_dir
  test "restart_managed builds tmux restart commands", %{tmp_dir: tmp_dir} do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")
    File.write!(workflow_path, "body")
    artifact_path = Path.join(tmp_dir, "symphony")
    File.write!(artifact_path, "#!/bin/sh\n")
    File.chmod!(artifact_path, 0o755)

    config =
      service_config(tmp_dir,
        self_healing: %SelfHealingConfig{
          enabled: true,
          workspace_root: Path.join(tmp_dir, "heal"),
          tmux_session: "symphony-test",
          restart_port: 9999,
          restart_workflow_path: workflow_path
        }
      )

    test_pid = self()

    runner = fn command, cwd, _env ->
      send(test_pid, {:command, command, cwd})
      %CommandResult{command: command, cwd: cwd, status: 0, output: ""}
    end

    assert {:ok, results} =
             SelfHeal.restart_managed(config, artifact_path: artifact_path, runner: runner)

    assert length(results) == 3
    assert_received {:command, "tmux has-session" <> _, ^tmp_dir}
    assert_received {:command, "pids=$(lsof" <> _, ^tmp_dir}
    assert_received {:command, "tmux new-session" <> command, ^tmp_dir}
    assert command =~ "symphony-test"
    assert command =~ artifact_path
    assert command =~ workflow_path
  end

  @tag :tmp_dir
  test "restart_managed refuses to stop a running service before artifact preflight passes", %{
    tmp_dir: tmp_dir
  } do
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")
    File.write!(workflow_path, "body")

    config =
      service_config(tmp_dir,
        self_healing: %SelfHealingConfig{
          enabled: true,
          workspace_root: Path.join(tmp_dir, "heal"),
          tmux_session: "symphony-test",
          restart_port: 9999,
          restart_workflow_path: workflow_path
        }
      )

    test_pid = self()

    runner = fn command, cwd, _env ->
      send(test_pid, {:unexpected_command, command, cwd})
      %CommandResult{command: command, cwd: cwd, status: 0, output: ""}
    end

    missing_artifact_path = Path.join(tmp_dir, "missing-symphony")

    assert {:error, [%CommandResult{} = result]} =
             SelfHeal.restart_managed(config,
               artifact_path: missing_artifact_path,
               runner: runner
             )

    assert result.command == "preflight managed Symphony artifact"
    assert result.cwd == tmp_dir
    assert result.status == 1
    assert result.output =~ "managed restart requires an executable Symphony artifact"
    assert result.output =~ missing_artifact_path
    refute_received {:unexpected_command, _command, _cwd}
  end

  @tag :tmp_dir
  test "run_once repairs in isolated worktree, deploys artifact, and opens PR", %{
    tmp_dir: tmp_dir
  } do
    setup_git_repo!(tmp_dir)
    workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

    config =
      service_config(tmp_dir,
        self_healing: %SelfHealingConfig{
          enabled: true,
          base_branch: "main",
          branch_prefix: "codex/self-heal",
          workspace_root: Path.join(tmp_dir, ".symphony-self-heal"),
          cooldown_ms: 1,
          max_attempts: 1,
          validation_commands: ["true"],
          tmux_session: "symphony-test",
          restart_port: 9999,
          restart_workflow_path: workflow_path
        }
      )

    test_pid = self()

    repair_fun = fn _config, worktree_path, prompt, 1, _opts ->
      assert prompt =~ "Fix the codebase generically"
      File.write!(Path.join(worktree_path, "fix.txt"), "fixed\n")
      File.write!(Path.join(worktree_path, "symphony"), "#!/bin/sh\n")
      File.chmod!(Path.join(worktree_path, "symphony"), 0o755)
      {:ok, "fixed"}
    end

    runner = fn command, cwd, env ->
      cond do
        String.starts_with?(command, "git push ") ->
          send(test_pid, {:command, command})
          %CommandResult{command: command, cwd: cwd, status: 0, output: ""}

        String.starts_with?(command, "gh pr create ") ->
          send(test_pid, {:command, command})

          %CommandResult{
            command: command,
            cwd: cwd,
            status: 0,
            output: "https://github.com/CarettaAI/caretta-symphony/pull/123\n"
          }

        String.starts_with?(command, "gh pr merge ") ->
          send(test_pid, {:command, command})
          %CommandResult{command: command, cwd: cwd, status: 1, output: "reviews required"}

        String.starts_with?(command, "tmux ") or String.starts_with?(command, "pids=") ->
          %CommandResult{command: command, cwd: cwd, status: 0, output: ""}

        true ->
          {output, status} =
            System.cmd("bash", ["-lc", command],
              cd: cwd,
              env: env,
              stderr_to_stdout: true
            )

          %CommandResult{command: command, cwd: cwd, status: status, output: output}
      end
    end

    result =
      SelfHeal.run_once(config,
        reason: "poll failure",
        run_id: "test-run",
        repair_fun: repair_fun,
        runner: runner
      )

    assert %RunResult{status: :ok, attempts: 1} = result
    assert result.branch == "codex/self-heal/test-run"

    assert result.worktree_path ==
             Path.join(config.self_healing.workspace_root, "worktrees/test-run")

    assert result.pr_url == "https://github.com/CarettaAI/caretta-symphony/pull/123"
    assert result.auto_merge_status == "reviews required"
    assert File.exists?(result.artifact_path)
    assert File.read!(result.artifact_path) == "#!/bin/sh\n"

    assert File.read!(Path.join(Path.dirname(result.evidence_path), "github-sync.json")) =~
             "reviews required"

    assert_received {:command, "git push " <> _}
    assert_received {:command, "gh pr create " <> _}
    assert_received {:command, "gh pr merge " <> _}
  end

  @tag :tmp_dir
  test "lock and cooldown skip repair before touching worktree", %{tmp_dir: tmp_dir} do
    config =
      service_config(tmp_dir,
        self_healing: %SelfHealingConfig{
          enabled: true,
          workspace_root: Path.join(tmp_dir, "heal"),
          cooldown_ms: 60_000
        }
      )

    File.mkdir_p!(config.self_healing.workspace_root)
    File.write!(Path.join(config.self_healing.workspace_root, "self-heal.lock"), "locked\n")

    assert %RunResult{status: :skipped, error: "another self-heal run is active"} =
             SelfHeal.run_once(config, reason: "manual")

    File.rm!(Path.join(config.self_healing.workspace_root, "self-heal.lock"))

    File.write!(
      Path.join(config.self_healing.workspace_root, "last-success-ms"),
      "#{System.os_time(:millisecond)}"
    )

    assert %RunResult{status: :skipped, error: "self-heal cooldown is active"} =
             SelfHeal.run_once(config, reason: "manual")
  end

  defp service_config(tmp_dir, overrides) do
    self_healing =
      Keyword.get(
        overrides,
        :self_healing,
        %SelfHealingConfig{enabled: true, workspace_root: Path.join(tmp_dir, "heal")}
      )

    %ServiceConfig{
      workflow_path: Path.join(tmp_dir, "WORKFLOW.md"),
      polling: %PollingConfig{interval_ms: 1_000},
      self_healing: self_healing
    }
  end

  defp setup_git_repo!(tmp_dir) do
    File.write!(Path.join(tmp_dir, "WORKFLOW.md"), "body\n")
    File.write!(Path.join(tmp_dir, "README.md"), "repo\n")
    git!(tmp_dir, ["init"])
    git!(tmp_dir, ["config", "user.name", "Symphony Test"])
    git!(tmp_dir, ["config", "user.email", "symphony-test@example.com"])
    git!(tmp_dir, ["add", "."])
    git!(tmp_dir, ["commit", "-m", "initial"])
    git!(tmp_dir, ["branch", "-M", "main"])
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
