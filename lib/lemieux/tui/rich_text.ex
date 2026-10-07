# Like `Lemieux.TUI`, this adapter exists only when the optional terminal UI
# dependency does. Keeping the guard here prevents the library's core from
# acquiring a dependency on a Rust NIF that embedders did not ask for.
if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.RichText do
    @moduledoc """
    Turns transcript rows into wrapped `ExRatatui` rich text.

    Model rows understand a deliberately small inline vocabulary: bold,
    italic, and inline code. It is small because this module also owns exact
    wrapping; pretending to implement all of Markdown would create a second,
    subtly different Markdown renderer beside `ExRatatui.Widgets.Markdown`.
    The block vocabulary — headings, quotes, rules, list items, fenced code
    and tables — is `Lemieux.TUI.Blocks`'s to recognise and this module's to
    draw, and every block row here has an exact height for the same reason
    every other row does: `Lemieux.TUI.Window` pins the viewport by counting
    rows, and a renderer that could not say how tall a row is would make the
    pane drift while the model streams.

    User input is always literal. Rendering what somebody typed as markup
    would make the transcript differ from the text actually sent to the
    session. Lemieux's own rows use semantic colours so questions, tool
    activity, and errors can be found without reading every line.

    ## Colours come from a theme

    Every colour is a slot of `Lemieux.TUI.Theme`, named by what the row
    means rather than by hue, so the transcript stays legible across palettes:
    an edit is `theme.tools.edit` on a dark terminal, a light one, or none. The
    default is the palette the screen has always drawn. Callers that pass no
    theme get it.

    ## Copying stays clean

    Terminal-native selection copies cells exactly as drawn, so nothing here
    puts a glyph beside code that would end up in a pasted command: a code
    row is tinted, not gutter-marked, and starts in the first column.
    """

    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Width

    @typedoc """
    A part of the context window, as `/context` colours it.

    The keys are `Lemieux.Context.composition/2`'s, and the mapping to
    colours is here rather than there because a token count has no colour —
    only a screen does.
    """
    @type context_key :: :system | :tools | :conversation | :sent | :output | :free

    @typedoc """
    One delegated child, as its own row.

    `activity` is the last tool it announced and `count` how many times in a
    row, so a stuck scout is one line with a number rather than a screenful
    of identical reads. `text` is that call rendered for a person.
    """
    @type child :: %{
            id: String.t(),
            name: String.t(),
            kind: String.t() | nil,
            goal: String.t() | nil,
            status: String.t(),
            activity: String.t() | nil,
            count: pos_integer(),
            text: String.t() | nil
          }

    @typedoc "A row selected for the visible transcript window."
    @type row ::
            {:lmx | :you | :space | :summary | :notice | :interrupted | :verify | :hook,
             String.t()}
            | {:activity, String.t(), String.t()}
            | Blocks.row()
            | {:subagent_child, child()}
            | {:context_bar, [{context_key(), float()}]}
            | {:context_key, [{context_key(), String.t()}]}
            | Lemieux.TUI.ToolText.row()

    # Too narrow for a hanging indent to leave room for words: below this the
    # gutter is drawn inline and the text wraps under it like any other.
    @hanging_minimum 6

    # A table cell is never squeezed below this; the ellipsis needs a cell.
    @cell_minimum 3

    @doc """
    Renders rows as rich-text lines no wider than `width` visible graphemes.

    Wrapping happens after inline markers have been removed, and styles are
    carried across a wrap. Unclosed markers are rendered literally.
    """
    @spec lines(rows :: [row()], width :: pos_integer(), theme :: Theme.t()) :: [Line.t()]
    def lines(rows, width, theme \\ Theme.default())

    def lines(rows, width, %Theme{} = theme)
        when is_list(rows) and is_integer(width) and width > 0 do
      Enum.flat_map(rows, fn
        {:summary, text} ->
          summary(text, width, theme)

        {:notice, text} ->
          notice(text, width, theme)

        {:tool_output, _id, _position, _tone, _text} = row ->
          styled(row, theme) |> preserve(width)

        {:tool_code, _id, _change, _spans} = row ->
          styled(row, theme) |> preserve(width)

        {:tool_code, _id, _change, _number, _spans} = row ->
          styled(row, theme) |> preserve(width)

        {:tool_heading, _id, :run, _verb, _subject, _spans} = row ->
          styled(row, theme) |> preserve(width)

        {:activity, _glyph, _text} = row ->
          activity_lines(row, width, theme)

        {:subagent_child, child} ->
          child_lines(child, width, theme)

        {:context_bar, segments} ->
          context_bar(segments, width, theme)

        {:context_key, entries} ->
          context_key(entries, width, theme)

        {:model_heading, level, text} ->
          heading(level, text, width, theme)

        {:model_quote, text} ->
          quote_lines(text, width, theme)

        {:model_rule, _text} ->
          [rule(width, theme)]

        {:model_item, indent, marker, text} ->
          item(indent, marker, text, width, theme)

        {:model_fence, edge, language, _fence} ->
          [fence(edge, language, width, theme)]

        {:model_code, _language, text, spans} ->
          code(text, spans, width, theme)

        {:model_table, table} ->
          table(table, width, theme)

        {:steer, status, text} ->
          steer_lines(status, text, width, theme)

        row ->
          styled(row, theme) |> wrap(width)
      end)
    end

    defp styled({:model, text}, theme), do: parse_inline(text, %Style{}, theme)
    defp styled({:space, ""}, _theme), do: [{"", %Style{}}]
    defp styled({:compact_space, _tick}, _theme), do: [{"", %Style{}}]

    defp styled({:you, text}, theme) do
      [
        {"› ", %Style{fg: theme.voices.you, modifiers: [:bold]}},
        {text, %Style{fg: theme.voices.you_text}}
      ]
    end

    defp styled({:lmx, text}, theme), do: [{text, lmx_style(text, theme)}]

    # What the model had said when its stream broke off: on the record, dimmed
    # and marked, so it is not read as the answer that follows it.
    defp styled({:interrupted, text}, theme),
      do: [
        {"⎿ ", %Style{fg: theme.text.muted}},
        {text, %Style{fg: theme.text.muted, modifiers: [:italic, :dim]}}
      ]

    # A check the verify extension ran and reported to the model: said by the
    # harness, not by the person, so it is drawn in the harness's voice with
    # its marker, not as a `›` line somebody typed.
    defp styled({:verify, text}, theme),
      do: [
        {"✓ ", %Style{fg: theme.voices.activity, modifiers: [:bold]}},
        {text, %Style{fg: theme.voices.activity}}
      ]

    # Any other stop hook sending the model back to work — an unfinished plan,
    # an answer cut off, a host's own rule — in the same voice, with a mark
    # that says the turn goes round again.
    defp styled({:hook, text}, theme),
      do: [
        {"↻ ", %Style{fg: theme.voices.activity, modifiers: [:bold]}},
        {text, %Style{fg: theme.voices.activity}}
      ]

    defp styled({:compacting, _tick, text}, theme),
      do: [{text, %Style{fg: theme.voices.activity, modifiers: [:bold]}}]

    defp styled({:compact_result, text}, theme),
      do: [{text, %Style{fg: theme.voices.activity, modifiers: [:bold]}}]

    defp styled({:tool_heading, _id, kind, verb, subject}, theme) do
      accent = accent(kind, theme)

      [{"• ", %Style{fg: accent}}, {verb, %Style{fg: accent, modifiers: [:bold]}}] ++
        subject_span(subject, theme)
    end

    defp styled({:tool_heading, _id, :run, verb, subject, spans}, theme) do
      heading = styled({:tool_heading, nil, :run, verb, ""}, theme)
      gap = if subject == "", do: [], else: [{" ", %Style{}}]

      heading ++ gap ++ Enum.map(spans, &{&1.content, &1.style})
    end

    defp styled({:tool_detail, _id, :explore, text}, theme),
      do: [
        {"  └ ", gutter_style(theme)},
        {text, %Style{fg: accent(:explore, theme), modifiers: [:dim]}}
      ]

    defp styled({:tool_detail, _id, _kind, text}, theme),
      do: [{"  └ ", gutter_style(theme)}, {text, %Style{fg: theme.text.muted}}]

    defp styled({:tool_output, _id, :first, tone, text}, theme),
      do: [{"  └ ", gutter_style(theme)}, {text, output_style(tone, theme)}]

    defp styled({:tool_output, _id, :rest, tone, text}, theme),
      do: [{"    ", %Style{}}, {text, output_style(tone, theme)}]

    defp styled({:tool_question, _id, text}, theme),
      do: [{"? ", question_style(theme)}, {text, question_style(theme)}]

    defp styled({:tool_option, _id, index, label, description}, theme) do
      [
        {"  #{index}. ", %Style{fg: theme.voices.question}},
        {label, %Style{fg: theme.text.plain, modifiers: [:bold]}}
      ] ++
        option_description(description, theme)
    end

    defp styled({:tool_answer, _id, text}, theme) do
      [
        {"› ", %Style{fg: theme.voices.you, modifiers: [:bold]}},
        {text, %Style{fg: theme.voices.you_text}}
      ]
    end

    defp styled({:tool_code, _id, change, spans}, theme) do
      {marker, style} = diff_marker(change, theme)

      [
        {"  #{marker} ", style}
        | Enum.map(spans, &{&1.content, diff_style(&1.style, change, theme)})
      ]
    end

    # A diff line: its number in the file, right-aligned in a gutter of its
    # own, then the change marker, then the code. Context lines are drawn
    # plain, so the eye goes to the tinted ones.
    defp styled({:tool_code, _id, change, number, spans}, theme) do
      {marker, style} = diff_marker(change, theme)
      gutter = if number, do: String.pad_leading(Integer.to_string(number), 4), else: "    "

      [
        {"  #{gutter} ", %Style{fg: theme.text.muted}},
        {"#{marker} ", style}
        | Enum.map(spans, &{&1.content, diff_style(&1.style, change, theme)})
      ]
    end

    defp steer_lines(status, text, width, theme) do
      border = %Style{fg: theme.text.muted}
      content = %Style{fg: theme.voices.you_text}
      title = "╭─ Steer · #{steer_status(status)} "
      title_style = %Style{fg: theme.text.muted, modifiers: [:italic]}

      body =
        text
        |> String.split("\n")
        |> Enum.flat_map(fn part ->
          hanging([{part, content}], {"│ ", border}, {"│ ", border}, width)
        end)

      [
        Line.new([
          Span.new(title, style: title_style),
          Span.new(String.duplicate("─", max(width - String.length(title), 0)), style: border)
        ])
        | body
      ] ++
        [Line.new([Span.new(ruled("╰", width), style: border)])]
    end

    # Says how to take it back while that is still possible: the key that
    # used to be the only way (Cmd+Z) never reaches most terminals.
    defp steer_status(:pending), do: "queued for next model request · /unsteer takes it back"
    defp steer_status(:sent), do: "included in model request"
    defp steer_status(:not_sent), do: "turn stopped before delivery"

    # The live row, drawn under everything the turn has said so far — see
    # `Lemieux.TUI.Activity` for why it is there rather than on the status line.
    # Not dimmed, unlike a delegated child's activity in the same colour: while
    # a turn is running this is the row being watched. The glyph is bold so it
    # still reads as the moving part under `mono/0`, which has no colours to
    # tell it apart with, and the hanging indent keeps a phase that wrapped
    # under the sentence rather than under the spinner.
    defp activity_lines({:activity, glyph, text}, width, theme) do
      style = %Style{fg: theme.voices.activity}

      hanging(
        [{text, style}],
        {glyph <> " ", %Style{fg: theme.voices.activity, modifiers: [:bold]}},
        {"  ", style},
        width
      )
    end

    # Something about the workspace the person should see but was not asking about.
    # Amber and marked rather than folded into the grey `:lmx` voice, because these
    # arrive in a block before anything has happened and would read as part of the
    # greeting. A notice is "what was found; what to pass about it", and those are
    # two things to a reader — wrapped into one amber paragraph they read as
    # something to skip, which for a warning is the whole failure.
    defp notice(text, width, theme) do
      case String.split(text, "; ", parts: 2) do
        [found, remedy] ->
          notice_row("⚠ ", found, width, theme) ++ notice_row("↳ ", remedy, width, theme, [:dim])

        [found] ->
          notice_row("⚠ ", found, width, theme)
      end
    end

    # The gutter is a glyph rather than indentation because `wrap/2` collapses
    # leading whitespace — and a glyph is what aligns the continuation under
    # the notice it belongs to anyway, both being two cells wide.
    defp notice_row(gutter, text, width, theme, modifiers \\ [:bold]) do
      wrap(
        [
          {gutter, %Style{fg: theme.voices.notice, modifiers: modifiers}},
          {text, %Style{fg: theme.voices.notice}}
        ],
        width
      )
    end

    defp summary(text, width, theme) do
      prefix = "── #{text} "
      style = output_style(:ok, theme)

      prefix
      |> then(&[{&1, style}])
      |> wrap(width)
      |> close_rule(width, style)
    end

    # A heading is its text in the heading colour and bold; the top level is
    # underlined as well, because a screen that draws `#` glyphs is drawing
    # the source of a document rather than the document. The level otherwise
    # changes nothing: a terminal has no larger type to set a title in.
    defp heading(level, text, width, theme) do
      modifiers = if level == 1, do: [:bold, :underlined], else: [:bold]

      text
      |> parse_inline(%Style{fg: theme.blocks.heading, modifiers: modifiers}, theme)
      |> wrap(width)
    end

    # A bar down the left and the text set in from it on every row, which is
    # what makes a quoted paragraph read as one thing rather than as a first
    # line with a mark on it.
    defp quote_lines(text, width, theme) do
      bar = {"▎ ", %Style{fg: theme.blocks.quote}}

      text
      |> parse_inline(%Style{fg: theme.text.muted, modifiers: [:italic]}, theme)
      |> hanging(bar, bar, width)
    end

    defp rule(width, theme),
      do: Line.new([Span.new(String.duplicate("─", width), style: %Style{fg: theme.blocks.rule})])

    # The marker on the first row and the continuation rows set in under the
    # text, not under the marker. `-`, `*` and `+` all draw as a bullet; a
    # number keeps its number, because `3.` is information and `•` is not.
    defp item(indent, marker, text, width, theme) do
      lead = String.duplicate(" ", indent)
      bullet = if marker in ["-", "*", "+"], do: "•", else: marker
      first = {lead <> bullet <> " ", %Style{fg: theme.text.gutter}}
      rest = {String.duplicate(" ", String.length(lead <> bullet) + 1), %Style{}}

      text
      |> parse_inline(%Style{}, theme)
      |> hanging(first, rest, width)
    end

    # Rules above and below a block, the top one carrying the language, so
    # the block is delimited on a terminal that draws no background tint —
    # and on the mono theme, which draws none by design.
    defp fence(:open, language, width, theme) do
      label = if language, do: "╭─ #{language} ", else: "╭"
      Line.new([Span.new(ruled(label, width), style: %Style{fg: theme.blocks.rule})])
    end

    defp fence(:close, _language, width, theme),
      do: Line.new([Span.new(ruled("╰", width), style: %Style{fg: theme.blocks.rule})])

    defp ruled(text, width) do
      length = String.length(text)

      if length >= width,
        do: String.slice(text, 0, width),
        else: text <> String.duplicate("─", width - length)
    end

    # Preserved rather than wrapped: indentation is the code. Tinted rather
    # than marked, so a copied block is the block. The tint replaces whatever
    # background the highlighter's own theme painted, so a line still being
    # written, an empty line and a highlighted one are one colour.
    defp code(text, nil, width, theme),
      do: preserve([{text, %Style{bg: theme.blocks.code_bg}}], width)

    defp code(_text, spans, width, theme) do
      spans
      |> Enum.map(&{&1.content, %{&1.style | bg: theme.blocks.code_bg}})
      |> preserve(width)
    end

    # One screen row per table row, always: columns take their natural width when it
    # fits and are squeezed from the widest down when it does not, with a truncated
    # cell ending in an ellipsis. That is what lets a table sit in a viewport that
    # counts rows.
    defp table(%{header: header, aligns: aligns, rows: rows}, width, theme) do
      all = if header, do: [header | rows], else: rows
      columns = all |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

      if columns == 0 do
        [line([], %Style{})]
      else
        aligns = pad_list(aligns || [], columns, :left)
        cells = Enum.map(all, &table_cells(&1, columns, theme))
        widths = cells |> natural_widths(columns) |> fit_widths(width - 2 * (columns - 1))

        {head, body} = if header, do: Enum.split(cells, 1), else: {[], cells}

        Enum.map(head, &table_row(&1, widths, aligns, width, [:bold])) ++
          header_rule(header, widths, width, theme) ++
          Enum.map(body, &table_row(&1, widths, aligns, width, []))
      end
    end

    defp header_rule(nil, _widths, _width, _theme), do: []

    defp header_rule(_header, widths, width, theme) do
      text = Enum.map_join(widths, "  ", &String.duplicate("─", &1))
      [Line.new([Span.new(String.slice(text, 0, width), style: %Style{fg: theme.blocks.rule})])]
    end

    # Each cell as styled graphemes, inline markup already applied, so a cell
    # of `` `mix test` `` is measured and padded as eight characters and not
    # as ten.
    defp table_cells(row, columns, theme) do
      row
      |> pad_list(columns, "")
      |> Enum.map(fn cell ->
        cell
        |> parse_inline(%Style{fg: theme.text.plain}, theme)
        |> chars()
        |> collapse_whitespace()
      end)
    end

    # Widths, clipping and padding are all in columns rather than graphemes,
    # for the reason `Lemieux.TUI.Width` gives: a cell of Chinese measured by
    # its grapheme count pushed every column after it right, and the end of
    # the row off the screen.
    defp natural_widths(cells, columns) do
      for column <- 0..(columns - 1) do
        cells
        |> Enum.map(&breadth(Enum.at(&1, column)))
        |> Enum.max(fn -> 1 end)
        |> max(1)
      end
    end

    defp breadth(chars), do: Enum.reduce(chars, 0, &(&2 + Width.grapheme(elem(&1, 0))))

    # Shrinks the widest column first, one cell at a time, until the table
    # fits or every column is at the minimum — at which point the row is
    # clipped by `table_row/5` and the table is still one row per row.
    defp fit_widths(widths, available) do
      if Enum.sum(widths) <= available or Enum.all?(widths, &(&1 <= @cell_minimum)) do
        widths
      else
        widest = widths |> Enum.with_index() |> Enum.max_by(fn {w, _i} -> w end) |> elem(1)

        widths
        |> List.update_at(widest, &(&1 - 1))
        |> fit_widths(available)
      end
    end

    defp table_row(cells, widths, aligns, width, modifiers) do
      separator = {"  ", %Style{}}

      cells
      |> Enum.zip(Enum.zip(widths, aligns))
      |> Enum.map(fn {chars, {cell_width, align}} ->
        chars |> clip(cell_width) |> aligned(cell_width, align) |> emphasised(modifiers)
      end)
      |> Enum.intersperse([separator])
      |> List.flatten()
      |> then(&Enum.take(&1, fitting(&1, width)))
      |> line(%Style{})
    end

    defp clip(chars, cell_width) do
      if breadth(chars) <= cell_width do
        chars
      else
        # Room for the ellipsis; a wide character that would straddle the
        # edge goes whole, and the padding makes up the column it leaves.
        keep = if cell_width > 1, do: fitting(chars, cell_width - 1), else: 0
        {kept, [{_char, style} | _rest]} = Enum.split(chars, keep)
        kept ++ [{"…", style}]
      end
    end

    defp aligned(chars, cell_width, align) do
      missing = max(cell_width - breadth(chars), 0)
      pad = fn count -> List.duplicate({" ", %Style{}}, count) end

      case align do
        :right -> pad.(missing) ++ chars
        :centre -> pad.(div(missing, 2)) ++ chars ++ pad.(missing - div(missing, 2))
        _left -> chars ++ pad.(missing)
      end
    end

    defp emphasised(chars, []), do: chars

    defp emphasised(chars, modifiers),
      do: Enum.map(chars, fn {char, style} -> {char, modifiers(style, modifiers)} end)

    defp pad_list(list, length, _filler) when length(list) >= length, do: Enum.take(list, length)
    defp pad_list(list, length, filler), do: list ++ List.duplicate(filler, length - length(list))

    # `█ label · █ label · …`, packed onto as many lines as it takes. Not `wrap/2`:
    # five bands with their token counts do not fit one eighty-column line, and
    # breaking on whitespace puts `free` at the end of one line and `181.5k` at the
    # start of the next, which reads as a sixth band with no name.
    defp context_key(entries, width, theme) do
      entries
      |> Enum.map(fn {key, label} -> {context_glyph(key) <> " " <> label, key} end)
      |> packed(width, [], [])
      |> Enum.map(&Line.new(spans(&1, theme)))
    end

    defp packed([], _width, [], lines), do: Enum.reverse(lines)
    defp packed([], _width, current, lines), do: packed([], 0, [], [current | lines])

    defp packed([{text, key} | rest], width, current, lines) do
      separator = if current == [], do: "", else: " · "
      grown = used(current) + String.length(separator) + String.length(text)

      if current != [] and grown > width,
        do: packed([{text, key} | rest], width, [], [current | lines]),
        else: packed(rest, width, current ++ [{separator, text, key}], lines)
    end

    defp used(current),
      do:
        Enum.reduce(current, 0, fn {separator, text, _key}, total ->
          total + String.length(separator) + String.length(text)
        end)

    # One span per entry rather than per glyph, so the swatch carries the
    # band's colour and the label stays readable beside it.
    defp spans(current, theme) do
      Enum.flat_map(current, fn {separator, text, key} ->
        {glyph, label} = String.split_at(text, 2)

        [
          Span.new(separator, style: gutter_style(theme)),
          Span.new(glyph, style: %Style{fg: context_colour(key, theme)}),
          Span.new(label, style: %Style{fg: theme.text.muted})
        ]
      end)
    end

    # A child is one or two lines: what it is and how it is going, then what it is
    # doing right now indented under that. Two lines rather than one, because the
    # second changes several times a second while the first does not, and a row that
    # reflowed on every tool call would be unreadable next to its siblings.
    defp child_lines(child, width, theme) do
      wrap(headline(child, theme), width) ++ activity(child, width, theme)
    end

    defp headline(child, theme) do
      [
        {"├─ ", gutter_style(theme)},
        {child.name, %Style{fg: theme.children.name, modifiers: [:bold]}},
        {" · ", gutter_style(theme)},
        {child.status, status_style(child.status, theme)}
      ] ++ goal(child, theme)
    end

    # The brief, which is the only thing on the row that says *why* this
    # child exists. Dimmed, because the name and the status are what a person
    # scans for once they know what the delegation was.
    defp goal(%{goal: goal}, theme) when is_binary(goal) and goal != "",
      do: [{" · ", gutter_style(theme)}, {goal, %Style{fg: theme.text.muted, modifiers: [:dim]}}]

    defp goal(_child, _theme), do: []

    defp activity(%{text: text, count: count}, width, theme)
         when is_binary(text) and text != "" do
      suffix = if count > 1, do: " ×#{count}", else: ""

      wrap(
        [
          # One space, not two: `wrap/2` collapses runs of whitespace, so a
          # wider indent renders as this one anyway and the code would be
          # describing something that never reaches the screen.
          {"│ └ ", gutter_style(theme)},
          {text <> suffix, %Style{fg: theme.voices.activity, modifiers: [:dim]}}
        ],
        width
      )
    end

    defp activity(_child, _width, _theme), do: []

    # The statuses a coordinator reports, coloured by whether anybody needs to
    # do something about them. `budget_exhausted` is yellow rather than red:
    # the cap did its job, which is not a failure.
    defp status_style(status, theme) when status in ["failed", "timeout"],
      do: %Style{fg: theme.children.fail, modifiers: [:bold]}

    defp status_style(status, theme)
         when status in ["cancelled", "cancelling", "budget_exhausted", "stalled"],
         do: %Style{fg: theme.children.warn}

    defp status_style("ok", theme), do: %Style{fg: theme.children.ok}
    defp status_style(_status, theme), do: %Style{fg: theme.text.muted, modifiers: [:dim]}

    # Built rather than wrapped: the bar is one line by definition, it has to
    # tile the pane exactly, and `wrap/2` collapses runs of whitespace — which
    # is most of what a bar is.
    defp context_bar(segments, width, theme) do
      spans =
        segments
        |> cells(width)
        |> Enum.reject(fn {_key, cells} -> cells <= 0 end)
        |> Enum.map(fn {key, cells} ->
          Span.new(String.duplicate(context_glyph(key), cells),
            style: %Style{fg: context_colour(key, theme)}
          )
        end)

      [Line.new(spans)]
    end

    # Floors every band and hands the cells rounding left over to the largest, where
    # a cell is least visible. A band under one cell draws as nothing and is named in
    # the legend anyway, which is the honest rendering of "too small to see" and
    # better than rounding five of them up into a bar wider than the pane.
    defp cells(segments, width) do
      {counts, used} =
        Enum.map_reduce(segments, 0, fn {key, fraction}, used ->
          cells = fraction |> Kernel.*(width) |> trunc() |> max(0) |> min(width)

          {{key, fraction, cells}, used + cells}
        end)

      counts
      |> pad(width - used)
      |> Enum.map(fn {key, _fraction, cells} -> {key, cells} end)
    end

    defp pad(counts, remaining) when remaining <= 0, do: counts

    defp pad([], _remaining), do: []

    # By fraction rather than by the floored cells: three equal bands floor to
    # the same number and the first of them is not the largest, it is merely
    # first.
    defp pad(counts, remaining) do
      largest =
        counts
        |> Enum.with_index()
        |> Enum.max_by(fn {{_key, fraction, _cells}, _index} -> fraction end)
        |> elem(1)

      List.update_at(counts, largest, fn {key, fraction, cells} ->
        {key, fraction, cells + remaining}
      end)
    end

    # Green for the prompt the harness wrote, red for the tool schemas it
    # attached, blue for the conversation itself, magenta for the answer, and
    # the terminal's dimmest grey for what is still free.
    defp context_colour(:system, theme), do: theme.context.system
    defp context_colour(:tools, theme), do: theme.context.tools
    defp context_colour(:conversation, theme), do: theme.context.conversation
    defp context_colour(:sent, theme), do: theme.context.conversation
    defp context_colour(:output, theme), do: theme.context.output
    defp context_colour(_free, theme), do: theme.context.free

    # Two glyphs, not one, so the bar still reads on a terminal that lost the
    # palette — and so the legend's swatch says which band is the empty one.
    defp context_glyph(:free), do: "░"
    defp context_glyph(_key), do: "█"

    defp close_rule(lines, width, style) do
      {last, rest} = Elixir.List.pop_at(lines, -1)
      used = Enum.reduce(last.spans, 0, fn span, total -> total + Width.of(span.content) end)
      available = max(width - used, 0)

      suffix =
        case available do
          0 -> ""
          1 -> "─"
          amount -> " " <> String.duplicate("─", amount - 1)
        end

      rest ++ [%{last | spans: last.spans ++ [%Span{content: suffix, style: style}]}]
    end

    # Tool activity is three tiers: the heading names the call, the detail names its
    # arguments, and the output is what came back. Only the gutter that draws the
    # tier is the gutter colour; text never is. `:dark_gray` *with* `:dim` is two
    # reductions stacked on the darkest colour a terminal renders as visible, and on
    # a dark background the result was text present on screen and not readable.
    defp output_style(:error, theme), do: %Style{fg: theme.text.error}
    defp output_style(_tone, theme), do: %Style{fg: theme.text.muted, modifiers: [:dim]}
    defp gutter_style(theme), do: %Style{fg: theme.text.gutter}
    defp question_style(theme), do: %Style{fg: theme.voices.question, modifiers: [:bold]}

    # One colour per kind of work, so a screenful of tool activity can be scanned
    # rather than read. The split that matters is side effects: exploration recedes
    # in blue, a command that ran is yellow, and anything that changed a file is
    # green. Elixir evaluation borrows the magenta the pane border uses for Elixir
    # mode, so the two agree about what that colour means. A kind these clauses
    # do not name is one a `Lemieux.TUI.Renderer` brought with it, and it is
    # drawn plain rather than refused: a renderer reusing a kind above borrows
    # its colour, and one inventing a kind still gets a legible heading.
    defp accent(:explore, theme), do: theme.tools.explore
    defp accent(:search, theme), do: theme.tools.search
    defp accent(:run, theme), do: theme.tools.run
    defp accent(:edit, theme), do: theme.tools.edit
    defp accent(:write, theme), do: theme.tools.write
    defp accent(:eval, theme), do: theme.tools.eval
    # An approval card is a question put to the person, so it borrows the
    # question's colour rather than a tool's: what it asks is whether the
    # tool may run at all.
    defp accent(:approval, theme), do: theme.voices.question
    defp accent(_kind, theme), do: theme.text.plain

    # The subject is the part worth reading twice — the path, the command, the
    # query — so it stays plain against the coloured verb rather than
    # competing with it.
    defp subject_span("", _theme), do: []
    defp subject_span(subject, theme), do: [{" " <> subject, %Style{fg: theme.text.plain}}]

    defp option_description(nil, _theme), do: []

    defp option_description(description, theme) when is_binary(description),
      do: [{" — #{description}", %Style{fg: theme.text.muted, modifiers: [:dim]}}]

    defp diff_marker(:add, theme), do: {"+", %Style{fg: theme.blocks.add, modifiers: [:bold]}}

    defp diff_marker(:delete, theme),
      do: {"-", %Style{fg: theme.blocks.delete, modifiers: [:bold]}}

    defp diff_marker(:context, theme), do: {" ", %Style{fg: theme.text.muted}}

    defp diff_style(style, :add, theme), do: %{style | bg: theme.blocks.add_bg}
    defp diff_style(style, :delete, theme), do: %{style | bg: theme.blocks.delete_bg}
    defp diff_style(style, :context, _theme), do: %{style | bg: nil}

    defp lmx_style(text, theme) do
      cond do
        # A cancellation is the one thing here somebody did on purpose and
        # then has to find again in the scrollback — how far the turn got
        # before it stopped is the next question, and a grey italic line the
        # same colour as every other remark is not findable.
        String.starts_with?(text, ["error:", "stopped:", "cancelled", "— cancelled"]) ->
          %Style{fg: theme.voices.alert, modifiers: [:bold]}

        String.starts_with?(text, "?") ->
          %Style{fg: theme.voices.question, modifiers: [:bold]}

        text |> String.trim_leading() |> String.starts_with?("·") ->
          %Style{fg: theme.voices.activity, modifiers: [:dim]}

        true ->
          %Style{fg: theme.voices.remark, modifiers: [:italic]}
      end
    end

    defp parse_inline("", style, _theme), do: [{"", style}]
    defp parse_inline(text, style, theme), do: parse_next(text, style, theme)

    defp parse_next("", _style, _theme), do: []

    @markdown_link ~r/\[([^\]\n]+)\]\((<?[^\s)>]+>?)(?:\s+"[^"]*")?\)/
    @bare_url ~r/(?:https?:\/\/|file:\/\/)[^\s<>()\[\]]+/
    @local_path ~r/(?<![\w:])(?:\.{1,2}\/|~\/|\/|[\w.-]+\/)[\w.\/-]*\.[[:alnum:]_-]+(?::\d+(?::\d+)?)?/

    defp parse_next(text, style, theme) do
      case next_marker(text) do
        nil ->
          [{text, style}]

        {index, {:link, length, label, destination}} ->
          <<plain::binary-size(^index), rest::binary>> = text
          tail = binary_part(rest, length, byte_size(rest) - length)
          target = String.trim(destination, "<>")
          link_style = %{style | fg: theme.tools.search, modifiers: [:underlined]}

          token(plain, style) ++
            [{"↗ #{label} (#{target})", link_style}] ++ parse_next(tail, style, theme)

        {index, {:bare_link, length}} ->
          <<plain::binary-size(^index), marked::binary>> = text
          <<target::binary-size(^length), tail::binary>> = marked
          link_style = %{style | fg: theme.tools.search, modifiers: [:underlined]}
          token(plain, style) ++ [{target, link_style}] ++ parse_next(tail, style, theme)

        {index, marker} ->
          <<plain::binary-size(^index), marked::binary>> = text

          after_open =
            binary_part(marked, byte_size(marker), byte_size(marked) - byte_size(marker))

          case :binary.match(after_open, marker) do
            {close_at, _length} ->
              <<inside::binary-size(^close_at), rest::binary>> = after_open
              tail = binary_part(rest, byte_size(marker), byte_size(rest) - byte_size(marker))

              token(plain, style) ++
                marked(inside, marker, style, theme) ++ parse_next(tail, style, theme)

            :nomatch ->
              token(plain <> marker, style) ++ parse_next(after_open, style, theme)
          end
      end
    end

    defp next_marker(text) do
      markers =
        Enum.flat_map(["**", "*", "`"], fn marker ->
          case :binary.match(text, marker) do
            {index, _length} -> [{index, marker}]
            :nomatch -> []
          end
        end)

      links =
        case Regex.run(@markdown_link, text, return: :index) do
          [{index, length}, {label_start, label_length}, {target_start, target_length}] ->
            label = binary_part(text, label_start, label_length)
            target = binary_part(text, target_start, target_length)
            [{index, {:link, length, label, target}}]

          _none ->
            []
        end

      bare_links =
        Enum.flat_map([@bare_url, @local_path], fn pattern ->
          case Regex.run(pattern, text, return: :index) do
            [{index, length}] ->
              candidate = binary_part(text, index, length)
              trimmed = String.replace(candidate, ~r/[.,;:!?]+$/, "")
              [{index, {:bare_link, byte_size(trimmed)}}]

            _none ->
              []
          end
        end)

      Enum.min_by(
        markers ++ links ++ bare_links,
        fn
          {index, {:link, _length, _label, _target}} -> {index, 0}
          {index, {:bare_link, _length}} -> {index, 0}
          {index, marker} -> {index, -byte_size(marker)}
        end,
        fn -> nil end
      )
    end

    defp marked(inside, "**", style, theme),
      do: parse_inline(inside, modifier(style, :bold), theme)

    defp marked(inside, "*", style, theme),
      do: parse_inline(inside, modifier(style, :italic), theme)

    defp marked(inside, "`", style, theme),
      do: [{inside, %{style | fg: theme.blocks.code, bg: theme.blocks.code_bg}}]

    defp modifier(style, modifier), do: modifiers(style, [modifier])

    defp modifiers(style, added),
      do: %{style | modifiers: Enum.uniq(style.modifiers ++ added)}

    defp token("", _style), do: []
    defp token(text, style), do: [{text, style}]

    defp wrap(styled, width) do
      case styled |> chars() |> collapse_whitespace() do
        [] -> [line([], blank_style(styled))]
        chars -> chars |> wrapped(width, []) |> Enum.map(&line(&1, %Style{}))
      end
    end

    # `wrap/2` with a gutter: the first row is set in by `first` and every row
    # after it by `rest`, and the text wraps to what is left. A pane too
    # narrow to leave room for words draws the gutter inline instead, which
    # is a worse row than a row of nothing.
    defp hanging(styled, first, rest, width) do
      {gutter_text, _style} = first
      inner = width - String.length(gutter_text)

      if inner < @hanging_minimum do
        wrap([first | styled], width)
      else
        styled
        |> wrap(inner)
        |> Enum.with_index()
        |> Enum.map(&guttered(&1, first, rest))
      end
    end

    defp guttered({line, 0}, {text, style}, _rest),
      do: %{line | spans: [Span.new(text, style: style) | line.spans]}

    defp guttered({line, _index}, _first, {text, style}),
      do: %{line | spans: [Span.new(text, style: style) | line.spans]}

    defp chars(styled) do
      Enum.flat_map(styled, fn {content, style} ->
        Enum.map(String.graphemes(content), &{&1, style})
      end)
    end

    # Where `wrap/2` collapses whitespace, this keeps it — which makes a newline this
    # function's problem. A `Line` cannot hold one: `ExRatatui.Text.Span.new/2`
    # raises on a span containing a newline, and it raises inside the draw loop, so
    # the row that would have been drawn slightly wrong ends the terminal instead.
    defp preserve(styled, width) do
      case chars(styled) do
        [] -> [line([], blank_style(styled))]
        chars -> chars |> segments() |> Enum.flat_map(&preserved(&1, width))
      end
    end

    defp preserved([], _width), do: [line([], %Style{})]

    defp preserved(chars, width),
      do: chars |> by_columns(width, []) |> Enum.map(&line(&1, %Style{}))

    # `Enum.chunk_every/2` by columns rather than by graphemes: see
    # `Lemieux.TUI.Width` for the rows of CJK this used to clip.
    defp by_columns([], _width, rows), do: Enum.reverse(rows)

    defp by_columns(chars, width, rows) do
      {row, rest} = Enum.split(chars, fitting(chars, width))
      by_columns(rest, width, [row | rows])
    end

    defp fitting(chars, width), do: Width.fit(chars, width, &elem(&1, 0))

    defp segments(chars) do
      {last, rest} =
        Enum.reduce(chars, {[], []}, fn
          {"\n", _style}, {segment, segments} -> {[], [Enum.reverse(segment) | segments]}
          char, {segment, segments} -> {[char | segment], segments}
        end)

      Enum.reverse([Enum.reverse(last) | rest])
    end

    # Match `Lemieux.TUI.Window`'s treatment of whitespace: runs collapse to
    # one cell, while leading and trailing whitespace do not consume a row.
    defp collapse_whitespace(chars) do
      chars
      |> Enum.reduce([], fn {char, style}, acc ->
        cond do
          not whitespace?(char) -> [{char, style} | acc]
          acc == [] -> acc
          match?([{" ", _style} | _rest], acc) -> acc
          true -> [{" ", style} | acc]
        end
      end)
      |> drop_trailing_space()
      |> Enum.reverse()
    end

    defp whitespace?(char), do: Regex.match?(~r/^\s$/u, char)
    defp drop_trailing_space([{" ", _style} | rest]), do: rest
    defp drop_trailing_space(chars), do: chars

    defp wrapped([], _width, rows), do: Enum.reverse(rows)

    defp wrapped(chars, width, rows) do
      {row, rest} = take_row(chars, width)
      wrapped(rest, width, [row | rows])
    end

    # A row is what fits in `width` columns, broken back to its last space
    # when the grapheme after it would not fit. Split rather than counted:
    # the rest of a long paragraph is never measured to wrap one row of it.
    defp take_row(chars, width) do
      case Enum.split(chars, fitting(chars, width)) do
        {row, []} ->
          {row, []}

        {row, [next | _after] = rest} ->
          case last_space(row ++ [next]) do
            nil ->
              {row, rest}

            index ->
              {Enum.take(chars, index), chars |> Enum.drop(index + 1) |> drop_leading_space()}
          end
      end
    end

    defp last_space(chars) do
      chars
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {{" ", _style}, index}, _last -> index
        {_char, _index}, last -> last
      end)
    end

    defp drop_leading_space([{" ", _style} | rest]), do: drop_leading_space(rest)
    defp drop_leading_space(chars), do: chars

    defp line([], style), do: Line.new([Span.new("", style: style)])

    defp line(chars, _style) do
      spans =
        chars
        |> Enum.reduce([], fn {char, style}, acc ->
          case acc do
            [{content, ^style} | rest] -> [{content <> char, style} | rest]
            _otherwise -> [{char, style} | acc]
          end
        end)
        |> Enum.reverse()
        |> Enum.map(fn {content, style} -> Span.new(content, style: style) end)

      Line.new(spans)
    end

    defp blank_style([{_content, style} | _rest]), do: style
    defp blank_style([]), do: %Style{}
  end
end
