# Pure and unguarded, like `Lemieux.TUI.Activity`: the arithmetic most likely
# to be wrong is tested on a machine without the terminal dependency.
defmodule Lemieux.TUI.Diff do
  @moduledoc """
  A unified diff of two lists of lines, numbered, with context.

  An edit used to be drawn as the whole old block in red above the whole new
  block in green, unnumbered, counting every line of both as changed. That
  is a picture of the arguments, not of the change: a one-word fix in a
  twenty-line block read as forty changed lines. This computes what actually
  changed — `List.myers_difference/2`, the standard library's — keeps a few
  lines of context around each change, and numbers every line with where it
  sits in the file, so a person can find it.

  Lines that belong to neither side's change are context. Runs of context
  longer than twice `:context` collapse to the lines on either side of a gap.
  """

  @typedoc """
  One line of the diff: what happened to it, its number in the old and the
  new file (`nil` when it is not in that side, or when the numbering is not
  known), and its text. `{:gap, count}` stands for unchanged lines left out.
  """
  @type line ::
          {:context | :add | :delete, pos_integer() | nil, pos_integer() | nil, String.t()}
          | {:gap, pos_integer()}

  @doc """
  The diff of `old` and `new`.

  Options: `:old_start` and `:new_start`, the file line numbers of the first
  line of each (default 1; `nil` leaves the lines unnumbered), and
  `:context`, how many unchanged lines to keep beside a change (default 3).
  """
  @spec unified(old :: [String.t()], new :: [String.t()], opts :: keyword()) :: [line()]
  def unified(old, new, opts \\ []) when is_list(old) and is_list(new) do
    context = Keyword.get(opts, :context, 3)

    old
    |> List.myers_difference(new)
    |> numbered(Keyword.get(opts, :old_start, 1), Keyword.get(opts, :new_start, 1))
    |> collapsed(context)
  end

  @doc "How many lines were added and removed."
  @spec counts([line()]) :: {non_neg_integer(), non_neg_integer()}
  def counts(lines) do
    Enum.reduce(lines, {0, 0}, fn
      {:add, _old, _new, _text}, {added, removed} -> {added + 1, removed}
      {:delete, _old, _new, _text}, {added, removed} -> {added, removed + 1}
      _other, counts -> counts
    end)
  end

  defp numbered(script, old_start, new_start) do
    {lines, _old, _new} =
      Enum.reduce(script, {[], old_start, new_start}, fn
        {:eq, texts}, acc -> Enum.reduce(texts, acc, &emit(:context, &1, &2))
        {:del, texts}, acc -> Enum.reduce(texts, acc, &emit(:delete, &1, &2))
        {:ins, texts}, acc -> Enum.reduce(texts, acc, &emit(:add, &1, &2))
      end)

    Enum.reverse(lines)
  end

  defp emit(:context, text, {lines, old, new}),
    do: {[{:context, old, new, text} | lines], step(old), step(new)}

  defp emit(:delete, text, {lines, old, new}),
    do: {[{:delete, old, nil, text} | lines], step(old), new}

  defp emit(:add, text, {lines, old, new}),
    do: {[{:add, nil, new, text} | lines], old, step(new)}

  defp step(nil), do: nil
  defp step(number), do: number + 1

  # Context runs longer than `2 × context` keep `context` lines at each end
  # beside a change; a run at the very start or end keeps only the side
  # facing the change. A diff with no change at all is left whole — there is
  # nothing to centre on, and the caller decides what to say about it.
  defp collapsed(lines, context) do
    if Enum.all?(lines, &match?({:context, _old, _new, _text}, &1)) do
      lines
    else
      lines
      |> Enum.chunk_by(&match?({:context, _old, _new, _text}, &1))
      |> then(fn chunks -> trim_chunks(chunks, context, length(chunks)) end)
    end
  end

  defp trim_chunks(chunks, context, count) do
    chunks
    |> Enum.with_index()
    |> Enum.flat_map(fn {chunk, index} ->
      if match?([{:context, _old, _new, _text} | _rest], chunk),
        do: trim(chunk, context, index == 0, index == count - 1),
        else: chunk
    end)
  end

  defp trim(chunk, context, first?, last?) do
    keep_head = if first?, do: 0, else: context
    keep_tail = if last?, do: 0, else: context
    hidden = length(chunk) - keep_head - keep_tail

    if hidden > 0,
      do: Enum.take(chunk, keep_head) ++ [{:gap, hidden}] ++ Enum.take(chunk, -keep_tail),
      else: chunk
  end
end
