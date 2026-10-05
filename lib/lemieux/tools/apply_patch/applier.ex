defmodule Lemieux.Tools.ApplyPatch.Applier do
  @moduledoc """
  Applies the hunks of one `*** Update File` to a file's contents, in memory.

  ## Finding the lines

  Each hunk names the lines it replaces (its context and `-` lines) and is
  searched for from where the previous hunk ended, after any `@@` headers
  have narrowed the position. The search is tried four ways, strictest
  first, as in OpenAI's reference implementation: exact; ignoring trailing
  whitespace; ignoring surrounding whitespace; and with typographic dashes,
  quotes and spaces folded to ASCII. The first position found wins.

  Loosening is safe here in a way it is not for `edit`'s single string: a
  hunk is several whole lines in order, found after an anchor, and a
  whitespace difference is by far the commonest reason a model's copy of
  them differs from the file. What the file ends up containing is always the
  hunk's own `+` and context lines.

  ## What is preserved

  Line endings: a file written with `\\r\\n` keeps them, including on the
  lines the patch added. A byte-order mark stays at the front. A file that
  did not end in a newline still does not. The obvious alternative, joining
  with `\\n` and always appending one, makes every Windows file in a
  repository show as entirely changed after a one-line fix.

  ## When it fails

  With the lines it looked for and the line of the file that came closest,
  because "could not find the expected lines" alone leaves a model re-sending
  the same wrong hunk.
  """

  alias Lemieux.Tools.ApplyPatch.Parser

  @bom "﻿"

  @doc "Applies `chunks` to `contents`. `path` names the file in errors."
  @spec update(contents :: String.t(), chunks :: [Parser.chunk()], path :: String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def update(contents, chunks, path) when is_binary(contents) and is_list(chunks) do
    {bom, body} = split_bom(contents)
    eol = eol(body)
    final_newline? = body == "" or String.ends_with?(body, "\n")
    lines = lines(body)

    with {:ok, replacements} <- replacements(List.to_tuple(lines), chunks, path) do
      updated = replace(lines, replacements)
      text = Enum.join(updated, eol)
      text = if final_newline? and updated != [], do: text <> eol, else: text
      {:ok, bom <> text}
    end
  end

  @doc "The contents of a file an `*** Add File` creates from `lines`."
  @spec new_file(lines :: [String.t()]) :: String.t()
  def new_file([]), do: ""
  def new_file(lines), do: Enum.join(lines, "\n") <> "\n"

  defp split_bom(@bom <> body), do: {@bom, body}
  defp split_bom(body), do: {"", body}

  # The ending most lines already use. A file with none (one line) gets `\n`.
  defp eol(body) do
    crlf = body |> :binary.matches("\r\n") |> length()
    lf = body |> :binary.matches("\n") |> length()
    if crlf > 0 and crlf * 2 >= lf, do: "\r\n", else: "\n"
  end

  defp lines(""), do: []

  defp lines(body) do
    body
    |> String.replace_suffix("\n", "")
    |> String.replace_suffix("\r", "")
    |> String.split("\n")
    |> Enum.map(&String.replace_suffix(&1, "\r", ""))
  end

  defp replacements(lines, chunks, path) do
    located =
      chunks
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, [], 0}, fn {chunk, number}, {:ok, done, from} ->
        case locate(lines, chunk, from) do
          {:ok, at, length, new} ->
            {:cont, {:ok, [{at, length, new} | done], at + length}}

          {:error, reason} ->
            {:halt, {:error, failure(reason, lines, chunk, number, path)}}
        end
      end)

    case located do
      {:ok, done, _from} -> {:ok, done}
      {:error, _reason} = error -> error
    end
  end

  defp locate(lines, chunk, from) do
    with {:ok, from} <- contexts(lines, chunk.contexts, from) do
      body(lines, chunk, from)
    end
  end

  defp contexts(lines, contexts, from) do
    Enum.reduce_while(contexts, {:ok, from}, fn context, {:ok, from} ->
      case seek(lines, [context], from, false) do
        nil -> {:halt, {:error, {:context, context}}}
        at -> {:cont, {:ok, at + 1}}
      end
    end)
  end

  # A hunk of only additions goes where its `@@` header put it, or at the end
  # of the file when it has none.
  defp body(lines, %{old: [], new: new, contexts: []}, _from),
    do: {:ok, tuple_size(lines), 0, new}

  defp body(_lines, %{old: [], new: new}, from), do: {:ok, from, 0, new}

  defp body(lines, %{old: old, new: new, end_of_file?: end_of_file?}, from) do
    case seek(lines, old, from, end_of_file?) do
      nil -> without_trailing_blank(lines, old, new, from, end_of_file?)
      at -> {:ok, at, length(old), new}
    end
  end

  # A model that ends a hunk with a blank context line the file does not have
  # (the file's last line, usually) is describing the same place.
  defp without_trailing_blank(lines, old, new, from, end_of_file?) do
    if List.last(old) == "" do
      old = Enum.drop(old, -1)
      new = if List.last(new) == "", do: Enum.drop(new, -1), else: new

      case seek(lines, old, from, end_of_file?) do
        nil -> {:error, :lines}
        at -> {:ok, at, length(old), new}
      end
    else
      {:error, :lines}
    end
  end

  defp seek(_lines, [], from, _end_of_file?), do: from

  defp seek(lines, pattern, from, end_of_file?) do
    total = tuple_size(lines)
    size = length(pattern)

    cond do
      size > total ->
        nil

      end_of_file? ->
        # Anchored at the end first; a model that marked the end of the file
        # but miscounted still means these lines.
        find(lines, pattern, total - size, total - size) ||
          find(lines, pattern, from, total - size)

      true ->
        find(lines, pattern, from, total - size)
    end
  end

  defp find(_lines, _pattern, from, last) when from > last, do: nil

  defp find(lines, pattern, from, last) do
    Enum.find_value([&exact/1, &String.trim_trailing/1, &String.trim/1, &normalize/1], fn fold ->
      folded = Enum.map(pattern, fold)
      Enum.find(from..last//1, &same?(lines, folded, &1, fold))
    end)
  end

  defp exact(line), do: line

  defp same?(lines, folded, at, fold) do
    folded
    |> Enum.with_index(at)
    |> Enum.all?(fn {line, index} -> fold.(elem(lines, index)) == line end)
  end

  @dashes ~w(‐ ‑ ‒ – — ― −)
  @single ~w(‘ ’ ‚ ‛)
  @double ~w(“ ” „ ‟)
  @spaces [
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    " ",
    "　"
  ]

  defp normalize(line) do
    line
    |> String.replace(@dashes, "-")
    |> String.replace(@single, "'")
    |> String.replace(@double, "\"")
    |> String.replace(@spaces, " ")
    |> String.trim()
  end

  defp replace(lines, replacements) do
    replacements
    |> Enum.sort_by(fn {at, _length, _new} -> at end, :desc)
    |> Enum.reduce(lines, fn {at, length, new}, lines ->
      {before, rest} = Enum.split(lines, at)
      before ++ new ++ Enum.drop(rest, length)
    end)
  end

  defp failure({:context, context}, lines, _chunk, number, path) do
    "could not find the @@ context #{inspect(context)} in #{path} (hunk #{number})" <>
      closest(lines, context)
  end

  defp failure(:lines, lines, chunk, number, path) do
    expected = chunk.old |> Enum.take(8) |> Enum.map_join("\n", &("  " <> &1))
    more = if length(chunk.old) > 8, do: "\n  …", else: ""
    anchor = Enum.find(chunk.old, "", &(String.trim(&1) != ""))

    "could not find the lines hunk #{number} changes in #{path}:\n#{expected}#{more}" <>
      closest(lines, anchor) <>
      "\nRead the file again and copy the context lines exactly."
  end

  defp closest(_lines, ""), do: ""

  defp closest(lines, text) do
    target = String.trim(text)

    best =
      lines
      |> Tuple.to_list()
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)
      |> Enum.max_by(&String.jaro_distance(String.trim(elem(&1, 0)), target), fn -> nil end)

    case best do
      {line, number} -> "\nThe closest line is #{number}: #{inspect(line)}"
      nil -> ""
    end
  end
end
