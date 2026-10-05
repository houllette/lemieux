defmodule Lemieux.Tools.Edit.Match do
  @moduledoc """
  Where `old` is in a file, and the file with `new` in its place.

  Pure functions over binaries, kept apart from `Lemieux.Tools.Edit` so each
  rule below has a test that states it. The contract they serve is the edit
  tool's: an edit lands in exactly one place, or in every place the model
  asked for, or nowhere — never in a place chosen by a guess.

  ## Line endings and byte-order marks

  Matching happens on text with `\\r\\n` turned into `\\n` and without a leading
  UTF-8 byte-order mark, in both the file and the strings. A model never sees
  `\\r` (`Lemieux.Tools.Read` does not show it) and so never types one; before
  this, a multi-line edit to a Windows-style file could not match however
  exactly it was copied, and the model repeated it until the loop guard
  stopped the session. The result is written back byte-for-byte outside the
  replaced text, and the replacement takes the file's predominant line ending,
  so an edit to a CRLF file stays a CRLF file.

  ## When the exact text is not there

  Models get the text almost right in a few predictable ways, and each is
  tried in turn — but only ever to find **one** place. A looser rule that
  finds two is as ambiguous as the stricter one that found none, and the edit
  is refused rather than aimed:

    1. the exact text;
    2. the text without the `N<tab>` line-number prefixes `read` puts on each
       line, when every line of it carries one;
    3. whole lines equal once trailing whitespace is ignored;
    4. whole lines equal once indentation is ignored — `new` is re-indented
       by the difference, so a block copied at the wrong depth lands at the
       right one;
    5. whole lines equal once every run of whitespace is one space.

  `replace_all` uses only the first two: "every place that roughly looks like
  this" is not an instruction anyone means.

  When nothing matches, `closest/2` finds the most similar region, so the
  refusal can show the model the text it was probably reaching for.
  """

  @bom <<0xEF, 0xBB, 0xBF>>
  @prefix ~r/^\s*\d+\t/
  @fuzzy [:trailing_whitespace, :indentation, :whitespace]

  @typedoc "How a match was found."
  @type strategy ::
          :exact | :line_numbers | :trailing_whitespace | :indentation | :whitespace

  @typedoc "A replaced file and what the tool reports about it."
  @type replaced :: %{
          contents: binary(),
          count: pos_integer(),
          strategy: strategy(),
          first_line: pos_integer(),
          last_line: pos_integer(),
          text: String.t()
        }

  @doc """
  Replaces `old` with `new` in `contents`.

  Returns the new contents with where the (first) replacement now sits in it,
  as 1-based line numbers of the *new* file, and `text`, the new file as the
  model sees it (no `\\r`, no BOM) for showing that region. Errors are
  `:empty`, `:identical`, `:not_found`, or `{:ambiguous, strategy, count}`.
  """
  @spec replace(
          contents :: binary(),
          old :: String.t(),
          new :: String.t(),
          replace_all? :: boolean()
        ) ::
          {:ok, replaced()}
          | {:error, :empty | :identical | :not_found | {:ambiguous, strategy(), pos_integer()}}
  def replace(contents, old, new, replace_all?) do
    {bom, body} = split_bom(contents)
    {text, crlf_at} = normalize(body)
    old = old |> strip_bom() |> lf()
    new = new |> strip_bom() |> lf()

    with :ok <- check(old, new),
         {:ok, strategy, regions, replacement} <- find(text, old, new, replace_all?) do
      eol = predominant(body, crlf_at)

      {:ok,
       splice(bom, body, text, crlf_at, regions, replacement, eol)
       |> Map.merge(%{count: length(regions), strategy: strategy})}
    end
  end

  @doc """
  The region of `contents` most like `old`, as `{first_line, last_line, similarity}`.

  Similarity is the mean Jaro similarity of the trimmed lines, from 0.0 to
  1.0. `nil` when nothing is similar enough to be worth showing. Bounded: a
  large file is compared only at the lines most like the start of `old`.
  """
  @spec closest(contents :: binary(), old :: String.t()) ::
          {pos_integer(), pos_integer(), float()} | nil
  def closest(contents, old) do
    {text, _crlf_at} = contents |> strip_bom() |> normalize()
    lines = text |> String.split("\n") |> List.to_tuple()
    wanted = old |> strip_bom() |> lf() |> String.trim_trailing("\n") |> String.split("\n")
    size = length(wanted)
    total = tuple_size(lines)

    lines
    |> candidates(wanted, size)
    |> Enum.map(fn start -> {start, similarity(window(lines, start, size), wanted)} end)
    |> Enum.max_by(fn {_start, score} -> score end, fn -> nil end)
    |> best(size, total)
  end

  defp best(nil, _size, _total), do: nil
  defp best({_start, score}, _size, _total) when score < 0.6, do: nil

  defp best({start, score}, size, total),
    do: {start + 1, min(start + size, total), Float.round(score, 2)}

  defp window(lines, start, size) do
    last = min(start + size, tuple_size(lines)) - 1
    if last < start, do: [], else: Enum.map(start..last, &elem(lines, &1))
  end

  # Every window when that is cheap; otherwise only those starting at the
  # lines most like the first line of `old`.
  defp candidates(lines, wanted, size) do
    total = tuple_size(lines)
    last = max(total - size, 0)

    if total * size <= 50_000 do
      Enum.to_list(0..last)
    else
      first = wanted |> Enum.find("", &(String.trim(&1) != "")) |> key()

      0..last
      |> Enum.map(fn index -> {index, String.jaro_distance(key(elem(lines, index)), first)} end)
      |> Enum.sort_by(fn {_index, score} -> score end, :desc)
      |> Enum.take(25)
      |> Enum.map(fn {index, _score} -> index end)
    end
  end

  defp similarity([], _wanted), do: 0.0

  defp similarity(window, wanted) do
    window
    |> Enum.zip(wanted)
    |> Enum.map(fn {have, want} -> String.jaro_distance(key(have), key(want)) end)
    |> Enum.sum()
    |> Kernel./(length(wanted))
  end

  # Long lines are compared by their first few hundred characters: Jaro is
  # quadratic in the worst case, and a hint does not need more.
  defp key(line), do: line |> String.trim() |> String.slice(0, 200)

  defp check("", _new), do: {:error, :empty}
  defp check(same, same), do: {:error, :identical}
  defp check(_old, _new), do: :ok

  defp find(text, old, new, replace_all?) do
    with :none <- exact(text, old, new, replace_all?, :exact),
         :none <- line_numbers(text, old, new, replace_all?),
         :none <- fuzzy(text, old, new, replace_all?) do
      {:error, :not_found}
    end
  end

  defp exact(text, old, new, replace_all?, strategy) do
    case :binary.matches(text, old) do
      [] -> :none
      [single] -> {:ok, strategy, [single], new}
      many when replace_all? -> {:ok, strategy, many, new}
      many -> {:error, {:ambiguous, strategy, length(many)}}
    end
  end

  defp line_numbers(text, old, new, replace_all?) do
    if prefixed?(old),
      do: exact(text, unprefix(old), unprefixed_new(new), replace_all?, :line_numbers),
      else: :none
  end

  defp prefixed?(text), do: text |> lines() |> Enum.all?(&Regex.match?(@prefix, &1))

  defp unprefix(text) do
    text
    |> lines()
    |> Enum.map_join("\n", &Regex.replace(@prefix, &1, ""))
    |> keep_final_newline(text)
  end

  # The model usually copies the prefixes into `new` too; when every line of
  # `new` has one, they come off. When only some do, `new` is taken as written.
  defp unprefixed_new(new), do: if(prefixed?(new), do: unprefix(new), else: new)

  defp fuzzy(_text, _old, _new, true = _replace_all?), do: :none

  defp fuzzy(text, old, new, false) do
    file_lines = String.split(text, "\n")
    wanted = lines(old)

    Enum.reduce_while(@fuzzy, :none, fn strategy, :none ->
      case windows(file_lines, wanted, strategy) do
        [] -> {:cont, :none}
        [start] -> {:halt, line_region(text, file_lines, start, wanted, old, new, strategy)}
        many -> {:halt, {:error, {:ambiguous, strategy, length(many)}}}
      end
    end)
  end

  defp windows(_file_lines, [], _strategy), do: []

  defp windows(file_lines, wanted, strategy) do
    size = length(wanted)
    keys = Enum.map(wanted, &normal(&1, strategy))

    file_lines
    |> Stream.map(&normal(&1, strategy))
    |> Stream.chunk_every(size, 1, :discard)
    |> Stream.with_index()
    |> Stream.filter(fn {window, _start} -> window == keys end)
    |> Enum.map(fn {_window, start} -> start end)
  end

  defp normal(line, :trailing_whitespace), do: String.trim_trailing(line)
  defp normal(line, :indentation), do: String.trim(line)
  defp normal(line, :whitespace), do: line |> String.split() |> Enum.join(" ")

  # The matched lines, from the start of the first to the end of the last
  # (without its newline), and `new` fitted to them: re-indented when
  # indentation was what differed, and without the trailing newline `old` had,
  # since the region stops before the last line's newline.
  defp line_region(text, file_lines, start, wanted, old, new, strategy) do
    size = length(wanted)
    from = file_lines |> Enum.take(start) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
    span = file_lines |> Enum.slice(start, size) |> Enum.join("\n") |> byte_size()
    new = if String.ends_with?(old, "\n"), do: String.replace_suffix(new, "\n", ""), else: new
    matched = binary_part(text, from, span)

    {:ok, strategy, [{from, span}], reindent(new, wanted, matched, strategy)}
  end

  defp reindent(new, wanted, matched, strategy) when strategy in [:indentation, :whitespace] do
    from = indentation(wanted)
    to = matched |> String.split("\n") |> indentation()

    new
    |> String.split("\n")
    |> Enum.map_join("\n", &shift(&1, from, to))
  end

  defp reindent(new, _wanted, _matched, _strategy), do: new

  defp shift(line, from, to) do
    cond do
      String.trim(line) == "" -> ""
      String.starts_with?(line, from) -> to <> String.replace_prefix(line, from, "")
      true -> line
    end
  end

  defp indentation(lines) do
    case Enum.find(lines, &(String.trim(&1) != "")) do
      nil -> ""
      line -> line |> String.split(~r/\S/, parts: 2) |> hd()
    end
  end

  # The lines of `old` or `new`, without the empty one a trailing newline makes.
  defp lines(text), do: text |> String.replace_suffix("\n", "") |> String.split("\n")

  defp keep_final_newline(joined, original) do
    if String.ends_with?(original, "\n"), do: joined <> "\n", else: joined
  end

  # Rebuilds the file around each replaced region. Offsets are found in the
  # normalised text; `raw/2` turns one into the matching offset in the file as
  # stored, by counting the `\r`s that normalising removed before it.
  defp splice(bom, body, text, crlf_at, regions, replacement, eol) do
    stored = String.replace(replacement, "\n", eol)

    {parts, cursor} =
      Enum.reduce(regions, {[], 0}, fn {from, span}, {parts, cursor} ->
        start = raw(from, crlf_at)
        stop = raw(from + span, crlf_at)
        {[stored, binary_part(body, cursor, start - cursor) | parts], stop}
      end)

    rest = binary_part(body, cursor, byte_size(body) - cursor)
    contents = IO.iodata_to_binary([bom | Enum.reverse([rest | parts])])

    [{first_from, _span} | _rest] = regions
    before = binary_part(text, 0, first_from)
    first_line = count_lines(before) + 1
    last_line = first_line + count_lines(String.replace_suffix(replacement, "\n", ""))
    {new_text, _crlf_at} = contents |> strip_bom() |> normalize()

    %{contents: contents, first_line: first_line, last_line: last_line, text: new_text}
  end

  defp raw(offset, crlf_at), do: offset + Enum.count(crlf_at, &(&1 < offset))

  defp count_lines(text), do: text |> :binary.matches("\n") |> length()

  # CRLF when most of the file's line endings are; a file with none keeps LF.
  defp predominant(body, crlf_at) do
    crlf = length(crlf_at)
    lf = length(:binary.matches(body, "\n")) - crlf
    if crlf > lf, do: "\r\n", else: "\n"
  end

  # The text with each `\r\n` as `\n`, and the offsets (in that text) of the
  # newlines that had a `\r` before them.
  defp normalize(body) do
    pieces = String.split(body, "\r\n")
    text = Enum.join(pieces, "\n")

    {crlf_at, _offset} =
      pieces
      |> Enum.drop(-1)
      |> Enum.map_reduce(0, fn piece, offset ->
        at = offset + byte_size(piece)
        {at, at + 1}
      end)

    {text, crlf_at}
  end

  defp lf(text), do: String.replace(text, "\r\n", "\n")

  defp split_bom(@bom <> rest), do: {@bom, rest}
  defp split_bom(contents), do: {"", contents}

  defp strip_bom(@bom <> rest), do: rest
  defp strip_bom(text), do: text
end
