defmodule Lemieux.Usage do
  @moduledoc """
  The stable, JSON-shaped usage contract emitted by a session.

  Providers do not agree on names for cache tokens or cost, and `req_llm` may
  add provider-specific fields over time. Lemieux preserves those fields while
  guaranteeing these string-keyed ones:

    * `"input_tokens"` and `"output_tokens"` — non-negative token counts.
    * `"cache_read_tokens"` and `"cache_write_tokens"` — non-negative token
      counts, zero when the provider reported none.
    * `"cost_usd"` — the request cost as a number, or `nil` when pricing is
      unavailable. Unknown cost is never represented as zero.
    * `"model"` — the model specification used for the request.

  The full map remains attached to the assistant entry and is also emitted as
  `{:usage, usage}`. Hosts can depend on the keys above without depending on a
  provider library's response shape.
  """

  @type t :: %{required(String.t()) => term()}

  @doc "Returns a zero-valued aggregate suitable for folding request usage."
  @spec empty() :: t()
  def empty do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cache_read_tokens" => 0,
      "cache_write_tokens" => 0,
      "cost_usd" => 0.0
    }
  end

  @doc "Adds two usage values. Any unmeasured request makes aggregate cost unmeasured."
  @spec add(left :: map(), right :: map()) :: t()
  def add(left, right) when is_map(left) and is_map(right) do
    empty()
    |> Map.put("input_tokens", input_count(left) + input_count(right))
    |> add_count(left, right, "output_tokens")
    |> add_count(left, right, "cache_read_tokens")
    |> add_count(left, right, "cache_write_tokens")
    |> Map.put("cost_usd", add_cost(cost_usd(left), cost_usd(right)))
  end

  @doc "Sums request usage values into one aggregate."
  @spec sum(usages :: Enumerable.t()) :: t()
  def sum(usages), do: Enum.reduce(usages, empty(), &add(&2, &1))

  @doc "Normalises a provider usage map into Lemieux's public contract."
  @spec normalize(usage :: map(), model :: String.t()) :: t()
  def normalize(usage, model) when is_map(usage) and is_binary(model) do
    usage = json(usage)

    usage
    |> Map.put("input_tokens", count(usage, ["input_tokens"]))
    |> Map.put("output_tokens", count(usage, ["output_tokens"]))
    |> Map.put(
      "cache_read_tokens",
      count(usage, ["cache_read_tokens", "cached_tokens", "cache_read_input_tokens"])
    )
    |> Map.put(
      "cache_write_tokens",
      count(usage, ["cache_write_tokens", "cache_creation_tokens"])
    )
    |> Map.put("cost_usd", cost(usage))
    |> Map.put("model", model)
  end

  @doc "Returns the measured USD cost, or `nil` when it was not measured."
  @spec cost_usd(usage :: map()) :: number() | nil
  def cost_usd(usage) when is_map(usage) do
    usage = json(usage)

    case cost(usage) do
      value when is_number(value) -> value
      _unknown -> nil
    end
  end

  defp add_count(total, left, right, key) do
    Map.put(total, key, nonnegative(left, key) + nonnegative(right, key))
  end

  defp input_count(usage) do
    input = nonnegative(usage, "input_tokens")

    if Map.get(usage, "input_includes_cached") in [true, "true"] or
         Map.get(usage, :input_includes_cached) == true do
      max(
        input - nonnegative(usage, "cache_read_tokens") -
          nonnegative(usage, "cache_write_tokens"),
        0
      )
    else
      input
    end
  end

  defp nonnegative(usage, key) do
    case Map.get(usage, key) || Map.get(usage, count_atom(key)) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _unknown -> 0
    end
  end

  defp count_atom("input_tokens"), do: :input_tokens
  defp count_atom("output_tokens"), do: :output_tokens
  defp count_atom("cache_read_tokens"), do: :cache_read_tokens
  defp count_atom("cache_write_tokens"), do: :cache_write_tokens

  defp add_cost(left, right) when is_number(left) and is_number(right), do: left + right
  defp add_cost(_left, _right), do: nil

  defp count(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp cost(usage) do
    direct = Map.get(usage, "cost_usd") || Map.get(usage, "total_cost")
    nested = get_in(usage, ["cost", "total"])

    case direct || nested do
      value when is_number(value) -> value
      _unknown -> nil
    end
  end

  defp json(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&json/1)
  defp json(value) when is_boolean(value) or is_nil(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value), do: value
end
