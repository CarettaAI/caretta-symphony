defmodule Symphony.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Symphony.Config.{HooksConfig, RepositoryConfig, RepositoryPlanningConfig, WorkspaceConfig}
  alias Symphony.Error
  alias Symphony.Models.{RepoPlan, RepoPlanItem}
  alias Symphony.Workspace.Manager

  @tag :tmp_dir
  test "workspace sanitizes and after_create runs once", %{tmp_dir: tmp_dir} do
    manager =
      Manager.new(
        %WorkspaceConfig{root: Path.join(tmp_dir, "root")},
        %HooksConfig{
          after_create: "echo created >> marker.txt",
          before_run: "echo before >> marker.txt"
        }
      )

    first = Manager.create_for_issue(manager, "ABC/1")
    second = Manager.create_for_issue(manager, "ABC/1")
    Manager.before_run(manager, first.path)

    assert first.workspace_key == "ABC_1"
    refute second.created_now
    assert first.path == second.path

    assert Path.join(first.path, "marker.txt") |> File.read!() |> String.split("\n", trim: true) ==
             ["created", "before"]
  end

  @tag :tmp_dir
  test "before_run failure is fatal", %{tmp_dir: tmp_dir} do
    manager = Manager.new(%WorkspaceConfig{root: tmp_dir}, %HooksConfig{before_run: "exit 7"})
    workspace = Manager.create_for_issue(manager, "ABC-1")

    assert_raise Error, ~r/hook_failed/, fn ->
      Manager.before_run(manager, workspace.path)
    end
  end

  @tag :tmp_dir
  test "before_run hook timeout is fatal", %{tmp_dir: tmp_dir} do
    manager =
      Manager.new(
        %WorkspaceConfig{root: tmp_dir},
        %HooksConfig{before_run: "sleep 5", timeout_ms: 10}
      )

    workspace = Manager.create_for_issue(manager, "ABC-1")

    assert_raise Error, ~r/hook_timeout/, fn ->
      Manager.before_run(manager, workspace.path)
    end
  end

  @tag :tmp_dir
  test "existing non-directory workspace fails", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    File.mkdir!(root)
    File.write!(Path.join(root, "ABC-1"), "not a dir")
    manager = Manager.new(%WorkspaceConfig{root: root}, %HooksConfig{})

    assert_raise Error, ~r/workspace_path_not_directory/, fn ->
      Manager.create_for_issue(manager, "ABC-1")
    end
  end

  @tag :tmp_dir
  test "repo plan materializes multi-repo workspace and quarantines legacy checkout", %{
    tmp_dir: tmp_dir
  } do
    {project_source, project_remote} = git_repo_with_remote(tmp_dir, "desktop-runtime")
    {wrong_source, _wrong_remote} = git_repo_with_remote(tmp_dir, "model-gateway")
    checkout_branch_with_commit(project_source, "feature/aec-bugfix", "feature.txt")

    root = Path.join(tmp_dir, "root")
    File.mkdir!(root)
    legacy_workspace = Path.join(root, "ENG-251")
    System.cmd("git", ["clone", wrong_source, legacy_workspace], stderr_to_stdout: true)

    manager = Manager.new(%WorkspaceConfig{root: root}, %HooksConfig{})
    workspace = Manager.create_for_issue(manager, "ENG-251")

    plan = %RepoPlan{
      issue_identifier: "ENG-251",
      coding_task: true,
      planner: "rules",
      source: "test",
      primary_repo: %RepoPlanItem{
        slug: "ExampleOrg/desktop-runtime",
        role: "primary",
        path_name: "desktop-runtime"
      }
    }

    repo_config = %RepositoryPlanningConfig{
      enabled: true,
      repositories: [
        %RepositoryConfig{
          slug: "ExampleOrg/desktop-runtime",
          local_path: project_source,
          remote_url: project_remote
        }
      ]
    }

    prepared = Manager.materialize_repo_plan(manager, workspace, plan, repo_config)
    repo_path = Path.join([root, "ENG-251", "repos", "desktop-runtime"])

    assert prepared.primary_repo_path == repo_path
    assert File.exists?(Path.join(repo_path, ".git"))
    assert File.exists?(Path.join(root, "ENG-251/repo-plan.json"))
    assert Path.join(root, "_quarantine") |> Path.join("ENG-251-*") |> Path.wildcard() != []
    assert git(repo_path, ["config", "--get", "remote.origin.url"]) == project_remote
    assert git(repo_path, ["branch", "--show-current"]) == "Symphony/ENG-251-desktop-runtime"
    refute File.exists?(Path.join(repo_path, "feature.txt"))

    metadata =
      Path.join(root, "ENG-251/.symphony-workspace.json") |> File.read!() |> Jason.decode!()

    assert get_in(metadata, ["repositories", Access.at(0), "git", "expected_branch"]) ==
             "Symphony/ENG-251-desktop-runtime"

    assert get_in(metadata, ["repositories", Access.at(0), "git", "base_ref"]) == "origin/dev"
    assert File.exists?(Path.join(repo_path, ".git/hooks/pre-push"))
  end

  @tag :tmp_dir
  test "pre-push guard allows expected branch and rejects wrong pushes", %{tmp_dir: tmp_dir} do
    {project_source, project_remote} = git_repo_with_remote(tmp_dir, "desktop-runtime")
    manager = Manager.new(%WorkspaceConfig{root: Path.join(tmp_dir, "root")}, %HooksConfig{})
    workspace = Manager.create_for_issue(manager, "ENG-260")

    plan = %RepoPlan{
      issue_identifier: "ENG-260",
      coding_task: true,
      planner: "rules",
      source: "test",
      primary_repo: %RepoPlanItem{
        slug: "ExampleOrg/desktop-runtime",
        role: "primary",
        path_name: "desktop-runtime"
      }
    }

    repo_config = %RepositoryPlanningConfig{
      enabled: true,
      repositories: [
        %RepositoryConfig{
          slug: "ExampleOrg/desktop-runtime",
          local_path: project_source,
          remote_url: project_remote
        }
      ]
    }

    prepared = Manager.materialize_repo_plan(manager, workspace, plan, repo_config)
    repo_path = prepared.primary_repo_path
    expected_branch = "Symphony/ENG-260-desktop-runtime"

    {_out, allowed} =
      System.cmd("git", ["-C", repo_path, "push", "origin", "HEAD:#{expected_branch}"],
        stderr_to_stdout: true
      )

    {wrong_destination_out, wrong_destination} =
      System.cmd("git", ["-C", repo_path, "push", "origin", "HEAD:feature/aec-bugfix"],
        stderr_to_stdout: true
      )

    System.cmd("git", ["-C", repo_path, "checkout", "-b", "feature/aec-bugfix"],
      stderr_to_stdout: true
    )

    {wrong_current_branch_out, wrong_current_branch} =
      System.cmd("git", ["-C", repo_path, "push", "origin", "HEAD:#{expected_branch}"],
        stderr_to_stdout: true
      )

    assert allowed == 0
    assert wrong_destination != 0
    assert wrong_destination_out =~ "Symphony branch guard"
    assert wrong_current_branch != 0
    assert wrong_current_branch_out =~ "Symphony branch guard"
  end

  @tag :tmp_dir
  test "repo clone timeout is enforced", %{tmp_dir: tmp_dir} do
    old_path = System.get_env("PATH") || ""
    fake_bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(fake_bin)
    fake_git = Path.join(fake_bin, "git")
    File.write!(fake_git, "#!/bin/sh\nsleep 5\n")
    File.chmod!(fake_git, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> old_path)

    try do
      manager = Manager.new(%WorkspaceConfig{root: Path.join(tmp_dir, "root")}, %HooksConfig{})
      workspace = Manager.create_for_issue(manager, "ENG-300")

      plan = %RepoPlan{
        issue_identifier: "ENG-300",
        coding_task: true,
        planner: "rules",
        source: "test",
        primary_repo: %RepoPlanItem{
          slug: "ExampleOrg/desktop-runtime",
          role: "primary",
          path_name: "desktop-runtime"
        }
      }

      repo_config = %RepositoryPlanningConfig{
        enabled: true,
        clone_timeout_ms: 10,
        repositories: [
          %RepositoryConfig{
            slug: "ExampleOrg/desktop-runtime",
            remote_url: "https://example.invalid/desktop-runtime.git"
          }
        ]
      }

      assert_raise Error, ~r/repo_clone_timeout/, fn ->
        Manager.materialize_repo_plan(manager, workspace, plan, repo_config)
      end
    after
      System.put_env("PATH", old_path)
    end
  end

  defp git_repo_with_remote(tmp_dir, name) do
    remote = Path.join([tmp_dir, "remotes", "#{name}.git"])
    File.mkdir_p!(Path.dirname(remote))
    System.cmd("git", ["init", "--bare", "-q", remote], stderr_to_stdout: true)
    source = Path.join([tmp_dir, "source", name])
    File.mkdir_p!(source)
    System.cmd("git", ["init", "-q"], cd: source, stderr_to_stdout: true)
    configure_git_user(source)
    File.write!(Path.join(source, "README.md"), "# #{name}\n")
    System.cmd("git", ["add", "README.md"], cd: source, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-q", "-m", "initial"], cd: source, stderr_to_stdout: true)
    System.cmd("git", ["branch", "-M", "dev"], cd: source, stderr_to_stdout: true)
    System.cmd("git", ["remote", "add", "origin", remote], cd: source, stderr_to_stdout: true)
    System.cmd("git", ["push", "-q", "-u", "origin", "dev"], cd: source, stderr_to_stdout: true)
    {source, remote}
  end

  defp checkout_branch_with_commit(repo_path, branch, filename) do
    System.cmd("git", ["checkout", "-q", "-b", branch], cd: repo_path, stderr_to_stdout: true)
    File.write!(Path.join(repo_path, filename), "source branch residue\n")
    System.cmd("git", ["add", filename], cd: repo_path, stderr_to_stdout: true)

    System.cmd("git", ["commit", "-q", "-m", "source branch residue"],
      cd: repo_path,
      stderr_to_stdout: true
    )
  end

  defp configure_git_user(repo_path) do
    System.cmd("git", ["config", "user.name", "Symphony Test"],
      cd: repo_path,
      stderr_to_stdout: true
    )

    System.cmd("git", ["config", "user.email", "symphony@example.com"],
      cd: repo_path,
      stderr_to_stdout: true
    )
  end

  defp git(repo_path, args) do
    {out, 0} = System.cmd("git", ["-C", repo_path | args], stderr_to_stdout: true)
    String.trim(out)
  end
end
