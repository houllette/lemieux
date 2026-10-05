defmodule Lemieux.Conversation.Columns do
  @moduledoc """
  Two-column help rows: a name, then what it does.

  The name column is as wide as its widest entry up to a cap, with a gutter
  of two spaces after it. A name longer than the cap keeps its own line and
  puts its words on the next one, indented under the column, so the rows
  below it stay aligned.

  A fixed pad was the obvious alternative and the one this replaced: every
  help section padded to a constant (10 for commands, 18 for skills and
  keys), which does nothing to a name already that long. `/permissions` ran
  into its description, and a remapped key list read as
  "back_tab, shift-back_tabcycle mode".
  """

  @gutter 2
  @default_max 24

  @typedoc "A name and the words that describe it."
  @type row :: {name :: String.t(), words :: String.t()}

  @doc """
  Formats `rows` as aligned lines.

  `:max` caps the name column (default #{@default_max}); a name longer than
  the cap is put on a line of its own, with its words on the next line under
  the column.

      iex> Lemieux.Conversation.Columns.format([{"/new", "new session"}, {"/permissions", "modes"}])
      ["/new          new session", "/permissions  modes"]
  """
  @spec format(rows :: [row()], opts :: keyword()) :: [String.t()]
  def format(rows, opts \\ []) when is_list(rows) and is_list(opts) do
    max = Keyword.get(opts, :max, @default_max)

    width =
      rows
      |> Enum.map(fn {name, _words} -> String.length(name) end)
      |> Enum.filter(&(&1 <= max))
      |> Enum.max(fn -> 0 end)

    Enum.map(rows, &line(&1, width))
  end

  defp line({name, words}, width) do
    if String.length(name) <= width do
      String.pad_trailing(name, width + @gutter) <> words
    else
      name <> "\n" <> String.duplicate(" ", width + @gutter) <> words
    end
  end
end
