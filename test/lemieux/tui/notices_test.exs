defmodule Lemieux.TUI.NoticesTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI
  alias Lemieux.TUI.Notices
  alias Lemieux.TUI.Screen

  @link "https://github.com/houllette/lemieux/blob/v0.2.0/CHANGELOG.md"

  describe "startup" do
    test "the banner and what connected share a temporary box in the transcript" do
      state =
        [
          id: "01NOTICES",
          model: "test:model",
          test_mode: {80, 24},
          permissions: nil,
          sandbox: nil
        ]
        |> TUI.new()
        |> TUI.Policy.banner()
        |> Notices.say(:info, "MCP connected: github (3 tools)")
        |> sized()

      assert [{:notice_box, _id, items}] = state.lines
      assert items == Notices.items(state)

      assert Enum.map(Notices.items(state), & &1.text) == [
               "full auto: tools run without asking · commands are not sandboxed",
               "MCP connected: github (3 tools)"
             ]

      assert {%Paragraph{}, _area} = notice_box(state)
      assert screen(state) =~ "full auto: tools run without asking"
    end
  end

  describe "closing" do
    test "five seconds after the newest item, not the first" do
      first = Notices.say(sized(tui()), :info, "one")
      %{token: early} = first.terminal.notices
      second = Notices.say(first, :info, "two")
      %{token: late} = second.terminal.notices

      assert {:noreply, still} = TUI.handle_info({:notices_expired, early}, second)
      assert length(Notices.items(still)) == 2

      assert {:noreply, closed} = TUI.handle_info({:notices_expired, late}, still)
      assert Notices.items(closed) == []
      assert notice_box(closed) == nil
    end

    # The launch audit watched the full-auto banner close behind the
    # first-run provider panel, before anybody could have read it.
    test "not while a panel holds the keyboard: closing the panel starts its five seconds again" do
      provider = %{id: "zz", label: "ZZ", env: "ZZ_API_KEY", model: "zz:model"}

      panel =
        [
          id: "01NOTICES",
          model: "test:model",
          test_mode: {80, 24},
          permissions: nil,
          first_run: %{providers: [provider], config_path: nil}
        ]
        |> TUI.new()
        |> sized()
        |> TUI.Policy.banner()
        |> TUI.FirstRun.open()

      assert panel.modal.kind == :first_run
      %{token: during} = panel.terminal.notices

      assert {:noreply, held} = TUI.handle_info({:notices_expired, during}, panel)
      assert [%{text: "full auto: tools run without asking" <> _}] = Notices.items(held)

      closed = press(held, "esc")
      assert closed.modal == nil
      %{token: after_panel} = closed.terminal.notices
      refute after_panel == during
      assert Notices.items(closed) != []

      assert {:noreply, stale} = TUI.handle_info({:notices_expired, during}, closed)
      assert Notices.items(stale) != []

      assert {:noreply, gone} = TUI.handle_info({:notices_expired, after_panel}, closed)
      assert Notices.items(gone) == []
    end

    test "Esc closes it at once" do
      state = sized(tui()) |> Notices.say(:info, "something") |> press("esc")

      assert Notices.items(state) == []
      assert notice_box(state) == nil
    end

    test "an item the box is showing is not added again, and does not restart its time" do
      once = Notices.say(tui(), :warning, "a notice")
      twice = Notices.say(once, :warning, "a notice")

      assert twice == once
    end
  end

  describe "the box on the screen" do
    test "appears and disappears inside the transcript with unchanged pane geometry" do
      open = sized(tui()) |> Notices.say(:info, "something to say")
      panes = Screen.panes(open)
      assert panes.transcript.y == 0
      refute Map.has_key?(panes, :notices)

      closed = Notices.dismiss(open)
      assert Screen.panes(closed) == panes
    end

    test "a short screen uses the normal transcript window rather than a separate strip" do
      short =
        tui(test_mode: {80, 8})
        |> put_in([Access.key!(:terminal), :height], 8)
        |> Notices.say(:info, "something to say")

      assert Screen.panes(short).transcript.y == 0
      refute Map.has_key?(Screen.panes(short), :notices)
      assert Notices.items(short) != []
    end

    test "an error is drawn in the alert colour, its remedy on a row of its own" do
      state = sized(tui()) |> Notices.say(:error, "github is unavailable; /mcp reconnects it")

      {%Paragraph{text: [found, remedy | _rest]}, _area} = notice_box(state)

      assert Enum.map(found.spans, &{&1.content, &1.style.fg}) ==
               [{"✗ ", :red}, {"github is unavailable", :red}]

      assert Enum.map(remedy.spans, & &1.content) == ["↳ ", "/mcp reconnects it"]
    end
  end

  describe "a link in the box" do
    test "a link opens on release and plain text can be selected as transcript content" do
      test = self()

      open_link = fn url ->
        send(test, {:opened, url})
        :ok
      end

      state =
        tui(open_link: open_link)
        |> sized()
        |> Notices.say(:info, "plain news")
        |> Notices.say(:info, "Lemieux was updated · [full changelog](#{@link})")

      area = Screen.panes(state).transcript
      # The pane's top rail, the box border, then the first and second items.
      plain = %ExRatatui.Event.Mouse{kind: "down", button: "left", x: 4, y: area.y + 2}
      linked = %{plain | y: area.y + 3}

      assert {:noreply, after_plain} = TUI.handle_event(plain, state)
      assert after_plain.selection != nil
      refute_receive {:opened, _url}, 50

      assert {:noreply, pressed} = TUI.handle_event(linked, state)
      refute_receive {:opened, _url}, 50
      assert {:noreply, _state} = TUI.handle_event(%{linked | kind: "up"}, pressed)
      assert_receive {:opened, @link}
    end

    test "is drawn the way links in answers are" do
      state = sized(tui()) |> Notices.say(:info, "news · [full changelog](#{@link})")

      assert screen(state) =~ "↗ full changelog"
    end
  end
end
