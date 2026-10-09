defmodule Lemieux.TUI.NoticeFlowTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI
  alias Lemieux.TUI.{Notices, Screen, Selection, Transcript}

  test "the startup box is drawn inside the transcript without reserving a pane" do
    initial = sized(tui())
    open = Notices.say(initial, :info, "full auto: tools run without asking")
    assert Screen.panes(open).transcript == Screen.panes(initial).transcript
    [{%Paragraph{text: lines}, area} | _rest] = TUI.render(open, %{width: 80, height: 24})
    assert area == Screen.panes(initial).transcript

    assert Enum.any?(
             lines,
             &(Enum.map_join(&1.spans, fn span -> span.content end) =~ "full auto")
           )

    assert Enum.any?(lines, &(Enum.map_join(&1.spans, fn span -> span.content end) =~ "╭─ lmx"))
  end

  test "expiry removes only the box and keeps pane and newer selection geometry stable" do
    open = sized(tui()) |> Notices.say(:info, "startup") |> Transcript.say(:lmx, "answer")
    selection = Selection.start({0, 0}) |> Selection.extend({0, 3})
    open = %{open | selection: selection}
    assert {:noreply, closed} = Notices.expire(open, open.terminal.notices.token)
    assert closed.lines == [{:lmx, "answer"}]
    assert closed.selection == selection
    assert Screen.panes(closed) == Screen.panes(open)
  end

  test "expiry preserves scrollback anchored above the temporary box" do
    initial = sized(tui()) |> Transcript.say(:lmx, "older")
    open = initial |> Notices.say(:info, "startup") |> Transcript.say(:lmx, "newer")
    count = Enum.sum(Enum.map(open.lines, &Transcript.rows(open, &1)))
    selection = Selection.start({count - 1, 0}) |> Selection.extend({count - 1, 3})
    open = %{open | scroll: count - 1, selection: selection}
    assert {:noreply, closed} = Notices.expire(open, open.terminal.notices.token)
    assert closed.scroll == 1
    assert closed.selection == Selection.start({1, 0}) |> Selection.extend({1, 3})
  end

  test "a notice arriving during a streamed code fence does not split the model block" do
    state = sized(tui()) |> put_in([Access.key!(:conversation), Access.key!(:busy?)], true)
    state = state |> Transcript.say(:model, "```elixir\none") |> Notices.say(:info, "connected")

    state =
      state
      |> Transcript.extend(" ++ two")
      |> Transcript.say(:model, "```")
      |> Transcript.close_line()

    assert screen(state) =~ "one ++ two"
    assert Enum.any?(state.lines, &match?({:model_code, "elixir", "one ++ two", _spans}, &1))
    assert Notices.items(state) == [%{kind: :info, text: "connected"}]
  end

  test "notices schedule five seconds and cancel their timer when dismissed" do
    state = Notices.say(sized(tui()), :info, "startup")
    timer = state.terminal.notices.timer
    assert Process.read_timer(timer) in 1..5_000
    closed = Notices.dismiss(state)
    assert Process.read_timer(timer) == false
    assert Notices.items(closed) == []
  end

  @tag :tmp_dir
  test "a local-file link in a notice never falls through to the transcript's file opener", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "note.md")
    File.write!(path, "a fixture")
    test_pid = self()

    open = fn target ->
      send(test_pid, {:opened, target})
      :ok
    end

    state = tui(open_link: open) |> sized() |> put_in([Access.key!(:terminal), :width], 240)
    state = Notices.say(state, :info, "[local file](#{path})")
    event = %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 4, y: 2}
    assert {:noreply, pressed} = TUI.handle_event(event, state)
    assert {:noreply, _released} = TUI.handle_event(%{event | kind: "up"}, pressed)
    refute_receive {:opened, _target}, 50
  end

  test "wrapped notice links retain their target after scrolling and resize" do
    target = "https://example.com/a/long/path/to/the/changelog"

    state =
      sized(tui())
      |> Notices.say(:info, "[changelog](#{target})")
      |> Transcript.say(:lmx, "later")

    for width <- [20, 78] do
      box = Enum.find(state.lines, &match?({:notice_box, _id, _items}, &1))
      height = Transcript.rows(put_in(state.terminal.width, width + 2), box)
      # Depth zero is the later message, one the box's bottom border; its
      # next row is the link's final wrapped continuation.
      assert height >= 3
      assert Notices.link_at(state, 2, width) == {:notice, target}
      assert Notices.link_at(%{state | scroll: 2}, 2, width) == {:notice, target}
      assert Notices.link_at(state, 0, width) == :outside
    end
  end

  test "expiry cancels a pending click on the disappearing box" do
    test_pid = self()

    state =
      sized(
        tui(
          open_link: fn target ->
            send(test_pid, {:opened, target})
            :ok
          end
        )
      )
      |> Notices.say(:info, "[changelog](https://example.com/changelog)")

    event = %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 4, y: 2}
    assert {:noreply, pressed} = TUI.handle_event(event, state)
    assert {"https://example.com/changelog", _point} = pressed.terminal.link_press
    assert {:noreply, expired} = Notices.expire(pressed, pressed.terminal.notices.token)
    assert expired.terminal.link_press == nil
    assert {:noreply, _released} = TUI.handle_event(%{event | kind: "up"}, expired)
    refute_receive {:opened, _target}, 50
  end
end
