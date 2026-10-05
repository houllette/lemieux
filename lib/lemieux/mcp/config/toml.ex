defmodule Lemieux.MCP.Config.TOML do
  @moduledoc """
  Enough TOML to read another client's MCP servers, and no more.

  Codex keeps its servers in `~/.codex/config.toml` as `[mcp_servers.NAME]`
  tables. Importing them is worth doing — somebody switching tools should not
  retype a working setup — and a TOML dependency is not: the project adds none
  for small problems, and the core in particular stays lean. So this reads the
  parts of TOML 1.0 such a file uses: tables and arrays of tables, bare,
  quoted and dotted keys, basic and literal strings (single- and multi-line),
  integers, floats, booleans, arrays and inline tables. Dates and times are
  kept as the text they were written as, since nothing here needs them as
  dates.

  It does not validate everything a conforming parser would — redefining a
  table is allowed, for instance — because its only job is to get values out
  of files another program already accepted. A file it cannot read is an
  error naming the line, never a guess.
  """

  @typedoc "A decoded document: string keys, TOML values."
  @type document :: %{optional(String.t()) => term()}

  @doc "Decodes a TOML document."
  @spec decode(text :: String.t()) :: {:ok, document()} | {:error, String.t()}
  def decode(text) when is_binary(text) do
    {:ok, document(text, 1, %{}, [])}
  catch
    {:toml, line, message} -> {:error, "line #{line}: #{message}"}
  end

  # --------------------------------------------------------------------------
  # Document level
  # --------------------------------------------------------------------------

  defp document("", _line, acc, _table), do: acc

  defp document(<<c, rest::binary>>, line, acc, table) when c in [?\s, ?\t, ?\r],
    do: document(rest, line, acc, table)

  defp document(<<?\n, rest::binary>>, line, acc, table), do: document(rest, line + 1, acc, table)

  defp document(<<?#, rest::binary>>, line, acc, table),
    do: document(skip_comment(rest), line, acc, table)

  defp document(<<"[[", rest::binary>>, line, acc, _table) do
    {path, rest, line} = keys(rest, line, [])
    rest = expect(rest, "]]", line)
    acc = append_table(acc, path, line)
    document(end_of_line(rest, line), line, acc, {:array, path})
  end

  defp document(<<?[, rest::binary>>, line, acc, _table) do
    {path, rest, line} = keys(rest, line, [])
    rest = expect(rest, "]", line)
    acc = ensure_table(acc, path, line)
    document(end_of_line(rest, line), line, acc, {:table, path})
  end

  defp document(text, line, acc, table) do
    {path, rest, line} = keys(text, line, [])
    rest = expect(skip_blank(rest), "=", line)
    {value, rest, line} = value(skip_blank(rest), line)
    acc = put_value(acc, table, path, value, line)
    document(end_of_line(rest, line), line, acc, table)
  end

  defp skip_comment(text) do
    case :binary.split(text, "\n") do
      [_comment, rest] -> "\n" <> rest
      [_comment] -> ""
    end
  end

  defp skip_blank(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_blank(rest)
  defp skip_blank(text), do: text

  # After a value or a header only a comment may follow on the same line.
  defp end_of_line(text, line) do
    case skip_blank(text) do
      "" -> ""
      <<?\n, _rest::binary>> = rest -> rest
      <<?\r, ?\n, _rest::binary>> = rest -> binary_part(rest, 1, byte_size(rest) - 1)
      <<?#, rest::binary>> -> skip_comment(rest)
      other -> throw({:toml, line, "unexpected #{inspect(String.slice(other, 0, 12))}"})
    end
  end

  defp expect(text, token, line) do
    text = skip_blank(text)

    if String.starts_with?(text, token),
      do: binary_part(text, byte_size(token), byte_size(text) - byte_size(token)),
      else: throw({:toml, line, "expected #{inspect(token)}"})
  end

  # --------------------------------------------------------------------------
  # Keys
  # --------------------------------------------------------------------------

  defp keys(text, line, acc) do
    {key, rest} = key(skip_blank(text), line)

    case skip_blank(rest) do
      <<?., rest::binary>> -> keys(rest, line, [key | acc])
      rest -> {Enum.reverse([key | acc]), rest, line}
    end
  end

  defp key(<<?", rest::binary>>, line), do: basic_string(rest, line, [])
  defp key(<<?', rest::binary>>, line), do: literal_string(rest, line)

  defp key(text, line) do
    case Regex.run(~r/\A[A-Za-z0-9_-]+/, text) do
      [bare] -> {bare, binary_part(text, byte_size(bare), byte_size(text) - byte_size(bare))}
      nil -> throw({:toml, line, "expected a key"})
    end
  end

  # --------------------------------------------------------------------------
  # Values
  # --------------------------------------------------------------------------

  defp value(<<"\"\"\"", rest::binary>>, line), do: multiline_basic(trim_newline(rest), line, [])
  defp value(<<"'''", rest::binary>>, line), do: multiline_literal(trim_newline(rest), line, [])

  defp value(<<?", rest::binary>>, line) do
    {string, rest} = basic_string(rest, line, [])
    {string, rest, line}
  end

  defp value(<<?', rest::binary>>, line) do
    {string, rest} = literal_string(rest, line)
    {string, rest, line}
  end

  defp value(<<"true", rest::binary>>, line), do: {true, rest, line}
  defp value(<<"false", rest::binary>>, line), do: {false, rest, line}
  defp value(<<?[, rest::binary>>, line), do: array(rest, line, [])
  defp value(<<?{, rest::binary>>, line), do: inline_table(rest, line, %{})
  defp value(text, line), do: scalar(text, line)

  defp trim_newline(<<?\r, ?\n, rest::binary>>), do: rest
  defp trim_newline(<<?\n, rest::binary>>), do: rest
  defp trim_newline(text), do: text

  defp basic_string(<<?", rest::binary>>, _line, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp basic_string(<<?\n, _rest::binary>>, line, _acc),
    do: throw({:toml, line, "unterminated string"})

  defp basic_string("", line, _acc), do: throw({:toml, line, "unterminated string"})

  defp basic_string(<<?\\, rest::binary>>, line, acc) do
    {char, rest} = escape(rest, line)
    basic_string(rest, line, [char | acc])
  end

  defp basic_string(<<c::utf8, rest::binary>>, line, acc),
    do: basic_string(rest, line, [<<c::utf8>> | acc])

  defp literal_string(text, line) do
    case :binary.split(text, "'") do
      [string, rest] ->
        if String.contains?(string, "\n"),
          do: throw({:toml, line, "unterminated string"}),
          else: {string, rest}

      [_unterminated] ->
        throw({:toml, line, "unterminated string"})
    end
  end

  defp multiline_basic(<<"\"\"\"", rest::binary>>, line, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, line}

  defp multiline_basic("", line, _acc), do: throw({:toml, line, "unterminated string"})

  # A backslash at the end of a line swallows the newline and the indentation
  # that follows it.
  defp multiline_basic(<<?\\, rest::binary>>, line, acc) do
    case Regex.run(~r/\A[ \t]*\r?\n/, rest) do
      [_] ->
        {skipped, rest} = skip_whitespace(rest, line)
        multiline_basic(rest, skipped, acc)

      nil ->
        {char, rest} = escape(rest, line)
        multiline_basic(rest, line, [char | acc])
    end
  end

  defp multiline_basic(<<?\n, rest::binary>>, line, acc),
    do: multiline_basic(rest, line + 1, ["\n" | acc])

  defp multiline_basic(<<c::utf8, rest::binary>>, line, acc),
    do: multiline_basic(rest, line, [<<c::utf8>> | acc])

  defp skip_whitespace(<<c, rest::binary>>, line) when c in [?\s, ?\t, ?\r],
    do: skip_whitespace(rest, line)

  defp skip_whitespace(<<?\n, rest::binary>>, line), do: skip_whitespace(rest, line + 1)
  defp skip_whitespace(text, line), do: {line, text}

  defp multiline_literal(text, line, _acc) do
    case :binary.split(text, "'''") do
      [string, rest] -> {string, rest, line + count_newlines(string)}
      [_unterminated] -> throw({:toml, line, "unterminated string"})
    end
  end

  defp count_newlines(string), do: string |> :binary.matches("\n") |> length()

  defp escape(<<?b, rest::binary>>, _line), do: {"\b", rest}
  defp escape(<<?t, rest::binary>>, _line), do: {"\t", rest}
  defp escape(<<?n, rest::binary>>, _line), do: {"\n", rest}
  defp escape(<<?f, rest::binary>>, _line), do: {"\f", rest}
  defp escape(<<?r, rest::binary>>, _line), do: {"\r", rest}
  defp escape(<<?", rest::binary>>, _line), do: {"\"", rest}
  defp escape(<<?\\, rest::binary>>, _line), do: {"\\", rest}
  defp escape(<<?u, hex::binary-size(4), rest::binary>>, line), do: {codepoint(hex, line), rest}
  defp escape(<<?U, hex::binary-size(8), rest::binary>>, line), do: {codepoint(hex, line), rest}
  defp escape(_text, line), do: throw({:toml, line, "invalid escape"})

  defp codepoint(hex, line) do
    case Integer.parse(hex, 16) do
      {code, ""} -> <<code::utf8>>
      _invalid -> throw({:toml, line, "invalid unicode escape"})
    end
  rescue
    ArgumentError -> throw({:toml, line, "invalid unicode escape"})
  end

  # Arrays may span lines and hold comments and a trailing comma.
  defp array(text, line, acc) do
    case skip_space_and_comments(text, line) do
      {<<?], rest::binary>>, line} ->
        {Enum.reverse(acc), rest, line}

      {text, line} ->
        {value, rest, line} = value(text, line)

        case skip_space_and_comments(rest, line) do
          {<<?,, rest::binary>>, line} -> array(rest, line, [value | acc])
          {<<?], rest::binary>>, line} -> {Enum.reverse([value | acc]), rest, line}
          {_other, line} -> throw({:toml, line, "expected , or ] in an array"})
        end
    end
  end

  # Inline tables are single-line in TOML 1.0; newlines are tolerated here
  # because a file written for a newer version is still a file to import.
  defp inline_table(text, line, acc) do
    case skip_space_and_comments(text, line) do
      {<<?}, rest::binary>>, line} ->
        {acc, rest, line}

      {text, line} ->
        {path, rest, line} = keys(text, line, [])
        rest = expect(skip_blank(rest), "=", line)
        {value, rest, line} = value(skip_blank(rest), line)
        acc = put_path(acc, path, value, line)

        case skip_space_and_comments(rest, line) do
          {<<?,, rest::binary>>, line} -> inline_table(rest, line, acc)
          {<<?}, rest::binary>>, line} -> {acc, rest, line}
          {_other, line} -> throw({:toml, line, "expected , or } in an inline table"})
        end
    end
  end

  defp skip_space_and_comments(<<c, rest::binary>>, line) when c in [?\s, ?\t, ?\r],
    do: skip_space_and_comments(rest, line)

  defp skip_space_and_comments(<<?\n, rest::binary>>, line),
    do: skip_space_and_comments(rest, line + 1)

  defp skip_space_and_comments(<<?#, rest::binary>>, line),
    do: skip_space_and_comments(skip_comment(rest), line)

  defp skip_space_and_comments(text, line), do: {text, line}

  # Numbers, and dates and times kept as text.
  defp scalar(text, line) do
    case Regex.run(~r/\A[^\s,\]\}#]+(?: [0-9][^\s,\]\}#]*)?/, text) do
      [token] ->
        rest = binary_part(text, byte_size(token), byte_size(text) - byte_size(token))
        {number(token, line), rest, line}

      nil ->
        throw({:toml, line, "expected a value"})
    end
  end

  defp number(token, line) do
    clean = String.replace(token, "_", "")

    case special(clean) do
      {:ok, {:radix, digits, base}} -> radix(digits, base, line)
      {:ok, value} -> value
      :error -> decimal(clean, token, line)
    end
  end

  defp special(clean) when clean in ["inf", "+inf"], do: {:ok, :infinity}
  defp special("-inf"), do: {:ok, :neg_infinity}
  defp special(clean) when clean in ["nan", "+nan", "-nan"], do: {:ok, :nan}
  defp special("0x" <> _digits = clean), do: {:ok, {:radix, clean, 16}}
  defp special("0o" <> _digits = clean), do: {:ok, {:radix, clean, 8}}
  defp special("0b" <> _digits = clean), do: {:ok, {:radix, clean, 2}}
  defp special(_clean), do: :error

  defp decimal(clean, token, line) do
    cond do
      Regex.match?(~r/\A[+-]?\d+\z/, clean) -> String.to_integer(clean)
      Regex.match?(~r/\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/, clean) -> float(clean)
      Regex.match?(~r/\A\d{4}-\d{2}-\d{2}|\A\d{2}:\d{2}/, token) -> token
      true -> throw({:toml, line, "unrecognised value #{inspect(token)}"})
    end
  end

  defp radix(<<_prefix::binary-size(2), digits::binary>>, base, line) do
    case Integer.parse(digits, base) do
      {value, ""} -> value
      _invalid -> throw({:toml, line, "invalid number"})
    end
  end

  defp float(clean) do
    # `Float.parse/1` wants a digit after the point; "1e5" has none.
    normalised =
      if String.contains?(clean, "."), do: clean, else: String.replace(clean, ~r/[eE]/, ".0e")

    {value, ""} = Float.parse(normalised)
    value
  end

  # --------------------------------------------------------------------------
  # Building the document
  # --------------------------------------------------------------------------

  defp ensure_table(acc, path, line), do: update_in_path(acc, path, %{}, & &1, line)

  defp append_table(acc, path, line) do
    {parent, [last]} = Enum.split(path, -1)

    update_in_path(
      acc,
      parent,
      %{},
      fn table ->
        case Map.get(table, last) do
          nil -> Map.put(table, last, [%{}])
          list when is_list(list) -> Map.put(table, last, list ++ [%{}])
          _other -> throw({:toml, line, "#{Enum.join(path, ".")} is not an array of tables"})
        end
      end,
      line
    )
  end

  defp put_value(acc, [], path, value, line), do: put_path(acc, path, value, line)

  defp put_value(acc, {:table, table}, path, value, line),
    do: update_in_path(acc, table, %{}, &put_path(&1, path, value, line), line)

  defp put_value(acc, {:array, table}, path, value, line) do
    {parent, [last]} = Enum.split(table, -1)

    update_in_path(
      acc,
      parent,
      %{},
      fn parent_table ->
        entries = Map.fetch!(parent_table, last)
        {init, [current]} = Enum.split(entries, -1)
        Map.put(parent_table, last, init ++ [put_path(current, path, value, line)])
      end,
      line
    )
  end

  defp put_path(table, [key], value, _line), do: Map.put(table, key, value)

  defp put_path(table, [key | rest], value, line) do
    case Map.get(table, key, %{}) do
      nested when is_map(nested) -> Map.put(table, key, put_path(nested, rest, value, line))
      _scalar -> throw({:toml, line, "#{key} is not a table"})
    end
  end

  # Walks to `path`, creating tables on the way, and applies `fun` there. A
  # path that runs through an array of tables continues in its last entry.
  defp update_in_path(acc, [], _default, fun, _line), do: fun.(acc)

  defp update_in_path(acc, [key | rest], default, fun, line) do
    case Map.get(acc, key, default) do
      nested when is_map(nested) ->
        Map.put(acc, key, update_in_path(nested, rest, default, fun, line))

      [_ | _] = entries ->
        {init, [current]} = Enum.split(entries, -1)
        Map.put(acc, key, init ++ [update_in_path(current, rest, default, fun, line)])

      _scalar ->
        throw({:toml, line, "#{key} is not a table"})
    end
  end
end
