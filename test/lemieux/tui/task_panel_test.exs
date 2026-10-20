defmodule Lemieux.TUI.TaskPanelTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias ExRatatui.Event.{Mouse, Resize}
  alias ExRatatui.Frame
  alias Lemieux.CLI.{Options, Runtime, Tasks}
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  alias Lemieux.TUI.TaskPanel
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.Transcript
  @moduletag :tmp_dir

  defmodule Source do
    @behaviour Lemieux.Extensions.Watches.Source
    @impl true
    def validate(_state, %{"run_id" => id} = target) when is_binary(id) and id != "",
      do: {:ok, target}

    def validate(_state, _target), do: {:error, :target_needs_run_id}
    @impl true
    def observe(owner, target) do
      send(owner, {:external_observer, self(), target})

      receive do
        :complete -> {:done, %{"outcome" => "success", "logs" => "Deployment ready"}}
      after
        60_000 -> {:error, :unavailable, "fixture held too long"}
      end
    end
  end

  setup %{tmp_dir: dir} do
    runtime = :"task_panel_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    # This fixture exercises the task UI, not automatic sandbox approval.
    {:ok, options} =
      Options.parse([
        "--config",
        "none",
        "--bare",
        "--no-delegate",
        "--permission-mode",
        "full_auto",
        "--no-sandbox"
      ])

    provider =
      Scripted.new([
        Scripted.tool_call("start", "bash", %{
          "command" => "printf READY; sleep 60",
          "background" => true
        }),
        Scripted.complete("Started.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        cwd: dir,
        store: JSONL.new(Path.join(dir, "sessions"))
      )

    :ok = Session.prompt(session, "Start the fixture.")
    assert_receive {:lemieux, _, {:finished, :stop}}
    assert {:ok, %{rows: [%{running?: true, watching?: true}]}} = Tasks.snapshot(session)
    state = tui(session: session, id: Session.id(session), cwd: dir) |> type("keep this draft")

    %{
      state: state,
      session: session,
      provider: provider,
      runtime: runtime,
      options: options,
      dir: dir
    }
  end

  defp click(state, label) do
    {_widget, rect} =
      Enum.find(TaskPanel.render(state, TUI.Screen.panes(state)), fn
        {%ExRatatui.Widgets.Paragraph{text: ^label}, _rect} -> true
        _other -> false
      end)

    assert {:noreply, state} =
             TUI.handle_event(%Mouse{kind: "down", button: "left", x: rect.x, y: rect.y}, state)

    state
  end

  test "mouse buttons stop observation and confirm cancellation of the selected command", ctx do
    state = ctx.state |> press("f6") |> loaded()
    state = state |> click("[s Pause tracking]") |> updated()
    assert hd(TaskPanel.cache(state).rows).running?
    refute hd(TaskPanel.cache(state).rows).watching?
    state = state |> click("[c Cancel command]") |> click("[y Confirm]") |> updated()
    assert hd(TaskPanel.cache(state).rows).status == "cancelled"
  end

  test "native form registration observes an external run without a model turn", ctx do
    provider = Scripted.new([Scripted.complete("The deployment completed.")])

    {:ok, session} =
      Runtime.start_session(ctx.options,
        supervisor: ctx.runtime,
        provider: provider,
        cwd: ctx.dir,
        state_dir: nil,
        watch_sources: %{"deployment" => {Source, self()}},
        store: JSONL.new(Path.join(ctx.dir, "sessions"))
      )

    id = Session.id(session)
    state = tui(session: session, id: id, cwd: ctx.dir) |> press("f6") |> loaded() |> press("a")

    state =
      state
      |> press("tab")
      |> type("deployment-42")
      |> press("tab")
      |> press("tab")
      |> press("tab")
      |> press("enter")

    assert_receive {:external_observer, observer, %{"run_id" => "deployment-42"}}
    state = updated(state)
    assert state.modal.form == nil

    assert [%{source: "deployment", label: "deployment · deployment-42"}] =
             TaskPanel.cache(state).rows

    send(observer, :complete)

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{type: :extension_state, payload: %{"namespace" => "lemieux.notification"}}}}

    state = state |> TaskPanel.refresh() |> loaded()
    assert TaskPanel.cache(state).detail.logs == "Deployment ready"
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 1
  end

  defp loaded(state) do
    session = state.session
    token = TaskPanel.cache(state).token
    assert_receive {:tasks_result, ^session, ^token, :snapshot, {:ok, _view}} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    state
  end

  defp updated(state) do
    session = state.session
    token = state.modal.operation
    assert_receive {:tasks_result, ^session, ^token, :action, :ok} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    loaded(state)
  end

  test "Shift+Up and the composer badge open native tasks without altering the draft", ctx do
    state = ctx.state |> press("up", ["shift"]) |> loaded()
    state = %{state | terminal: %{state.terminal | width: 120, height: 45}}
    assert state.modal.kind == :tasks

    assert Enum.any?(TaskPanel.render(state, TUI.Screen.panes(state)), fn
             {%ExRatatui.Widgets.Block{title: title}, _rect} -> title =~ "Tasks"
             _other -> false
           end)

    assert Enum.any?(TaskPanel.render(state, TUI.Screen.panes(state)), fn
             {%ExRatatui.Widgets.Paragraph{
                block: %ExRatatui.Widgets.Block{title: " Command · v expand "},
                text: lines
              }, _} ->
               Enum.map_join(lines, fn line -> Enum.map_join(line.spans, & &1.content) end) =~
                 "printf READY; sleep 60"

             _ ->
               false
           end)

    assert screen(state) =~ "v Expand command"
    state = press(state, "v")
    assert screen(state) =~ "printf READY; sleep 60"
    assert screen(state) =~ "Command · full shell source"
    state = press(state, "l")
    assert screen(state) =~ "Cancel command"
    assert typed(state) == "keep this draft"
    state = press(state, "up", ["shift"])
    assert state.modal == nil
    area = TUI.Screen.panes(state).input
    event = %Mouse{kind: "down", button: "left", x: area.x + area.width - 4, y: area.y}
    assert {:noreply, state} = TUI.handle_event(event, state)
    assert state.modal.kind == :tasks
    loaded(state)
    assert length(Scripted.requests(ctx.provider)) == 2
  end

  test "empty Active and History frames stay identical throughout periodic refreshes", ctx do
    provider = Scripted.new([])

    {:ok, session} =
      Runtime.start_session(ctx.options,
        supervisor: ctx.runtime,
        provider: provider,
        cwd: ctx.dir,
        store: JSONL.new(Path.join(ctx.dir, "empty-sessions"))
      )

    state = tui(session: session, id: Session.id(session)) |> press("f6")
    assert screen(state) =~ "Loading tasks"
    state = loaded(state)

    for view <- ["1", "2"] do
      selected = state |> press(view) |> loaded()
      assert TaskPanel.cache(selected).rows == []
      before = painted_cells(selected)
      refute Enum.map_join(before, & &1.symbol) =~ "Loading tasks"

      for _ <- 1..3, reduce: selected do
        previous ->
          refreshing = TaskPanel.refresh(previous)
          refute is_nil(TaskPanel.cache(refreshing).token)
          assert painted_cells(refreshing) == before
          settled = loaded(refreshing)
          assert painted_cells(settled) == before
          settled
      end
    end

    assert Scripted.requests(provider) == []
    {:ok, %{rows: [fixture]}} = Tasks.snapshot(ctx.session)
    assert :ok = Tasks.action(ctx.session, fixture.id, :cancel)
  end

  test "a rebound Tasks shortcut toggles the tray and releases Shift+Up to transcript scrolling",
       ctx do
    keys = %{"shift-up" => "scroll_up", "f7" => "tasks"}
    state = tui(session: ctx.session, id: Session.id(ctx.session), keys: keys)
    state = state |> type("keep custom draft") |> press("f7") |> loaded()
    assert state.modal.kind == :tasks
    state = press(state, "f7")
    assert state.modal == nil
    assert typed(state) == "keep custom draft"
    refute Enum.map_join(TaskPanel.title(state, 80), & &1.content) =~ "Shift+Up"
    {:ok, %{rows: [fixture]}} = Tasks.snapshot(ctx.session)
    assert :ok = Tasks.action(ctx.session, fixture.id, :cancel)
  end

  test "human stop, resume and cancellation controls do not invoke the model", ctx do
    state = ctx.state |> press("f6") |> loaded()
    state = state |> press("s") |> updated()
    [row] = TaskPanel.cache(state).rows
    assert row.running?
    refute row.watching?
    state = state |> press("w") |> updated()
    assert hd(TaskPanel.cache(state).rows).watching?
    state = state |> press("f") |> updated()
    refute hd(TaskPanel.cache(state).rows).follow_up?
    state = press(state, "c")
    assert screen(state) =~ "Cancel command"
    assert {:ok, %{rows: [%{running?: true}]}} = Tasks.snapshot(ctx.session)
    state = state |> press("y") |> updated()
    assert hd(TaskPanel.cache(state).rows).status == "cancelled"
    refute hd(TaskPanel.cache(state).rows).watching?
    state = state |> press("x") |> press("y") |> updated()
    assert TaskPanel.cache(state).detail.logs == ""
    assert length(Scripted.requests(ctx.provider)) == 2
  end

  test "tracking attempts keep one row, and completion moves the selected output into History",
       ctx do
    state = ctx.state |> press("f6") |> loaded()
    original = TaskPanel.cache(state).selected
    assert screen(state) =~ "Active 1"
    assert screen(state) =~ "Auto-resume: on"
    state = state |> press("s") |> updated()
    assert screen(state) =~ "command still running"
    state = state |> press("w") |> updated()
    assert [%{id: ^original, history: [_, _]}] = TaskPanel.cache(state).rows
    state = state |> press("c") |> press("y") |> updated()
    assert state.modal.view == :history
    assert TaskPanel.cache(state).selected == original
    assert screen(state) =~ "Cancelled"
    assert screen(state) =~ "History 1"
    refute screen(state) =~ "Resume tracking"
    state = state |> press("1") |> loaded()
    assert state.modal.view == :active
    assert screen(state) =~ "No active tasks"
    state = state |> press("2") |> loaded()
    assert TaskPanel.cache(state).detail.id == original
    assert length(Scripted.requests(ctx.provider)) == 2
  end

  test "a native external-watch form validates fields without command or JSON input", ctx do
    state = ctx.state |> press("f6") |> loaded() |> press("a")
    assert state.modal.form != nil
    assert screen(state) =~ "Observe an existing run"
    assert screen(state) =~ "Repository (owner/repo)"
    assert screen(state) =~ "Commit SHA (40 characters)"
    state = press(state, "enter", ["ctrl"])
    token = state.modal.operation
    assert_receive {:tasks_result, _, ^token, :action, {:error, :invalid_github_target}} = reply
    assert {:noreply, state} = TUI.handle_info(reply, state)
    assert state.modal.form != nil
    assert state.modal.notice =~ "GitHub"
    state = press(state, "esc") |> press("esc")
    assert state.modal == nil
    assert typed(state) == "keep this draft"
    assert length(Scripted.requests(ctx.provider)) == 2
  end

  test "stale replies cannot change a switched session or overwrite a new selection", ctx do
    state = ctx.state |> press("f6") |> loaded()
    old = TaskPanel.cache(state)

    assert TaskPanel.answer(state, ctx.session, make_ref(), :snapshot, {:ok, %{rows: []}}) ==
             state

    switched = %{state | session: nil}

    assert TaskPanel.answer(switched, ctx.session, old.token, :snapshot, {:ok, %{rows: []}}) ==
             switched

    assert TaskPanel.tick(switched, ctx.session, old.timer) == switched
  end

  test "switching tasks shows the selected command immediately and fences late output", ctx do
    state = ctx.state |> press("f6") |> loaded()
    first = TaskPanel.cache(state).detail

    second = %{
      first
      | id: "task:second",
        name: "wayne-gretzky",
        command: "printf SECOND",
        logs: ""
    }

    state = put_in(state.session_view.tasks.rows, [first, second])
    state = state |> press("v") |> press("tab") |> press("down")
    pending = TaskPanel.cache(state)
    assert pending.detail.id == second.id
    assert screen(state) =~ "printf SECOND"
    refute screen(state) =~ "printf READY; sleep 60"
    state = press(state, "up")
    assert TaskPanel.cache(state).detail.id == first.id
    assert TaskPanel.cache(state).detail.logs == first.logs

    assert TaskPanel.answer(
             state,
             ctx.session,
             pending.token,
             :snapshot,
             {:ok, %{rows: [first, second], selected: second.id, detail: second}}
           ) == state

    loaded(state)
    assert :ok = Tasks.action(ctx.session, first.id, :cancel)
  end

  test "successive long and short task frames repaint without leftover cells", ctx do
    state = ctx.state |> press("f6") |> loaded()
    detail = TaskPanel.cache(state).detail
    cells = ExRatatui.CellSession.new(80, 24)
    on_exit(fn -> ExRatatui.CellSession.close(cells) end)

    for {command, logs} <- [
          {String.duplicate("printf '長い command'; ", 50), String.duplicate("old output\n", 100)},
          {"printf NEW", "new"},
          {"sleep 30", ""}
        ],
        content <- ["v", "l"] do
      updated = %{detail | command: command, logs: logs}
      next = put_in(state.session_view.tasks.detail, updated) |> press(content)
      widgets = TUI.render(next, %Frame{width: 80, height: 24})
      :ok = ExRatatui.CellSession.draw(cells, widgets)
      actual = ExRatatui.CellSession.take_cells(cells).cells
      fresh = ExRatatui.CellSession.new(80, 24)
      :ok = ExRatatui.CellSession.draw(fresh, widgets)
      assert actual == ExRatatui.CellSession.take_cells(fresh).cells
      :ok = ExRatatui.CellSession.close(fresh)
    end

    assert :ok = Tasks.action(ctx.session, detail.id, :cancel)
  end

  test "expanded commands scroll through the complete source and return to output", ctx do
    state = ctx.state |> press("f6") |> loaded()
    command = Enum.map_join(1..40, "\n", &"printf STEP_#{&1}") <> "\nprintf SOURCE_END"
    state = put_in(state.session_view.tasks.detail.command, command)
    refute painted(state) =~ "SOURCE_END"
    state = press(state, "v")
    assert painted(state) =~ "STEP_1"
    refute painted(state) =~ "SOURCE_END"
    state = press(state, "end")
    assert painted(state) =~ "SOURCE_END"
    state = press(state, "v")
    assert state.modal.content == :output
    assert state.modal.follow?
    assert screen(state) =~ "v Expand command"
    state = press(state, "v")
    assert state.modal.content == :command
    state = click(state, "[v Show output]")
    assert state.modal.content == :output
    state = press(state, "l")
    assert painted(state) =~ "Output"
    refute painted(state) =~ "SOURCE_END"
    assert :ok = Tasks.action(ctx.session, TaskPanel.cache(state).detail.id, :cancel)
  end

  defp painted(state), do: state |> painted_cells() |> Enum.map_join(& &1.symbol)

  test "Tab focus has distinct section borders and labels in every theme", ctx do
    state = ctx.state |> press("f6") |> loaded()

    section = fn current, label ->
      Enum.find_value(TaskPanel.render(current, TUI.Screen.panes(current)), fn
        {%ExRatatui.Widgets.Paragraph{block: %ExRatatui.Widgets.Block{} = block}, _} ->
          if String.starts_with?(block.title, " #{label}"), do: block

        _ ->
          nil
      end)
    end

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      themed = put_in(state.appearance.theme, theme)
      list = section.(themed, "Task list")
      output = section.(themed, "Output")
      assert list.title =~ "focused"
      refute output.title =~ "focused"
      refute list.border_style == output.border_style
      switched = press(themed, "tab")
      assert section.(switched, "Output").title =~ "focused"
      refute section.(switched, "Task list").title =~ "focused"
      assert section.(switched, "Output").border_style == list.border_style
      assert press(switched, "tab").modal.focus == :list
    end

    assert :ok = Tasks.action(ctx.session, TaskPanel.cache(state).detail.id, :cancel)
  end

  test "expanded details adapt between commands and agents without blanking cached output", ctx do
    state = ctx.state |> press("f6") |> loaded() |> press("v") |> press("tab")
    command = TaskPanel.cache(state).detail

    agent =
      Map.merge(command, %{
        id: "agent:fixture",
        kind: :agent,
        command: nil,
        instructions: "Inspect the repository",
        name: "fixture-agent",
        cancel_label: "Cancel agent",
        steerable?: false
      })

    state = put_in(state.session_view.tasks.rows, [command, agent])
    state = put_in(state.session_view.tasks.details[agent.id], agent)
    selected = press(state, "down")
    assert selected.modal.content == :instructions
    assert screen(selected) =~ "Inspect the repository"
    refute screen(selected) =~ "No local command"
    returned = press(selected, "up")
    assert returned.modal.content == :command
    assert screen(returned) =~ command.command
    state = loaded(returned)
    assert :ok = Tasks.action(ctx.session, TaskPanel.cache(state).detail.id, :cancel)
  end

  defp painted_cells(state) do
    cells = ExRatatui.CellSession.new(80, 24)
    :ok = ExRatatui.CellSession.draw(cells, TUI.render(state, %Frame{width: 80, height: 24}))
    snapshot = ExRatatui.CellSession.take_cells(cells).cells
    :ok = ExRatatui.CellSession.close(cells)
    snapshot
  end

  test "the task tray grows above the composer and leaves the transcript visible", ctx do
    state = ctx.state |> press("f6") |> loaded()
    state = %{state | terminal: %{state.terminal | width: 120, height: 50}}
    panes = TUI.Screen.panes(state)
    small = TaskPanel.area(state, panes)
    assert small.y + small.height == panes.input.y
    assert small.y > panes.transcript.y + 5
    assert small.height < 25
    assert small.x == panes.input.x and small.width == panes.input.width
    detail = TaskPanel.cache(state).detail
    long = %{detail | logs: Enum.map_join(1..80, "\n", &"log #{&1}")}
    rows = Enum.map(1..5, &%{detail | id: "task:#{&1}"})

    expanded =
      state
      |> put_in([Access.key!(:session_view), :tasks, :rows], rows)
      |> put_in([Access.key!(:session_view), :tasks, :detail], long)

    large = TaskPanel.area(expanded, panes)
    assert large.height > small.height
    assert large.y + large.height == panes.input.y
    assert large.y > panes.transcript.y
    assert typed(expanded) == "keep this draft"

    assert Enum.any?(TaskPanel.render(expanded, panes), fn
             {%ExRatatui.Widgets.Paragraph{block: %ExRatatui.Widgets.Block{title: title}}, rect} ->
               String.starts_with?(title, " Output") and rect.height >= 6

             _ ->
               false
           end)

    empty =
      state
      |> put_in([Access.key!(:session_view), :tasks, :rows], [])
      |> put_in([Access.key!(:session_view), :tasks, :detail], nil)
      |> put_in([Access.key!(:session_view), :tasks, :selected], nil)

    assert TaskPanel.area(empty, panes).height <= 6
    assert :ok = Tasks.action(ctx.session, detail.id, :cancel)
  end

  test "native frames retain the latest transcript above the tray and leave composer cells intact",
       ctx do
    state = ctx.state |> press("f6") |> loaded()
    state = %{state | terminal: %{state.terminal | width: 100, height: 40}}
    state = Transcript.say(state, :lmx, "PRIMARY_TRANSCRIPT_IS_VISIBLE")
    panes = TUI.Screen.panes(state)
    area = TaskPanel.area(state, panes)
    cells = ExRatatui.CellSession.new(100, 40)
    on_exit(fn -> ExRatatui.CellSession.close(cells) end)

    :ok = ExRatatui.CellSession.draw(cells, TUI.render(state, %Frame{width: 100, height: 40}))
    open = ExRatatui.CellSession.take_cells(cells).cells
    above = open |> Enum.filter(&(&1.row < area.y)) |> Enum.map_join(& &1.symbol)
    assert above =~ "PRIMARY_TRANSCRIPT_IS_VISIBLE"
    assert Enum.map_join(open, & &1.symbol) =~ "keep this draft"

    :ok =
      ExRatatui.CellSession.draw(
        cells,
        TUI.render(press(state, "f6"), %Frame{width: 100, height: 40})
      )

    closed = ExRatatui.CellSession.take_cells(cells).cells

    composer = fn snapshot ->
      snapshot
      |> Enum.filter(&(&1.row >= panes.input.y and &1.row < panes.input.y + panes.input.height))
      |> Enum.map(&{&1.row, &1.col, &1.symbol})
    end

    assert composer.(open) == composer.(closed)
    assert :ok = Tasks.action(ctx.session, TaskPanel.cache(state).detail.id, :cancel)
  end

  test "list, logs and form geometry remain inside small and resized terminals", ctx do
    state = ctx.state |> press("f6") |> loaded()
    detail = %{TaskPanel.cache(state).detail | logs: Enum.map_join(1..80, "\n", &"log #{&1} 測試")}
    state = put_in(state.session_view.tasks.detail, detail)
    state = state |> press("enter") |> press("page_up")
    refute state.modal.follow?
    assert state.modal.offset > 0
    assert press(state, "end").modal.follow?

    for {width, height} <- [{1, 1}, {20, 8}, {42, 17}, {100, 30}], form? <- [false, true] do
      resized = if form?, do: press(state, "a"), else: state

      assert {:noreply, resized} =
               TUI.handle_event(%Resize{width: width, height: height}, resized)

      for {_widget, rect} <- TaskPanel.render(resized, TUI.Screen.panes(resized)) do
        assert rect.x >= 0 and rect.y >= 0
        assert rect.x + rect.width <= width
        assert rect.y + rect.height <= height
      end

      assert is_list(TUI.render(resized, %Frame{width: width, height: height}))
      cells = ExRatatui.CellSession.new(width, height)

      assert :ok =
               ExRatatui.CellSession.draw(
                 cells,
                 TUI.render(resized, %Frame{width: width, height: height})
               )

      assert :ok = ExRatatui.CellSession.close(cells)
    end
  end

  test "native controls respect the embedding host's action policy", ctx do
    state =
      put_in(ctx.state, [Access.key!(:tool_choices), :command_policy], fn {:tasks, _action} ->
        {:deny, "Tasks withheld by this host"}
      end)

    state = press(state, "f6")
    assert state.modal == nil
    assert state.terminal.feedback.text == "Tasks withheld by this host"
    assert TaskPanel.title(state, 80) == []
  end

  test "hosts without native runtime metadata do not start polling workers", ctx do
    state = TaskPanel.reset(ctx.state, %{id: Session.id(ctx.session)})
    refute TaskPanel.cache(state).supported?
    assert TaskPanel.cache(state).token == nil
    state = press(state, "f6")
    assert state.modal.kind == :tasks
    assert screen(state) =~ "This host does not expose native tasks"
    assert TaskPanel.cache(state).token == nil
  end

  test "disconnection keeps evidence visible and disables active controls", ctx do
    state = ctx.state |> press("f6") |> loaded() |> TaskPanel.disconnected()

    assert [%{status: "unavailable", running?: false, watching?: false}] =
             TaskPanel.cache(state).rows

    assert screen(state) =~ "Unavailable"
    refute screen(state) =~ "Cancel command"
    assert TaskPanel.cache(state).token == nil
    assert TaskPanel.cache(state).timer == nil
  end

  test "run links accept web URLs and reject local schemes", ctx do
    state = ctx.state |> press("f6") |> loaded()
    owner = self()

    state =
      put_in(state.terminal.open_link, fn url ->
        send(owner, {:opened, url})
        :ok
      end)

    for {url, expected} <- [
          {"file:///tmp/unsafe", {:error, :no_run_link}},
          {"https://example.test/run/42", :ok}
        ] do
      rows = Enum.map(TaskPanel.cache(state).rows, &%{&1 | url: url})
      changed = put_in(state.session_view.tasks.rows, rows) |> press("o")
      token = changed.modal.operation
      assert_receive {:tasks_result, _, ^token, :action, ^expected} = reply
      assert {:noreply, changed} = TUI.handle_info(reply, changed)
      loaded(changed)
    end

    assert_receive {:opened, "https://example.test/run/42"}
    refute_receive {:opened, "file:///tmp/unsafe"}, 20
  end
end
