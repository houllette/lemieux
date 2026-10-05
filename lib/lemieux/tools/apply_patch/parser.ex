defmodule Lemieux.Tools.ApplyPatch.Parser do
  @moduledoc """
  Reads the patch format GPT-5-family models are trained to write.

      *** Begin Patch
      *** Add File: path/new.ex
      +line
      *** Update File: path/old.ex
      *** Move to: path/renamed.ex
      @@ def some_function
       context
      -removed
      +added
      *** End of File
      *** Delete File: path/gone.ex
      *** End Patch

  The grammar is OpenAI's (`codex-rs/apply-patch`), including its leniencies,
  because those are what the models actually emit:

    * the patch may arrive wrapped in a shell heredoc (`<<'EOF'` … `EOF`);
    * the first hunk of an update may omit its `@@` line;
    * an empty line inside a hunk is an empty context line, since trailing
      whitespace is routinely stripped from what the model wrote.

  Three more, each a failure seen from models that half-remember the format:
  a patch without the `*** Begin Patch`/`*** End Patch` envelope is accepted
  when it starts with a file header; several `@@ header` lines in a row
  narrow the search in order (`@@ class Cache` then `@@ def get`), which the
  format's own instructions describe and its reference parser rejects; and a
  unified-diff hunk header (`@@ -12,7 +12,8 @@ def get`) keeps only the text
  after its ranges as context, while `\\ No newline at end of file` is
  skipped. A patch that is still malformed after that is refused with the
  line that broke it, because a guess about what the model meant would
  change a file it did not intend to change.

  Parsing is separate from applying so a policy (a checkpoint wrapper, a
  permission rule) can learn which paths a patch touches without applying it.
  """

  @typedoc "One `@@` hunk of an update."
  @type chunk :: %{
          contexts: [String.t()],
          old: [String.t()],
          new: [String.t()],
          end_of_file?: boolean()
        }

  @typedoc "One file operation."
  @type operation ::
          %{type: :add, path: String.t(), lines: [String.t()]}
          | %{type: :delete, path: String.t()}
          | %{type: :update, path: String.t(), move_to: String.t() | nil, chunks: [chunk()]}

  @begin "*** Begin Patch"
  @finish "*** End Patch"
  @add "*** Add File: "
  @delete "*** Delete File: "
  @update "*** Update File: "
  @move "*** Move to: "
  @end_of_file "*** End of File"
  @unified ~r/^-\d+(?:,\d+)? \+\d+(?:,\d+)? @@\s*(.*)$/

  @doc "Parses a whole patch into its operations, in order."
  @spec parse(text :: String.t()) :: {:ok, [operation()]} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    with {:ok, lines} <- envelope(text),
         {:ok, operations} <- operations(lines, []) do
      nonempty(operations)
    end
  end

  def parse(_text), do: {:error, "the patch must be a string"}

  @doc "Every path a patch reads or writes, destinations of moves included."
  @spec paths(operations :: [operation()]) :: [String.t()]
  def paths(operations) do
    operations
    |> Enum.flat_map(fn
      %{type: :update, path: path, move_to: to} when is_binary(to) -> [path, to]
      %{path: path} -> [path]
    end)
    |> Enum.uniq()
  end

  defp nonempty([]), do: {:error, "the patch contains no file operations"}
  defp nonempty(operations), do: {:ok, operations}

  defp envelope(text) do
    lines =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> unwrap_heredoc()
      |> trim_blank_edges()

    case lines do
      [@begin | rest] ->
        if List.last(rest) == @finish,
          do: {:ok, Enum.drop(rest, -1)},
          else: {:error, "the patch must end with \"#{@finish}\""}

      [first | _rest] = lines ->
        if header?(first),
          do: {:ok, drop_finish(lines)},
          else: {:error, "the patch must start with \"#{@begin}\""}

      [] ->
        {:error, "the patch is empty"}
    end
  end

  defp drop_finish(lines) do
    if List.last(lines) == @finish, do: Enum.drop(lines, -1), else: lines
  end

  # `apply_patch <<'EOF'` … `EOF` is how the models were trained to call the
  # tool from a shell, and some send the wrapper through a function call too.
  defp unwrap_heredoc(lines) do
    trimmed = trim_blank_edges(lines)

    with [first | middle] <- trimmed,
         [_, marker] <- Regex.run(~r/<<\s*['"]?(\w+)['"]?\s*$/, first),
         last when is_binary(last) <- List.last(middle),
         true <- String.trim(last) == marker do
      Enum.drop(middle, -1)
    else
      _not_a_heredoc -> lines
    end
  end

  defp trim_blank_edges(lines) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
  end

  defp blank?(line), do: String.trim(line) == ""

  defp operations([], operations), do: {:ok, Enum.reverse(operations)}

  defp operations([line | rest], operations) do
    cond do
      String.starts_with?(line, @add) ->
        with {:ok, path} <- path(line, @add) do
          {content, rest} = Enum.split_while(rest, &(not header?(&1)))
          add(path, content, rest, operations)
        end

      String.starts_with?(line, @delete) ->
        with {:ok, path} <- path(line, @delete) do
          operations(rest, [%{type: :delete, path: path} | operations])
        end

      String.starts_with?(line, @update) ->
        with {:ok, path} <- path(line, @update) do
          update(path, rest, operations)
        end

      blank?(line) ->
        operations(rest, operations)

      true ->
        {:error,
         ~s(unexpected line #{inspect(line)}: expected "#{@add}", "#{@update}" or ) <>
           ~s("#{@delete}" followed by a path)}
    end
  end

  defp header?(line), do: Enum.any?([@add, @delete, @update], &String.starts_with?(line, &1))

  defp add(path, content, rest, operations) do
    content = trim_trailing_blank(content)

    case Enum.reject(content, &String.starts_with?(&1, "+")) do
      [] ->
        lines = Enum.map(content, &String.replace_prefix(&1, "+", ""))
        operations(rest, [%{type: :add, path: path, lines: lines} | operations])

      [bad | _rest] ->
        {:error, "in \"#{@add}#{path}\", every line must start with +; got #{inspect(bad)}"}
    end
  end

  defp update(path, rest, operations) do
    {move_to, rest} = move(rest)
    {body, rest} = Enum.split_while(rest, &(not header?(&1)))

    with {:ok, chunks} <- chunks(trim_trailing_blank(body), path, [], true),
         :ok <- changes(path, chunks, move_to) do
      operation = %{type: :update, path: path, move_to: move_to, chunks: chunks}
      operations(rest, [operation | operations])
    end
  end

  defp move([@move <> destination | rest]) do
    case String.trim(destination) do
      "" -> {nil, rest}
      destination -> {destination, rest}
    end
  end

  defp move(rest), do: {nil, rest}

  defp changes(path, [], nil),
    do: {:error, "\"#{@update}#{path}\" has no hunks, so nothing would change"}

  defp changes(_path, _chunks, _move_to), do: :ok

  defp chunks([], _path, chunks, _first?), do: {:ok, Enum.reverse(chunks)}

  defp chunks(lines, path, chunks, first?) do
    {contexts, rest} = headers(lines, [], false)

    if contexts == :none and not first? do
      {:error,
       "in \"#{@update}#{path}\", expected a @@ line to start the next hunk; got " <>
         inspect(hd(lines))}
    else
      {hunk, rest} = hunk_lines(rest, [])

      case chunk(contexts_list(contexts), hunk) do
        {:ok, chunk} -> chunks(rest, path, [chunk | chunks], false)
        {:error, reason} -> {:error, "in \"#{@update}#{path}\": #{reason}"}
      end
    end
  end

  defp contexts_list(:none), do: []
  defp contexts_list(contexts), do: contexts

  # `:none` when the hunk had no `@@` line at all, which only the first hunk of
  # a file may do; `[]` when it had one with no context text.
  defp headers(["@@" <> header | rest], contexts, _seen?) do
    headers(rest, context(String.trim(header), contexts), true)
  end

  defp headers(lines, _contexts, false), do: {:none, lines}
  defp headers(lines, contexts, true), do: {Enum.reverse(contexts), lines}

  defp context("", contexts), do: contexts

  defp context(header, contexts) do
    case Regex.run(@unified, header) do
      [_, ""] -> contexts
      [_, text] -> [text | contexts]
      nil -> [header |> String.trim_trailing("@@") |> String.trim() | contexts]
    end
  end

  defp hunk_lines([@end_of_file | rest], acc), do: {{Enum.reverse(acc), true}, rest}
  defp hunk_lines(["@@" <> _header | _rest] = rest, acc), do: {{Enum.reverse(acc), false}, rest}
  defp hunk_lines(["\\ " <> _note | rest], acc), do: hunk_lines(rest, acc)
  defp hunk_lines(["" | rest], acc), do: hunk_lines(rest, [{:context, ""} | acc])
  defp hunk_lines([" " <> text | rest], acc), do: hunk_lines(rest, [{:context, text} | acc])
  defp hunk_lines(["-" <> text | rest], acc), do: hunk_lines(rest, [{:remove, text} | acc])
  defp hunk_lines(["+" <> text | rest], acc), do: hunk_lines(rest, [{:add, text} | acc])
  defp hunk_lines([line | _rest], _acc), do: {{:bad, line}, []}
  defp hunk_lines([], acc), do: {{Enum.reverse(acc), false}, []}

  defp chunk(_contexts, {:bad, line}) do
    {:error,
     "unexpected line #{inspect(line)} in a hunk: every line starts with a space " <>
       "(context), - (remove) or + (add)"}
  end

  defp chunk(_contexts, {[], _end_of_file?}), do: {:error, "a hunk has no lines"}

  defp chunk(contexts, {lines, end_of_file?}) do
    old = for {kind, text} <- lines, kind in [:context, :remove], do: text
    new = for {kind, text} <- lines, kind in [:context, :add], do: text

    if Enum.all?(lines, &match?({:context, _text}, &1)),
      do: {:error, "a hunk has only context lines, so it changes nothing"},
      else: {:ok, %{contexts: contexts, old: old, new: new, end_of_file?: end_of_file?}}
  end

  defp path(line, prefix) do
    case line |> String.replace_prefix(prefix, "") |> String.trim() do
      "" -> {:error, "#{String.trim(prefix)} needs a path"}
      path -> {:ok, path}
    end
  end

  defp trim_trailing_blank(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
  end
end
