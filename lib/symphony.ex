defmodule Symphony do
  @moduledoc """
  Caretta Symphony orchestrates Codex app-server workers from Linear issues.

  This Elixir implementation keeps the same service boundaries as the previous
  implementation: workflow/config parsing, Linear adapters, workspace
  preparation, Codex JSONL sessions, review reconciliation, and a small status
  server.
  """

  @version "0.1.0"

  def version, do: @version
end
