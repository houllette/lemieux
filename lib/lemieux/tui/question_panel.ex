if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.QuestionPanel do
    @moduledoc "Draws the compact, tabbed ask_user panel around its editor."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Paragraph
    alias ExRatatui.Widgets.Tabs
    alias ExRatatui.Widgets.Textarea
    alias Lemieux.TUI.QuestionFlow
    alias Lemieux.TUI.QuestionSelection
    alias Lemieux.TUI.Takeover
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Width
    alias Lemieux.TUI.Window

    @doc """
    Widgets for the question panel over the transcript and input.

    `accent` marks the row being chosen, as it does on every menu on the
    screen. What a person has answered, and the notes they add, take their
    colour from `theme` — its `children.ok`, or `voices.question` where that
    is the accent — so the light palette draws them in colours a pale page
    can show. Without a `theme`, the dark one's.
    """
    @spec render(
            flow :: map(),
            panes :: map(),
            editor :: term(),
            accent :: Theme.colour(),
            theme :: Theme.t(),
            cursor_style :: Style.t()
          ) :: [{term(), Rect.t()}]
    def render(
          flow,
          panes,
          editor,
          accent,
          theme \\ Theme.default(),
          cursor_style \\ %Style{modifiers: [:reversed]}
        ) do
      bottom = panes.input.y + panes.input.height
      inner_width = max(panes.input.width - 4, 1)
      visual = visual(flow)
      side? = has_visual?(flow) and inner_width >= 58
      left_width = if side?, do: div(inner_width - 2, 2), else: inner_width
      look = %{accent: accent, answer: answer_style(theme, accent)}
      views = selection_views(flow, panes, look)
      lines = QuestionSelection.highlight(flow, views.body)
      area = area(flow, panes)
      tab_area = %Rect{x: area.x + 2, y: area.y + 1, width: inner_width, height: 1}

      body = %Rect{
        x: area.x + 2,
        y: area.y + 3,
        width: left_width,
        height: max(area.height - 8, 1)
      }

      input_area = %Rect{x: area.x + 2, y: bottom - 4, width: inner_width, height: 3}

      tabs = %Tabs{
        titles: tab_labels(flow),
        selected: if(flow.review?, do: length(flow.questions), else: flow.index),
        highlight_style: %Style{fg: accent, modifiers: [:bold]},
        divider: "│"
      }

      base =
        Takeover.frame(area, title(flow)) ++
          [
            {tabs, tab_area},
            {%Paragraph{text: lines, scroll: {views.body.scroll, 0}}, body},
            {footer(flow, editor, cursor_style), input_area}
          ]

      if side? and visual do
        side = %Rect{
          x: body.x + left_width + 2,
          y: body.y,
          width: inner_width - left_width - 2,
          height: body.height
        }

        base ++
          [
            {%Paragraph{
               text: QuestionSelection.highlight(flow, views.visual),
               scroll: {views.visual.scroll, 0},
               block: %Block{title: visual.title, borders: [:all], border_type: :rounded}
             }, side}
          ]
      else
        base
      end
    end

    @doc false
    @spec selection_views(flow :: map(), panes :: map(), look :: map()) :: map()
    def selection_views(flow, panes, look \\ %{accent: :white, answer: %Style{}}) do
      area = area(flow, panes)
      inner_width = max(panes.input.width - 4, 1)
      side? = has_visual?(flow) and inner_width >= 58
      width = if side?, do: div(inner_width - 2, 2), else: inner_width

      body_area = %Rect{
        x: area.x + 2,
        y: area.y + 3,
        width: width,
        height: max(area.height - 8, 1)
      }

      rows = body_lines(flow, look, width, side?)

      body = %{
        region: :body,
        area: body_area,
        rows: rows,
        meta: body_meta(flow, rows, look, width, side?),
        scroll: body_scroll(flow, rows, body_area.height),
        signature: {width, side?, flow.index, flow.review?, flow.selected}
      }

      visual = visual(flow)

      side =
        if side? and visual do
          visual_area = %Rect{
            x: body_area.x + width + 3,
            y: body_area.y + 1,
            width: max(inner_width - width - 4, 1),
            height: max(body_area.height - 2, 1)
          }

          meta = Enum.flat_map(visual.lines, &glyph_rows(plain(&1), visual_area.width))

          %{
            region: :visual,
            area: visual_area,
            rows: Enum.map(meta, &line(&1.text)),
            meta: meta,
            scroll:
              min(Map.get(flow, :visual_scroll, 0), max(length(meta) - visual_area.height, 0)),
            signature: {visual_area.width, flow.index, flow.review?, flow.selected}
          }
        end

      %{body: body, visual: side}
    end

    defp body_meta(%{review?: true}, rows, _look, _width, _side?), do: default_meta(rows)

    defp body_meta(flow, rows, look, width, side?) do
      question = QuestionFlow.current(flow)
      prompt = glyph_rows(question.text, width)
      meta = replace_meta(default_meta(rows), 0, prompt)

      {meta, start} =
        if not side? and visual(flow) do
          visual_meta = Enum.flat_map(visual(flow).lines, &glyph_rows(plain(&1), width))
          {replace_meta(meta, length(prompt), visual_meta), length(prompt) + length(visual_meta)}
        else
          {meta, length(prompt)}
        end

      if question.type in ~w(text number),
        do: meta,
        else: choice_meta(flow, question, rows, meta, start, look, width)
    end

    defp choice_meta(flow, question, rows, meta, start, look, width) do
      texts = Enum.map(rows, &plain/1)

      {meta, _next} =
        question.options
        |> Enum.with_index()
        |> Enum.reduce({meta, start}, fn {option, index}, {meta, start} ->
          raw = option_line(flow, question, option, index, look, width) |> Enum.map(&plain/1)

          offset =
            Enum.find(
              start..max(length(rows) - 1, start),
              start,
              &(Enum.slice(texts, &1, length(raw)) == raw)
            )

          parts = option_meta(option, raw)
          {replace_meta(meta, offset, parts), offset + length(parts)}
        end)

      meta
    end

    defp option_meta(option, raw) do
      prefix =
        String.length(hd(raw)) -
          String.length(
            hd(raw)
            |> String.replace(~r/^[› ] (?:\[[^]]*\]|✓| ) /u, "")
            |> String.trim_leading()
          )

      source =
        (option.label <> if(option.description, do: " — #{option.description}", else: ""))
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      {parts, _remaining} =
        raw
        |> Enum.with_index()
        |> Enum.map_reduce(source, fn {text, row}, source ->
          content = text |> String.slice(prefix..-1//1) |> String.trim_leading()

          remaining =
            source |> String.trim_leading() |> String.slice(String.length(content)..-1//1)

          {%{text: text, prefix: prefix, join: source_join(row, source)}, remaining}
        end)

      parts
    end

    defp source_join(0, _source), do: "\n"
    defp source_join(_row, " " <> _rest), do: " "
    defp source_join(_row, _source), do: ""

    defp default_meta(rows),
      do:
        Enum.map(rows, fn row ->
          text = plain(row)
          %{text: text, prefix: if(String.starts_with?(text, "› "), do: 2, else: 0), join: "\n"}
        end)

    defp replace_meta(rows, offset, replacements),
      do:
        Enum.take(rows, offset) ++ replacements ++ Enum.drop(rows, offset + length(replacements))

    defp plain(row), do: Enum.map_join(row.spans, & &1.content)

    @doc false
    @spec copy_text(flow :: map()) :: String.t()
    def copy_text(flow) do
      question = QuestionFlow.current(flow)

      [
        question.text,
        question.diagram
        | Enum.flat_map(question.options, fn option ->
            [option.label, option.description, option.diagram, option.preview]
          end)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end

    @doc "The stationary takeover rect used to reserve transcript viewport space."
    @spec area(flow :: map(), panes :: map()) :: Rect.t()
    def area(flow, panes) do
      bottom = panes.input.y + panes.input.height
      inner_width = max(panes.input.width - 4, 1)
      side? = has_visual?(flow) and inner_width >= 58
      left_width = if side?, do: div(inner_width - 2, 2), else: inner_width

      body_rows =
        flow.questions
        |> Enum.map(&question_rows(&1, left_width, side?))
        |> Enum.max(fn -> 0 end)
        |> max(4 + 2 * length(flow.questions))

      visual_rows =
        if side?,
          do: flow.questions |> Enum.map(&visual_rows/1) |> Enum.max(fn -> 0 end),
          else: 0

      height = min(max(body_rows, visual_rows) + 8, bottom - panes.transcript.y)
      Takeover.area(panes, height)
    end

    @doc "Scrolls the question body, clamping repeated paging at either end."
    @spec scroll(flow :: map(), panes :: map(), by :: integer()) :: map()
    def scroll(flow, panes, by) do
      width = max(panes.input.width - 4, 1)
      side? = has_visual?(flow) and width >= 58
      width = if side?, do: div(width - 2, 2), else: width
      lines = body_lines(flow, %{accent: :white, answer: %Style{}}, width, side?)
      height = max(area(flow, panes).height - 8, 1)
      base = body_scroll(Map.put(flow, :body_scroll, 0), lines, height)
      offset = min(max(body_scroll(flow, lines, height) + by, 0), max(length(lines) - height, 0))
      Map.put(flow, :body_scroll, offset - base)
    end

    defp has_visual?(flow), do: Enum.any?(flow.questions, &(visual_rows(&1) > 0))

    defp visual_rows(question) do
      shared = question.diagram

      question.options
      |> Enum.map(fn option ->
        diagram = option.diagram || shared
        preview = option.preview

        if is_binary(diagram) or is_binary(preview),
          do: length(diagram_lines(diagram)) + length(preview_lines(preview)) + 2,
          else: 0
      end)
      |> Enum.max(fn -> if(is_binary(shared), do: length(diagram_lines(shared)) + 2, else: 0) end)
    end

    defp question_rows(question, width, side?) do
      prompt = length(prompt_lines(question.text, width)) + 1
      inline_diagram = if side?, do: 0, else: max_diagram_rows(question)

      if question.type in ~w(text number) do
        prompt + 1 + inline_diagram
      else
        other = if question.allow_other?, do: 1, else: 0
        extra = 1

        prompt +
          Enum.sum(Enum.map(question.options, &length(wrapped_option(&1, width, "  [ ] ")))) +
          other + extra + inline_diagram
      end
    end

    defp max_diagram_rows(question) do
      question.options
      |> Enum.map(fn option -> length(diagram_lines(option.diagram || question.diagram)) end)
      |> Enum.max(fn -> length(diagram_lines(question.diagram)) end)
    end

    defp footer(%{note_option: :question}, editor, cursor),
      do: editor_footer(editor, " Note for this question · Enter saves · Esc returns ", cursor)

    defp footer(%{note_option: id} = flow, editor, cursor) when is_binary(id) do
      option = Enum.find(QuestionFlow.current(flow).options, &(&1.id == id))
      editor_footer(editor, " Note for #{option.label} · Enter saves · Esc returns ", cursor)
    end

    defp footer(%{other?: true} = flow, editor, cursor) do
      title =
        case QuestionFlow.current(flow).type do
          "number" -> " Number · Enter saves "
          "text" -> " Your answer · Enter saves "
          _choice -> " Other answer · Enter saves "
        end

      editor_footer(editor, title, cursor)
    end

    defp footer(flow, _editor, _cursor),
      do: %Paragraph{
        text: footer_text(flow),
        block: %Block{title: " Answer ", borders: [:all], border_type: :rounded}
      }

    defp editor_footer(editor, title, cursor),
      do: %Textarea{
        state: editor,
        wrap_mode: :word_or_glyph,
        cursor_style: cursor,
        block: %Block{title: title <> "· Tab questions ", borders: [:all], border_type: :rounded}
      }

    defp tab_labels(flow) do
      flow.questions
      |> Enum.with_index(1)
      |> Enum.map(fn {question, index} ->
        marker = if Map.has_key?(flow.answers, question.id), do: "✓", else: "·"
        "#{index} #{marker}"
      end)
      |> Kernel.++(["Review"])
    end

    defp body_lines(%{review?: true} = flow, look, width, _side?) do
      heading = [line(review_heading(flow), bold()), line("")]

      answers =
        flow.questions
        |> Enum.with_index()
        |> Enum.flat_map(fn {question, index} ->
          selected? = flow.review_index == index
          question_text = trim("#{index + 1}. #{question.text}", width - 2)
          answer = trim(QuestionFlow.summary(flow, question), width - 5)

          [
            line(
              "#{if(selected?, do: "›", else: " ")} #{question_text}",
              selected_style(selected?, look)
            ),
            line("    #{answer}", look.answer)
          ]
        end)

      submit =
        line(
          "#{if(flow.review_index == length(flow.questions), do: "›", else: " ")} #{submit_label(flow)}",
          selected_style(flow.review_index == length(flow.questions), look)
        )

      heading ++ answers ++ [line(""), submit] ++ notice_lines(flow)
    end

    defp body_lines(flow, look, width, side?) do
      question = QuestionFlow.current(flow)

      inline_diagram =
        if side? or is_nil(visual(flow)),
          do: [],
          else:
            Enum.flat_map(visual(flow).lines, fn row ->
              row |> plain() |> glyph_rows(width) |> Enum.map(&line(&1.text))
            end)

      prompt_lines(question.text, width) ++
        inline_diagram ++
        [line("")] ++
        if(question.type in ~w(text number),
          do: [line("Type your answer below.")],
          else:
            option_lines(flow, question, look, width) ++
              other_lines(flow, question, look, width) ++
              question_note_lines(flow, question, look, width)
        ) ++ notice_lines(flow)
    end

    defp visual(%{review?: true}), do: nil

    defp visual(flow) do
      question = QuestionFlow.current(flow)
      option = Enum.at(question.options, flow.selected)
      diagram = (option && option.diagram) || question.diagram
      preview = option && option.preview

      if is_binary(diagram) or is_binary(preview) do
        title =
          if option && (is_binary(option.diagram) or is_binary(preview)),
            do: " Example · #{trim(option.label, 24)} ",
            else: " Shared diagram "

        %{title: title, lines: diagram_lines(diagram) ++ preview_lines(preview)}
      end
    end

    defp prompt_lines(text, width),
      do: Enum.map(glyph_rows(text, width), &line(&1.text, bold()))

    defp glyph_rows(text, width) do
      text
      |> String.split("\n")
      |> Enum.flat_map(fn logical ->
        logical
        |> chunks(width)
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          %{text: text, prefix: 0, join: if(index == 0, do: "\n", else: "")}
        end)
      end)
    end

    defp chunks("", _width), do: [""]

    defp chunks(text, width) do
      {head, tail} = Width.split(text, max(width, 1))
      if tail == "", do: [head], else: [head | chunks(tail, width)]
    end

    defp diagram_lines(nil), do: []
    defp diagram_lines(diagram), do: diagram |> String.split("\n") |> Enum.map(&line/1)
    defp preview_lines(nil), do: []
    defp preview_lines(preview), do: [line("")] ++ Enum.map(String.split(preview, "\n"), &line/1)

    defp option_lines(flow, question, look, width) do
      question.options
      |> Enum.with_index()
      |> Enum.flat_map(fn {option, index} ->
        row = option_line(flow, question, option, index, look, width)

        note =
          if question.type == "single_choice",
            do: QuestionFlow.note_text(flow, option.id),
            else: ""

        if note == "" or flow.selected != index,
          do: row,
          else: row ++ [line(trim("      ↳ #{note}", width), look.answer)]
      end)
    end

    defp question_note_lines(flow, %{type: type}, look, width)
         when type in ~w(multi_select ranking) do
      note = QuestionFlow.note_text(flow)
      if note == "", do: [], else: [line(trim("  Note: #{note}", width), look.answer)]
    end

    defp question_note_lines(_flow, _question, _look, _width), do: []

    defp option_line(flow, question, option, index, look, width) do
      selected? = flow.selected == index
      marker = if selected?, do: "›", else: " "

      checked = option_marker(flow, question, option)

      option
      |> wrapped_option(width, "#{marker} #{checked} ")
      |> Enum.map(&line(&1, selected_style(selected?, look)))
    end

    # Render and measure the same rows. Keep every continuation under the
    # label, including when a preview halves the available column width.
    defp wrapped_option(option, width, prefix) do
      detail = if option.description, do: " — #{option.description}", else: ""
      padding = String.duplicate(" ", min(Width.of(prefix), max(width - 1, 0)))
      prefix = if Width.of(prefix) < width, do: prefix, else: ""
      padding = if prefix == "", do: "", else: padding
      [first | rest] = Window.wrap(option.label <> detail, max(width - Width.of(prefix), 1))
      [prefix <> first | Enum.map(rest, &(padding <> &1))]
    end

    defp body_scroll(flow, lines, height) do
      selected =
        Enum.find_index(lines, fn row ->
          Enum.any?(row.spans, &String.starts_with?(&1.content, "›"))
        end) || 0

      max_scroll = max(length(lines) - height, 0)
      min(max(max(selected - div(height, 2), 0) + Map.get(flow, :body_scroll, 0), 0), max_scroll)
    end

    defp option_marker(flow, %{type: "ranking"} = question, option) do
      case QuestionFlow.rank_for(flow, question.id, option.id) do
        nil -> "[ ]"
        rank -> "[#{rank}]"
      end
    end

    defp option_marker(flow, %{type: "multi_select"} = question, option) do
      if selected_option?(flow, question, option), do: "[x]", else: "[ ]"
    end

    defp option_marker(flow, question, option) do
      if selected_option?(flow, question, option), do: "✓", else: " "
    end

    defp selected_option?(flow, question, option),
      do: option.id in (get_in(flow.answers, [question.id, "selected"]) || [])

    defp other_lines(_flow, %{type: "ranking"}, _look, _width), do: []
    defp other_lines(_flow, %{allow_other?: false}, _look, _width), do: []

    defp other_lines(flow, question, look, width) do
      selected? = flow.selected == length(question.options)
      marker = if selected?, do: "›", else: " "
      answer = if selected?, do: QuestionFlow.other_text(flow), else: ""

      row =
        line(
          trim("#{marker}   Other · type your own answer", width),
          selected_style(selected?, look)
        )

      if answer == "",
        do: [row],
        else: [row, line(trim("      ↳ #{answer}", width), look.answer)]
    end

    defp footer_text(%{kind: :mcp, review?: true}),
      do: "↑↓ edit or Save server · ←→ tabs · Esc returns to servers"

    defp footer_text(%{review?: true}),
      do: "↑↓ edit or Submit · ←→ questions · Esc/Ctrl-C cancels"

    defp footer_text(%{kind: :mcp} = flow) do
      action =
        if QuestionFlow.current(flow).type == "single_choice",
          do: "Enter selects",
          else: "Type below · Enter continues"

      "↑↓ choose · #{action} · ←→ tabs · Esc returns to servers"
    end

    defp footer_text(%{questions: questions} = flow) do
      action =
        case QuestionFlow.current(flow).type do
          "multi_select" -> "Space checks boxes · Enter continues"
          "ranking" -> "Press 1–6 to rank each item · Enter continues"
          type when type in ~w(text number) -> "Type below · Enter continues"
          _choice -> "Enter selects"
        end

      "Ctrl+Shift+C copy · ↑↓ choose · #{action} · PgUp/PgDn scroll · n adds note · ←→ questions · #{length(questions)} total · Esc cancels"
    end

    defp trim(text, width), do: String.slice(text, 0, max(width, 1))
    defp title(%{kind: :mcp}), do: " Add MCP server · review before saving "
    defp title(_flow), do: " ask_user · review before sending "
    defp review_heading(%{kind: :mcp}), do: "Review server configuration"
    defp review_heading(_flow), do: "Review your answers"
    defp submit_label(%{kind: :mcp}), do: "Save server"
    defp submit_label(_flow), do: "Submit answers"
    defp notice_lines(%{notice: text}) when is_binary(text), do: [line(""), line(text)]
    defp notice_lines(_flow), do: []
    defp line(content, style \\ %Style{}), do: Line.new([Span.new(content, style: style)])
    defp bold, do: %Style{modifiers: [:bold]}
    defp selected_style(true, look), do: %Style{fg: look.accent, modifiers: [:bold]}
    defp selected_style(false, _look), do: %Style{}

    # What a person has answered, and the notes they added, set apart from
    # the accent on the row being chosen: in the colour of a child that
    # finished well — something given, done — or in the question's own voice
    # where `/color` made that colour the accent. These were the named
    # `:green` and `:yellow`, which no theme could re-pick, and on a white
    # page they measured 2.2:1 and 1.7:1. The slot is borrowed rather than
    # new because a new slot is one every theme map already written lacks,
    # and `Lemieux.TUI.Theme.from_map/1` refuses a theme with a slot missing —
    # the example in the docs among them.
    defp answer_style(theme, accent) do
      %Style{
        fg: if(theme.children.ok == accent, do: theme.voices.question, else: theme.children.ok)
      }
    end
  end
end
