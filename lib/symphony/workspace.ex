defmodule Symphony.Workspace do
  @moduledoc false

  alias Symphony.Config.{HooksConfig, RepositoryConfig, RepositoryPlanningConfig, WorkspaceConfig}
  alias Symphony.Error
  alias Symphony.Logging
  alias Symphony.Models.{RepoPlan, RepoPlanItem, Workspace}
  alias Symphony.Utils

  defmodule Manager do
    defstruct root: nil, hooks: %HooksConfig{}

    def new(%WorkspaceConfig{} = workspace_config, %HooksConfig{} = hooks) do
      %__MODULE__{root: Path.expand(workspace_config.root), hooks: hooks}
    end

    def workspace_path_for_identifier(%__MODULE__{} = manager, identifier) do
      Utils.resolve_under_root(manager.root, Utils.sanitize_workspace_key(identifier))
    end

    def create_for_issue(%__MODULE__{} = manager, identifier) do
      workspace_key = Utils.sanitize_workspace_key(identifier)
      workspace_path = Utils.resolve_under_root(manager.root, workspace_key)
      File.mkdir_p!(manager.root)

      if File.exists?(workspace_path) and !File.dir?(workspace_path) do
        raise Error,
          code: :workspace_path_not_directory,
          message: "workspace path exists and is not a directory: #{workspace_path}"
      end

      created_now = !File.exists?(workspace_path)
      if created_now, do: File.mkdir!(workspace_path)

      workspace = %Workspace{
        path: workspace_path,
        workspace_key: workspace_key,
        created_now: created_now
      }

      if created_now and manager.hooks.after_create do
        run_hook(manager, :after_create, workspace.path, fatal: true)
      end

      workspace
    end

    def materialize_repo_plan(
          %__MODULE__{} = manager,
          %Workspace{} = workspace,
          %RepoPlan{} = repo_plan,
          %RepositoryPlanningConfig{} = config
        ) do
      if !repo_plan.coding_task or is_nil(repo_plan.primary_repo) do
        %{workspace | repo_plan: repo_plan}
      else
        workspace =
          if workspace_requires_quarantine?(manager, workspace.path, repo_plan, config) do
            unless config.quarantine_on_mismatch do
              raise Error,
                code: :workspace_repo_mismatch,
                message:
                  "workspace does not match repo plan and quarantine_on_mismatch is false: #{workspace.path}"
            end

            quarantine_workspace(workspace.path)
            File.mkdir!(workspace.path)
            %{workspace | created_now: true}
          else
            workspace
          end

        repos_dir = Path.join(workspace.path, "repos")
        File.mkdir_p!(repos_dir)
        repository_by_slug = RepositoryPlanningConfig.repository_by_slug(config)

        repo_metadata =
          repo_plan
          |> RepoPlan.all_repos()
          |> Enum.map(fn planned_repo ->
            repo_config = repository_by_slug[planned_repo.slug]

            unless repo_config do
              raise Error,
                code: :unknown_planned_repository,
                message: "repo plan references unknown repo: #{planned_repo.slug}"
            end

            path_name = repo_path_name(planned_repo, repo_config)
            repo_path = Path.join(repos_dir, path_name)
            base_branch = base_branch_name(repo_config.base_branch || config.base_branch)

            expected_branch =
              expected_branch_name(
                repo_plan.issue_identifier,
                planned_repo,
                repo_config,
                config.branch_prefix
              )

            checkout_metadata =
              ensure_repo_checkout(manager, repo_path, repo_config, config.clone_timeout_ms,
                base_branch: base_branch,
                expected_branch: expected_branch
              )

            %{
              "slug" => planned_repo.slug,
              "role" => planned_repo.role,
              "edit_allowed" => planned_repo.edit_allowed,
              "path_name" => path_name,
              "path" => "repos/#{path_name}",
              "remote_url" => checkout_metadata["remote_url"],
              "git" => checkout_metadata
            }
          end)

        write_repo_metadata(workspace.path, repo_plan, repo_metadata)

        %{
          workspace
          | repo_plan: repo_plan,
            primary_repo_path:
              repo_path(workspace.path, repo_plan.primary_repo, repository_by_slug)
        }
      end
    end

    def repo_path(workspace_path, %RepoPlanItem{} = repo_item, repository_by_slug) do
      repo_config = repository_by_slug[repo_item.slug]
      Path.join([workspace_path, "repos", repo_path_name(repo_item, repo_config)])
    end

    def before_run(%__MODULE__{} = manager, workspace_path) do
      if manager.hooks.before_run, do: run_hook(manager, :before_run, workspace_path, fatal: true)
    end

    def after_run(%__MODULE__{} = manager, workspace_path) do
      if manager.hooks.after_run do
        try do
          run_hook(manager, :after_run, workspace_path, fatal: false)
        rescue
          Error -> :ok
        end
      end
    end

    def remove_for_identifier(%__MODULE__{} = manager, identifier) do
      workspace_path = workspace_path_for_identifier(manager, identifier)

      if File.exists?(workspace_path) do
        if manager.hooks.before_remove do
          try do
            run_hook(manager, :before_remove, workspace_path, fatal: false)
          rescue
            Error -> :ok
          end
        end

        File.rm_rf!(workspace_path)
      end

      :ok
    end

    defp workspace_requires_quarantine?(_manager, workspace_path, repo_plan, config) do
      cond do
        !File.exists?(workspace_path) ->
          false

        File.dir?(Path.join(workspace_path, ".git")) ->
          true

        true ->
          repos_dir = Path.join(workspace_path, "repos")
          ignored = MapSet.new(["repo-plan.json", ".symphony-workspace.json", "repos"])

          existing_entries =
            workspace_path
            |> File.ls!()
            |> Enum.reject(&MapSet.member?(ignored, &1))

          cond do
            existing_entries != [] and !File.exists?(repos_dir) ->
              true

            true ->
              repository_by_slug = RepositoryPlanningConfig.repository_by_slug(config)

              Enum.any?(RepoPlan.all_repos(repo_plan), fn planned_repo ->
                repo_config = repository_by_slug[planned_repo.slug]

                if repo_config do
                  repo_path =
                    Path.join([
                      workspace_path,
                      "repos",
                      repo_path_name(planned_repo, repo_config)
                    ])

                  File.exists?(repo_path) and !repo_checkout_matches?(repo_path, repo_config)
                else
                  false
                end
              end)
          end
      end
    end

    defp quarantine_workspace(workspace_path) do
      if File.exists?(workspace_path) do
        quarantine_root = Path.join(Path.dirname(workspace_path), "_quarantine")
        File.mkdir_p!(quarantine_root)

        timestamp =
          Utils.now_utc()
          |> Utils.isoformat_z()
          |> String.replace(":", "")
          |> String.replace(".", "-")

        base = Path.join(quarantine_root, "#{Path.basename(workspace_path)}-#{timestamp}")
        target = unique_path(base)
        File.rename!(workspace_path, target)
      end
    end

    defp unique_path(path, suffix \\ 1)
    defp unique_path(path, 1), do: if(File.exists?(path), do: unique_path(path, 2), else: path)

    defp unique_path(path, suffix),
      do:
        if(File.exists?("#{path}-#{suffix}"),
          do: unique_path(path, suffix + 1),
          else: "#{path}-#{suffix}"
        )

    defp ensure_repo_checkout(_manager, repo_path, repo_config, timeout_ms, opts) do
      base_branch = Keyword.fetch!(opts, :base_branch)
      expected_branch = Keyword.fetch!(opts, :expected_branch)

      if File.exists?(repo_path) do
        unless File.dir?(repo_path),
          do:
            raise(Error,
              code: :repo_path_not_directory,
              message: "repo path exists and is not a directory: #{repo_path}"
            )

        unless repo_checkout_matches?(repo_path, repo_config) do
          raise Error,
            code: :repo_checkout_mismatch,
            message:
              "repo path exists but remote does not match #{repo_config.slug}: #{repo_path}"
        end

        current_branch =
          git_output(
            repo_path,
            ["branch", "--show-current"],
            timeout_ms,
            :repo_branch_read_failed,
            "failed reading current branch for #{repo_config.slug}"
          )

        install_pre_push_guard(repo_path, expected_branch)

        %{
          "base_branch" => base_branch,
          "base_ref" => "origin/#{base_branch}",
          "base_sha" => nil,
          "expected_branch" => expected_branch,
          "expected_ref" => "refs/heads/#{expected_branch}",
          "current_branch" => current_branch,
          "branch_prepared" => false,
          "pre_push_guard" => true,
          "remote_url" => git_remote(repo_path)
        }
      else
        source = repo_config.local_path || repo_config.remote_url

        unless source,
          do:
            raise(Error,
              code: :repository_missing_source,
              message: "repository has no clone source: #{repo_config.slug}"
            )

        File.mkdir_p!(Path.dirname(repo_path))

        command =
          if repo_config.local_path,
            do: ["clone", "--no-hardlinks", source, repo_path],
            else: ["clone", source, repo_path]

        Logging.log_event(:info, "repo_clone_started",
          repo_slug: repo_config.slug,
          source: source,
          repo_path: repo_path
        )

        run_git(
          nil,
          command,
          timeout_ms,
          :repo_clone_failed,
          "git clone failed for #{repo_config.slug}"
        )

        if repo_config.remote_url do
          git_output(
            repo_path,
            ["remote", "set-url", "origin", repo_config.remote_url],
            timeout_ms,
            :repo_remote_set_failed,
            "git remote set-url failed for #{repo_path}"
          )
        end

        base_sha =
          prepare_expected_branch(
            repo_path,
            repo_config.slug,
            base_branch,
            expected_branch,
            timeout_ms
          )

        install_pre_push_guard(repo_path, expected_branch)

        Logging.log_event(:info, "repo_clone_completed",
          repo_slug: repo_config.slug,
          repo_path: repo_path
        )

        %{
          "base_branch" => base_branch,
          "base_ref" => "origin/#{base_branch}",
          "base_sha" => base_sha,
          "expected_branch" => expected_branch,
          "expected_ref" => "refs/heads/#{expected_branch}",
          "current_branch" => expected_branch,
          "branch_prepared" => true,
          "pre_push_guard" => true,
          "remote_url" => git_remote(repo_path)
        }
      end
    end

    defp prepare_expected_branch(repo_path, repo_slug, base_branch, expected_branch, timeout_ms) do
      git_output(
        repo_path,
        ["fetch", "origin", "+#{base_branch}:refs/remotes/origin/#{base_branch}"],
        timeout_ms,
        :repo_base_fetch_failed,
        "failed fetching origin/#{base_branch} for #{repo_slug}"
      )

      base_sha =
        git_output(
          repo_path,
          ["rev-parse", "origin/#{base_branch}"],
          timeout_ms,
          :repo_base_ref_failed,
          "failed resolving origin/#{base_branch} for #{repo_slug}"
        )

      git_output(
        repo_path,
        ["checkout", "-B", expected_branch, "origin/#{base_branch}"],
        timeout_ms,
        :repo_branch_checkout_failed,
        "failed checking out #{expected_branch} from origin/#{base_branch} for #{repo_slug}"
      )

      git_output(
        repo_path,
        ["config", "branch.#{expected_branch}.remote", "origin"],
        timeout_ms,
        :repo_branch_config_failed,
        "failed configuring push remote for #{expected_branch} in #{repo_slug}"
      )

      git_output(
        repo_path,
        ["config", "branch.#{expected_branch}.merge", "refs/heads/#{expected_branch}"],
        timeout_ms,
        :repo_branch_config_failed,
        "failed configuring upstream branch for #{expected_branch} in #{repo_slug}"
      )

      base_sha
    end

    defp git_output(repo_path, args, timeout_ms, error_code, error_message) do
      run_git(repo_path, args, timeout_ms, error_code, error_message)
    end

    defp run_git(repo_path, args, timeout_ms, error_code, error_message) do
      options = [stderr_to_stdout: true]
      options = if repo_path, do: Keyword.put(options, :cd, repo_path), else: options

      case command_result("git", args, options, timeout_ms) do
        {:ok, output, 0} ->
          String.trim(output)

        {:ok, output, _status} ->
          raise Error,
            code: error_code,
            message: "#{error_message}: #{Utils.truncate(output, 2000)}"

        :timeout ->
          raise Error,
            code: timeout_error_code(error_code),
            message: "#{error_message}: timed out after #{timeout_ms} ms"

        {:error, reason} ->
          raise Error, code: error_code, message: "#{error_message}: #{inspect(reason)}"
      end
    end

    defp install_pre_push_guard(repo_path, expected_branch) do
      git_dir = Path.join(repo_path, ".git")

      unless File.dir?(git_dir),
        do:
          raise(Error,
            code: :repo_git_dir_missing,
            message: "repo .git directory is missing: #{repo_path}"
          )

      hooks_dir = Path.join(git_dir, "hooks")
      File.mkdir_p!(hooks_dir)
      expected_ref = "refs/heads/#{expected_branch}"

      script = """
      #!/bin/sh
      expected_branch=#{shell_quote(expected_branch)}
      expected_ref=#{shell_quote(expected_ref)}
      zero_oid=0000000000000000000000000000000000000000

      current_branch=$(git symbolic-ref --quiet --short HEAD) || {
        echo "Symphony branch guard: refusing to push from detached HEAD. Expected $expected_branch." >&2
        exit 1
      }

      if [ "$current_branch" != "$expected_branch" ]; then
        echo "Symphony branch guard: refusing to push from $current_branch. Expected $expected_branch." >&2
        exit 1
      fi

      while read local_ref local_oid remote_ref remote_oid
      do
        [ -z "$local_ref" ] && continue
        if [ "$local_oid" = "$zero_oid" ]; then
          echo "Symphony branch guard: refusing to delete remote refs from an agent workspace." >&2
          exit 1
        fi
        if [ "$local_ref" != "$expected_ref" ] && [ "$local_ref" != "HEAD" ]; then
          echo "Symphony branch guard: refusing to push $local_ref. Expected $expected_ref." >&2
          exit 1
        fi
        if [ "$remote_ref" != "$expected_ref" ]; then
          echo "Symphony branch guard: refusing to push to $remote_ref. Expected $expected_ref." >&2
          exit 1
        fi
      done
      exit 0
      """

      hook_path = Path.join(hooks_dir, "pre-push")
      File.write!(hook_path, script)
      File.chmod!(hook_path, 0o755)
    end

    defp repo_checkout_matches?(repo_path, %RepositoryConfig{} = repo_config) do
      if File.exists?(Path.join(repo_path, ".git")) do
        remote = git_remote(repo_path)

        cond do
          repo_config.remote_url ->
            normalize_git_remote(remote) == normalize_git_remote(repo_config.remote_url)

          repo_config.local_path ->
            Path.expand(remote) == Path.expand(repo_config.local_path)

          true ->
            String.contains?(normalize_git_remote(remote), String.downcase(repo_config.slug))
        end
      else
        false
      end
    rescue
      _ -> false
    end

    defp git_remote(repo_path) do
      git_output(
        repo_path,
        ["config", "--get", "remote.origin.url"],
        60_000,
        :git_remote_failed,
        "failed reading git remote for #{repo_path}"
      )
    end

    defp write_repo_metadata(workspace_path, repo_plan, repositories) do
      plan_payload = RepoPlan.to_map(repo_plan)

      File.write!(
        Path.join(workspace_path, "repo-plan.json"),
        Jason.encode!(plan_payload, pretty: true)
      )

      metadata = %{
        "version" => 1,
        "layout" => "multi_repo",
        "updated_at" => Utils.isoformat_z(Utils.now_utc()),
        "repo_plan" => plan_payload,
        "repositories" => repositories
      }

      File.write!(
        Path.join(workspace_path, ".symphony-workspace.json"),
        Jason.encode!(metadata, pretty: true)
      )
    end

    defp repo_path_name(%RepoPlanItem{} = repo_item, %RepositoryConfig{} = repo_config) do
      Utils.sanitize_workspace_key(repo_item.path_name || RepositoryConfig.path_name(repo_config))
    end

    defp expected_branch_name(issue_identifier, repo_item, repo_config, branch_prefix) do
      prefix = branch_segment(branch_prefix) || "Symphony"
      issue_segment = branch_segment(issue_identifier)

      repo_segment =
        branch_segment(repo_item.path_name || RepositoryConfig.path_name(repo_config))

      "#{prefix}/#{issue_segment}-#{repo_segment}"
    end

    def run_hook(%__MODULE__{} = manager, hook_name, workspace_path, opts) do
      script = Map.fetch!(manager.hooks, hook_name)
      fatal = Keyword.fetch!(opts, :fatal)
      workspace_abs = Path.expand(workspace_path)
      root_abs = Path.expand(manager.root)

      unless String.starts_with?(workspace_abs, root_abs <> "/") do
        raise Error,
          code: :invalid_workspace_cwd,
          message: "workspace path is outside workspace root: #{workspace_abs}"
      end

      Logging.log_event(:info, "hook_started", hook: hook_name, workspace_path: workspace_abs)

      case command_result(
             "bash",
             ["-lc", script],
             [cd: workspace_abs, stderr_to_stdout: true],
             manager.hooks.timeout_ms
           ) do
        {:ok, _output, 0} ->
          Logging.log_event(:info, "hook_completed",
            hook: hook_name,
            workspace_path: workspace_abs
          )

          :ok

        {:ok, output, status} ->
          Logging.log_event(:error, "hook_failed",
            hook: hook_name,
            workspace_path: workspace_abs,
            exit_code: status,
            fatal: fatal,
            output: Utils.truncate(output, 2000)
          )

          raise Error,
            code: :hook_failed,
            message: "hook failed with exit code #{status}: #{Utils.truncate(output, 2000)}"

        :timeout ->
          Logging.log_event(:error, "hook_timed_out",
            hook: hook_name,
            workspace_path: workspace_abs,
            fatal: fatal
          )

          raise Error,
            code: :hook_timeout,
            message: "hook timed out after #{manager.hooks.timeout_ms} ms"

        {:error, reason} ->
          raise Error, code: :hook_failed, message: "hook failed: #{inspect(reason)}"
      end
    end

    defp command_result(command, args, options, timeout_ms) do
      task =
        Task.async(fn ->
          try do
            {:ok, System.cmd(command, args, options)}
          rescue
            error -> {:error, error}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end)

      case Task.yield(task, max(timeout_ms, 1)) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {output, status}}} -> {:ok, output, status}
        {:ok, {:error, reason}} -> {:error, reason}
        nil -> :timeout
      end
    end

    defp timeout_error_code(:repo_clone_failed), do: :repo_clone_timeout
    defp timeout_error_code(:repo_remote_set_failed), do: :repo_remote_set_timeout
    defp timeout_error_code(error_code), do: error_code

    defp normalize_git_remote(value) do
      text = value |> to_string() |> String.trim() |> String.downcase()

      text =
        if String.starts_with?(text, "git@github.com:"),
          do: "https://github.com/" <> String.replace_prefix(text, "git@github.com:", ""),
          else: text

      text =
        if String.ends_with?(text, ".git"),
          do: String.slice(text, 0, String.length(text) - 4),
          else: text

      String.trim_trailing(text, "/")
    end

    defp base_branch_name(value) do
      text = value |> to_string() |> String.trim()
      text = String.replace_prefix(text, "refs/heads/", "")
      text = String.replace_prefix(text, "origin/", "")

      text
      |> String.split("/")
      |> Enum.map(&branch_segment/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("/")
      |> then(fn
        "" -> "dev"
        branch -> branch
      end)
    end

    defp branch_segment(value) do
      value
      |> to_string()
      |> String.trim()
      |> Utils.sanitize_workspace_key()
      |> String.trim("._-")
      |> case do
        "" -> nil
        text -> text
      end
    end

    defp shell_quote(value) do
      "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
    end
  end
end
