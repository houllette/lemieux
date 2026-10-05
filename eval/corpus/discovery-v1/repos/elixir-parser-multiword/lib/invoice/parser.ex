defmodule Invoice.Parser do
  @moduledoc """
  Parses the plain-text order lines that the sales team pastes into tickets.

  A line looks like `3 x widget @ 250`: a quantity, the literal `x`, the item
  name, the literal `@`, and the unit price in cents. Item names may contain
  spaces (`2 x blue widget @ 250`) but never `@`.
  """

  @type line :: %{quantity: pos_integer(), name: String.t(), unit_cents: non_neg_integer()}

  @doc "Parses one order line."
  @spec parse_line(String.t()) :: {:ok, line()} | {:error, :invalid_line}
  def parse_line(line) when is_binary(line) do
    case String.split(String.trim(line), " ") do
      [quantity, "x", name, "@", price] ->
        with {quantity, ""} <- Integer.parse(quantity),
             {price, ""} <- Integer.parse(price) do
          {:ok, %{quantity: quantity, name: name, unit_cents: price}}
        else
          _invalid -> {:error, :invalid_line}
        end

      _other ->
        {:error, :invalid_line}
    end
  end

  @doc "Parses every non-blank line, stopping at the first invalid one."
  @spec parse(String.t()) :: {:ok, [line()]} | {:error, {:invalid_line, pos_integer()}}
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, :invalid_line} -> {:halt, {:error, {:invalid_line, number}}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end
end
