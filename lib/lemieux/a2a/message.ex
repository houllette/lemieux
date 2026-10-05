defmodule Lemieux.A2A.Message do
  @moduledoc """
  A2A 1.0 messages, validated at the boundary. Convenience strings and partial
  messages are completed by [`new/1`](Lemieux.A2A.Message.html#new/1); incoming
  wire messages use [`validate/1`](Lemieux.A2A.Message.html#validate/1).
  Files and URLs are never fetched implicitly.
  """

  @doc """
  Completes a message from a string or a partial map.

  Keys may be atoms or strings, with `:task_id` and `:context_id` meaning
  `"taskId"` and `"contextId"`; a fresh `"messageId"` and the user role are
  added unless given. The result is not validated; `validate/1` does that.
  """
  @spec new(message :: String.t() | map()) :: map()
  def new(text) when is_binary(text), do: new(%{"parts" => [%{"text" => text}]})

  def new(message) when is_map(message) do
    message =
      Map.new(message, fn
        {:task_id, value} -> {"taskId", value}
        {:context_id, value} -> {"contextId", value}
        {key, value} -> {to_string(key), value}
      end)

    message = normalize_parts(message)

    message
    |> Map.put_new("messageId", Lemieux.ID.generate())
    |> Map.put_new("role", "ROLE_USER")
  end

  defp normalize_parts(%{"parts" => parts} = message) when is_list(parts),
    do: Map.put(message, "parts", Enum.map(parts, &normalize_part/1))

  defp normalize_parts(message), do: message

  defp normalize_part(part) when is_map(part),
    do: Map.new(part, fn {key, value} -> {to_string(key), value} end)

  defp normalize_part(part), do: part

  @doc "A message from the agent holding `text`."
  @spec agent(text :: String.t()) :: map()
  def agent(text), do: new(%{"role" => "ROLE_AGENT", "parts" => [%{"text" => text}]})

  @doc """
  Checks a message from the wire: a message id, a user or agent role, at least
  one well-formed part, and optional identifiers that are non-empty strings.
  """
  @spec validate(message :: term()) :: :ok | {:error, String.t()}
  def validate(%{"messageId" => id, "role" => role, "parts" => parts} = message)
      when is_binary(id) and byte_size(id) > 0 and role in ["ROLE_USER", "ROLE_AGENT"] and
             is_list(parts) and parts != [] do
    if Enum.all?(parts, &part?/1) and optional?(message, "taskId", &string?/1) and
         optional?(message, "contextId", &string?/1) and optional?(message, "metadata", &is_map/1),
       do: :ok,
       else: {:error, "invalid message parts or identifiers"}
  end

  def validate(_message), do: {:error, "message requires messageId, role and nonempty parts"}

  @doc """
  The message's text parts joined by newlines and trimmed; other parts add
  nothing.
  """
  @spec text(message :: map()) :: String.t()
  def text(%{"parts" => parts}),
    do: Enum.map_join(parts, "\n", fn part -> Map.get(part, "text", "") end) |> String.trim()

  @doc "Whether every part of the message is text."
  @spec text_only?(message :: map()) :: boolean()
  def text_only?(%{"parts" => parts}), do: Enum.all?(parts, &is_binary(Map.get(&1, "text")))

  @doc "Whether `part` is exactly one of text, raw, url or data, with optional metadata."
  @spec part?(part :: term()) :: boolean()
  def part?(part) when is_map(part) do
    keys = Enum.filter(["text", "raw", "url", "data"], &Map.has_key?(part, &1))

    case keys do
      ["data"] -> optional?(part, "metadata", &is_map/1)
      [key] -> is_binary(part[key]) and optional?(part, "metadata", &is_map/1)
      _ -> false
    end
  end

  def part?(_part), do: false

  @doc "Whether `key` is absent from `map` or its value satisfies `predicate`."
  @spec optional?(map :: map(), key :: String.t(), predicate :: (term() -> boolean())) ::
          boolean()
  def optional?(map, key, predicate), do: not Map.has_key?(map, key) or predicate.(map[key])
  @doc "Checks optional fields using named predicates; absent fields retain protocol defaults."
  @spec fields?(map :: map(), fields :: [{String.t(), (term() -> boolean())}]) :: boolean()
  def fields?(map, fields),
    do: Enum.all?(fields, fn {key, predicate} -> optional?(map, key, predicate) end)

  @doc "Validates a list of strings."
  @spec strings?(value :: term()) :: boolean()
  def strings?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  def strings?(_value), do: false

  @doc "Validates an ISO 8601 timestamp."
  @spec timestamp?(value :: term()) :: boolean()
  def timestamp?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  def timestamp?(_value), do: false

  defp string?(value), do: is_binary(value) and byte_size(value) > 0
end
