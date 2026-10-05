defmodule Lemieux.Extensions.Workspace.Frontmatter do
  @moduledoc """
  Reads the `---` block at the top of a `SKILL.md` or an agent definition.

  YAML first. Files written for Claude Code are often not valid YAML,
  though: `/agents` writes the whole description on one line, colons,
  examples and literal `\\n` sequences included, and Claude Code reads it.
  A strict parser refused exactly the files a person moving from Claude Code
  has. `~/.claude/agents/elixir-expert.md` failed on the `including:` in its
  description, and the screen showed the parser's error struct.

  So a block that is not valid YAML is read the way Claude Code reads it:
  - One `key: value` per top-level line, the value being the rest of the
    line, surrounding quotes removed, `\\n` sequences turned into line
    breaks, and `true`/`false` into booleans.
  - An indented line continues the value above it.
  - `- item` lines under a key with no value make a list.

  Only when that reading finds no key either is the block refused, with the
  YAML parser's line and column in a sentence rather than its struct.
  """

  @key ~r/\A([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]+(.*)|[ \t]*)\z/
  @item ~r/\A[ \t]*-[ \t]+(.*)\z/

  @typedoc "Why a block could not be read."
  @type error :: :not_an_object | {:invalid, detail :: String.t()}

  @doc """
  The block's attributes, read as YAML or, failing that, as Claude Code
  reads it.
  """
  @spec parse(frontmatter :: String.t()) :: {:ok, map()} | {:error, error()}
  def parse(frontmatter) when is_binary(frontmatter) do
    case YamlElixir.read_from_string(frontmatter) do
      {:ok, attributes} when is_map(attributes) -> {:ok, attributes}
      {:ok, _not_a_map} -> {:error, :not_an_object}
      {:error, reason} -> lenient(frontmatter, reason)
    end
  end

  defp lenient(frontmatter, reason) do
    case frontmatter |> String.split(~r/\r?\n/) |> Enum.reduce([], &line/2) do
      [] ->
        {:error, {:invalid, describe(reason)}}

      pairs ->
        {:ok, pairs |> Enum.reverse() |> Map.new(fn {key, value} -> {key, value(value)} end)}
    end
  end

  # Pairs are kept newest first; a line either starts a key, adds an item to
  # the newest key's list, or continues its text.
  defp line(line, pairs) do
    cond do
      String.trim(line) == "" or String.starts_with?(String.trim_leading(line), "#") ->
        pairs

      match = Regex.run(@key, line, capture: :all_but_first) ->
        [{key(match), text(match)} | pairs]

      match = Regex.run(@item, line, capture: :all_but_first) ->
        item(pairs, hd(match))

      true ->
        continue(pairs, String.trim(line))
    end
  end

  defp key([key | _value]), do: key
  defp text([_key, value]), do: String.trim(value)
  defp text([_key]), do: ""

  # A list starts under a key whose line had no value.
  defp item([{key, ""} | pairs], item), do: [{key, [String.trim(item)]} | pairs]

  defp item([{key, items} | pairs], item) when is_list(items),
    do: [{key, items ++ [String.trim(item)]} | pairs]

  defp item(pairs, item), do: continue(pairs, "- " <> String.trim(item))

  defp continue([{key, ""} | pairs], text), do: [{key, text} | pairs]

  defp continue([{key, value} | pairs], text) when is_binary(value),
    do: [{key, value <> "\n" <> text} | pairs]

  defp continue(pairs, _text), do: pairs

  defp value(value) when is_list(value), do: value
  defp value("true"), do: true
  defp value("false"), do: false
  defp value(value), do: value |> unquoted() |> String.replace("\\n", "\n")

  defp unquoted(<<quote, rest::binary>> = value) when quote in [?", ?'] do
    if String.ends_with?(rest, <<quote>>) and rest != "",
      do: String.slice(rest, 0..-2//1),
      else: value
  end

  defp unquoted(value), do: value

  defp describe(%{line: line, column: column, message: message})
       when is_integer(line) and is_integer(column),
       do: "line #{line}, column #{column}: #{message}"

  defp describe(%{message: message}) when is_binary(message), do: message
end
