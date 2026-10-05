defmodule LemieuxTest.Shell do
  @moduledoc false

  @doc """
  `value` as a single word for a POSIX shell, whatever it contains.

  For tests that build a command line around a path. The paths are under the
  checkout, so they contain whatever the checkout's own path does: a clone in
  `My Projects/lemieux` split an unquoted path in two, and the hook and timeout
  tests that interpolated one failed there and nowhere else (2026-10-02).
  Single quotes keep everything literal except a single quote, which closes
  the string, is escaped, and opens it again.
  """
  @spec quoted(value :: String.t()) :: String.t()
  def quoted(value) when is_binary(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
