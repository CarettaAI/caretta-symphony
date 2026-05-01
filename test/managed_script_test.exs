defmodule Symphony.ManagedScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../scripts/symphony-managed.sh", __DIR__)

  @tag :tmp_dir
  test "managed launcher uses deployed self-heal artifact when root build artifact is absent", %{
    tmp_dir: tmp_dir
  } do
    script_path = install_script!(tmp_dir)
    File.write!(Path.join(tmp_dir, "WORKFLOW.md"), "body\n")

    deployed_artifact_path =
      Path.join([tmp_dir, ".symphony-self-heal", "deploy", "current", "symphony"])

    invocation_path = Path.join(tmp_dir, "invocation.txt")
    File.mkdir_p!(Path.dirname(deployed_artifact_path))

    File.write!(
      deployed_artifact_path,
      """
      #!/bin/sh
      {
        printf '%s\\n' "$0"
        printf '%s\\n' "$@"
      } > "$SYMPHONY_TEST_INVOCATION"
      """
    )

    File.chmod!(deployed_artifact_path, 0o755)

    assert {_, 0} =
             System.cmd("/bin/sh", [script_path, "watchdog"],
               cd: tmp_dir,
               env: [{"SYMPHONY_TEST_INVOCATION", invocation_path}],
               stderr_to_stdout: true
             )

    assert File.read!(invocation_path) ==
             Enum.join(
               [
                 deployed_artifact_path,
                 Path.join(tmp_dir, "WORKFLOW.md"),
                 "--watchdog"
               ],
               "\n"
             ) <> "\n"
  end

  @tag :tmp_dir
  test "managed launcher fails before invoking escript when no executable artifact exists", %{
    tmp_dir: tmp_dir
  } do
    script_path = install_script!(tmp_dir)
    File.write!(Path.join(tmp_dir, "WORKFLOW.md"), "body\n")

    assert {output, 70} =
             System.cmd("/bin/sh", [script_path, "run"],
               cd: tmp_dir,
               stderr_to_stdout: true
             )

    assert output =~ "no Symphony executable found"
    refute output =~ "Failed to open file"
  end

  defp install_script!(tmp_dir) do
    script_dir = Path.join(tmp_dir, "scripts")
    script_path = Path.join(script_dir, "symphony-managed.sh")
    File.mkdir_p!(script_dir)
    File.cp!(@script, script_path)
    File.chmod!(script_path, 0o755)
    script_path
  end
end
