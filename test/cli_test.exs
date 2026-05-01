defmodule Symphony.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "run returns non-zero for startup errors" do
    output =
      capture_io(:stderr, fn ->
        assert Symphony.CLI.run(["/definitely/missing/WORKFLOW.md", "--once"]) == 1
      end)

    assert output =~ "missing_workflow_file"
  end
end
