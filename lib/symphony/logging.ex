defmodule Symphony.Logging do
  @moduledoc false

  require Logger

  alias Symphony.Utils

  def log_event(level, event, fields \\ []) do
    Logger.log(level, Utils.key_value_message(event, fields))
  end
end
