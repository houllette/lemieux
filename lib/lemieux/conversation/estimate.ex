defmodule Lemieux.Conversation.Estimate do
  @moduledoc """
  Adds illustrative USD decimal strings without converting them to floats.

  A receipt may carry more fractional digits than the status line normally
  shows for measured usage. Rounding every receipt before summing would make
  the displayed comparison depend on how many requests produced it.
  """

  @type t :: {non_neg_integer(), non_neg_integer()}

  @doc "Parses a non-negative decimal-string amount."
  @spec parse(amount :: String.t()) :: {:ok, t()} | :error
  def parse(amount) when is_binary(amount) and byte_size(amount) <= 64 do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/, amount) do
      case String.split(amount, ".", parts: 2) do
        [whole] ->
          {:ok, {String.to_integer(whole), 0}}

        [whole, fraction] ->
          {:ok, {String.to_integer(whole <> fraction), byte_size(fraction)}}
      end
    else
      :error
    end
  end

  def parse(_amount), do: :error

  @doc "Adds two parsed amounts at their greatest precision."
  @spec add(left :: t(), right :: t()) :: t()
  def add({left, left_scale}, {right, right_scale}) do
    scale = max(left_scale, right_scale)

    {left * Integer.pow(10, scale - left_scale) + right * Integer.pow(10, scale - right_scale),
     scale}
  end

  @doc "Displays an amount without dropping meaningful fractional digits."
  @spec format(amount :: t()) :: String.t()
  def format({amount, 0}), do: Integer.to_string(amount)

  def format({amount, scale}) do
    digits = amount |> Integer.to_string() |> String.pad_leading(scale + 1, "0")
    {whole, fraction} = String.split_at(digits, byte_size(digits) - scale)
    fraction = String.trim_trailing(fraction, "0")
    if fraction == "", do: whole, else: whole <> "." <> fraction
  end
end
