# Defined only when `ex_ratatui` is: a fenced block is highlighted through
# its NIF-backed highlighter, once, when the block closes. The recognition
# itself is pure and is tested without a terminal.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Blocks do
    @moduledoc """
    The Markdown blocks in a model's answer, recognised one closed line at a
    time.

    A streamed answer arrives in fragments that stop anywhere — in the middle
    of a word, after two of the three backticks that open a fence — so no line
    can be classified until the next one has started, and no block can be
    classified until its last line has. This module is built around that
    constraint rather than around a Markdown parser: `Lemieux.TUI` keeps the
    line being written as a raw row, calls `close/2` on it the moment a new
    line begins, and gets back the rows to draw in its place. A raw line that
    turns out to be a heading becomes a heading row; a table row joins the
    table beneath it; a closing fence re-highlights the whole block above it.
    The same walk over a finished answer (`rows/2`) is what a resumed
    transcript draws, so a block reads the same live and read back tomorrow.

    ## Every row has an exact height

    `Lemieux.TUI.Window` pins the viewport to the bottom by measuring rows,
    and `Lemieux.TUI.Selection` names a row by its distance from the newest
    one. Both are only right if every row's height is a function of the row
    and the pane width alone. That is why a fenced block is not handed to
    `ExRatatui.Widgets.Markdown` — a widget that reflows for itself cannot
    say how tall it is — and why a table is one stored row that
    `Lemieux.TUI.RichText` lays out into exactly its rows, rather than a
    widget that decides its own column widths at draw time.

    ## What is recognised

    Fenced code (```` ``` ```` and `~~~`, with the info string's first word as
    the language and `diff` drawn as a diff), pipe tables (a header when the
    second line is a delimiter row), block quotes, ATX headings, thematic
    breaks, and bullet and numbered list items. Inline bold, italic and code
    inside a paragraph, a heading, a quote or an item remain
    `Lemieux.TUI.RichText`'s. Nothing else is; a line this module does not
    recognise stays the paragraph text it was, which is the failure mode that
    costs nothing.

    ## What a code line looks like while it streams

    A line inside an open fence is a `:model_code` row with `nil` spans from
    the moment it starts, not a paragraph row that becomes code later. The
    difference is visible: a paragraph row parses `*` and `` ` `` as markup and
    collapses runs of spaces, so a line of code streamed as a paragraph
    flickered through italics and lost its indentation until it closed.

    Visualization fences (`a2ui` and `mermaid`) instead accumulate in one
    bounded `:model_drawing` row, whose info-string caption labels Drawing.
    `start_line/2` replaces that row as source arrives; `close/2` only compiles
    a matching closing fence. `finish/2` turns an interrupted drawing into a
    diagnostic. The original answer remains in the session, including source
    that this compact projection omits, for export and `/copy source`.
    """

    alias ExRatatui.CodeBlock
    alias ExRatatui.Style
    alias ExRatatui.Text.Span
    alias Lemieux.TUI.A2UI
    alias Lemieux.TUI.Diagrams
    alias Lemieux.TUI.Drawing
    alias Lemieux.TUI.Theme

    @typedoc "The first word of a fence's info string, lower-cased, or `nil`."
    @type language :: String.t() | nil

    @typedoc "How a table column is aligned, from its delimiter cell."
    @type alignment :: :left | :centre | :right

    @typedoc """
    A pipe table as one row.

    `rows` are oldest-first. `header` and `aligns` are `nil` until a delimiter
    row promotes the first row to a header; a table never gets one after that.
    """
    @type table :: %{
            header: [String.t()] | nil,
            aligns: [alignment()] | nil,
            rows: [[String.t()]]
          }

    @typedoc """
    A row of the model's answer.

      * `{:model, text}` — a paragraph line, or a line still being written.
      * `{:model_heading, level, text}` — an ATX heading, without its `#`s.
      * `{:model_quote, text}` — a block-quote line, without its `>`.
      * `{:model_rule, ""}` — a thematic break.
      * `{:model_item, indent, marker, text}` — a list item: its leading
        spaces, its marker (`-`, `*`, `+` or `1.`), and its text.
      * `{:model_fence, :open | :close, language, fence}` — a fence line, with
        the exact fence that opened or closed it.
      * `{:model_code, language, text, spans}` — a line inside a fence;
        `spans` is `nil` while the line is still being written.
      * `{:model_table, table}` — a whole pipe table.
      * `{:model_drawing, drawing}` — one open visualization placeholder.
      * `{:model_drawing_error, message}` — a compact rejected-drawing diagnostic.
    """
    @type row ::
            {:model, String.t()}
            | {:model_heading, 1..6, String.t()}
            | {:model_quote, String.t()}
            | {:model_rule, String.t()}
            | {:model_item, non_neg_integer(), String.t(), String.t()}
            | {:model_fence, :open | :close, language(), String.t()}
            | {:model_code, language(), String.t(), [Span.t()] | nil}
            | {:model_table, table()}
            | {:model_art, term(), String.t()}
            | {:model_ui, map()}
            | {:model_diagram, map()}
            | {:model_drawing, map()}
            | {:model_drawing_error, String.t()}

    # `\#`: a bare `#{` in a sigil would start an interpolation.
    @fence ~r/^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)/u
    @closing_fence ~r/^\s{0,3}(`{3,}|~{3,})\s*$/u
    @heading ~r/^(\#{1,6})\s+(.*?)\s*\#*\s*$/u
    @rule ~r/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/u
    @quote ~r/^\s{0,3}>\s?(.*)$/u
    @item ~r/^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$/u
    @table_row ~r/^\s*\|.*\|\s*$/u
    @delimiter_cell ~r/^:?-+:?$/u

    # Stands in for an escaped pipe while a table row is split on the others.
    @escaped_pipe <<0>>

    @doc """
    The row a new model line starts as, given the row beneath it.

    Inside an open fence — the row beneath is the fence or a line of its code
    — the line is code from its first character; anywhere else it is a
    paragraph line until `close/2` says otherwise.
    """
    @spec open(below :: term(), text :: String.t()) :: row()
    def open(below, text) when is_binary(text) do
      case fenced(below) do
        {:ok, language} -> {:model_code, language, code_text(text), nil}
        :error -> {:model, text}
      end
    end

    @doc "Streams more text onto the line being written."
    @spec extend(head :: row(), text :: String.t()) :: row()
    def extend({:model, answer}, text), do: {:model, answer <> text}

    def extend({:model_drawing, drawing}, text),
      do: {:model_drawing, Drawing.extend(drawing, text)}

    def extend({:model_code, language, answer, nil}, text),
      do: {:model_code, language, answer <> code_text(text), nil}

    @doc "Whether a row is a line still being written."
    @spec open?(row :: term()) :: boolean()
    def open?({:model, _text}), do: true
    def open?({:model_code, _language, _text, nil}), do: true
    def open?({:model_drawing, _drawing}), do: true
    def open?(_row), do: false

    @doc "Whether a row is part of the model's answer rather than somebody else's."
    @spec model_row?(row :: term()) :: boolean()
    def model_row?(row) when is_tuple(row) and tuple_size(row) >= 2 do
      elem(row, 0) in [
        :model,
        :model_heading,
        :model_quote,
        :model_rule,
        :model_item,
        :model_fence,
        :model_code,
        :model_table,
        :model_art,
        :model_ui,
        :model_diagram,
        :model_drawing,
        :model_drawing_error
      ]
    end

    def model_row?(_row), do: false

    @doc """
    Classifies the newest line now that it is complete.

    Takes the transcript newest-first and returns `{replaced, rows}`: how many
    rows to drop from the head, and the newest-first rows to put in their
    place. Usually that is one row for one. A table row also replaces the
    table beneath it, merged; a closing fence replaces every line of the block
    above it, highlighted as one source rather than a line at a time — which
    is what gets a heredoc or a multi-line string coloured correctly.

    `{0, []}` when the head is not a line being written, so a caller can close
    unconditionally before anything else is appended.
    """
    @spec close(newest_first :: [term()], theme :: Theme.t()) :: {non_neg_integer(), [row()]}
    def close([{:model_drawing, drawing} | _rest], %Theme{}) do
      with text when is_binary(text) <- drawing.current,
           {:ok, closing} <- closing_fence(text),
           true <- String.first(closing) == String.first(drawing.fence),
           true <- String.length(closing) >= String.length(drawing.fence) do
        result =
          if drawing.oversized?,
            do: {:error, Drawing.failure(drawing)},
            else: visualization(drawing.language, Drawing.source(drawing))

        replacement =
          case result do
            {:ok, rows} -> Enum.reverse(rows)
            {:error, message} -> [{:model_drawing_error, message}]
            :error -> [{:model_drawing_error, "This host cannot render this visualization."}]
          end

        {1, replacement}
      else
        _not_closed -> {0, []}
      end
    end

    def close([{:model_code, language, text, nil} | rest], %Theme{} = theme) do
      with {:ok, closing} <- closing_fence(text),
           {:ok, code, opener} <- block(rest, closing) do
        {length(code) + 2, closed_block(code, opener, closing, language, theme)}
      else
        :error -> {1, [{:model_code, language, text, highlight(text, language, theme)}]}
      end
    end

    def close([{:model, text} | rest], %Theme{}) do
      cond do
        Regex.match?(@fence, text) -> {1, [fence_row(text)]}
        Regex.match?(@table_row, text) -> table(text, rest)
        Regex.match?(@rule, text) -> {1, [{:model_rule, ""}]}
        true -> {1, [paragraph_row(text)]}
      end
    end

    def close(_rows, %Theme{}), do: {0, []}

    @doc "Starts the next logical line, replacing the single placeholder inside a drawing."
    @spec start_line(newest_first :: [term()], text :: String.t()) :: {non_neg_integer(), row()}
    def start_line([{:model_drawing, drawing} | _rest], text),
      do: {1, {:model_drawing, Drawing.next(drawing, text)}}

    def start_line(rows, text), do: {0, open(List.first(rows), text)}

    @doc "Finishes a model fragment, including an interrupted or unclosed visualization."
    @spec finish(newest_first :: [term()], theme :: Theme.t()) :: {non_neg_integer(), [row()]}
    def finish(rows, theme) do
      {count, replacement} = close(rows, theme)

      case replacement ++ Enum.drop(rows, count) do
        [{:model_drawing, drawing} | _rest] ->
          {1, [{:model_drawing_error, Drawing.failure(drawing)}]}

        _complete ->
          {count, replacement}
      end
    end

    @doc """
    The rows of a complete answer, oldest-first.

    The same `open/2` and `close/2` a streaming answer goes through, applied
    line by line, so that a transcript read back draws exactly what the
    screen drew as it arrived.
    """
    @spec rows(text :: String.t(), theme :: Theme.t()) :: [row()]
    def rows(text, %Theme{} = theme) when is_binary(text) do
      text
      |> String.split("\n")
      |> Enum.reduce([], fn line, acc ->
        acc = closed(acc, theme)
        {count, row} = start_line(acc, line)
        [row | Enum.drop(acc, count)]
      end)
      |> finished(theme)
      |> Enum.reverse()
    end

    defp finished(lines, theme) do
      {count, rows} = finish(lines, theme)
      rows ++ Enum.drop(lines, count)
    end

    defp closed(lines, theme) do
      case close(lines, theme) do
        {0, []} -> lines
        {count, rows} -> rows ++ Enum.drop(lines, count)
      end
    end

    defp fenced({:model_fence, :open, language, _fence}), do: {:ok, language}
    defp fenced({:model_code, language, _text, _spans}), do: {:ok, language}
    defp fenced(_row), do: :error

    defp fence_row(text) do
      [_whole, fence, info] = Regex.run(@fence, text)
      language = language(info)

      if language in ["a2ui", "mermaid"] do
        caption = Regex.replace(@fence, text, "") |> String.trim()
        {:model_drawing, Drawing.new(language, fence, caption)}
      else
        {:model_fence, :open, language, fence}
      end
    end

    defp closing_fence(text) do
      case Regex.run(@closing_fence, text) do
        [_whole, fence] -> {:ok, fence}
        nil -> :error
      end
    end

    # The block above a closing fence: its code rows oldest-first and the
    # fence that opened it. A closing fence has to be the opener's character
    # and at least as long, as Markdown has it, so a four-backtick block can
    # quote a three-backtick fence without ending.
    defp block(rows, closing), do: block(rows, closing, [])

    defp block([{:model_code, _language, _text, _spans} = row | rest], closing, code),
      do: block(rest, closing, [row | code])

    defp block([{:model_fence, :open, _language, fence} = opener | _rest], closing, code) do
      if String.first(fence) == String.first(closing) and
           String.length(closing) >= String.length(fence),
         do: {:ok, code, opener},
         else: :error
    end

    defp block(_rows, _closing, _code), do: :error

    defp closed_block(code, opener, closing, language, theme) do
      source = Enum.map_join(code, "\n", fn {:model_code, _language, text, _spans} -> text end)

      case visualization(language, source) do
        {:ok, rows} ->
          Enum.reverse(rows)

        :error ->
          highlighted_block(code, opener, closing, language, theme, source)

        {:error, message} ->
          [
            {:model_quote, "Diagram could not render: " <> message}
            | highlighted_block(code, opener, closing, language, theme, source)
          ]
      end
    end

    defp visualization("a2ui", source), do: A2UI.rows(source)
    defp visualization("mermaid", source), do: Diagrams.rows(source)
    defp visualization(_language, _source), do: :error

    defp highlighted_block(code, opener, closing, language, theme, source) do
      lines = highlight_lines(source, length(code), language, theme)

      highlighted =
        code
        |> Enum.zip(lines)
        |> Enum.map(fn {{:model_code, _language, text, _spans}, spans} ->
          {:model_code, language, text, spans}
        end)

      [{:model_fence, :close, language, closing} | Enum.reverse(highlighted)] ++ [opener]
    end

    # A table row joins the table beneath it. A delimiter row promotes the
    # one row above it to a header, and is otherwise the text it looks like:
    # a row of dashes with no header to describe is not a table.
    defp table(text, [{:model_table, table} | _rest]) do
      cells = cells(text)

      cond do
        delimiter?(cells) and table.header == nil and length(table.rows) == 1 ->
          [header] = table.rows
          {2, [{:model_table, %{header: header, aligns: aligns(cells), rows: []}}]}

        delimiter?(cells) ->
          {1, [paragraph_row(text)]}

        true ->
          {2, [{:model_table, %{table | rows: table.rows ++ [cells]}}]}
      end
    end

    defp table(text, _rest) do
      cells = cells(text)

      if delimiter?(cells),
        do: {1, [paragraph_row(text)]},
        else: {1, [{:model_table, %{header: nil, aligns: nil, rows: [cells]}}]}
    end

    defp paragraph_row(text) do
      cond do
        Regex.match?(@heading, text) -> heading_row(text)
        Regex.match?(@quote, text) -> quote_row(text)
        Regex.match?(@item, text) -> item_row(text)
        true -> {:model, text}
      end
    end

    defp heading_row(text) do
      [_whole, hashes, title] = Regex.run(@heading, text)
      {:model_heading, String.length(hashes), title}
    end

    defp quote_row(text) do
      [_whole, quoted] = Regex.run(@quote, text)
      {:model_quote, quoted}
    end

    defp item_row(text) do
      [_whole, indent, marker, item] = Regex.run(@item, text)
      {:model_item, String.length(indent), marker, item}
    end

    # Cells between the pipes, trimmed, with an escaped pipe kept as one.
    defp cells(text) do
      text
      |> String.trim()
      |> String.replace("\\|", @escaped_pipe)
      |> String.replace_prefix("|", "")
      |> String.replace_suffix("|", "")
      |> String.split("|")
      |> Enum.map(&(&1 |> String.trim() |> String.replace(@escaped_pipe, "|")))
    end

    defp delimiter?(cells),
      do: cells != [] and Enum.all?(cells, &Regex.match?(@delimiter_cell, &1))

    defp aligns(cells) do
      Enum.map(cells, fn cell ->
        case {String.starts_with?(cell, ":"), String.ends_with?(cell, ":")} do
          {true, true} -> :centre
          {false, true} -> :right
          _left -> :left
        end
      end)
    end

    # The first word of the info string, as the highlighter will look it up,
    # with the spellings people actually type folded onto the ones it knows.
    defp language(info) do
      case info |> String.split(~r/[\s,{]/u, parts: 2) |> List.first() |> String.downcase() do
        "" -> nil
        name -> alias_language(name)
      end
    end

    defp alias_language(name) when name in ["sh", "shell", "zsh", "console", "shell-session"],
      do: "bash"

    defp alias_language(name) when name in ["text", "txt", "plain", "plaintext"], do: nil
    defp alias_language("patch"), do: "diff"
    defp alias_language(name) when name in ["heex", "eex", "leex"], do: "elixir"
    defp alias_language("jsx"), do: "javascript"
    defp alias_language("tsx"), do: "typescript"
    defp alias_language(name), do: name

    # A row is one line and a span cannot hold a newline or, usefully, a tab:
    # the renderer counts graphemes to wrap, and a tab is one grapheme that
    # the terminal draws as up to eight cells.
    defp code_text(text) do
      text
      |> String.replace("\r", "")
      |> String.replace("\t", "    ")
    end

    defp highlight_lines(source, count, language, theme) do
      case whole_highlight(source, language, theme) do
        spans when is_list(spans) and length(spans) == count ->
          spans

        _line_by_line ->
          source |> String.split("\n") |> Enum.map(&highlight(&1, language, theme))
      end
    end

    # The whole block as one source, so that a construct spanning lines is
    # coloured as what it is. `nil` when the highlighter is not being asked —
    # a diff is drawn by its own rule, and the mono theme draws no colour.
    defp whole_highlight(_source, "diff", _theme), do: nil
    defp whole_highlight(_source, _language, %Theme{blocks: %{code_theme: nil}}), do: nil
    defp whole_highlight("", _language, _theme), do: nil

    defp whole_highlight(source, language, theme) do
      source
      |> CodeBlock.highlight(language, theme.blocks.code_theme)
      |> Enum.map(&unterminated(&1.spans))
    end

    defp highlight("", _language, _theme), do: []

    defp highlight(text, "diff", theme), do: diff_spans(text, theme)

    defp highlight(text, _language, %Theme{blocks: %{code_theme: nil}}), do: [Span.new(text)]

    defp highlight(text, language, theme) do
      case CodeBlock.highlight(text, language, theme.blocks.code_theme) do
        [line | _rest] -> unterminated(line.spans)
        [] -> [Span.new(text)]
      end
    end

    defp diff_spans("+" <> _rest = text, theme),
      do: [Span.new(text, style: %Style{fg: theme.blocks.add})]

    defp diff_spans("-" <> _rest = text, theme),
      do: [Span.new(text, style: %Style{fg: theme.blocks.delete})]

    defp diff_spans("@@" <> _rest = text, theme),
      do: [Span.new(text, style: %Style{fg: theme.blocks.code})]

    defp diff_spans(text, theme), do: [Span.new(text, style: %Style{fg: theme.text.muted})]

    # The highlighter leaves each line's newline on its last span, and a span
    # with a newline in it raises inside the draw loop. Same as
    # `Lemieux.TUI.ToolText`, for the same reason.
    defp unterminated(spans) do
      spans
      |> Enum.map(&%{&1 | content: String.replace(&1.content, "\n", "")})
      |> Enum.reject(&(&1.content == ""))
    end
  end
end
