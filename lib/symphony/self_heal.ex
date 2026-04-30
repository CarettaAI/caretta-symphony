defmodule Symphony.SelfHeal do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias Symphony.CodexClient
  alias Symphony.Config.{ConfigManager, ServiceConfig, SelfHealingConfig}
  alias Symphony.Utils

  @restart_port_release_timeout_seconds 10
  @restart_port_probe_interval_seconds "0.1"

  defmodule CommandResult do
    defstruct command: nil, cwd: nil, output: "", status: 0
  end

  defmodule RunResult do
    defstruct [
      :run_id,
      :reason,
      :branch,
      :worktree_path,
      :artifact_path,
      :pr_url,
      :auto_merge_status,
      :restart_status,
      :evidence_path,
      status: :unknown,
      attempts: 0,
      validation: [],
      error: nil
    ]
  end

  def run_once(manager_or_config, opts \\ [])

  def run_once(%ConfigManager{} = manager, opts) do
    {_manager, _workflow, config} = ConfigManager.current(manager)
    run_once(config, opts)
  end

  def run_once(%ServiceConfig{} = config, opts) do
    reason = Keyword.get(opts, :reason) || "manual self-heal"
    self_healing = config.self_healing
    ensure_root!(self_healing)

    with_lock(self_healing, fn ->
      cond do
        !self_healing.enabled and !Keyword.get(opts, :force, false) ->
          %RunResult{
            run_id: nil,
            reason: reason,
            status: :skipped,
            error: "self-healing is disabled"
          }

        cooldown_active?(self_healing) ->
          %RunResult{
            run_id: nil,
            reason: reason,
            status: :skipped,
            error: "self-heal cooldown is active"
          }

        true ->
          do_run_once(config, reason, opts)
      end
    end)
  end

  def restart_managed(manager_or_config, opts \\ [])

  def restart_managed(%ConfigManager{} = manager, opts) do
    {_manager, _workflow, config} = ConfigManager.current(manager)
    restart_managed(config, opts)
  end

  def restart_managed(%ServiceConfig{} = config, opts) do
    self_healing = config.self_healing
    repo_root = repo_root(config)

    artifact =
      Keyword.get(opts, :artifact_path) ||
        Path.join([self_healing.workspace_root, "deploy", "current", "symphony"])

    artifact = Path.expand(artifact)
    workflow_path = Path.expand(self_healing.restart_workflow_path || config.workflow_path)
    session = self_healing.tmux_session
    port = self_healing.restart_port

    if executable_artifact?(artifact) do
      managed_command =
        "cd #{shell(repo_root)} && exec #{shell(artifact)} #{shell(workflow_path)} --port #{port}"

      commands = [
        "tmux has-session -t #{shell(session)} 2>/dev/null && tmux kill-session -t #{shell(session)} || true",
        "pids=$(lsof -tiTCP:#{port} -sTCP:LISTEN 2>/dev/null || true); if [ -n \"$pids\" ]; then kill $pids 2>/dev/null || true; fi",
        wait_for_port_release_command(port),
        "tmux new-session -d -s #{shell(session)} #{shell(managed_command)}"
      ]

      case run_restart_commands(commands, repo_root, opts) do
        {:ok, results} -> {:ok, results}
        {:error, results} -> {:error, results}
      end
    else
      {:error,
       [
         %CommandResult{
           command: "preflight managed Symphony artifact",
           cwd: repo_root,
           output: "managed restart requires an executable Symphony artifact at #{artifact}",
           status: 1
         }
       ]}
    end
  end

  def build_repair_prompt(reason, evidence, attempt, max_attempts) do
    """
    You are a high-reasoning Codex repair agent for Caretta Symphony.

    Mission:
    - Diagnose the root cause of the local Symphony failure.
    - Fix the codebase generically with strong engineering practice.
    - Do not apply narrow point fixes, log silencing, sleeps, retries, or special-case hacks unless they are part of a principled design.
    - Add or improve tests that would have caught the failure or an adjacent failure mode.
    - Preserve existing behavior unless changing it is necessary and justified by the root cause.
    - Do not print, commit, or expose secrets.
    - Do not push, open PRs, merge, restart Symphony, or edit files outside this checkout. The self-heal supervisor owns validation, git, deploy, and GitHub synchronization.

    Attempt #{attempt} of #{max_attempts}.
    Trigger reason:
    #{reason}

    Evidence:
    #{Jason.encode!(evidence, pretty: true)}

    Completion bar:
    - Root cause has been addressed at the right abstraction level.
    - Relevant tests have been added or updated.
    - The repository is ready for `mix format --check-formatted`, `mix test`, and `mix escript.build`.
    """
    |> String.trim()
  end

  def validation_success?(results), do: Enum.all?(results, &(&1.status == 0))

  def result_to_map(%RunResult{} = result) do
    %{
      "status" => to_string(result.status),
      "run_id" => result.run_id,
      "reason" => result.reason,
      "branch" => result.branch,
      "worktree_path" => result.worktree_path,
      "artifact_path" => result.artifact_path,
      "evidence_path" => result.evidence_path,
      "pr_url" => result.pr_url,
      "auto_merge_status" => normalize_status(result.auto_merge_status),
      "restart_status" => normalize_status(result.restart_status),
      "attempts" => result.attempts,
      "validation" => encode_results(result.validation || []),
      "error" => result.error
    }
  end

  def branch_name(%SelfHealingConfig{} = config, run_id) do
    prefix = config.branch_prefix |> to_string() |> String.trim("/")
    "#{prefix}/#{run_id}"
  end

  def run_id(reason, now \\ Utils.now_utc()) do
    stamp =
      now
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9T]/, "")

    "#{stamp}-#{sanitize_segment(reason)}"
    |> String.trim("-")
    |> String.slice(0, 80)
    |> String.trim("-")
  end

  def classify_github_sync(pr_create, auto_merge) do
    cond do
      pr_create.status != 0 ->
        {:error, Utils.truncate(pr_create.output, 1000)}

      auto_merge.status == 0 ->
        {:ok, "auto-merge enabled"}

      true ->
        {:blocked, Utils.truncate(auto_merge.output, 1000)}
    end
  end

  defp do_run_once(config, reason, opts) do
    self_healing = config.self_healing
    run_id = Keyword.get(opts, :run_id) || run_id(reason)
    branch = branch_name(self_healing, run_id)
    run_dir = Path.join(self_healing.workspace_root, "runs/#{run_id}")
    worktree_path = Path.join(self_healing.workspace_root, "worktrees/#{run_id}")
    File.mkdir_p!(run_dir)

    evidence = collect_evidence(config, reason, run_dir, opts)
    evidence_path = Path.join(run_dir, "evidence.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))

    with {:ok, _} <- prepare_worktree(config, branch, worktree_path, run_dir, opts),
         {:ok, attempts, validation} <-
           repair_until_valid(config, reason, evidence, worktree_path, opts),
         true <- worktree_has_changes?(worktree_path, opts) || {:error, "repair made no changes"},
         {:ok, commit_sha} <- commit_repair(worktree_path, reason, opts),
         {:ok, artifact_path} <- deploy_artifact(config, worktree_path),
         restart_status <- restart_managed_status(config, artifact_path, opts),
         github <-
           sync_github(config, worktree_path, branch, reason, evidence_path, commit_sha, opts) do
      write_cooldown(self_healing)

      %RunResult{
        run_id: run_id,
        reason: reason,
        branch: branch,
        worktree_path: worktree_path,
        artifact_path: artifact_path,
        evidence_path: evidence_path,
        status: :ok,
        attempts: attempts,
        validation: validation,
        pr_url: github[:pr_url],
        auto_merge_status: github[:auto_merge_status],
        restart_status: restart_status
      }
    else
      {:error, error} ->
        %RunResult{
          run_id: run_id,
          reason: reason,
          branch: branch,
          worktree_path: worktree_path,
          evidence_path: evidence_path,
          status: :error,
          error: error
        }
    end
  end

  defp collect_evidence(%ServiceConfig{} = config, reason, run_dir, opts) do
    root = repo_root(config)
    port = config.self_healing.restart_port
    diff = run_shell("git diff --binary HEAD", root, opts)
    File.write!(Path.join(run_dir, "current-working-tree.patch"), diff.output || "")

    %{
      "reason" => reason,
      "captured_at" => Utils.isoformat_z(Utils.now_utc()),
      "repo_root" => root,
      "workflow_path" => config.workflow_path,
      "git_status" => command_output("git status --short", root, opts),
      "git_head" => command_output("git rev-parse HEAD", root, opts),
      "git_branch" => command_output("git branch --show-current", root, opts),
      "git_remote" => command_output("git remote -v", root, opts),
      "state" => fetch_state(port),
      "process" =>
        command_output("ps -ax -o pid,ppid,stat,command | grep '[s]ymphony'", root, opts),
      "listeners" => command_output("lsof -nP -iTCP:#{port} -sTCP:LISTEN", root, opts),
      "stdout_tail" =>
        command_output(
          "tail -n 200 /var/tmp/caretta-symphony.out.log 2>/dev/null || true",
          root,
          opts
        ),
      "stderr_tail" =>
        command_output(
          "tail -n 200 /var/tmp/caretta-symphony.err.log 2>/dev/null || true",
          root,
          opts
        )
    }
  end

  defp prepare_worktree(config, branch, worktree_path, run_dir, opts) do
    root = repo_root(config)
    File.rm_rf!(worktree_path)
    File.mkdir_p!(Path.dirname(worktree_path))

    commands = [
      "git fetch origin #{shell(config.self_healing.base_branch)} --quiet || true",
      "git worktree add -B #{shell(branch)} #{shell(worktree_path)} HEAD"
    ]

    case run_commands(commands, root, opts) do
      {:ok, results} ->
        patch_path = Path.join(run_dir, "current-working-tree.patch")

        if File.exists?(patch_path) and File.read!(patch_path) |> String.trim() != "" do
          apply = run_shell("git apply --3way #{shell(patch_path)}", worktree_path, opts)

          if apply.status == 0,
            do: {:ok, results ++ [apply]},
            else: {:error, "failed to apply current working-tree patch: #{apply.output}"}
        else
          {:ok, results}
        end

      {:error, result} ->
        {:error, result.output}
    end
  end

  defp repair_until_valid(config, reason, evidence, worktree_path, opts) do
    max_attempts = config.self_healing.max_attempts
    repair_fun = Keyword.get(opts, :repair_fun, &run_codex_repair/5)

    Enum.reduce_while(1..max_attempts, {:error, []}, fn attempt, {_status, history} ->
      prompt =
        build_repair_prompt(
          reason,
          Map.put(evidence, "validation_history", history),
          attempt,
          max_attempts
        )

      case repair_fun.(config, worktree_path, prompt, attempt, opts) do
        {:ok, _text} ->
          validation = validate(worktree_path, config.self_healing.validation_commands, opts)

          history =
            history ++ [%{"attempt" => attempt, "validation" => encode_results(validation)}]

          if validation_success?(validation) do
            {:halt, {:ok, attempt, validation}}
          else
            {:cont, {:error, history}}
          end

        {:error, reason} ->
          {:halt, {:error, "repair agent failed: #{reason}"}}
      end
    end)
    |> case do
      {:ok, attempts, validation} ->
        {:ok, attempts, validation}

      {:error, history} ->
        {:error, "validation failed after #{max_attempts} attempt(s): #{Jason.encode!(history)}"}
    end
  end

  defp run_codex_repair(config, worktree_path, prompt, _attempt, _opts) do
    session = CodexClient.start_session(config.self_healing.repair_codex, worktree_path)

    try do
      {result, _session} = CodexClient.run_turn(session, prompt, capture_agent_text: true)
      {:ok, result.agent_message_text}
    after
      CodexClient.stop_session(session)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp validate(worktree_path, commands, opts) do
    Enum.map(commands, &run_shell(&1, worktree_path, opts))
  end

  defp worktree_has_changes?(worktree_path, opts) do
    result = run_shell("git status --porcelain", worktree_path, opts)
    result.status == 0 and String.trim(result.output || "") != ""
  end

  defp commit_repair(worktree_path, reason, opts) do
    message = "Self-heal Symphony: #{Utils.truncate(reason, 72)}"

    with {:ok, _} <-
           run_commands(["git add -A", "git commit -m #{shell(message)}"], worktree_path, opts) do
      sha = command_output("git rev-parse HEAD", worktree_path, opts) |> String.trim()
      {:ok, sha}
    else
      {:error, result} -> {:error, "failed to commit repair: #{result.output}"}
    end
  end

  defp deploy_artifact(config, worktree_path) do
    source = Path.join(worktree_path, "symphony")
    dest = Path.join([config.self_healing.workspace_root, "deploy", "current", "symphony"])

    if File.exists?(source) do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
      File.chmod!(dest, 0o755)
      {:ok, dest}
    else
      {:error, "validated build did not produce #{source}"}
    end
  end

  defp restart_managed_status(config, artifact_path, opts) do
    case restart_managed(config, Keyword.put(opts, :artifact_path, artifact_path)) do
      {:ok, results} -> {:ok, encode_results(results)}
      {:error, results} -> {:error, encode_results(results)}
    end
  end

  defp sync_github(config, worktree_path, branch, reason, evidence_path, commit_sha, opts) do
    body_path = Path.join(Path.dirname(evidence_path), "pull-request.md")

    File.write!(body_path, pr_body(reason, evidence_path, commit_sha))

    push = run_shell("git push -u origin #{shell(branch)}", worktree_path, opts)

    if push.status != 0 do
      result = [
        pr_url: nil,
        auto_merge_status: {:error, "push failed: #{Utils.truncate(push.output, 1000)}"}
      ]

      write_github_sync_result(evidence_path, result)
      result
    else
      title = "Self-heal Symphony: #{Utils.truncate(reason, 80)}"

      create =
        run_shell(
          "gh pr create --base #{shell(config.self_healing.base_branch)} --head #{shell(branch)} --title #{shell(title)} --body-file #{shell(body_path)}",
          worktree_path,
          opts
        )

      pr_url = pr_url_from_output(create.output)

      auto_merge =
        if pr_url,
          do: run_shell("gh pr merge --auto --squash #{shell(pr_url)}", worktree_path, opts),
          else: %CommandResult{status: 1, output: "PR creation did not return a URL"}

      {_status, auto_merge_status} = classify_github_sync(create, auto_merge)

      result = [pr_url: pr_url, auto_merge_status: auto_merge_status]
      write_github_sync_result(evidence_path, result)
      result
    end
  end

  defp write_github_sync_result(evidence_path, result) do
    body =
      %{
        "pr_url" => result[:pr_url],
        "auto_merge_status" => normalize_status(result[:auto_merge_status])
      }
      |> Jason.encode!(pretty: true)

    File.write!(Path.join(Path.dirname(evidence_path), "github-sync.json"), body)
  end

  defp pr_body(reason, evidence_path, commit_sha) do
    """
    ## Self-Heal Summary
    Symphony detected a local failure and produced a validated generic repair.

    Trigger:
    #{reason}

    Local validated commit:
    #{commit_sha}

    Evidence artifact:
    #{evidence_path}

    Validation:
    - `mix format --check-formatted`
    - `mix test`
    - `mix escript.build`

    Notes:
    - Local Symphony is allowed to run ahead of `main`.
    - This PR is the sync/audit path back to `main`.
    - Auto-merge was requested without bypassing branch protection.
    """
  end

  defp run_commands(commands, cwd, opts) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, acc} ->
      result = run_shell(command, cwd, opts)
      if result.status == 0, do: {:cont, {:ok, acc ++ [result]}}, else: {:halt, {:error, result}}
    end)
  end

  defp run_restart_commands(commands, cwd, opts) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, acc} ->
      result = run_shell(command, cwd, opts)
      results = acc ++ [result]

      if result.status == 0,
        do: {:cont, {:ok, results}},
        else: {:halt, {:error, results}}
    end)
  end

  defp wait_for_port_release_command(port) do
    "deadline=$((SECONDS + #{@restart_port_release_timeout_seconds})); " <>
      "while pids=$(lsof -tiTCP:#{port} -sTCP:LISTEN 2>/dev/null) && [ -n \"$pids\" ]; do " <>
      "if [ \"$SECONDS\" -ge \"$deadline\" ]; then " <>
      "printf '%s\\n' \"timed out waiting for TCP port #{port} to be released by pids: $pids\" >&2; " <>
      "exit 75; " <>
      "fi; " <>
      "sleep #{@restart_port_probe_interval_seconds}; " <>
      "done"
  end

  defp run_shell(command, cwd, opts) do
    runner = Keyword.get(opts, :runner, &default_runner/3)
    runner.(command, cwd, Keyword.get(opts, :env, []))
  end

  defp default_runner(command, cwd, env) do
    {output, status} =
      System.cmd("bash", ["-lc", command],
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    %CommandResult{command: command, cwd: cwd, output: output, status: status}
  rescue
    error ->
      %CommandResult{command: command, cwd: cwd, output: Exception.message(error), status: 1}
  end

  defp command_output(command, cwd, opts) do
    result = run_shell(command, cwd, opts)
    Utils.truncate(result.output || "", 20_000)
  end

  defp fetch_state(port) do
    url = String.to_charlist("http://127.0.0.1:#{port}/api/v1/state")

    with {:ok, {{_, 200, _}, _headers, body}} <-
           :httpc.request(:get, {url, []}, [{:timeout, 5_000}], body_format: :binary),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      error -> %{"error" => inspect(error)}
    end
  end

  defp with_lock(%SelfHealingConfig{} = config, fun) do
    lock_path = Path.join(config.workspace_root, "self-heal.lock")
    File.mkdir_p!(Path.dirname(lock_path))

    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.write(io, "#{System.os_time(:second)}\n")
          File.close(io)
          fun.()
        after
          File.rm(lock_path)
        end

      {:error, :eexist} ->
        %RunResult{status: :skipped, error: "another self-heal run is active"}

      {:error, reason} ->
        %RunResult{status: :error, error: "failed to create self-heal lock: #{inspect(reason)}"}
    end
  end

  defp cooldown_active?(%SelfHealingConfig{} = config) do
    path = cooldown_path(config)

    with {:ok, body} <- File.read(path),
         {timestamp, ""} <- Integer.parse(String.trim(body)) do
      System.os_time(:millisecond) - timestamp < config.cooldown_ms
    else
      _ -> false
    end
  end

  defp write_cooldown(%SelfHealingConfig{} = config) do
    File.mkdir_p!(config.workspace_root)
    File.write!(cooldown_path(config), Integer.to_string(System.os_time(:millisecond)))
  end

  defp cooldown_path(config), do: Path.join(config.workspace_root, "last-success-ms")

  defp ensure_root!(%SelfHealingConfig{} = config), do: File.mkdir_p!(config.workspace_root)

  defp repo_root(%ServiceConfig{} = config),
    do: config.workflow_path |> Path.dirname() |> Path.expand()

  defp executable_artifact?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp encode_results(results) do
    Enum.map(results, fn result ->
      %{
        "command" => result.command,
        "status" => result.status,
        "output" => Utils.truncate(result.output || "", 10_000)
      }
    end)
  end

  defp normalize_status(nil), do: nil

  defp normalize_status({status, message}),
    do: %{"status" => to_string(status), "message" => message}

  defp normalize_status(value), do: value

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+/pull/\d+", output || "") do
      [url] -> url
      _ -> nil
    end
  end

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> then(fn text -> if text == "", do: "manual", else: text end)
  end

  defp shell(value),
    do: value |> to_string() |> String.replace("'", "'\"'\"'") |> then(&"'#{&1}'")
end
