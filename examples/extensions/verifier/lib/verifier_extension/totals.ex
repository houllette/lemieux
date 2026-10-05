defmodule VerifierExtension.Totals do
  @moduledoc """
  Sums the per-session accounting maps into one composition-wide record.

  A multi-session agent owns cumulative usage, and a benchmark reads one
  `usage`, `resources` and `tool_metrics` map per attempt. The shapes are
  `Lemieux.Agent.Session`'s, so the rule is by value rather than by key:
  numbers add, nested maps recurse, lists union, and booleans such as
  `tokens_complete` hold only when every session's do.

  An unknown counter stays unknown. A session whose cost was `nil` makes the
  total `nil` rather than silently counting as free, because a cost-capped
  benchmark would otherwise reserve for one session and be billed for two.
  A key one session never reported is skipped rather than treated as `nil`,
  so a stage only the retry reached does not erase the task session's totals.
  """

  @doc "Adds JSON-shaped accounting maps together; `nil` in means `nil` out."
  @spec sum(maps :: [map()]) :: map()
  def sum(maps) when is_list(maps) do
    maps
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Map.new(fn key ->
      values = for map <- maps, {:ok, value} <- [Map.fetch(map, key)], do: value
      {key, combine(values)}
    end)
  end

  defp combine(values) do
    cond do
      Enum.all?(values, &is_map/1) -> sum(values)
      Enum.all?(values, &is_number/1) -> Enum.sum(values)
      Enum.all?(values, &is_list/1) -> values |> Enum.concat() |> Enum.uniq()
      Enum.all?(values, &is_boolean/1) -> Enum.all?(values)
      true -> nil
    end
  end
end
