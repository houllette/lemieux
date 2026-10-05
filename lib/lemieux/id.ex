defmodule Lemieux.ID do
  @moduledoc """
  Identifiers for sessions and transcript entries.

  These are [ULIDs](https://github.com/ulid/spec): 48 bits of millisecond
  timestamp followed by 80 random bits, rendered as 26 characters of Crockford
  base32.

  A random UUID would have been less code, and it is the wrong shape for what
  these ids are used for. Session ids are filenames and CLI arguments — a user
  runs `ls ~/.lmx/sessions` and `lmx log <id>`. Sorting that listing by name
  has to be sorting it by age, and a v4 UUID makes that listing arbitrary.
  Entry ids inherit the same property, so a transcript read off disk is in
  causal order even before `parent_id` is consulted.

  Crockford base32 rather than hex or base64: no hyphens to quote, no case to
  get wrong, and the ambiguous characters (`I`, `L`, `O`, `U`) are absent, so
  an id read off a terminal and typed back in survives the trip.

  What all of that buys is an id that sorts, is safe as a filename, and
  survives being retyped — not one anybody remembers. `Lemieux.ID.Shorthand`
  covers the remembering, by deriving a name from the id rather than by
  changing what an id is.

  This module deliberately does not depend on `req_llm`'s id generator. Ids
  here are a storage concern that outlives any provider, and borrowing one
  from the provider library would put the on-disk format at the mercy of a
  dependency that has no idea it is being used this way.
  """

  # Crockford base32: the digits, then the alphabet minus I, L, O and U.
  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc """
  Generates an id stamped with the current time.
  """
  @spec generate() :: String.t()
  def generate, do: generate(System.system_time(:millisecond))

  @doc """
  Generates an id stamped with `timestamp` (milliseconds since the epoch).

  Taking the clock as an argument is what lets a test assert on ordering
  without sleeping.
  """
  @spec generate(timestamp :: integer()) :: String.t()
  def generate(timestamp) when is_integer(timestamp) and timestamp >= 0 do
    <<value::128>> = <<timestamp::48, :crypto.strong_rand_bytes(10)::binary>>

    encode(value, 0, [])
  end

  @doc """
  Returns the millisecond timestamp encoded in `id`, or `:error`.
  """
  @spec timestamp(id :: String.t()) :: integer() | :error
  def timestamp(id) when is_binary(id) and byte_size(id) == 26 do
    case decode(id, 0) do
      {:ok, value} -> Bitwise.bsr(value, 80)
      :error -> :error
    end
  end

  def timestamp(id) when is_binary(id), do: :error

  # Least significant digit first, prepending, so the most significant digit
  # ends up leftmost — which is what makes the string sort like the number.
  defp encode(_value, 26, digits), do: List.to_string(digits)

  defp encode(value, position, digits) do
    index = value |> Bitwise.bsr(position * 5) |> Bitwise.band(31)

    encode(value, position + 1, [binary_part(@alphabet, index, 1) | digits])
  end

  defp decode(<<>>, value), do: {:ok, value}

  defp decode(<<char, rest::binary>>, value) do
    case :binary.match(@alphabet, <<char>>) do
      {index, 1} -> decode(rest, Bitwise.bsl(value, 5) + index)
      :nomatch -> :error
    end
  end
end
