defmodule Lemieux.JSON do
  @moduledoc """
  JSON display encoding and prose for `JSON.decode/1` failures.

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

  @doc """
  Encodes a JSON value with collection members on separate lines.

  Model-facing files must be pageable with the read tool: compact objects can
  lose every field after its per-line display cap. This is a display encoding,
  not the canonical bytes used by integrity contracts. Individual long strings
  still need bounded excerpts or a separate readable projection from the host.
  """
  @spec encode_readable!(value :: term()) :: String.t()
  def encode_readable!(value) do
    value
    |> JSON.encode!()
    |> JSON.decode!()
    |> readable(0)
    |> IO.iodata_to_binary()
  end

  defp readable(map, depth) when is_map(map) and map_size(map) > 0 do
    members =
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ": ", readable(value, depth + 1)] end)

    collection("{", "}", members, depth)
  end

  defp readable([_ | _] = list, depth),
    do: collection("[", "]", Enum.map(list, &readable(&1, depth + 1)), depth)

  defp readable(value, _depth), do: JSON.encode!(value)

  defp collection(open, close, members, depth) do
    indent = String.duplicate("  ", depth)
    [open, "\n", Enum.map_intersperse(members, ",\n", &[indent, "  ", &1]), "\n", indent, close]
  end

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
