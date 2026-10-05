# The screen projects callback state into widgets without owning the editor or session.
# Keep it behind the same optional dependency guard as Lemieux.TUI.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Screen do
    @moduledoc "Projects a TUI state into a complete terminal frame and shared viewport geometry."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.BigText
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.Paragraph
    alias ExRatatui.Widgets.Textarea
    alias Lemieux.Conversation
    alias Lemieux.ID.Shorthand
    alias Lemieux.ModelSpec
    alias Lemieux.TUI
    alias Lemieux.TUI.Activity
    alias Lemieux.TUI.Colour
    alias Lemieux.TUI.Followup
    alias Lemieux.TUI.Layout
    alias Lemieux.TUI.MCPPanel
    alias Lemieux.TUI.MCPStatus
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.PlanPanel
    alias Lemieux.TUI.Policy
    alias Lemieux.TUI.QuestionPanel
    alias Lemieux.TUI.Renderer
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Selection
    alias Lemieux.TUI.Status
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Width
    alias Lemieux.TUI.Window

    @doc false
    @spec render(TUI.t(), map(), (map() -> list())) :: list()
    def render(%TUI{terminal: %{repaint: repaint}}, frame, _completion_widgets)
        when is_integer(repaint) and repaint > 0,
        do: repaint_frame(frame)

    def render(state, frame, completion_widgets),
      do: state |> widgets(frame, completion_widgets) |> for_terminal(state)

    defp widgets(state, frame, completion_widgets) do
      frame = drawable(frame)
      {panes, problem} = arranged(state, frame)

      base =
        [{transcript(state, panes.transcript, problem), panes.transcript}] ++
          notice_widgets(state, panes) ++
          status(state, panes.status) ++
          input_widgets(state, panes.input) ++
          queued_widgets(state, panes) ++
          plan_widgets(state, panes)

      case state.overlay do
        nil when not is_nil(state.modal) ->
          base ++ Modal.render(state, panes)

        nil ->
          case {state.tools.question_flow, state.tools.mcp_flow} do
            {nil, nil} ->
              base ++ completion_widgets.(panes)

            {nil, %{mode: :add, questionnaire: questionnaire}} ->
              base ++ question_panel(questionnaire, panes, state)

            {nil, flow} ->
              base ++ MCPPanel.render(flow, panes, accent(state))

            {flow, _mcp_flow} ->
              base ++ question_panel(flow, panes, state)
          end

        overlay ->
          overlay(overlay, frame)
      end
    end

    # The theme as well as the accent: what a person answered is drawn from
    # the theme's slots, which a pale page re-picks (`Lemieux.TUI.QuestionPanel`).
    defp question_panel(flow, panes, state),
      do: QuestionPanel.render(flow, panes, state.input, accent(state), theme(state))

    # What this terminal can show, applied to the finished frame so it reaches
    # every colour on it — the theme's, the syntax highlighter's, `/color`'s,
    # and whatever a host's status line or renderer chose — rather than each
    # place that picks one. Two adaptations, each skipped where it is not
    # needed, so the common terminal pays for neither:
    #
    #   * On a terminal without 24-bit colour every RGB colour becomes its
    #     nearest palette colour (`Lemieux.TUI.Colour`): macOS Terminal before
    #     macOS 26 and GNU screen 4 drew `38;2;…` as dim text on yellow.
    #   * Under a palette drawn for a pale page (`Lemieux.TUI.Theme.pale?/1`),
    #     dim text is drawn in the palette's muted colour instead. Terminals
    #     dim by fading towards the background, which on white leaves a faint
    #     black at 3.9:1 and a faint grey near 2:1 — tool output and the
    #     status row unreadable under the very palette meant to fix that.
    defp for_terminal(widgets, state) do
      theme = theme(state)
      depth = Map.get(state.terminal, :colours, :truecolor)

      faint =
        if Theme.pale?(theme), do: %{muted: theme.text.muted, plain: theme.text.plain}

      if depth == :truecolor and is_nil(faint),
        do: widgets,
        else: adapt(widgets, %{depth: depth, faint: faint})
    end

    defp adapt(%Style{} = style, how) do
      style = undimmed(style, how.faint)

      %{
        style
        | fg: adapt(style.fg, how),
          bg: adapt(style.bg, how),
          underline_color: adapt(style.underline_color, how)
      }
    end

    defp adapt({:rgb, _red, _green, _blue} = colour, %{depth: depth}),
      do: Colour.for_depth(colour, depth)

    defp adapt(list, how) when is_list(list), do: Enum.map(list, &adapt(&1, how))

    defp adapt(tuple, how) when is_tuple(tuple),
      do: tuple |> Tuple.to_list() |> adapt(how) |> List.to_tuple()

    defp adapt(map, how) when is_map(map),
      do: :maps.map(fn _key, value -> adapt(value, how) end, map)

    defp adapt(other, _how), do: other

    defp undimmed(style, nil), do: style

    defp undimmed(%Style{modifiers: modifiers} = style, %{muted: muted, plain: plain}) do
      if :dim in modifiers do
        fg = if style.fg in [nil, plain], do: muted, else: style.fg
        %{style | fg: fg, modifiers: List.delete(modifiers, :dim)}
      else
        style
      end
    end

    # After the terminal was handed to an editor and back, what is on the glass
    # is not what the renderer believes it last drew, and it repaints only
    # the cells it thinks changed. One frame of hidden blanks makes every cell
    # differ from the one before it and from the one after, so this frame and
    # the next are both drawn in full. See `Lemieux.TUI.ExternalEditor`.
    @doc false
    @spec repaint(TUI.t()) :: TUI.t()
    def repaint(state) do
      send(self(), :repaint_done)
      put_in(state.terminal.repaint, 1)
    end

    defp repaint_frame(frame) do
      width = max(frame.width, 1)
      height = max(frame.height, 1)
      blank = String.duplicate(" ", width)

      [
        {%Paragraph{
           text: Enum.map(1..height, fn _row -> Line.new([Span.new(blank)]) end),
           style: %Style{modifiers: [:hidden]}
         }, %Rect{x: 0, y: 0, width: width, height: height}}
      ]
    end

    # `/habs` also covers the screen while the CLI's asynchronous startup runs.
    # The screen it covers comes back untouched when the animation ends — an
    # easter egg that threw a transcript away would be a bug wearing a joke's clothes.
    # `:quadrant` rather than `:full`, because at one cell per pixel "GO HABS GO!"
    # needs 88 columns and at four it needs 44, which fits the terminal most people
    # run this in.
    @habs_words ["GO", "HABS", "GO!"]
    @habs_colours [:blue, :red, :white]
    @habs_frames 10
    @habs_height 4

    defp overlay(%{frame: frame}, frame_size) do
      area = %Rect{x: 0, y: 0, width: frame_size.width, height: frame_size.height}

      [{%Clear{}, area} | habs_banner(frame, frame_size)]
    end

    # The last frame is the blank one: the animation clears itself before
    # handing the screen back, so the transcript reappears rather than being
    # wiped in by a banner dissolving over it.
    defp habs_banner(frame, _frame_size) when frame >= @habs_frames - 1, do: []

    defp habs_banner(frame, frame_size) do
      spans =
        @habs_words
        |> Enum.take(min(frame + 1, length(@habs_words)))
        |> Enum.with_index()
        |> Enum.map(fn {word, index} ->
          colour = Enum.at(@habs_colours, rem(index + frame, length(@habs_colours)))
          Span.new(word <> " ", style: %Style{fg: colour, modifiers: [:bold]})
        end)

      banner = %BigText{
        lines: [Line.new(spans)],
        pixel_size: :quadrant,
        alignment: :center
      }

      area = %Rect{
        x: 0,
        y: max(div(frame_size.height - @habs_height, 2), 0),
        width: frame_size.width,
        height: min(@habs_height, frame_size.height)
      }

      [{banner, area}]
    end

    # What the accents are drawn in: the transcript rails, the input cursor
    # and the highlighted completion. An explicit `/color` wins over Elixir
    # mode's own colour — it is the one thing on this screen that was asked
    # for by name, and the mode is named in the footer either way.
    @doc false
    @spec accent(TUI.t()) :: Style.color() | nil
    def accent(%TUI{appearance: %{colour: colour}}) when not is_nil(colour), do: colour
    def accent(%TUI{elixir_mode?: true} = state), do: theme(state).elixir_accent
    def accent(state), do: theme(state).accent

    @doc false
    @spec theme(TUI.t()) :: Theme.t()
    def theme(%TUI{appearance: %{theme: %Theme{} = theme}}), do: theme
    def theme(_state), do: Theme.default()

    # What `/theme` picks from: the registry `new/1` built, or the shipped
    # three for a state built without one.
    @doc false
    @spec themes(TUI.t()) :: Theme.registry()
    def themes(%TUI{appearance: %{themes: %{} = themes}}), do: themes
    def themes(_state), do: Theme.shipped()

    # How each tool's receipt is drawn: the registry `new/1` built, or the
    # built-ins for a state built without one.
    @doc false
    @spec renderers(TUI.t()) :: map()
    def renderers(%TUI{status: %{renderers: %{} = renderers}}), do: renderers
    def renderers(_state), do: Renderer.builtin()
    # The panes, from the size the last resize reported. Shared by the draw
    # and by everything that happens between draws — paging, mouse
    # hit-testing, drag selection, counting the rows a line adds — because a
    # page that disagreed with the pane would scroll past what it had just
    # shown, and a click that disagreed would select the wrong row. Computed
    # rather than remembered: a host's status line may change its height
    # between frames, and `render/2` cannot write what it laid out.
    @doc false
    @spec panes(TUI.t()) :: map()
    def panes(state) do
      {panes, _problem} =
        arranged(state, %{width: state.terminal.width, height: state.terminal.height})

      panes
    end

    # The status band's height is a host module's answer, asked once here and
    # handed to the layout: two calls in one frame are two chances to
    # disagree, and panes that disagree by a row either overlap or leave a
    # hole. `Lemieux.TUI.Layout.arrange/3` says what happens to a layout that
    # breaks the rules; the problem, if any, is drawn on the transcript's rail.
    # A terminal that reports no size (an unsized pty, some containers and
    # editors) hands over a 0×0 frame. Every measurement below assumes at
    # least one cell, and such a frame used to fail every render with a
    # clause error in `Layout.input_height/2`. It is drawn as the smallest
    # frame instead.
    defp drawable(%{width: width, height: height} = frame),
      do: %{frame | width: max(width, 1), height: max(height, 1)}

    defp arranged(state, frame) do
      needs = %{
        input: Layout.input_height(ExRatatui.textarea_get_value(state.input), frame.width),
        status: Status.height(status_line(state), frame.height)
      }

      case Layout.arrange(Layout.module(state.status.layout), frame, needs) do
        {:ok, panes} ->
          {reserved(panes, state), nil}

        {:fallback, panes, reason} ->
          {reserved(panes, state), reason}
      end
    end

    defp reserved(panes, state) do
      panes
      |> reserve_notices(state)
      |> reserve_queued_panel(state)
      |> reserve_plan_panel(state)
      |> then(&reserve_question_panel(state, &1))
    end

    # The notice box takes its rows from the top of the transcript pane, so
    # everything that measures the transcript — paging, hit-testing, the
    # panels that size themselves from its top — measures what is left. Kept
    # in the panes as `:notices` for the draw and for a click on its link. A
    # pane too short to spare the rows and keep a few for the conversation
    # does without the box; its timer still runs.
    defp reserve_notices(%{transcript: %Rect{} = transcript} = panes, state) do
      rows = Notices.rows(state, transcript.width, transcript.height)

      if rows >= 3 and transcript.height - rows >= 4 do
        area = %Rect{transcript | height: rows}
        rest = %{transcript | y: transcript.y + rows, height: transcript.height - rows}
        %{panes | transcript: rest} |> Map.put(:notices, area)
      else
        Map.put(panes, :notices, nil)
      end
    end

    defp notice_widgets(state, %{notices: %Rect{} = area}), do: Notices.render(state, area)
    defp notice_widgets(_state, _panes), do: []

    # The plan sits above the queued inputs, if there are any, and above the
    # input box otherwise, taking its rows from the transcript as they do.
    defp reserve_plan_panel(panes, state) do
      case plan_area(state, panes) do
        nil ->
          panes

        area ->
          height = min(panes.transcript.height, max(area.y - panes.transcript.y, 0))
          %{panes | transcript: %{panes.transcript | height: height}}
      end
    end

    defp plan_area(%{tools: %{question_flow: flow}}, _panes) when not is_nil(flow), do: nil
    defp plan_area(%{modal: modal}, _panes) when not is_nil(modal), do: nil

    defp plan_area(state, panes) do
      bottom =
        case queued_area(state, panes) do
          nil -> panes.input.y
          area -> area.y
        end

      rows = PlanPanel.rows(state, bottom - panes.transcript.y)

      if rows >= 3 and bottom - rows - panes.transcript.y >= 3,
        do: %Rect{x: panes.input.x, y: bottom - rows, width: panes.input.width, height: rows}
    end

    defp plan_widgets(state, panes) do
      case plan_area(state, panes) do
        nil -> []
        area -> PlanPanel.render(state, area)
      end
    end

    defp reserve_queued_panel(panes, state) do
      case queued_area(state, panes) do
        nil ->
          panes

        area ->
          height = min(panes.transcript.height, max(area.y - panes.transcript.y, 0))
          %{panes | transcript: %{panes.transcript | height: height}}
      end
    end

    defp queued_area(%{tools: %{question_flow: flow}}, _panes) when not is_nil(flow), do: nil
    defp queued_area(%{history: %{queued: []}}, _panes), do: nil

    defp queued_area(state, panes) do
      transcript = panes.transcript
      available = panes.input.y - transcript.y - 3
      rows = min(length(state.history.queued) + 2, available)

      if rows >= 3 do
        area = %Rect{
          x: panes.input.x,
          y: panes.input.y - rows,
          width: panes.input.width,
          height: rows
        }

        status = panes.status

        if area.x < status.x + status.width and status.x < area.x + area.width and
             area.y < status.y + status.height and status.y < area.y + area.height,
           do: nil,
           else: area
      end
    end

    defp queued_widgets(state, panes) do
      case queued_area(state, panes) do
        nil -> []
        area -> [{queued_panel(state, area), area}]
      end
    end

    defp queued_panel(state, area) do
      room = area.height - 2
      selected = state.history.queued_selected
      start = max(min(selected - room, length(state.history.queued) - room), 0)
      shown = state.history.queued |> Enum.with_index(1) |> Enum.slice(start, room)

      lines =
        Enum.map(shown, fn {message, number} ->
          marker = if number == selected, do: "› ", else: "  "
          preview = queued_preview(message, max(area.width - 8, 1))
          style = %Style{fg: theme(state).voices.you_text}
          Line.new([Span.new("#{marker}#{number}. #{preview}", style: style)])
        end)

      %Paragraph{
        text: lines,
        wrap: false,
        block: %Block{
          title: " queued inputs (#{length(state.history.queued)}/9) ",
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: theme(state).text.muted},
          padding: {1, 1, 0, 0}
        }
      }
    end

    defp queued_preview(message, width) do
      clean = message |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.length(clean) > width,
        do: String.slice(clean, 0, max(width - 1, 1)) <> "…",
        else: clean
    end

    defp reserve_question_panel(%{tools: %{question_flow: nil}}, panes), do: panes

    defp reserve_question_panel(%{tools: %{question_flow: flow}}, panes) do
      panel = QuestionPanel.area(flow, panes)
      transcript = panes.transcript

      if transcript.y < panel.y and transcript.y + transcript.height > panel.y do
        %{panes | transcript: %{transcript | height: panel.y - transcript.y}}
      else
        panes
      end
    end

    @doc false
    @spec transcript_pane(TUI.t()) :: map()
    def transcript_pane(state), do: panes(state).transcript

    # The width transcript rows wrap to: the transcript pane's, less its padding.
    @doc false
    @spec columns(TUI.t()) :: pos_integer()
    def columns(state), do: inner(transcript_pane(state).width)

    # `nil` is the shipped layout, which is what `Lemieux.TUI.Status.module/1`
    # is for — one field holding "whatever was configured" rather than two,
    # one of them saying whether anything was.
    defp status_line(state), do: Status.module(state.status.line)

    # Reverse video rather than a colour: the transcript already spends its
    # palette on meaning — errors red, questions cyan — and a selection that
    # painted over those would hide exactly what somebody is selecting closely
    # enough to copy. Reversing keeps them and is unmistakable.
    @selection_style %Style{modifiers: [:reversed]}

    defp transcript(state, %Rect{} = pane, problem) do
      width = inner(pane.width)
      live = live_rows(state, width)

      view =
        Window.view(
          state.lines,
          width,
          visible(state, pane),
          state.scroll,
          row_renderer(state, width)
        )

      %Paragraph{
        text: selected(state, view) ++ live,
        # Already wrapped, to the same width the window measured against. Left
        # to the widget, the wrap would happen after the count of what fits,
        # and the pane would show fewer rows than it was asked for without
        # ever saying so.
        wrap: false,
        block: %Block{
          title: header(state),
          # A pane that is not showing the newest line has to say so, or it
          # looks like an agent that stopped talking. A layout that could not
          # be drawn says so here too, on every frame until it is fixed.
          titles: scrollback(view.offset, theme(state)) ++ layout_notice(problem),
          # Terminal selection copies cells exactly as drawn. Horizontal rails
          # keep the pane identity and mode colour without putting a `│` at
          # both ends of every copied transcript row; padding preserves the
          # same content width as the old lateral borders.
          borders: if(view.offset > 0, do: [:top, :bottom], else: [:top]),
          border_type: :rounded,
          border_style: %Style{fg: accent(state)},
          padding: {1, 1, 0, 0}
        }
      }
    end

    defp header(state) do
      provider = ModelSpec.provider(state.conversation.model) || "unknown"

      model =
        ModelSpec.model_id(state.conversation.model) || state.conversation.model || "unknown"

      effort = state.conversation.reasoning_effort

      # The session's name goes here now, where its id deliberately did not.
      # An opaque ULID in a permanently visible header was noise nobody could
      # act on; a shorthand is the argument you give `--resume` tomorrow, so
      # it earns the space that the id did not.
      #
      # The working directory goes first after the version, because it is the
      # one thing here that says what the agent can change: it edits and runs
      # commands there without asking unless permissions are on, and nothing
      # on the screen used to say where "there" was — `-C DIR` and the
      # directory lmx was started in were indistinguishable once it was open.
      # A header too long for the terminal loses its end, so the effort goes
      # before the directory does.
      [place(state), name(state), provider, model, "effort #{effort}"]
      |> Enum.reject(&is_nil/1)
      # `Lemieux.version/0` comes from mix.exs but still works in a release
      # where Mix itself is absent.
      |> then(&(" " <> Enum.join(["lemieux (v#{Lemieux.version()})" | &1], " · ") <> " "))
    end

    # Short enough to leave the header room for the session and the model,
    # long enough for a typical `~/code/project`.
    @place_columns 32

    @doc """
    The session's working directory as the header and the terminal title show
    it, or `nil` before a session has said where it runs. See `directory/3`,
    and `printable/1` for what happens to a control character in it.
    """
    @spec place(state :: TUI.t()) :: String.t() | nil
    def place(%TUI{references: %{cwd: cwd}}) when is_binary(cwd) and cwd != "" do
      home = System.user_home()
      directory(printable(cwd), home && printable(home), @place_columns)
    end

    def place(_state), do: nil

    @doc """
    `text` with every control character drawn as `?`, as `ls` draws one, and
    any byte that is not UTF-8 the same way.

    A directory's name may hold anything but `/` and NUL, escape sequences
    included, and the working directory is now written into the header and,
    through OSC 0, into the terminal's title. `Lemieux.Terminal` strips the
    C0 controls from a title but not the C1 ones (U+0080–U+009F), and some
    terminals act on those — U+009C is the string terminator — so a crafted
    directory name could end the title early and send what followed to the
    terminal as commands.
    """
    @spec printable(text :: String.t()) :: String.t()
    def printable(text) when is_binary(text) do
      text
      |> String.replace_invalid("?")
      |> String.replace(~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u, "?")
    end

    @doc """
    `path` for a person to recognise in at most `columns` columns.

    The home directory is `~`, as a shell prompt writes it. A path still too
    long has every directory but the last shortened to its first letter, as
    fish's prompt does — `~/Documents/work/lemieux` becomes `~/D/w/lemieux` —
    and one longer still is the last directory alone, after `…/`: the last
    name is the one a person knows a project by.
    """
    @spec directory(path :: String.t(), home :: String.t() | nil, columns :: pos_integer()) ::
            String.t()
    def directory(path, home, columns) when is_binary(path) and is_integer(columns) do
      homed = homed(path, home)

      cond do
        Width.of(homed) <= columns -> homed
        Width.of(shortened(homed)) <= columns -> shortened(homed)
        true -> "…/" <> Path.basename(homed)
      end
    end

    defp homed(path, home) when is_binary(home) and home not in ["", "/"] do
      cond do
        path == home -> "~"
        String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
        true -> path
      end
    end

    defp homed(path, _home), do: path

    defp shortened(path) do
      case String.split(path, "/") do
        [only] ->
          only

        parts ->
          {leading, [last]} = Enum.split(parts, -1)
          Enum.map_join(leading, "/", &initial/1) <> "/" <> last
      end
    end

    # `~` and the empty root stay as they are; a hidden directory keeps its
    # dot, so `.config` is `.c` rather than a bare `.`.
    defp initial("~"), do: "~"
    defp initial("." <> rest) when rest != "", do: "." <> String.first(rest)
    defp initial(name), do: String.first(name) || ""

    # `/name` wins over the derived one, and only here: what it changes is
    # the caption on a screen. `Lemieux.ID.Shorthand` is explicit that the
    # handle `--resume` takes has to stay something any build recomputes from
    # the id, so `perform/2` says so when it takes the override.
    @doc false
    @spec name(TUI.t()) :: String.t() | nil
    def name(%TUI{appearance: %{name: name}}) when is_binary(name), do: name
    def name(%TUI{id: id}) when is_binary(id), do: Shorthand.of(id)
    def name(_state), do: nil

    # Both dimensions lose the pane's border.
    @doc false
    @spec inner(integer()) :: pos_integer()
    def inner(size), do: max(size - 2, 1)

    defp scrollback(0, _theme), do: []

    defp scrollback(offset, theme),
      do: [
        %Block.Title{
          content: scrollback_title(offset),
          position: :bottom,
          alignment: :center,
          style: %Style{fg: theme.voices.notice}
        }
      ]

    @doc false
    @spec scrollback_title(non_neg_integer()) :: String.t()
    def scrollback_title(offset), do: " ↓ #{offset} lines below · click for latest "

    # On the rail rather than in the transcript, because it is true of this
    # frame and not something that was said: a row in `:lines` would repeat
    # on every resize, and a notice that scrolled away would be missed.
    defp layout_notice(nil), do: []

    defp layout_notice(reason),
      do: [
        %Block.Title{
          content: " layout: #{reason} · drawn as shipped ",
          position: :bottom,
          alignment: :left
        }
      ]

    @doc false
    @spec rich_rows(TUI.line(), pos_integer(), Theme.t()) :: list()
    def rich_rows(line, width, theme), do: RichText.lines([line], width, theme)

    @doc false
    @spec row_renderer(TUI.t(), pos_integer()) :: (TUI.line(), pos_integer() -> list())
    def row_renderer(state, width) do
      theme = theme(state)

      case state.terminal.row_cache do
        %{width: ^width, theme: ^theme, rows: cached} ->
          fn line, row_width -> Map.get(cached, line) || rich_rows(line, row_width, theme) end

        _other ->
          fn line, row_width -> rich_rows(line, row_width, theme) end
      end
    end

    # Two, because one is not always enough — `reading 3 read-only
    # investigations (30.1 KB) · waiting for the model (6s)` is seventy columns
    # before the label reaches it — and clipping the phase off the right-hand
    # edge clips the only part that is news. The cap is there because the rows
    # come out of the transcript's own height: a live row free to grow would
    # take the conversation with it.
    @live_rows 2

    # What the turn is doing, drawn under everything it has said so far, or
    # nothing between turns — where `finish_processing/1`'s summary rule takes
    # its place. It is a row of the pane rather than an entry in `:lines`
    # because it is not something that was said: it is rewritten on every tick,
    # and a transcript keeping the ghosts of it would be one sentence repeated
    # four times a second. Drawn after the window rather than inside it for a
    # second reason — `Lemieux.TUI.Selection` names rows by how many are newer
    # than them, and a row appearing and vanishing at the newest end would move
    # every selection and every scroll position with it.
    defp live_rows(state, width) do
      case Activity.line(activity(state)) do
        nil ->
          []

        text ->
          [{:activity, Activity.spinner(state.turn.frame), text}]
          |> RichText.lines(width, theme(state))
          |> Enum.take(@live_rows)
      end
    end

    defp selected(%TUI{selection: nil}, view), do: view.rows

    defp selected(%TUI{selection: selection}, view),
      do: Selection.highlight(selection, view, @selection_style)

    defp input_widgets(state, area), do: [{input(state), area} | placeholder_widgets(state, area)]

    defp input(state) do
      %Textarea{
        state: state.input,
        wrap_mode: :word_or_glyph,
        cursor_style: cursor_style(state),
        block: %Block{
          title: title(state.conversation),
          borders: [:all],
          border_type: :rounded
        }
      }
    end

    # The textarea puts its own placeholder after the cursor cell. Draw the
    # hint over that cell so its first letter aligns with typed text; keep the
    # textarea as the sole owner of the actual editor value and cursor motion.
    defp placeholder_widgets(state, %Rect{width: width, height: height} = area)
         when width > 2 and height > 2 do
      if ExRatatui.textarea_get_value(state.input) == "",
        do: empty_placeholder(state, area),
        else: []
    end

    defp placeholder_widgets(_state, _area), do: []

    defp empty_placeholder(%TUI{resume: %{startup_status: :failed}} = state, area) do
      style = %Style{fg: theme(state).text.plain, modifiers: [:bold]}
      text = Line.new([Span.new(placeholder(state), style: style)])

      inner = %Rect{
        x: area.x + 1,
        y: area.y + 1,
        width: area.width - 2,
        height: area.height - 2
      }

      [{%Paragraph{text: [text], wrap: true}, inner}]
    end

    defp empty_placeholder(state, area) do
      case String.next_grapheme(placeholder(state)) do
        {first, rest} ->
          hint_style = %Style{fg: theme(state).text.plain, modifiers: [:dim]}

          first_style =
            if state.terminal.cursor_blink.visible?, do: cursor_style(state), else: hint_style

          text =
            Line.new([
              Span.new(first, style: first_style),
              Span.new(rest, style: hint_style)
            ])

          inner = %Rect{
            x: area.x + 1,
            y: area.y + 1,
            width: area.width - 2,
            height: area.height - 2
          }

          [{%Paragraph{text: [text], wrap: true}, inner}]

        nil ->
          []
      end
    end

    # Reversed rather than painted when there is no accent to paint it in —
    # the mono theme — because black on the terminal's own background is a
    # cursor nobody can find.
    defp cursor_style(%TUI{resume: %{startup_status: :failed}}), do: %Style{}

    defp cursor_style(%TUI{terminal: %{cursor_blink: %{visible?: false}}}),
      do: %Style{}

    defp cursor_style(%TUI{} = state), do: cursor_style(accent(state))
    defp cursor_style(nil), do: %Style{modifiers: [:reversed]}

    # Black on a light accent and white on a dark one: black on the light
    # palette's blue was 3.3:1, and on `/color blue` 2.2:1.
    defp cursor_style(accent),
      do: %Style{fg: if(Colour.light?(accent), do: :black, else: :white), bg: accent}

    # The prompt says what the next line will be taken as.
    defp title(%Conversation{asking: asking}) when is_binary(asking), do: " answer "
    defp title(%Conversation{approvals: [_call | _rest]}), do: " approve? "
    defp title(_conversation), do: " message "

    defp placeholder(%TUI{resume: %{startup_status: :loading}}),
      do: "Starting session... type ahead; Enter queues it"

    defp placeholder(%TUI{resume: %{startup_status: :failed}}),
      do: "Session could not start · /model NAME or /provider NAME tries again · /quit"

    defp placeholder(%TUI{resume: %{down: down}}) when not is_nil(down),
      do: "The session stopped · Enter resumes it · /new starts another"

    defp placeholder(%TUI{conversation: %Conversation{question: %{options: options}}})
         when options != [],
         do: "type 1-#{length(options)}, or a different answer"

    defp placeholder(%TUI{
           conversation: %Conversation{asking: nil, approvals: [%{name: name} | _rest]}
         }),
         do: "y runs #{name} · n [reason] refuses it"

    defp placeholder(state) do
      case followup(state) do
        nil -> "ask, or say what to change"
        suggestion -> "#{suggestion} · tab"
      end
    end

    # The guess at what comes next, offered only between turns and only into an
    # empty box: mid-turn it would describe work still happening, and over typed
    # text it would hint at a prompt nobody is writing. `Lemieux.TUI.Followup` says
    # why the guess is local rather than a model's.
    @doc false
    @spec followup(TUI.t()) :: String.t() | nil
    def followup(%TUI{turn: %{started_at: nil, signals: signals}} = state) do
      if ExRatatui.textarea_get_value(state.input) == "", do: followups(state).suggest(signals)
    end

    def followup(_state), do: nil

    defp followups(state), do: Followup.module(state.status.followups)

    # The row belongs to whichever module the host asked for; what is left here is
    # turning a turn into the snapshot that module is given. Rects come back clamped
    # to the area, because the obvious mistake in writing a status line — placing a
    # widget at `y: 0`, because that is where it goes *within* the row — would erase
    # the transcript.
    defp status(state, area) do
      module = status_line(state)

      state
      |> status_snapshot(area)
      |> module.render(area)
      |> Enum.map(fn {widget, rect} -> {widget, Status.confine(rect, area)} end)
    end

    defp status_snapshot(state, area) do
      Status.new(
        Map.to_list(activity(state)) ++
          [
            width: area.width,
            height: area.height,
            theme: theme(state),
            accent: accent(state),
            conversation: state.conversation,
            compact_at: state.status.compact_at,
            name: name(state),
            draft?: String.trim(ExRatatui.textarea_get_value(state.input)) != "",
            queued?: state.history.queued != [],
            queued_count: length(state.history.queued),
            revising: state.history.revising,
            feedback: if(state.terminal.feedback, do: state.terminal.feedback.text),
            resuming?: state.resume.busy?,
            exiting?: not is_nil(state.exit_armed),
            permission: Policy.label(state),
            requests: state.session_view.requests,
            request_cap: state.session_view.request_cap,
            mcp_connecting: MCPStatus.connecting(state)
          ]
      )
    end

    # The turn as both readers of it want it: the transcript's live row, and the
    # snapshot a host's status line is handed. One function, because two would
    # eventually disagree about which phase the clock belongs to.
    defp activity(state) do
      %{
        busy?: state.conversation.busy?,
        # `nil` until a turn has started, which is every screen before the
        # first prompt and every test that builds a turn by hand. The word
        # the label always was is the right thing to fall back to.
        label: state.turn.label || "Processing",
        elapsed: elapsed(state),
        frame: state.turn.frame,
        phase: status_phase(state),
        delegation: state.turn.delegation
      }
    end

    # The phase with its clock already read: `render/2` runs at frame rate, and the
    # clock is this struct's — a host's module has no way to reach the same one, so
    # a phase carrying a raw timestamp would be one nobody else could time.
    defp status_phase(%TUI{turn: %{phase: nil}}), do: nil

    defp status_phase(%TUI{turn: %{phase: phase}} = state) do
      elapsed_ms = max(state.clock.() - phase.since, 0)

      %{
        kind: phase.kind,
        detail: phase.detail,
        for: div(elapsed_ms, 1_000),
        elapsed_ms: elapsed_ms
      }
    end

    @doc false
    @spec elapsed(TUI.t()) :: non_neg_integer()
    def elapsed(%TUI{turn: %{started_at: nil}}), do: 0
    def elapsed(state), do: max(div(state.clock.() - state.turn.started_at, 1_000), 0)
    # The rows the pane can give the transcript: its height less the border,
    # less what the live row is spending, which the scrollback arithmetic
    # cannot also hand to the transcript.
    @doc false
    @spec visible(TUI.t()) :: non_neg_integer()
    def visible(state), do: visible(state, transcript_pane(state))

    # Keep the row count fixed as the bottom rail appears or disappears.
    # Gaining a row at offset zero made one Page Down stop one row early and
    # moved a selection under a stationary pointer at the scroll boundary.
    @doc false
    @spec visible(TUI.t(), Rect.t()) :: non_neg_integer()
    def visible(state, %Rect{} = pane),
      do: max(inner(pane.height) - length(live_rows(state, inner(pane.width))), 0)
  end
end
