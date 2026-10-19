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

  test "F6 and the composer badge open native tasks without altering the draft", ctx do
    state = ctx.state |> press("f6") |> loaded()
    assert state.modal.kind == :tasks

    assert Enum.any?(TaskPanel.render(state, TUI.Screen.panes(state)), fn
             {%ExRatatui.Widgets.Block{title: title}, _rect} -> title =~ "Background tasks"
             _other -> false
           end)

    assert screen(state) =~ "printf READY; sleep 60"
    assert screen(state) =~ "Cancel command"
    assert typed(state) == "keep this draft"
    state = press(state, "f6")
    assert state.modal == nil
    area = TUI.Screen.panes(state).input
    event = %Mouse{kind: "down", button: "left", x: area.x + area.width - 4, y: area.y}
    assert {:noreply, state} = TUI.handle_event(event, state)
    assert state.modal.kind == :tasks
    loaded(state)
    assert length(Scripted.requests(ctx.provider)) == 2
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
    assert screen(state) =~ "Cancel this command?"
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
