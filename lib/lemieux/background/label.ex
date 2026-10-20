defmodule Lemieux.Background.Label do
  @moduledoc false
  alias Lemieux.ID.Shorthand

  @spec candidate(id :: String.t(), attempt :: non_neg_integer()) :: String.t()
  def candidate(id, 0), do: Shorthand.of(id)
  def candidate(id, attempt), do: Shorthand.of("#{id}:#{attempt}")

  @spec summary(value :: term()) :: String.t()
  def summary(value) when is_binary(value) do
    value =
      value
      |> String.replace(~r/[\s\x00-\x1f\x7f]+/u, " ")
      |> String.trim()
      |> String.slice(0, 160)

    if value == "", do: "Background command", else: value
  end

  def summary(_value), do: "Background command"
end
