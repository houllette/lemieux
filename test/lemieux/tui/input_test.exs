defmodule Lemieux.TUI.InputTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Event.Paste
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.BigText
  alias ExRatatui.Widgets.Block.Title, as: BlockTitle
  alias ExRatatui.Widgets.List
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Tabs
  alias ExRatatui.Widgets.Textarea
  alias Lemieux.CLI.SessionIndex
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Entry
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.ID.Shorthand
  alias Lemieux.MCP.Config, as: MCPConfig
  alias Lemieux.Providers.Scripted
  alias Lemieux.Reference
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  alias Lemieux.TUI.Selection

  @frame %Frame{width: 80, height: 24}

  describe "the screen" do
    test "wraps the draft and grows to five text rows before scrolling" do
      state = tui()
      :ok = ExRatatui.textarea_insert_str(state.input, String.duplicate("word ", 90))

      [{_transcript, transcript}, {_status, _}, {%Textarea{} = input, composer}] =
        TUI.render(state, @frame)

      assert input.wrap_mode == :word_or_glyph
      assert composer.height == 7
      assert transcript.height == 16
      assert typed(state) == String.duplicate("word ", 90)

      :ok = ExRatatui.textarea_set_value(state.input, "short\nsecond")
      [{_, _}, {_, _}, {_, composer}] = TUI.render(state, @frame)
      assert composer.height == 4
    end

    test "up and down move through draft lines while Alt+Up still browses history" do
      state = tui(history: ["older prompt"])
      :ok = ExRatatui.textarea_insert_str(state.input, "first\nsecond")
      assert caret(state) == {1, 6}

      above = press(state, "up")
      assert caret(above) == {0, 5}
      assert typed(above) == "first\nsecond"

      below = press(above, "down")
      assert caret(below) == {1, 5}
      assert typed(press(below, "up", ["alt"])) == "older prompt"

      :ok = ExRatatui.textarea_set_value(state.input, "first\nsecond")
      top = state |> press("up")
      oldest = press(top, "up")
      assert typed(oldest) == "older prompt"
      assert typed(press(oldest, "down")) == "first\nsecond"
    end

    test "down on the current draft moves the caret to its end" do
      state = tui() |> type("current draft") |> press("home")
      assert caret(state) == {0, 0}
      moved = press(state, "down")
      assert caret(moved) == {0, 13}
      assert typed(moved) == "current draft"

      multiline = tui() |> type("first\nsecond") |> press("home")
      assert caret(multiline) == {1, 0}
      assert caret(press(multiline, "down")) == {1, 6}
    end

    test "is laid out to fill the frame, and nothing is drawn outside it" do
      widgets = TUI.render(tui(), @frame)

      assert [_, _, {%Textarea{}, input}, {%Paragraph{wrap: true}, hint}] = widgets
      assert hint.x == input.x + 1
      assert hint.y == input.y + 1
      assert hint.width == input.width - 2

      for {_widget, rect} <- widgets do
        assert rect.x + rect.width <= @frame.width
        assert rect.y + rect.height <= @frame.height
      end

      # The three panes tile the height rather than overlapping: a transcript
      # drawn under the input box is the bug this catches.
      assert widgets
             |> Enum.take(3)
             |> Enum.map(fn {_widget, rect} -> {rect.y, rect.height} end)
             |> Enum.sort()
             |> Enum.reduce(0, fn {y, height}, next ->
               assert y == next
               y + height
             end) == @frame.height
    end

    test "puts the status below the input" do
      [
        {%Paragraph{}, transcript_rect},
        {%Paragraph{}, status_rect},
        {%Textarea{}, input_rect},
        {%Paragraph{wrap: true}, _hint_rect}
      ] = TUI.render(tui(), @frame)

      assert input_rect.y == transcript_rect.y + transcript_rect.height
      assert status_rect.y == input_rect.y + input_rect.height
    end

    # The id stays out of the header for the reason it always did — nobody can
    # act on a ULID — and the name goes in for the reason the id could not:
    # it is the argument `--resume` takes tomorrow.
    test "shows the session name, provider, model, and effort, but never the raw id" do
      rendered = screen(tui())

      assert rendered =~
               "#{app_label()} · #{Shorthand.of("01SESSION")} · test · model · effort default"

      refute rendered =~ "01SESSION"
    end

    test "uses copy-friendly horizontal transcript rails without lateral border glyphs" do
      {%Paragraph{block: block}, _rect} = Elixir.List.first(TUI.render(tui(), @frame))

      assert block.borders == [:top]
      assert block.padding == {1, 1, 0, 0}
    end
  end

  # Capturing the mouse for the wheel takes the terminal's own drag selection
  # with it, so the screen selects for itself. These drive the real event
  # handlers; `Lemieux.TUI.SelectionTest` covers the arithmetic.
  describe "selecting transcript text" do
    test "a plain click opens a rendered Markdown link while dragging still selects" do
      owner = self()
      opener = fn target -> send(owner, {:opened, target}) end

      state =
        sized(tui(lines: [{:model, "Visit [Google](https://google.com)"}], open_link: opener))

      clicked = events(state, [{"down", 10, 1}, {"up", 10, 1}])
      assert_receive {:opened, "https://google.com"}
      assert clicked.selection == nil

      dragged = events(state, [{"down", 10, 1}, {"drag", 16, 1}, {"up", 16, 1}])
      assert dragged.selection
      refute_receive {:opened, "https://google.com"}
    end

    test "a code-styled command is inert while the adjacent local doc opens" do
      owner = self()
      opener = fn target -> send(owner, {:opened, target}) end

      state =
        sized(
          tui(
            cwd: File.cwd!(),
            lines: [{:model, "Use `lmx`: docs/getting-started.md"}],
            open_link: opener
          )
        )

      events(state, [{"down", 6, 1}, {"up", 6, 1}])
      refute_receive {:opened, _target}, 20

      events(state, [{"down", 13, 1}, {"up", 13, 1}])
      assert_receive {:opened, target}
      assert target == Path.join(File.cwd!(), "docs/getting-started.md")
    end

    test "an opener failure is a temporary status hint rather than a transcript error" do
      state = tui(lines: [{:model, "[guide](https://example.com)"}])

      assert {:noreply, failed} =
               TUI.handle_info({:open_link_result, {:error, {:opener_failed, 1}}}, state)

      assert status_row(failed) =~ "could not open link · opener exited 1"
      refute screen(failed) =~ "could not open link:"

      assert {:noreply, cleared} =
               TUI.handle_info({:feedback_expired, failed.terminal.feedback.token}, failed)

      refute status_row(cleared) =~ "could not open link"
    end

    # The frame is 24 high and 80 wide: the transcript pane is rows 0..19 with
    # a one-cell border, so content is screen rows 1..18 and columns 1..78.
    # The window picks the newest rows and the pane paints them from its top,
    # so a short transcript sits at screen row 1 and a full one reaches 18.
    defp picked(state, {from_x, from_y}, {to_x, to_y}) do
      events(state, [{"down", from_x, from_y}, {"drag", to_x, to_y}, {"up", to_x, to_y}])
    end

    defp release(state, {x, y}),
      do: TUI.handle_event(%Mouse{kind: "up", button: "left", x: x, y: y}, state)

    defp copying do
      owner = self()

      fn text ->
        send(owner, {:copied, text})
        :ok
      end
    end

    defp selectable(lines) do
      sized(tui(lines: lines, clipboard: copying()))
    end

    test "a drag copies what it covered, and the pane shows what was taken" do
      state = selectable([{:lmx, "lib/lemieux/session.ex"}])

      selected = picked(state, {1, 1}, {22, 1})

      assert_receive {:copied, "lib/lemieux/session.ex"}
      assert selected.selection
      refute Selection.empty?(selected.selection)
      assert status_row(selected) =~ "copied 22 characters"

      assert {:noreply, cleared} =
               TUI.handle_info({:feedback_expired, selected.terminal.feedback.token}, selected)

      refute status_row(cleared) =~ "copied"
    end

    test "the highlight reaches the drawn frame, keeping the styles under it" do
      state = selectable([{:lmx, "lib/lemieux/session.ex"}])
      selected = picked(state, {1, 1}, {11, 1})

      assert_receive {:copied, "lib/lemieux"}

      [{%Paragraph{text: [line | _rest]}, _rect} | _panes] = TUI.render(selected, @frame)

      # Reversed where the drag was, and the row's own italic kept throughout:
      # a selection that repainted the transcript's semantic styles would hide
      # what somebody is reading closely enough to copy.
      assert Enum.map(line.spans, &{&1.content, &1.style.modifiers}) == [
               {"lib/lemieux", [:italic, :reversed]},
               {"/session.ex", [:italic]}
             ]
    end

    test "a click copies nothing and clears the last selection" do
      state = selectable([{:lmx, "lib/lemieux/session.ex"}])
      selected = picked(state, {1, 1}, {10, 1})
      assert_receive {:copied, _text}

      clicked = picked(selected, {5, 1}, {5, 1})

      refute clicked.selection
      refute_receive {:copied, _text}
    end

    test "a drag outside the transcript selects nothing" do
      state = selectable([{:lmx, "a line"}])

      # Row 21 is the status line; row 22 is inside the input box.
      untouched = picked(state, {4, 21}, {10, 22})

      refute untouched.selection
      refute_receive {:copied, _text}
    end

    # A selection is stored as a distance back from the newest row, so neither
    # scrolling nor the model talking moves it off the text it covers. Both
    # used to drop it, which capped a selection at one screen of a transcript
    # that was standing still.
    test "a selection survives scrolling away from it" do
      state = selectable(for n <- 1..100, do: {:lmx, "row #{n} of the transcript"})

      selected = picked(state, {1, 18}, {40, 18})
      assert_receive {:copied, "row 100 of the transcript"}

      scrolled = press(selected, "page_up")
      assert scrolled.selection == selected.selection
      assert scrolled.scroll > 0

      # Released from where the pane is no longer showing it: copying asks the
      # window for the selection's own rows, not the visible ones.
      assert {:noreply, kept} = release(scrolled, {40, 18})
      assert_receive {:copied, "row 100 of the transcript"}
      assert kept.selection
    end

    test "esc clears the selection, because something has to" do
      state = selectable(for n <- 1..100, do: {:lmx, "line #{n}"})
      selected = picked(state, {1, 18}, {6, 18})
      assert selected.selection

      assert press(selected, "esc").selection == nil
    end

    # The transcript growing underneath a highlight happens on every streamed
    # fragment, and the count of rows that arrived is exactly how far back the
    # selected text moved.
    test "an arriving answer moves the selection with its own text" do
      state = selectable([{:lmx, "the important path"}])
      selected = picked(state, {1, 1}, {18, 1})
      assert_receive {:copied, "the important path"}

      assert {:noreply, grown} =
               TUI.handle_info({:lemieux, "01SESSION", {:text_delta, "new answer"}}, selected)

      assert grown.selection
      refute grown.selection == selected.selection

      assert {:noreply, _state} = release(grown, {18, 1})
      assert_receive {:copied, "the important path"}
    end

    # Dragging past the pane's edge is how a selection covers more rows than
    # the pane has: the alternative is a selection that stops at the border of
    # a transcript you can scroll.
    test "a drag past the top edge scrolls, and keeps selecting" do
      state = selectable(for n <- 1..100, do: {:lmx, "row #{n} of the transcript"})

      dragged =
        events(state, [
          {"down", 40, 18},
          {"drag", 1, 0},
          {"drag", 1, 0},
          {"up", 1, 0}
        ])

      # A wheel notch per drag event, so the scroll still follows the hand
      # rather than running away from it — but covers ground at the rate
      # every other way of scrolling this pane does. A terminal reports a
      # pointer clamped to its own grid, so pushing harder against the top
      # row sends nothing at all; one row per event made a long drag a wrist
      # exercise.
      assert dragged.scroll == 6

      assert_receive {:copied, copied}
      rows = String.split(copied, "\n")

      # Twenty-four rows out of an eighteen-row pane.
      assert length(rows) == 24
      assert hd(rows) == "row 77 of the transcript"
      assert Enum.at(rows, -1) == "row 100 of the transcript"
    end

    # Held still, nothing arrives and nothing moves: the scroll is driven by
    # the drag events a moving hand sends, not by a timer that would carry on
    # to the top of the session while somebody thought about where to let go.
    test "a drag that stays inside the pane does not scroll at all" do
      state = selectable(for n <- 1..100, do: {:lmx, "row #{n} of the transcript"})

      dragged =
        events(state, [
          {"down", 40, 18},
          {"drag", 20, 10},
          {"drag", 10, 4},
          {"up", 10, 4}
        ])

      assert dragged.scroll == 0
    end

    # The one edit a depth cannot follow: rows vanishing from the middle move
    # everything above them by an amount that depends on where they were, and
    # the append count says nothing about that.
    test "a tool result replacing its own rows drops the selection" do
      state = selectable([{:lmx, "the important path"}])
      selected = picked(state, {1, 1}, {18, 1})
      assert selected.selection

      call = %{id: "bash-1", name: "bash", arguments: %{"command" => "mix test"}}

      result =
        Entry.new(:tool_result, %{
          "call_id" => "bash-1",
          "name" => "bash",
          "arguments" => call.arguments,
          "output" => "ok",
          "error" => false
        })

      # The announcement alone only appends, so the selection survives that.
      announced = info(selected, {:tool_call, call})
      assert announced.selection

      refute info(announced, {:entry, result}).selection
    end

    test "a terminal with no clipboard says so rather than failing silently" do
      state =
        sized(
          tui(lines: [{:lmx, "a line"}], clipboard: fn _ -> {:error, :unsupported_transport} end)
        )

      told = picked(state, {1, 1}, {5, 1})

      refute told.selection

      assert Enum.any?(
               told.lines,
               &match?({:lmx, "this terminal transport has no clipboard" <> _}, &1)
             )
    end
  end

  describe "scrolling back" do
    # The frame is 24 high: 3 for the input, 1 for the status, 20 for the
    # transcript pane, of which 2 are its border. So 18 rows are visible.
    defp scrolling(n), do: sized(tui(lines: said(n)))

    test "shows the newest lines until somebody asks for older ones" do
      state = scrolling(100)

      assert screen(state) =~ "line 100"
      refute screen(state) =~ "line 50"
    end

    test "page up moves back by a screenful and page down returns" do
      state = scrolling(100) |> press("page_up")

      assert state.scroll > 0
      refute screen(state) =~ "line 100"
      assert screen(state) =~ "line 70"

      assert press(state, "page_down").scroll == 0
    end

    test "mouse wheel and shift-arrows scroll by a few rows" do
      state = scrolling(100)

      assert {:noreply, wheeled} =
               TUI.handle_event(%Mouse{kind: "scroll_up"}, state)

      assert wheeled.scroll == 3
      assert press(wheeled, "down", ["shift"]).scroll == 0
      assert press(state, "up", ["shift"]).scroll == 3
    end

    test "a wheel burst defers intermediate paints and flushes before another action" do
      state = sized(tui(lines: said(100), scroll_coalesce?: true))

      {:noreply, one, render?: false} =
        TUI.handle_event(%Mouse{kind: "scroll_up"}, state)

      {:noreply, two, render?: false} =
        TUI.handle_event(%Mouse{kind: "scroll_up"}, one)

      assert two.scroll == 6
      assert two.terminal.row_cache == nil

      # A click must observe the final wheel position even if its timer has
      # not fired. The bottom marker is centered on row 19.
      assert {:noreply, clicked} =
               TUI.handle_event(%Mouse{kind: "down", button: "left", x: 40, y: 19}, two)

      assert clicked.scroll == 0
      assert clicked.terminal.scroll_pending == nil
      assert clicked.terminal.row_cache
    end

    # The regression this is here for: paging measured the transcript with the
    # two-tuple default renderer while the pane drew it with the rich one, so
    # the first Page Up over a transcript containing a tool output row — which
    # is every real transcript — crashed the app outright.
    test "paging over every row the transcript actually stores" do
      lines =
        [
          {:you, "read the config"},
          {:tool_heading, "call_1", :read, "read", "config.yaml"},
          {:tool_detail, "call_1", :ordinary, "timeout_seconds: 30"},
          {:tool_output, "call_1", :first, :ok, "timeout_seconds: 30"},
          {:tool_output, "call_1", :rest, :ok, ""},
          {:tool_question, "call_2", "Which one?"},
          {:tool_option, "call_2", 1, "the first", "a description"},
          {:tool_answer, "call_2", "the first"},
          {:tool_code, "call_3", :add, []},
          {:subagent_child,
           %{
             id: "child_1",
             name: "holden-gretzky",
             kind: "explore",
             goal: "find the config",
             status: "running",
             activity: "read",
             count: 2,
             text: "read config.yaml"
           }},
          {:summary, "3 reqs · 1.2k tokens"},
          {:space, ""},
          {:model, "The default is 30 seconds."}
        ] ++ said(60)

      state = sized(tui(lines: lines))

      assert {:noreply, paged} = TUI.handle_event(key("page_up"), state)
      assert paged.scroll > 0
      assert is_binary(screen(paged))

      # And back down again, and past the beginning, without ever measuring a
      # row the pane would not draw.
      deep = Enum.reduce(1..12, state, fn _n, state -> press(state, "page_up") end)
      assert screen(deep) =~ "read the config"
      assert press(deep, "page_down").scroll < deep.scroll
    end

    test "paging past the beginning stops at it rather than scrolling into nothing" do
      state = scrolling(5)

      state = Enum.reduce(1..10, state, fn _n, state -> press(state, "page_up") end)

      assert screen(state) =~ "line 1"
      assert screen(state) =~ "line 5"
    end

    test "says how far back it is, because a still pane looks like a stopped agent" do
      scrolled = scrolling(100) |> press("page_up")
      [{%Paragraph{block: block}, _rect} | _] = TUI.render(scrolled, @frame)

      assert [%BlockTitle{content: title, alignment: :center, position: :bottom} | _] =
               block.titles

      assert title =~ "↓ #{scrolled.scroll} lines below · click for latest"
      assert hd(block.titles).style.fg == :yellow
      assert block.borders == [:top, :bottom]

      [{%Paragraph{block: bottom_block}, _rect} | _] = TUI.render(scrolling(100), @frame)
      assert bottom_block.borders == [:top]
      refute screen(scrolling(100)) =~ "lines below"
    end

    test "clicking the centered scrollback marker returns to the latest rows" do
      scrolled = scrolling(100) |> press("page_up")
      assert scrolled.scroll > 0

      latest = events(scrolled, [{"down", 40, 19}])
      assert latest.scroll == 0
      assert screen(latest) =~ "line 100"
    end

    test "typing and submitting keep scrollback in place" do
      session = fake_session(snapshot("01SESSION"))
      scrolled = sized(tui(session: session, lines: said(100))) |> press("page_up")
      typed = type(scrolled, "follow up")

      assert typed.scroll == scrolled.scroll
      sent = press(typed, "enter")
      assert_receive {:prompted, "follow up"}
      assert sent.scroll > 0
      assert screen(sent) =~ "click for latest"
    end

    test "a transcript at the bottom follows what arrives" do
      {:noreply, state} =
        TUI.handle_info({:lemieux, "01SESSION", {:text_delta, "new"}}, scrolling(100))

      assert state.scroll == 0
      assert screen(state) =~ "new"
    end

    test "a transcript scrolled back holds its place while the model talks" do
      state = scrolling(100) |> press("page_up")
      was = state.scroll

      {:noreply, state} =
        TUI.handle_info({:lemieux, "01SESSION", {:text_delta, "and more"}}, state)

      # The same text, still: rows arriving underneath a reader must not slide
      # what they are reading off the top.
      assert screen(state) =~ "line 67"
      assert screen(state) =~ "line 84"
      refute screen(state) =~ "and more"

      # And the distance to the bottom grew by the response row, which is what
      # holding the text still *means* when the offset is measured from the
      # bottom.
      assert state.scroll == was + 1
    end

    test "and returns to following once it is scrolled back to the bottom" do
      state = scrolling(100) |> press("page_up") |> press("page_down")

      {:noreply, state} =
        TUI.handle_info({:lemieux, "01SESSION", {:text_delta, "newest"}}, state)

      assert screen(state) =~ "newest"
    end
  end

  describe "typing" do
    test "Shift+Enter inserts one newline at the caret and its release never submits" do
      state = tui() |> type("first second") |> press("left") |> press("left")
      assert caret(state) == {0, 10}

      after_press = press(state, "enter", ["shift"])
      assert typed(after_press) == "first seco\nnd"
      assert caret(after_press) == {1, 0}
      assert after_press.lines == state.lines
      assert after_press.history.entries == []

      assert {:noreply, after_release} =
               TUI.handle_event(
                 %Key{code: "enter", kind: "release", modifiers: []},
                 after_press
               )

      assert typed(after_release) == "first seco\nnd"
      assert after_release.history.entries == []
    end

    test "Shift+Enter keeps the existing draft visible when the composer grows" do
      state = tui() |> type("keep this draft")
      terminal = ExRatatui.init_test_terminal(@frame.width, @frame.height)

      assert :ok = ExRatatui.draw(terminal, TUI.render(state, @frame))
      assert ExRatatui.get_buffer_content(terminal) =~ "keep this draft"

      continued = press(state, "enter", ["shift"])
      assert :ok = ExRatatui.draw(terminal, TUI.render(continued, @frame))

      screen = ExRatatui.get_buffer_content(terminal)
      assert screen =~ "keep this draft"
      assert typed(continued) == "keep this draft\n"
      assert caret(continued) == {1, 0}
      assert continued.history.entries == []
    end

    test "a printable key lands in the input box" do
      assert tui() |> type("hello") |> typed() == "hello"
    end

    test "and shows up on screen, because a terminal is not echoing it here" do
      assert tui() |> type("hello") |> screen() =~ "hello"
    end

    test "a space is a printable key like any other" do
      assert tui() |> type("say hi") |> typed() == "say hi"
    end

    test "backspace takes one back" do
      assert tui() |> type("hello") |> press("backspace") |> typed() == "hell"
    end

    test "backspace on an empty line is not an error" do
      assert tui() |> press("backspace") |> typed() == ""
    end

    test "a key that is not a character is ignored rather than inserted" do
      assert tui() |> type("hi") |> press("f5") |> typed() == "hi"
    end

    # The editing itself is the widget's; what these check is that the keys
    # reach it at all, which is the half that silently does nothing when a
    # binding is missing.
    test "the cursor moves, and typing lands where it is" do
      state = tui() |> type("helo") |> press("left")

      assert caret(state) == {0, 3}
      assert state |> type("l") |> typed() == "hello"
    end

    test "home and end reach the ends" do
      state = tui() |> type("world") |> press("home") |> type("hello ")

      assert typed(state) == "hello world"
      assert state |> press("end") |> type("!") |> typed() == "hello world!"
    end

    test "ctrl-w takes back a word" do
      assert tui() |> type("say hello") |> press("w", ["ctrl"]) |> typed() == "say "
    end

    test "alt-b moves back a word without deleting it" do
      assert tui() |> type("say hello") |> press("b", ["alt"]) |> type("X") |> typed() ==
               "say Xhello"
    end

    # The reason for handing the box to the library rather than hand-rolling
    # it: selection is the part not worth writing twice.
    test "shift and an arrow select, and typing replaces the selection" do
      state =
        tui()
        |> type("hello")
        |> press("home")
        |> press("right", ["shift"])
        |> press("right", ["shift"])
        |> type("X")

      assert typed(state) == "Xllo"
    end

    test "enter inside a paste makes a line rather than sending" do
      state = tui()

      assert {:noreply, state} =
               TUI.handle_event(%ExRatatui.Event.Paste{content: "one\ntwo"}, state)

      assert typed(state) == "one\ntwo"
    end

    test "ctrl-c requires a quick second press to leave" do
      assert {:noreply, armed} = TUI.handle_event(key("c", ["ctrl"]), tui())
      assert screen(armed) =~ "ctrl-c again to leave"
      assert {:stop, _state} = TUI.handle_event(key("c", ["ctrl"]), armed)
    end

    test "ctrl-c after the 750ms window arms a new exit instead" do
      expired = %{tui() | exit_armed: {make_ref(), System.monotonic_time(:millisecond) - 1}}

      assert {:noreply, rearmed} = TUI.handle_event(key("c", ["ctrl"]), expired)
      assert rearmed.exit_armed != expired.exit_armed
    end

    test "the ctrl-c exit prompt expires and is not otherwise displayed" do
      refute screen(tui()) =~ "ctrl-c"

      assert {:noreply, %{exit_armed: {token, _expires_at}} = armed} =
               TUI.handle_event(key("c", ["ctrl"]), tui())

      assert {:noreply, disarmed} = TUI.handle_info({:ctrl_c_expired, token}, armed)
      assert disarmed.exit_armed == nil
      refute screen(disarmed) =~ "ctrl-c"
    end

    # Ctrl-C is the exit chord. Plain "c" is a letter somebody is typing, and
    # a TUI that quit on it would be unusable.
    test "and a plain c is just a letter" do
      assert {:noreply, state} = TUI.handle_event(key("c"), tui())
      assert typed(state) == "c"
    end
  end

  describe "the habs easter egg" do
    # Hidden means hidden: a command that shows up in `/help` or in the
    # completion menu is a feature, and this one is a joke.
    test "/habs is absent from help and from the completion menu" do
      refute Lemieux.Conversation.help() =~ "/habs"
      refute Enum.any?(suggestions(tui() |> type("/")).items, &(&1 =~ "habs"))
      assert tui() |> type("/hab") |> suggestions() == nil
    end

    test "/habs animates over the screen and hands it back untouched" do
      state = tui(lines: [{:model, "an answer worth keeping"}]) |> type("/habs")

      assert screen(state) =~ "an answer worth keeping"

      state = press(state, "enter")

      assert %{frame: 0, tick: tick} = state.overlay
      assert banner(state) =~ "GO"
      refute screen(state) =~ "an answer worth keeping"

      state = run_overlay(state, tick)

      assert is_nil(state.overlay)
      assert screen(state) =~ "an answer worth keeping"
    end

    # Every frame the animation asks for, until it stops asking.
    defp run_overlay(state, tick, steps \\ 40)

    defp run_overlay(%{overlay: nil} = state, _tick, _steps), do: state

    defp run_overlay(state, tick, steps) when steps > 0 do
      assert {:noreply, state} = TUI.handle_info({:habs_tick, tick}, state)

      run_overlay(state, tick, steps - 1)
    end

    defp banner(state) do
      state
      |> TUI.render(@frame)
      |> Enum.find_value("", fn
        {%BigText{lines: lines}, _rect} ->
          Enum.map_join(lines, &Enum.map_join(&1.spans, fn span -> span.content end))

        _other ->
          nil
      end)
    end
  end

  describe "slash command autocomplete" do
    test "a slash shows known commands and a prefix narrows them" do
      all = tui() |> type("/") |> suggestions()
      assert Enum.any?(all.items, &String.starts_with?(&1, "/help"))
      assert Enum.any?(all.items, &String.starts_with?(&1, "/model"))
      assert Enum.any?(all.items, &String.starts_with?(&1, "/mcp"))
      assert Enum.any?(all.items, &String.starts_with?(&1, "/copy"))

      assert tui()
             |> type("/tools")
             |> suggestions()
             |> Map.fetch!(:items)
             |> Enum.any?(&String.starts_with?(&1, "/tools"))

      only = tui() |> type("/can") |> suggestions()
      assert only.items == ["/cancel — stop the current turn"]
    end

    # A menu nobody can see all of at once is a menu somebody scans, and the
    # order `@commands` happens to be written in is not one anybody can
    # predict. Skills sort in with the rest rather than after them: a skill is
    # a command to whoever typed the slash, and a second alphabet starting
    # halfway down is worse than no alphabet at all.
    test "commands and skills are one alphabetical list" do
      skills = [
        %Skill{
          name: "zamboni",
          description: "resurface",
          source: :project,
          path: "z.md",
          root: "."
        },
        %Skill{name: "audit", description: "check", source: :project, path: "a.md", root: "."}
      ]

      state = tui(skills: skills) |> type("/")
      [_, total] = Regex.run(~r/\/(\d+)/, suggestions(state).block.title)

      {items, _state} =
        Enum.map_reduce(1..String.to_integer(total), state, fn _, state ->
          menu = suggestions(state)
          {Enum.at(menu.items, menu.selected), press(state, "down")}
        end)

      names = Enum.map(items, &(&1 |> String.split(" — ") |> hd()))

      assert names == Enum.sort(names)
      assert "/audit" in names
      assert "/zamboni" in names

      assert Enum.find_index(names, &(&1 == "/audit")) <
               Enum.find_index(names, &(&1 == "/cancel"))
    end

    test "/mcp has one completion and no argument menu" do
      state = tui() |> type("/mcp")
      assert suggestions(state).items == ["/mcp — list and manage MCP servers"]
      assert suggestions(tui() |> type("/mcp ")) == nil
    end

    # The regression this is here for: seven visible rows against seventeen
    # commands put `/elixir` below a fold with nothing on screen admitting
    # there was one, and it read as the command having been removed.
    test "every command is reachable and the menu says when it scrolls" do
      state = tui(commands: Builtin.elixir()) |> type("/")
      items = suggestions(state).items
      rect = suggestion_rect(state)

      elixir = Enum.find_index(items, &String.starts_with?(&1, "/elixir"))
      assert elixir, "/elixir is missing from the completion list"
      assert elixir < rect.height - 2, "/elixir is below the visible fold"

      titles =
        Enum.map_join(state |> TUI.render(@frame), " ", fn
          {%List{block: block}, _rect} -> block.title
          _other -> ""
        end)

      assert Regex.match?(~r/completions 1\/\d+/, titles)
      assert [%BlockTitle{content: content, position: :bottom}] = suggestions(state).block.titles
      assert content =~ "more options below"
    end

    test "completion overflow markers track hidden options above and below" do
      models =
        for number <- 1..30,
            do: "test:choice-#{number |> Integer.to_string() |> String.pad_leading(2, "0")}"

      first = tui(models: models) |> type("/model ")

      assert [%BlockTitle{content: " ↓ 12 more options below ", position: :bottom}] =
               suggestions(first).block.titles

      first_rect = suggestion_rect(first)

      assert painted_row(first, first_rect.y + first_rect.height - 1) =~
               "↓ 12 more options below"

      middle = Enum.reduce(1..20, first, fn _, state -> press(state, "down") end)

      assert suggestions(middle).selected == 16

      assert [
               %BlockTitle{content: " ↑ 4 more options above ", position: :top},
               %BlockTitle{content: " ↓ 8 more options below ", position: :bottom}
             ] =
               suggestions(middle).block.titles

      middle_rect = suggestion_rect(middle)
      assert painted_row(middle, middle_rect.y) =~ "↑ 4 more options above"

      assert painted_row(middle, middle_rect.y + middle_rect.height - 1) =~
               "↓ 8 more options below"

      last = Enum.reduce(1..9, middle, fn _, state -> press(state, "down") end)

      assert [%BlockTitle{content: " ↑ 12 more options above ", position: :top}] =
               suggestions(last).block.titles

      assert last |> press("tab") |> typed() == "/model choice-30"
    end

    test "arguments and ordinary messages do not open command suggestions" do
      assert tui() |> type("hello") |> suggestions() == nil
      assert tui() |> type("/attach myapp") |> suggestions() == nil
    end

    # `/elixir` swaps the catalog for the elixir tool, and a host that shares
    # one session between people refuses that tool by policy. Offering the
    # command anyway advertised something the session could only refuse, and
    # the only way to find out was to run it and read the error.
    test "a command the session's profile can never run is not offered" do
      state = tui(elixir_decision: {:deny, :default_off_shared}, commands: Builtin.elixir())

      refute Enum.any?(suggestions(state |> type("/")).items, &String.starts_with?(&1, "/elixir"))

      # And nothing else claims it either: `/el` matched only `/elixir`, so
      # with it gone the menu has nothing to show rather than a stale row.
      assert suggestions(state |> type("/el")) == nil
    end

    test "it is still offered when the profile allows the tool" do
      state = tui(elixir_decision: :allow, commands: Builtin.elixir()) |> type("/")

      assert Enum.any?(suggestions(state).items, &String.starts_with?(&1, "/elixir"))
    end

    test "a host command policy hides commands from autocomplete" do
      policy = fn
        :mcp_status -> {:deny, "MCP is disabled by this host"}
        {:attach, nil} -> {:deny, "attach is disabled by this host"}
        _action -> :allow
      end

      suggestions =
        tui(command_policy: policy, commands: Builtin.elixir()) |> type("/") |> suggestions()

      refute Enum.any?(suggestions.items, &String.starts_with?(&1, "/mcp"))
      refute Enum.any?(suggestions.items, &String.starts_with?(&1, "/attach"))
      assert Enum.any?(suggestions.items, &String.starts_with?(&1, "/elixir"))
    end

    test "a host command policy filters help and denies a typed command at dispatch" do
      test = self()

      policy = fn
        :mcp_status ->
          {:deny, "MCP is disabled by this host"}

        {:mcp_add, path} = action ->
          send(test, {:command_policy, action})
          {:deny, "MCP configuration is disabled by this host: #{path}"}

        {:mcp_remove, _name} ->
          {:deny, "MCP configuration is disabled by this host"}

        {:mcp_reconnect, _name} ->
          {:deny, "MCP configuration is disabled by this host"}

        _action ->
          :allow
      end

      help = tui(command_policy: policy) |> type("/help") |> press("enter")
      refute screen(help) =~ "/mcp"

      denied = help |> type("/mcp add mcp.json") |> press("enter")

      refute_received {:command_policy, {:mcp_add, _path}}
      assert screen(denied) =~ "MCP is disabled by this host"
    end

    test "attach is authorized independently from the elixir tool command" do
      session = fake_session(snapshot("01SESSION"))

      policy = fn
        {:attach, _target} -> {:deny, "attach is disabled by this host"}
        _action -> :allow
      end

      denied =
        tui(session: session, command_policy: policy, commands: Builtin.elixir())
        |> type("/attach myapp")
        |> press("enter")

      assert screen(denied) =~ "attach is disabled by this host"
      refute_receive {:attach, "myapp"}

      _elixir = denied |> type("/elixir") |> press("enter")
      assert_receive {:set_tools, ["elixir", "ask_user"]}
    end

    test "tool completion omits names outside the immutable profile cap" do
      state =
        tui(
          tool_statuses: [
            %{name: "read", source: :local, allowed?: true, enabled?: false},
            %{name: "elixir", source: :local, allowed?: false, enabled?: false}
          ]
        )
        |> type("/tools enable ")

      assert suggestions(state).items == ["read"]
    end

    test "up and down move the selection and tab completes without submitting" do
      state = tui() |> type("/co")
      assert suggestions(state).selected == 0
      assert state |> press("down") |> suggestions() |> Map.fetch!(:selected) == 1

      completed = state |> press("down") |> press("tab")
      assert typed(completed) == "/compact"
      assert caret(completed) == {0, 8}
      assert suggestions(completed) == nil
      refute completed.conversation.busy?
    end

    test "escape clears the input and closes suggestions" do
      cleared = tui() |> type("/can") |> press("esc")

      assert typed(cleared) == ""
      assert suggestions(cleared) == nil
    end

    test "provider, provider-scoped model, and effort values are searchable" do
      provider =
        tui(providers: ["anthropic", "openai"])
        |> type("/provider open")

      assert suggestions(provider).items == ["openai"]
      assert provider |> press("tab") |> typed() == "/provider openai"

      model =
        tui(models: ["openai:gpt-5", "openai:o3:mini"])
        |> type("/model o3")

      assert suggestions(model).items == ["o3:mini"]
      assert model |> press("tab") |> typed() == "/model o3:mini"

      effort = tui(efforts: ["default", "low", "high"]) |> type("/effort hi")
      assert suggestions(effort).items == ["high"]
      assert effort |> press("tab") |> typed() == "/effort high"
    end

    test "tool actions and available tool names are searchable" do
      actions = tui() |> type("/tools en") |> suggestions()
      assert actions.items == ["enable"]

      tools =
        tui(
          tool_statuses: [
            %{name: "read", source: :local, enabled?: true},
            %{name: "github__search", source: {:mcp, "github"}, enabled?: false}
          ]
        )
        |> type("/tools enable sea")

      assert suggestions(tools).items == ["github__search"]
      assert tools |> press("tab") |> typed() == "/tools enable github__search"
    end

    test "resume completions use recent-session labels and exclude the current session" do
      current = %SessionIndex{id: "01SESSION", model: "test:model", preview: "current"}
      older = %SessionIndex{id: "02OLDER", model: "openai:gpt-5", preview: "fix tests"}
      state = tui(sessions: [current, older]) |> type("/resume fix")

      assert suggestions(state).items == [SessionIndex.label(older)]

      # Tab leaves the name on the line, not the id: what completion writes is
      # also what a person can write down and type again next week.
      assert state |> press("tab") |> typed() == "/resume #{Shorthand.of("02OLDER")}"
    end

    test "Enter runs a highlighted leaf command and opens commands that take arguments" do
      leaf = tui() |> type("/hel") |> press("enter")

      assert typed(leaf) == ""
      assert hd(leaf.history.entries) == "/help"
      assert suggestions(leaf) == nil

      argument =
        tui(models: ["openai:gpt-5", "openai:o3:mini"])
        |> type("/mo")
        |> press("enter")

      assert typed(argument) == "/model "
      assert caret(argument) == {0, 7}
      assert suggestions(argument).items == ["gpt-5", "o3:mini"]
      assert suggestions(argument).selected == 0
    end
  end

  describe "re-attaching files that changed" do
    # `/refresh` used to be a command, and asking somebody to remember to run
    # it before mentioning a file is asking them to do the harness's job.
    # Typing `@` is the moment a person is thinking about files.
    test "typing @ re-reads what the conversation attached", %{} do
      session = fake_session(snapshot("01SESSION"), refresh: {:ok, 2})
      state = tui(session: session, cwd: File.cwd!(), clock: fn -> 0 end)

      refute_received {:refreshed, _session}

      state = type(state, "@")
      assert_receive {:refreshed, ^session}
      assert state.references.refreshed_at == 0

      # It re-attached something, so it says so — through the same wording
      # the typed command uses.
      assert_receive {:refresh_result, :automatic, {:ok, 2}}
      assert {:noreply, said} = TUI.handle_info({:refresh_result, :automatic, {:ok, 2}}, state)
      assert screen(said) =~ "re-attached 2 changed files"
    end

    # A path is typed one character at a time, and each one would otherwise
    # be a pass over every attachment.
    test "further typing inside the reference does not re-read again" do
      session = fake_session(snapshot("01SESSION"), refresh: {:ok, 0})
      state = tui(session: session, cwd: File.cwd!(), clock: fn -> 0 end)

      type(state, "@mix.e")

      assert_receive {:refreshed, ^session}
      refute_received {:refreshed, ^session}
    end

    test "the debounce lets it happen again later" do
      session = fake_session(snapshot("01SESSION"), refresh: {:ok, 0})
      clock = fn -> Process.get(:now, 0) end
      state = tui(session: session, cwd: File.cwd!(), clock: clock)

      state = type(state, "@")
      assert_receive {:refreshed, ^session}

      Process.put(:now, :timer.seconds(10))
      type(state, "x")
      assert_receive {:refreshed, ^session}
    end

    # Nobody asked for it, so "every attached file is current" would be a line
    # about nothing, and a session that got busy in between is not news.
    test "it says nothing when nothing changed, and nothing when it failed" do
      state = tui(session: fake_session(snapshot("01SESSION")))

      for result <- [{:ok, 0}, {:error, :busy}] do
        assert {:noreply, quiet} = TUI.handle_info({:refresh_result, :automatic, result}, state)
        assert quiet.lines == state.lines
      end
    end

    test "a mid-turn keystroke leaves the attachments alone" do
      session = fake_session(snapshot("01SESSION"))
      busy = %{Lemieux.Conversation.new() | busy?: true}

      type(tui(session: session, cwd: File.cwd!(), conversation: busy), "@")

      refute_received {:refreshed, ^session}
    end
  end

  describe "@ reference autocomplete" do
    @describetag :tmp_dir

    setup %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "mix.exs"), "")
      File.write!(Path.join(cwd, "README.md"), "")
      File.write!(Path.join(cwd, ".hidden"), "")
      File.mkdir_p!(Path.join(cwd, "lib"))
      File.write!(Path.join([cwd, "lib", "turn.ex"]), "")
      File.write!(Path.join([cwd, "lib", "session.ex"]), "")

      %{cwd: cwd}
    end

    test "a bare @ offers the working directory", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("@")

      # The environment's own order, which is what `read` lists a directory
      # in. A second ordering rule here would be a second thing to explain.
      assert suggestions(state).items == ["README.md", "lib/", "mix.exs"]
    end

    test "typing narrows by prefix", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("@RE")

      assert suggestions(state).items == ["README.md"]
    end

    test "hides dotfiles until a dot is typed", %{cwd: cwd} do
      refute ".hidden" in suggestions(tui(cwd: cwd) |> type("@")).items
      assert suggestions(tui(cwd: cwd) |> type("@.")).items == [".hidden"]
    end

    test "completing a file leaves a space, so the next word is prose", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("@RE") |> press("tab")

      assert typed(state) == "@README.md "
      assert suggestions(state) == nil
    end

    test "Enter accepts a file reference without submitting the prompt", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("explain @RE") |> press("enter")

      assert typed(state) == "explain @README.md "
      assert state.history.entries == []
      assert suggestions(state) == nil
    end

    test "completing a directory descends into it instead of sending it", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("@li") |> press("tab")

      assert typed(state) == "@lib/"
      assert suggestions(state).items == ["session.ex", "turn.ex"]

      assert state |> press("tab") |> typed() == "@lib/session.ex "
    end

    test "keeps the prose in front of the reference", %{cwd: cwd} do
      state = tui(cwd: cwd) |> type("explain @lib/tu") |> press("tab")

      assert typed(state) == "explain @lib/turn.ex "
    end

    test "quotes a name the prompt grammar could not read bare", %{cwd: cwd} do
      File.write!(Path.join(cwd, "last (final).md"), "")

      state = tui(cwd: cwd) |> type("@last") |> press("tab")

      assert typed(state) == "@\"last (final).md\" "
    end

    test "descends into a directory whose name has a space in it", %{cwd: cwd} do
      File.mkdir_p!(Path.join(cwd, "my notes"))
      File.write!(Path.join([cwd, "my notes", "a.md"]), "")

      state = tui(cwd: cwd) |> type("@my") |> press("tab")

      assert typed(state) == "@\"my notes/\""
      assert suggestions(state).items == ["a.md"]
      assert state |> press("tab") |> typed() == "@\"my notes/a.md\" "
    end

    # The claim the picker rests on: whatever Tab leaves on the line, the
    # session parses back as the same path. Without it the menu can offer a
    # file the prompt then declines to attach.
    test "every completion it offers is a reference the session can read back", %{cwd: cwd} do
      File.write!(Path.join(cwd, "last (final).md"), "")
      File.write!(Path.join(cwd, "a,b.ex"), "")

      items = suggestions(type(tui(cwd: cwd), "@")).items

      assert "last (final).md" in items
      assert "a,b.ex" in items

      for {item, index} <- Enum.with_index(items) do
        chosen =
          Enum.reduce(1..index//1, type(tui(cwd: cwd), "@"), fn _step, state ->
            press(state, "down")
          end)

        completed = chosen |> press("tab") |> typed()

        assert [%Reference{path: ^item}] = Reference.parse(completed),
               "completing #{inspect(item)} left #{inspect(completed)}, which does not read back"
      end
    end

    test "an email address is not a file picker", %{cwd: cwd} do
      assert suggestions(tui(cwd: cwd) |> type("mail someone@ex")) == nil
    end

    test "offers nothing before a session has said where it is working" do
      assert suggestions(tui() |> type("@")) == nil
    end

    test "a slash command still wins", %{cwd: cwd} do
      state = tui(cwd: cwd, providers: ["anthropic"]) |> type("/provider @")

      assert suggestions(state) == nil
    end

    test "a reference that is no longer the last word closes the menu", %{cwd: cwd} do
      assert suggestions(tui(cwd: cwd) |> type("@README.md and")) == nil
    end
  end

  describe "drafts while the agent is working" do
    defp working do
      session = fake_session(snapshot("01SESSION"))
      state = tui(session: session) |> sized()
      %{state | conversation: %{state.conversation | busy?: true}}
    end

    test "shows steer and queue choices as soon as a draft is typed" do
      state = working() |> type("one more thing")
      assert status_row(state) =~ "Enter steer · Tab queue"

      queued = press(state, "tab")
      assert typed(queued) == ""
      assert queued.history.queued == ["one more thing"]
      assert status_row(queued) =~ "queued for next turn"
      assert status_row(queued) =~ "Alt+1–9 select, Alt+E revise / Alt+U unstage"
      assert screen(queued) =~ "1. one more thing"
    end

    test "a slash command can be queued and runs only after the active turn" do
      queued = working() |> type("/compact") |> press("tab")

      assert queued.history.queued == ["/compact"]
      assert typed(queued) == ""
      refute_receive :compacting, 20

      finished = info(queued, {:finished, :stop})
      assert_receive :compacting
      assert_receive {:compaction_result, result}
      assert {:noreply, _settled} = TUI.handle_info({:compaction_result, result}, finished)
      assert finished.history.queued == []
      assert screen(finished) =~ "Compacting..."
    end

    test "a queued prompt waits for a queued compact command to finish" do
      queued =
        working()
        |> type("/compact")
        |> press("tab")
        |> type("follow-up")
        |> press("tab")

      compacting = info(queued, {:finished, :stop})
      assert_receive :compacting
      assert compacting.history.queued == ["follow-up"]
      refute_receive {:prompted, "follow-up"}, 20
      assert_receive {:compaction_result, result}

      assert {:noreply, resumed} =
               TUI.handle_info({:compaction_result, result}, compacting)

      assert_receive {:prompted, "follow-up"}
      assert resumed.history.queued == []
    end

    test "Enter steers now; Tab queues and submits only after a successful finish" do
      state = working() |> type("steer now") |> press("enter")
      assert_receive {:steered, "steer now"}
      assert Enum.any?(state.lines, &(&1 == {:steer, :pending, "steer now"}))
      assert screen(state) =~ "Steer · queued for next model request"
      refute screen(state) =~ "noted, will pass it on"

      delivered = info(state, {:entry, %{type: :request}})
      assert Enum.any?(delivered.lines, &(&1 == {:steer, :sent, "steer now"}))
      assert screen(delivered) =~ "Steer · included in model request"

      queued = delivered |> type("next prompt") |> press("tab")
      refute_receive {:prompted, "next prompt"}, 20

      finished = info(queued, {:finished, :stop})
      assert_receive {:prompted, "next prompt"}
      assert finished.history.queued == []
      assert finished.conversation.busy?
      assert Enum.any?(finished.lines, &(&1 == {:you, "next prompt"}))
    end

    test "the queued message can be revised or unstaged" do
      queued = working() |> type("first draft") |> press("tab")
      revising = press(queued, "e", ["alt"])
      assert revising.history.queued == []
      assert typed(revising) == "first draft"

      updated = revising |> type("!") |> press("tab")
      assert updated.history.queued == ["first draft!"]

      unstaged = press(updated, "u", ["alt"])
      assert unstaged.history.queued == []
      refute status_row(unstaged) =~ "queued for next turn"
    end

    test "numbered queued prompts can be selected, revised, and sent in order" do
      queued =
        working()
        |> type("first queued prompt")
        |> press("tab")
        |> type("second queued prompt")
        |> press("tab")
        |> type("third queued prompt")
        |> press("tab")

      assert queued.history.queued == [
               "first queued prompt",
               "second queued prompt",
               "third queued prompt"
             ]

      assert screen(queued) =~ "1. first queued prompt"
      assert screen(queued) =~ "2. second queued prompt"
      assert screen(queued) =~ "3. third queued prompt"

      selected = press(queued, "2", ["alt"])
      assert selected.history.queued_selected == 2
      revising = press(selected, "e", ["alt"])
      assert typed(revising) == "second queued prompt"
      assert revising.history.queued == ["first queued prompt", "third queued prompt"]

      restaged = revising |> type(" updated") |> press("tab")

      assert restaged.history.queued == [
               "first queued prompt",
               "second queued prompt updated",
               "third queued prompt"
             ]

      first = info(restaged, {:finished, :stop})
      assert_receive {:prompted, "first queued prompt"}
      assert first.history.queued == ["second queued prompt updated", "third queued prompt"]

      second = info(first, {:finished, :stop})
      assert_receive {:prompted, "second queued prompt updated"}
      assert second.history.queued == ["third queued prompt"]
    end

    test "the queue stops at nine without losing the draft" do
      queued =
        Enum.reduce(1..9, working(), fn number, state ->
          state |> type("prompt #{number}") |> press("tab")
        end)

      full = queued |> type("the tenth") |> press("tab")
      assert length(full.history.queued) == 9
      assert typed(full) == "the tenth"
      assert status_row(full) =~ "queue full (9)"

      selected = press(full, "5", ["alt"])
      unstaged = press(selected, "u", ["alt"])
      assert length(unstaged.history.queued) == 8
      refute "prompt 5" in unstaged.history.queued
    end

    test "a waiting steer can be revoked with Cmd+Z, and a second steer waits" do
      pending = working() |> type("do this first") |> press("enter")
      assert_receive {:steered, "do this first"}

      blocked = pending |> type("another steer") |> press("enter")
      assert typed(blocked) == "another steer"
      assert status_row(blocked) =~ "one steer is already waiting"
      refute_receive {:steered, "another steer"}, 20

      revoked = press(blocked, "z", ["super"])
      assert status_row(revoked) =~ "steer revoked"
      refute Enum.any?(revoked.lines, &match?({:steer, :pending, _}, &1))
      assert typed(revoked) == "another steer"

      sent = press(revoked, "enter")
      assert_receive {:steered, "another steer"}
      assert Enum.any?(sent.lines, &(&1 == {:steer, :pending, "another steer"}))
    end

    test "a steer appears after the active tool's result" do
      state = working()
      call = %{id: "bash-1", name: "bash", arguments: %{"command" => "sleep 30"}}
      called = info(state, {:tool_call, call})
      steered = called |> type("use the queued path") |> press("enter")
      assert steered.tools.deferred_steer == {:pending, "use the queued path"}
      refute screen(steered) =~ "Steer · queued for next model request"

      result =
        info(
          steered,
          {:entry,
           %{
             type: :tool_result,
             payload: %{"call_id" => "bash-1", "name" => "bash", "output" => "done"}
           }}
        )

      assert result.tools.deferred_steer == nil
      assert screen(result) =~ "Steer · queued for next model request"

      assert Enum.find_index(result.lines, &match?({:steer, _, _}, &1)) <
               Enum.find_index(result.lines, &match?({:tool_heading, _, _, _, _}, &1))
    end

    test "a stopped turn holds its queued message for revision" do
      queued = working() |> type("later") |> press("tab")
      stopped = info(queued, {:finished, :cancelled})

      refute_receive {:prompted, "later"}, 20
      assert stopped.history.queued == ["later"]
      assert status_row(stopped) =~ "queued after stopped turn"
      assert typed(press(stopped, "e", ["alt"])) == "later"
    end

    test "revision after cancellation saves in place and Escape restores the original" do
      stopped =
        working()
        |> type("first")
        |> press("tab")
        |> type("second")
        |> press("tab")
        |> info({:finished, :cancelled})

      revising = stopped |> press("1", ["alt"]) |> press("e", ["alt"])
      assert status_row(revising) =~ "editing queued #1"
      restored = revising |> type(" modified") |> press("esc")
      assert restored.history.queued == ["first", "second"]

      revised =
        stopped |> press("1", ["alt"]) |> press("e", ["alt"]) |> type(" modified") |> press("tab")

      assert revised.history.queued == ["first modified", "second"]
    end

    test "a steer that never reaches another model request is marked honestly" do
      pending = working() |> type("do this first") |> press("enter")
      stopped = info(pending, {:finished, :cancelled})

      assert Enum.any?(stopped.lines, &(&1 == {:steer, :not_sent, "do this first"}))
      assert screen(stopped) =~ "Steer · turn stopped before delivery"
    end

    test "a normal stop can leave a steer waiting for the next prompt" do
      pending = working() |> type("do this first") |> press("enter")
      stopped = info(pending, {:finished, :stop})

      assert Enum.any?(stopped.lines, &(&1 == {:steer, :pending, "do this first"}))
    end
  end

  describe "pressing enter" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("lmx-tui-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      runtime = :"lemieux_tui_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      provider = Scripted.new([[{:text_delta, "hi"}, {:done, :stop}]])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: provider,
          store: JSONL.new(tmp),
          model: "test:model",
          subscriber: self()
        )

      %{session: session, provider: provider, tmp: tmp}
    end

    test "/reflect dispatches from the TUI without blocking input", %{
      session: session,
      provider: provider
    } do
      state = tui(session: session) |> type("/reflect") |> press("enter")
      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)
      assert sent.conversation.busy?
      assert typed(sent) == ""
      assert_receive {:reflection_result, :ok}
      id = Lemieux.Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert [request] = Scripted.requests(provider)
      assert request.tools == []
      assert request.system =~ "/reflect workflow"
    end

    test "/reflect opportunities asks for the opportunity mode", %{
      session: session,
      provider: provider
    } do
      state = tui(session: session) |> type("/reflect opportunities")
      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)

      assert sent.conversation.reflecting == :opportunities
      assert Enum.any?(sent.lines, &match?({:lmx, "Mining opportunities" <> _rest}, &1))
      assert_receive {:reflection_result, :ok}
      id = Lemieux.Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert [request] = Scripted.requests(provider)
      assert request.system =~ "OUTPUT CONTRACT"
    end

    test "/feedback captures without prompting the model", %{
      session: session,
      provider: provider,
      tmp: tmp
    } do
      ledger = Lemieux.Feedback.Store.JSONL.new(Path.join(tmp, "ledger"))

      state =
        tui(session: session, id: Lemieux.Session.id(session))
        |> Map.put(:feedback_opts, feedback_store: ledger)
        |> type("/feedback the formatter never ran")

      assert {:noreply, asking} = TUI.handle_event(key("enter"), state)
      assert_receive {:feedback_anchors, anchors}
      assert anchors == []

      # An empty session has nothing to point at, and says so rather than
      # inventing an anchor or sending the words to the model.
      assert {:noreply, closed} = TUI.handle_info({:feedback_anchors, anchors}, asking)
      assert Enum.any?(closed.lines, &match?({:lmx, "nothing to anchor" <> _rest}, &1))
      refute closed.conversation.busy?
      assert Scripted.requests(provider) == []
    end

    test "/feedback writes the answers a person gave to the ledger", %{
      session: session,
      tmp: tmp
    } do
      ledger = Lemieux.Feedback.Store.JSONL.new(Path.join(tmp, "ledger"))
      id = Lemieux.Session.id(session)

      state =
        tui(session: session, id: id)
        |> Map.put(:feedback_opts, feedback_store: ledger)

      # One turn first, so there is a moment to point at.
      assert {:noreply, state} = TUI.handle_event(key("enter"), type(state, "say hi"))
      state = settle(state)

      # The first enter takes the completion the menu is offering; the second
      # submits, exactly as it does for `/reflect`.
      {:noreply, state} = TUI.handle_event(key("enter"), press(type(state, "/feedback"), "enter"))
      assert_receive {:feedback_anchors, anchors}
      refute anchors == []
      {:noreply, state} = TUI.handle_info({:feedback_anchors, anchors}, state)

      state =
        Enum.reduce(["it should have run the formatter", "1", "bug", "task", "always"], state, fn
          line, state ->
            {:noreply, next} = TUI.handle_event(key("enter"), type(state, line))
            next
        end)

      assert_receive {:feedback_result, {:ok, feedback_id}}
      {:noreply, _state} = TUI.handle_info({:feedback_result, {:ok, feedback_id}}, state)

      assert {:ok, revisions} = Lemieux.Feedback.Store.read(ledger, feedback_id)
      assert [captured, interpreted] = revisions
      assert captured.raw_text == "it should have run the formatter"
      assert captured.type == :bug
      assert captured.scope == :task
      assert captured.durability == :standing_rule
      assert captured.provenance["session_id"] == id
      assert [%{"questions_asked" => 3}] = interpreted.interpretations

      # The complaint is evidence about the run, not another turn in it.
      {:ok, entries} = Lemieux.Store.read(JSONL.new(tmp), id)
      texts = for %{type: :user, payload: payload} <- entries, do: payload["text"]
      assert texts == ["say hi"]
      assert Enum.any?(entries, &(&1.id == captured.provenance["entry_id"]))
    end

    test "sends what was typed and empties the box", %{session: session} do
      state = tui(session: session) |> type("say hi")

      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)

      assert typed(sent) == ""
      assert sent.conversation.busy?
      assert sent.history.entries == ["say hi"]
    end

    test "invokes a user skill as a slash command without echoing its expanded body", %{
      session: session,
      provider: provider,
      tmp: tmp
    } do
      path = Path.join(tmp, "skills/review/SKILL.md")
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        "---\nname: review\ndescription: Review one file.\n---\nReview $ARGUMENTS carefully."
      )

      assert {:ok, skill} = Skill.read(path)
      state = tui(session: session, skills: [skill]) |> type("/review lib/example.ex")

      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)
      assert screen(sent) =~ "/review lib/example.ex"
      refute screen(sent) =~ "Review lib/example.ex carefully"

      id = Lemieux.Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert [%{entries: entries}] = Scripted.requests(provider)

      assert Enum.any?(
               entries,
               &(&1.type == :user and &1.payload["text"] =~ "Review lib/example.ex carefully")
             )
    end

    test "built-in slash commands win a colliding skill name", %{session: session, tmp: tmp} do
      path = Path.join(tmp, "skills/help/SKILL.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "---\nname: help\ndescription: Replace help.\n---\nCOLLIDING SKILL")
      assert {:ok, skill} = Skill.read(path)

      state = tui(session: session, skills: [skill]) |> type("/help")
      assert {:noreply, completed} = TUI.handle_event(key("enter"), state)
      assert {:noreply, sent} = TUI.handle_event(key("enter"), completed)

      # The trailer rather than a command line: the built-in help is longer
      # than the pane, so which commands are still on screen depends on how
      # many there are, and this assertion is about which help ran. The key
      # bindings close it, so they are what the bottom of the pane shows.
      assert screen(sent) =~ "@path attach a file"
      refute screen(sent) =~ "COLLIDING SKILL"
    end

    test "echoes it, so the transcript reads as a conversation", %{session: session} do
      state = tui(session: session) |> type("say hi")

      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)
      assert screen(sent) =~ "say hi"
    end

    test "leaves one blank row between the previous answer and the next prompt", %{
      session: session
    } do
      state = tui(session: session, lines: [{:model, "finished"}]) |> type("next task")

      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)

      assert sent.lines == [
               {:you, "next task"},
               {:space, ""},
               {:model, "finished"}
             ]

      assert screen(sent) =~ "finished\n\n› next task"
    end

    test "on an empty box does nothing at all", %{session: session} do
      state = tui(session: session)

      assert {:noreply, unchanged} = TUI.handle_event(key("enter"), state)

      refute unchanged.conversation.busy?
      assert unchanged.lines == []
    end

    test "/quit leaves on the highlighted selection", %{session: session} do
      state = tui(session: session) |> type("/quit")

      assert {:stop, _state} = TUI.handle_event(key("enter"), state)
    end

    # `/mcp` opens the takeover in one press, without echoing a command.
    test "/mcp surfaces configured-server status", %{session: session} do
      state = tui(session: session) |> type("/mcp")

      assert {:noreply, shown} = TUI.handle_event(key("enter"), state)
      assert typed(shown) == ""
      assert screen(shown) =~ "No MCP servers configured"
      assert %{statuses: [], selected: 0, mode: :list} = shown.tools.mcp_flow
      [{_, transcript_rect} | _] = TUI.render(shown, @frame)

      {_, panel_rect} =
        Enum.find(TUI.render(shown, @frame), fn
          {%ExRatatui.Widgets.Block{title: " MCP servers "}, _rect} -> true
          _widget -> false
        end)

      assert panel_rect.height < @frame.height
      assert panel_rect.y > transcript_rect.y
      refute Enum.any?(shown.lines, &(&1 == {:you, "/mcp"}))
      assert press(shown, "esc").tools.mcp_flow == nil
    end

    test "/mcp takeover keeps connection errors visible while reconnecting" do
      session =
        fake_session(snapshot("01SESSION"),
          mcp_statuses: [
            %{name: "github", transport: "http", tool_count: 3, enabled?: true, error: nil},
            %{
              name: "local",
              transport: "stdio",
              tool_count: 0,
              enabled?: true,
              error: "the server offered no tools"
            }
          ]
        )

      state = tui(session: session) |> command("/mcp")
      assert state.tools.mcp_flow.selected == 0
      assert screen(state) =~ "github  ·  http  ·  3 tools"
      assert screen(state) =~ "local  ·  stdio  ·  0 tools"

      selected = press(state, "down")
      assert screen(selected) =~ "Connection error: the server offered no tools"
      reconnecting = press(selected, "r")
      assert reconnecting.tools.mcp_flow.busy?
      assert screen(reconnecting) =~ "Working…"
      canvas = CellSession.new(@frame.width, @frame.height)
      :ok = CellSession.draw(canvas, TUI.render(reconnecting, @frame))

      painted =
        canvas |> CellSession.take_cells() |> Map.fetch!(:cells) |> Enum.map_join(& &1.symbol)

      :ok = CellSession.close(canvas)
      assert painted =~ "Connection error: the server offered no tools"
      assert painted =~ "Working…"
      refute Enum.any?(reconnecting.lines, &match?({:lmx, "MCP reconnect" <> _}, &1))
    end

    @tag :tmp_dir
    test "a adds a pasted HTTP server in the takeover and writes project config", %{tmp_dir: cwd} do
      session = fake_session(snapshot("01MCPFORM"))

      state =
        tui(session: session, cwd: cwd, mcp_config: Path.join(cwd, ".mcp.json"))
        |> command("/mcp")
        |> press("a")

      assert screen(state) =~ "Server name"
      state = state |> type("manual") |> press("enter")
      assert screen(state) =~ "HTTP"
      assert screen(state) =~ "stdio"
      refute screen(state) =~ "Other · type your own answer"
      assert {:noreply, state} = TUI.handle_event(%Paste{content: "stdio"}, state)
      assert typed(state) == ""
      state = press(state, "enter")
      assert screen(state) =~ "Server URL"
      state = state |> type("https://example.com/mcp") |> press("enter")
      assert screen(state) =~ "HTTP headers"
      state = state |> type(~s({"authorization":"Bearer ${TEST_TOKEN}"})) |> press("enter")
      assert screen(state) =~ "Where should this server be saved?"
      state = state |> press("down") |> press("enter")
      assert screen(state) =~ "Review server configuration"
      assert screen(state) =~ "Save server"
      state = press(state, "enter")
      assert state.tools.mcp_flow.busy?
      assert_receive {:added_mcp, [%{"name" => "manual", "transport" => "http"}]}
      assert_receive {:mcp_ui_result, _, :ok, statuses} = result
      assert {:noreply, finished} = TUI.handle_info(result, state)
      assert %{mode: :list, busy?: false} = finished.tools.mcp_flow
      assert screen(finished) =~ "connection failed: the server offered no tools"
      assert [%{name: "manual"}] = statuses

      assert {:ok,
              [%{"name" => "manual", "url" => "https://example.com/mcp", "headers" => headers}]} =
               MCPConfig.read(Path.join(cwd, ".mcp.json"))

      assert headers == %{"authorization" => "Bearer ${TEST_TOKEN}"}
      refute Enum.any?(finished.lines, &match?({:you, "/mcp"}, &1))
    end

    test "the add questionnaire uses tabs and keeps a draft when moving between them" do
      state = tui(session: fake_session(snapshot("01MCPTABS"))) |> command("/mcp") |> press("a")

      assert Enum.any?(TUI.render(state, @frame), fn {widget, _rect} ->
               match?(%Tabs{}, widget)
             end)

      state = state |> type("draft-name") |> press("tab")
      assert screen(state) =~ "How does Lemieux connect"
      assert typed(state) == ""
      assert state.tools.mcp_flow.questionnaire.selected == 0
      assert press(press(state, "down"), "down").tools.mcp_flow.questionnaire.selected == 0

      state = press(state, "back_tab")
      assert typed(state) == "draft-name"
      assert screen(state) =~ "Server name"
    end

    test "o toggles a default server only in the current session" do
      session =
        fake_session(snapshot("01MCPOFF"),
          mcp_statuses: [
            %{name: "default", transport: "http", tool_count: 2, enabled?: true, error: nil}
          ]
        )

      state = tui(session: session) |> command("/mcp") |> press("o")
      assert_receive {:mcp_enabled, "default", false}
      assert_receive {:mcp_ui_result, _, :ok, _} = result
      assert {:noreply, off} = TUI.handle_info(result, state)
      assert screen(off) =~ "Off for this session"
      assert screen(off) =~ "default is off for this session"
      refute Enum.any?(off.lines, &match?({:lmx, "MCP" <> _}, &1))
    end

    test "d confirms removal inside the takeover" do
      session =
        fake_session(snapshot("01MCPREMOVE"),
          mcp_statuses: [
            %{name: "default", transport: "http", tool_count: 2, enabled?: true, error: nil}
          ]
        )

      state = tui(session: session) |> command("/mcp") |> press("d")
      assert screen(state) =~ "Press d again to remove default"
      refute_received {:removed_mcp, "default"}

      removing = press(state, "d")
      assert removing.tools.mcp_flow.busy?
      assert_receive {:removed_mcp, "default"}
      assert_receive {:mcp_ui_result, _, :ok, _} = result
      assert {:noreply, removed} = TUI.handle_info(result, removing)
      assert %{statuses: [], mode: :list} = removed.tools.mcp_flow
      refute Enum.any?(removed.lines, &match?({:lmx, "MCP" <> _}, &1))
    end

    @tag :tmp_dir
    test "Shift+D deletes a configured server and removes it from this session", %{tmp_dir: cwd} do
      path = Path.join(cwd, ".mcp.json")

      File.write!(
        path,
        ~s({"mcpServers":{"delete":{"url":"https://delete.example/mcp"},"keep":{"url":"https://keep.example/mcp"}}})
      )

      session =
        fake_session(snapshot("01MCPDELETE"),
          mcp_statuses: [
            %{name: "delete", transport: "http", tool_count: 1, enabled?: true, error: nil},
            %{name: "keep", transport: "http", tool_count: 1, enabled?: true, error: nil}
          ]
        )

      state = tui(session: session, mcp_config: path) |> command("/mcp") |> press("d", ["shift"])
      assert screen(state) =~ "Press Shift+D again to delete delete"
      refute_received {:removed_mcp, "delete"}

      deleting = press(state, "d", ["shift"])
      assert deleting.tools.mcp_flow.busy?
      assert_receive {:removed_mcp, "delete"}
      assert_receive {:mcp_ui_result, _, :ok, _} = result
      assert {:noreply, deleted} = TUI.handle_info(result, deleting)
      assert screen(deleted) =~ "deleted from"
      assert {:ok, [%{"name" => "keep"}]} = MCPConfig.read(path)
    end

    @tag :tmp_dir
    test "Shift+D leaves the session connected when its config is missing", %{tmp_dir: cwd} do
      path = Path.join(cwd, ".mcp.json")

      session =
        fake_session(snapshot("01MCPNOCONFIG"),
          mcp_statuses: [
            %{name: "default", transport: "http", tool_count: 1, enabled?: true, error: nil}
          ]
        )

      deleting =
        tui(session: session, mcp_config: path) |> command("/mcp") |> press("D") |> press("D")

      assert_receive {:mcp_ui_result, _, {:error, _}, statuses} = result
      refute_received {:removed_mcp, "default"}
      assert {:noreply, shown} = TUI.handle_info(result, deleting)
      assert [%{name: "default"}] = statuses
      assert screen(shown) =~ "could not read"
    end

    @tag :tmp_dir
    test "a accepts pasted stdio arguments and environment in the same screen", %{tmp_dir: cwd} do
      session = fake_session(snapshot("01MCPSTDIO"))
      path = Path.join(cwd, ".mcp.json")

      state =
        tui(session: session, mcp_config: path)
        |> command("/mcp")
        |> press("a")
        |> type("local")
        |> press("enter")
        |> press("down")
        |> press("enter")
        |> type("python3")
        |> press("enter")

      assert {:noreply, state} = TUI.handle_event(%Paste{content: ~s(["-m","server"])}, state)
      state = press(state, "enter")
      assert screen(state) =~ "Environment as JSON object"

      assert {:noreply, state} =
               TUI.handle_event(%Paste{content: ~s({"TOKEN":"${MCP_TOKEN}"})}, state)

      # The environment, then "This repository" rather than the default
      # personal settings, then the review.
      state = state |> press("enter") |> press("down") |> press("enter") |> press("enter")
      assert_receive {:added_mcp, [%{"name" => "local", "args" => ["-m", "server"]}]}
      assert_receive {:mcp_ui_result, _, :ok, _}

      assert {:ok, [%{"name" => "local", "env" => %{"TOKEN" => "${MCP_TOKEN}"}}]} =
               MCPConfig.read(path)

      assert state.tools.mcp_flow.busy?
    end

    test "ctrl-c cancels a busy conversation instead of leaving", %{session: session} do
      busy = %{
        tui(session: session).conversation
        | busy?: true,
          asking: "question-call"
      }

      assert {:noreply, cancelled} =
               TUI.handle_event(key("c", ["ctrl"]), tui(session: session, conversation: busy))

      assert cancelled.conversation.busy?
      assert cancelled.conversation.asking == nil
      assert cancelled.exit_armed == nil
    end

    test "history keeps at most 50 nonblank submitted inputs", %{session: session} do
      history = for n <- 1..50, do: "message #{n}"
      state = tui(session: session, history: history) |> type("newest")

      assert {:noreply, sent} = TUI.handle_event(key("enter"), state)
      assert length(sent.history.entries) == 50
      assert Elixir.List.first(sent.history.entries) == "newest"
      refute "message 50" in sent.history.entries

      blank = tui() |> type("   ") |> press("enter")
      assert blank.history.entries == []
    end
  end

  describe "input history" do
    test "up walks older inputs and down restores the draft" do
      state = tui(history: ["third", "second", "first"]) |> type("unfinished")

      newest = press(state, "up")
      assert typed(newest) == "third"

      older = press(newest, "up")
      assert typed(older) == "second"
      assert older |> press("down") |> typed() == "third"

      restored = older |> press("down") |> press("down")
      assert typed(restored) == "unfinished"
      assert restored.history.index == nil
    end

    test "completion navigation takes precedence over history" do
      state = tui(history: ["old message"]) |> type("/co") |> press("down")

      assert typed(state) == "/co"
      assert suggestions(state).selected == 1
      assert state.history.index == nil
    end

    test "historical slash commands do not interrupt up and down traversal" do
      state = tui(history: ["latest", "/compact", "oldest"]) |> type("unfinished")

      latest = press(state, "up")
      command = press(latest, "up")

      assert typed(command) == "/compact"
      assert caret(command) == {0, 8}
      assert suggestions(command) == nil

      oldest = press(command, "up")
      assert typed(oldest) == "oldest"

      assert oldest |> press("down") |> typed() == "/compact"
      assert oldest |> press("down") |> press("down") |> typed() == "latest"

      restored = oldest |> press("down") |> press("down") |> press("down")
      assert typed(restored) == "unfinished"
      assert caret(restored) == {0, 10}
      assert restored.history.index == nil
    end
  end

  describe "copy command" do
    test "copies the complete latest textual assistant entry" do
      entries = [
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "older"}]}),
        Entry.new(:assistant, %{
          "content" => [
            %{"type" => "text", "text" => "latest first"},
            %{"type" => "text", "text" => "latest second"}
          ]
        }),
        Entry.new(:assistant, %{
          "content" => [],
          "tool_calls" => [%{"id" => "read-1", "name" => "read", "arguments" => %{}}]
        })
      ]

      session = fake_session(snapshot("01SESSION", entries))
      owner = self()

      copied =
        tui(
          session: session,
          clipboard: fn text ->
            send(owner, {:copied, text})
            :ok
          end
        )
        |> type("/copy")
        |> press("enter")

      assert_receive {:copied, "latest first\nlatest second"}
      assert screen(copied) =~ "copied the latest agent response"
    end

    test "explains when there is no agent response to copy" do
      session = fake_session(snapshot("01SESSION"))

      state =
        tui(session: session, clipboard: fn _text -> flunk("nothing should be copied") end)
        |> type("/copy")
        |> press("enter")

      assert screen(state) =~ "no agent response to copy"
    end
  end
end
