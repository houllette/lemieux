defmodule Lemieux.TUI.ToolsPanelTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.Providers.Scripted
  alias Lemieux.{Session, Tool, Tools, TUI}
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI.{Screen, Theme, ToolsPanel}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"tools_panel_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new([Scripted.complete("Done")])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        model: "test:model",
        store: JSONL.new(dir),
        subscriber: self(),
        tools: [Tools.Read, Tools.Write, Tools.Eval],
        tool_profile: %{"shared" => true, "allow" => "all", "human_channel" => true}
      )

    state = tui(session: session, id: Session.id(session), lines: [{:model, "Earlier answer"}])
    %{session: session, state: state, provider: provider}
  end

  defp loaded(state) do
    %{session: session, token: token} = state.modal
    assert_receive {:tools_panel_result, ^session, ^token, _result} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    state
  end

  test "/tools opens a compact tray without chat echoes or a model request", ctx do
    before = ctx.state.lines
    entries = Session.snapshot(ctx.session).entries
    state = ctx.state |> command("/tools") |> loaded()
    assert state.modal.kind == :tools
    assert state.lines == before
    assert screen(state) =~ "Active"
    assert screen(state) =~ "Unavailable"
    assert typed(state) == ""
    assert Session.snapshot(ctx.session).entries == entries
    assert Scripted.requests(ctx.provider) == []

    for {width, height} <- [{120, 45}, {80, 24}, {25, 12}, {10, 5}] do
      state = %{state | terminal: %{state.terminal | width: width, height: height}}
      panes = Screen.panes(state)

      for {_widget, rect} <- ToolsPanel.render(state, panes) do
        assert rect.y >= panes.transcript.y
        assert rect.y + rect.height <= panes.input.y
        assert rect.x + rect.width <= width
      end
    end
  end

  test "keyboard and mouse toggle both ways and update the next request without chat receipts",
       ctx do
    state = ctx.state |> command("/tools") |> loaded() |> type("read")
    assert state.modal.selected == "read"
    state = state |> press(" ") |> loaded()
    refute Enum.find(Session.tool_status(ctx.session), &(&1.name == "read")).enabled?
    assert screen(state) =~ "Inactive"
    assert state.lines == ctx.state.lines
    assert_receive {:lemieux, _, {:tool_access_changed, _, _, _} = event}
    state = info(state, event)
    assert state.lines == ctx.state.lines

    {%Paragraph{text: "[Enter Activate]"}, rect} =
      Enum.find(ToolsPanel.render(state, Screen.panes(state)), fn
        {%Paragraph{text: "[Enter Activate]"}, _} -> true
        _ -> false
      end)

    assert {:noreply, state} =
             TUI.handle_event(%Mouse{kind: "down", button: "left", x: rect.x, y: rect.y}, state)

    state = loaded(state)
    assert Enum.find(Session.tool_status(ctx.session), &(&1.name == "read")).enabled?
    state = state |> press("enter") |> loaded() |> press("esc")
    assert state.modal == nil
    :ok = Session.prompt(ctx.session, "Answer")
    assert_receive {:lemieux, _, {:finished, :stop}}
    assert [request] = Scripted.requests(ctx.provider)
    refute Enum.any?(request.tools, &(Tool.name(&1) == "read"))
  end

  test "host restrictions and command policy cannot be toggled around", ctx do
    state = ctx.state |> command("/tools") |> loaded() |> type("elixir") |> press("enter")
    assert screen(state) =~ "host profile"
    refute Enum.find(Session.tool_status(ctx.session), &(&1.name == "elixir")).enabled?
    state = state |> press("esc")

    state =
      put_in(state.tool_choices.command_policy, fn
        {:disable_tools, _} -> {:deny, "Host locks tool changes"}
        _ -> :allow
      end)

    state = state |> command("/tools") |> loaded() |> type("write") |> press("enter")
    assert screen(state) =~ "Host locks tool changes"
    assert Enum.find(Session.tool_status(ctx.session), &(&1.name == "write")).enabled?
    assert state.lines == ctx.state.lines
  end

  test "a closed tray ignores late replies and preserves its composer draft", ctx do
    state = ctx.state |> type("draft") |> ToolsPanel.open()
    state = press(state, "esc")
    state = loaded_reply(state)
    assert state.modal == nil
    assert typed(state) == "draft"
    assert state.lines == ctx.state.lines
  end

  defp loaded_reply(state) do
    assert_receive {:tools_panel_result, _, _, _} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    state
  end

  test "native cells distinguish active inactive and restricted tools in each theme", ctx do
    assert {:ok, ["write"]} = Session.disable_tools(ctx.session, ["write"])
    state = ctx.state |> command("/tools") |> loaded()

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      state = put_in(state.appearance.theme, theme)
      cells = ExRatatui.CellSession.new(80, 24)
      :ok = ExRatatui.CellSession.draw(cells, TUI.render(state, %Frame{width: 80, height: 24}))
      snapshot = ExRatatui.CellSession.take_cells(cells).cells
      :ok = ExRatatui.CellSession.close(cells)
      text = Enum.map_join(snapshot, & &1.symbol)
      assert text =~ "Earlier answer"
      assert text =~ "✓ Active"
      assert text =~ "○ Inactive"
      assert text =~ "⊘ Unavailable"
      lines = screen(state)
      assert lines =~ "Filter:"

      spans =
        ToolsPanel.render(state, Screen.panes(state))
        |> Enum.flat_map(fn
          {%Paragraph{text: lines}, _} when is_list(lines) -> Enum.flat_map(lines, & &1.spans)
          _ -> []
        end)

      assert Enum.any?(spans, &(:bold in &1.style.modifiers))

      unless theme.name == "mono" do
        assert length(Enum.uniq_by(spans, & &1.style.fg)) >= 4
      end
    end
  end

  test "the tray filters MCP tools scrolls long lists and handles empty matches", ctx do
    statuses =
      for n <- 1..80,
          do: %{
            name: "fixture__tool_#{String.pad_leading(to_string(n), 2, "0")}",
            source: {:mcp, "fixture"},
            enabled?: rem(n, 2) == 0
          }

    session = fake_session(snapshot("01TOOLS"), tool_statuses: statuses)
    state = tui(session: session) |> command("/tools") |> loaded()
    state = state |> press("end")
    assert state.modal.selected == "fixture__tool_80"
    assert screen(state) =~ "fixture__tool_80"
    state = state |> type("fixture__tool_02")
    assert length(state.modal.rows) == 1
    assert screen(state) =~ "MCP fixture"
    state = state |> type("missing")
    assert state.modal.rows == []
    assert screen(state) =~ "No matching tools"
    assert press(state, "enter").modal.token == nil
    state = press(state, "backspace")
    assert String.ends_with?(state.modal.query, "missin")
    assert Scripted.requests(ctx.provider) == []
  end

  test "busy and denied inspection stay out of the transcript", ctx do
    state = ctx.state
    state = put_in(state.conversation.busy?, true)
    state = state |> command("/tools") |> loaded() |> type("read") |> press("enter")
    assert screen(state) =~ "Wait for the current turn"
    assert state.modal.token == nil
    assert state.lines == ctx.state.lines
    state = state |> press("esc")

    state =
      put_in(state.tool_choices.command_policy, fn
        :tools_status -> {:deny, "Catalog hidden"}
        _ -> :allow
      end)

    state = command(state, "/tools")
    assert state.modal == nil
    assert state.terminal.feedback.text == "Catalog hidden"
    assert state.lines == ctx.state.lines
  end
end
