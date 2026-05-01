defmodule Symphony.Error do
  @moduledoc "Stable machine-readable Symphony exception."

  defexception [:code, :message, :cause]

  @impl true
  def exception(opts) do
    code = Keyword.fetch!(opts, :code)
    message = Keyword.get(opts, :message, to_string(code))
    cause = Keyword.get(opts, :cause)
    %__MODULE__{code: code, message: message, cause: cause}
  end

  @impl true
  def message(%__MODULE__{code: code, message: message}) do
    "#{code}: #{message}"
  end
end
