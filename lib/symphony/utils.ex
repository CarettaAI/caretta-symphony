defmodule Symphony.Utils do
  @moduledoc false

  @workspace_key_re ~r/[^A-Za-z0-9._-]/
  @secret_field_re ~r/(api[_-]?key|token|secret|authorization)/i

  @jsonl_read_limit_bytes 10 * 1024 * 1024 + 1
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  def jsonl_read_limit_bytes, do: @jsonl_read_limit_bytes
  def non_interactive_tool_input_answer, do: @non_interactive_tool_input_answer
  def non_interactive_mcp_elicitation_response, do: %{"action" => "decline"}

  def now_utc do
    DateTime.utc_now()
  end

  def isoformat_z(nil), do: nil

  def isoformat_z(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def isoformat_z(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> isoformat_z()
  end

  def parse_datetime(nil), do: nil
  def parse_datetime(""), do: nil
  def parse_datetime(%DateTime{} = value), do: value

  def parse_datetime(value) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" ->
        nil

      true ->
        case DateTime.from_iso8601(text) do
          {:ok, datetime, _offset} -> datetime
          _ -> parse_naive_datetime(text)
        end
    end
  end

  def parse_datetime(_), do: nil

  defp parse_naive_datetime(text) do
    case NaiveDateTime.from_iso8601(String.trim_trailing(text, "Z")) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  def normalize_state(value) do
    value
    |> to_string_or_empty()
    |> String.trim()
    |> String.downcase()
  end

  def sanitize_workspace_key(identifier) do
    sanitized =
      identifier
      |> to_string_or_empty()
      |> String.replace(@workspace_key_re, "_")

    if sanitized == "", do: "_", else: sanitized
  end

  def resolve_under_root(root, child_name) do
    root_abs = Path.expand(root)
    child = Path.expand(Path.join(root_abs, child_name))
    root_parts = Path.split(root_abs)
    child_parts = Path.split(child)

    if Enum.take(child_parts, length(root_parts)) != root_parts do
      raise ArgumentError, "path escapes workspace root: #{child}"
    end

    child
  end

  def truncate(value, limit \\ 4000)
  def truncate(nil, _limit), do: ""

  def truncate(value, limit) do
    text = to_string(value)

    if String.length(text) <= limit,
      do: text,
      else: String.slice(text, 0, limit) <> "...<truncated>"
  end

  def redact_field(key, value) do
    if Regex.match?(@secret_field_re, to_string(key)), do: "<redacted>", else: value
  end

  def key_value_message(event, fields \\ []) do
    field_parts =
      Enum.map(fields, fn {key, value} ->
        safe = redact_field(key, value)
        text = format_field_value(safe)
        "#{key}=#{text}"
      end)

    Enum.join(["event=#{event}" | field_parts], " ")
  end

  defp format_field_value(nil), do: "null"
  defp format_field_value(%DateTime{} = value), do: isoformat_z(value)

  defp format_field_value(value) do
    text = value |> to_string() |> String.replace("\n", "\\n")
    if String.contains?(text, " "), do: inspect(text), else: text
  end

  def tool_request_user_input_approval_answers(params) when is_map(params) do
    with questions when is_list(questions) <-
           Map.get(params, "questions") || Map.get(params, :questions) do
      answers =
        Enum.reduce_while(questions, %{}, fn question, acc ->
          question_id = map_get(question, "id")
          answer_label = approval_option_label(map_get(question, "options"))

          cond do
            not is_binary(question_id) or question_id == "" -> {:halt, nil}
            is_nil(answer_label) -> {:halt, nil}
            true -> {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}
          end
        end)

      if map_size(answers || %{}) == 0, do: nil, else: answers
    else
      _ -> nil
    end
  end

  def tool_request_user_input_approval_answers(_), do: nil

  def tool_request_user_input_unavailable_answers(params) when is_map(params) do
    with questions when is_list(questions) <-
           Map.get(params, "questions") || Map.get(params, :questions) do
      answers =
        Enum.reduce_while(questions, %{}, fn question, acc ->
          question_id = map_get(question, "id")

          if is_binary(question_id) and question_id != "" do
            {:cont,
             Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}
          else
            {:halt, nil}
          end
        end)

      if map_size(answers || %{}) == 0, do: nil, else: answers
    else
      _ -> nil
    end
  end

  def tool_request_user_input_unavailable_answers(_), do: nil

  defp approval_option_label(options) when is_list(options) do
    labels =
      options
      |> Enum.map(&map_get(&1, "label"))
      |> Enum.filter(&is_binary/1)

    Enum.find(["Approve this Session", "Approve Once"], &(&1 in labels)) ||
      Enum.find(labels, fn label ->
        normalized = label |> String.trim() |> String.downcase()
        String.starts_with?(normalized, "approve") or String.starts_with?(normalized, "allow")
      end)
  end

  defp approval_option_label(_), do: nil

  def map_get(map, key, default \\ nil)

  def map_get(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_binary(key) ->
        case existing_atom(key) do
          nil -> default
          atom -> Map.get(map, atom, default)
        end

      true ->
        default
    end
  end

  def map_get(_, _, default), do: default

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  def to_string_or_empty(nil), do: ""
  def to_string_or_empty(value), do: to_string(value)

  def to_int(value)
  def to_int(value) when is_boolean(value) or is_nil(value), do: nil
  def to_int(value) when is_integer(value), do: value

  def to_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def to_float(value)
  def to_float(value) when is_boolean(value) or is_nil(value), do: nil
  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value / 1

  def to_float(value) do
    case Float.parse(to_string(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end
end
