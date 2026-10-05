defmodule Lemieux.JSON do
  @moduledoc """
  Prose for `JSON.decode/1` failures.

  `JSON.decode/1` reports failure as a bare term — `{:invalid_byte, 12, 104}` —
  and the sentence for it exists only inside `JSON.decode!/1`, which raises it
  as a `JSON.DecodeError`. Several readers wanted to keep their error tuple and
  still say something readable, and matched `{:error, %JSON.DecodeError{}}` on
  the non-raising path; that pattern can never match (the struct never travels
  through `decode/1`), so each of them silently passed the raw term upward
  instead. Dialyzer found them. This module is the one place that wording
  lives now.

  Do not `alias` this module bare at a call site: `alias Lemieux.JSON` shadows
  the standard-library `JSON` the same file is decoding with.
  """

  @doc "The sentence `JSON.decode!/1` would raise for a `JSON.decode/1` error reason."
  @spec describe_error(reason :: term()) :: String.t()
  def describe_error({:unexpected_end, offset}) when is_integer(offset),
    do: "unexpected end of JSON binary at position (byte offset) #{offset}"

  def describe_error({:invalid_byte, offset, byte}) when is_integer(offset),
    do: "invalid byte #{byte} at position (byte offset) #{offset}"

  def describe_error({:unexpected_sequence, offset, bytes}) when is_integer(offset),
    do: "unexpected sequence #{inspect(bytes)} at position (byte offset) #{offset}"

  def describe_error(reason), do: inspect(reason)
end
