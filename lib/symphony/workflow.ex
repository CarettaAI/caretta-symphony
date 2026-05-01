defmodule Symphony.Workflow do
  @moduledoc false

  alias Symphony.Error
  alias Symphony.Models.WorkflowDefinition

  def default_workflow_path(cwd \\ File.cwd!()) do
    Path.join(cwd, "WORKFLOW.md")
  end

  def resolve_workflow_path(path, cwd \\ File.cwd!())
  def resolve_workflow_path(nil, cwd), do: cwd |> default_workflow_path() |> Path.expand()
  def resolve_workflow_path(path, _cwd), do: path |> to_string() |> Path.expand()

  def load_workflow(path \\ nil, cwd \\ File.cwd!()) do
    workflow_path = resolve_workflow_path(path, cwd)

    raw =
      case File.read(workflow_path) do
        {:ok, body} ->
          body

        {:error, reason} ->
          raise Error,
            code: :missing_workflow_file,
            message: "workflow file cannot be read: #{workflow_path}",
            cause: reason
      end

    {config, body} = parse_workflow(raw)

    %WorkflowDefinition{
      config: config,
      prompt_template: String.trim(body),
      path: workflow_path,
      mtime_ns: mtime(workflow_path)
    }
  end

  defp parse_workflow("---" <> _ = raw) do
    lines = String.split(raw, ~r/\R/, trim: false)

    closing_index =
      lines
      |> Enum.drop(1)
      |> Enum.find_index(&(String.trim(&1) == "---"))

    if is_nil(closing_index) do
      raise Error,
        code: :workflow_parse_error,
        message: "YAML front matter is missing closing ---"
    end

    closing_index = closing_index + 1
    front_matter = lines |> Enum.slice(1, closing_index - 1) |> Enum.join("\n")
    body = lines |> Enum.slice((closing_index + 1)..-1//1) |> Enum.join("\n")

    parsed =
      if String.trim(front_matter) == "" do
        %{}
      else
        case YamlElixir.read_from_string(front_matter) do
          {:ok, value} ->
            value

          {:error, reason} ->
            raise Error,
              code: :workflow_parse_error,
              message: "invalid YAML front matter: #{inspect(reason)}"

          value ->
            value
        end
      end

    cond do
      is_nil(parsed) ->
        {%{}, body}

      is_map(parsed) ->
        {parsed, body}

      true ->
        raise Error,
          code: :workflow_front_matter_not_a_map,
          message: "YAML front matter must decode to a map/object"
    end
  end

  defp parse_workflow(raw), do: {%{}, raw}

  def mtime(path) do
    case File.stat(path, time: :nanosecond) do
      {:ok, stat} -> stat.mtime
      _ -> nil
    end
  end
end
