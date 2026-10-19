defmodule Lemieux.TasksUnifiedTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Tasks
  alias Lemieux.ID.Shorthand
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.{Definition, Request, Task}
  alias Lemieux.TUI
  alias Lemieux.TUI.TaskPanel
  import Lemieux.TUI.TestSupport
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"unified_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: Scripted.new([]),
        model: "test:model",
        subscriber: self(),
        cwd: dir,
        tools: []
      )

    %{runtime: runtime, parent: parent, dir: dir}
  end

  defp child(ctx, opts \\ []) do
    owner = self()

    provider =
      Scripted.new([
        fn _ ->
          send(owner, {:agent_ready, self()})

          receive do
            :finish -> Scripted.complete(JSON.encode!(%{"answer" => "Found the result"}))
          after
            60_000 -> raise "agent fixture not released"
          end
        end,
        Scripted.complete(JSON.encode!(%{"answer" => "Updated result"}))
      ])

    definition =
      Definition.new(
        id: "scout",
        description: "Read-only scout",
        system_prompt: "Investigate",
        model: "test:child",
        tools: [],
        max_requests: 5
      )

    request =
      Request.new(
        definition,
        Task.new(objective: "Investigate the repository layout", snapshot: %{"version" => 1})
      )

    {:ok, group} =
      Subagent.spawn_many(
        ctx.parent,
        [request],
        [max_cost_usd: 10, providers: %{"scout" => provider}] ++ opts
      )

    {:ok, [ref]} = Subagent.children(group)
    assert_receive {:agent_ready, worker}
    {group, ref, worker, provider}
  end

  test "agents without commands appear with their brief and durable result in the same task view",
       ctx do
    {group, ref, worker, provider} = child(ctx)
    assert {:ok, %{rows: [row], detail: detail}} = Tasks.snapshot(ctx.parent)
    assert row.kind == :agent and row.running?
    assert row.name == Shorthand.of(ref.id)
    assert {:ok, %{session: summary}} = Subagent.inspect(ref, include_entries: false)
    refute Map.has_key?(summary, :entries)
    assert {:ok, %{session: %{entries: [_ | _]}}} = Subagent.inspect(ref)
    assert row.description == "Investigate the repository layout"
    assert detail.instructions =~ "Investigate the repository layout"
    assert length(Scripted.requests(provider)) == 1
    send(worker, :finish)
    assert {:ok, %{results: [%{status: :ok}]}} = Subagent.await(group, 5000)

    assert {:ok, %{rows: [%{active?: false, status: "success"}], detail: completed}} =
             Tasks.snapshot(ctx.parent, row.id)

    assert completed.logs =~ "Found the result"
    assert length(Scripted.requests(provider)) == 1

    state = tui(session: ctx.parent, id: Session.id(ctx.parent)) |> press("f6") |> loaded()
    state = state |> press("2") |> loaded()
    assert TaskPanel.cache(state).detail.logs =~ "Found the result"
    state = press(state, "up")
    assert TaskPanel.cache(state).detail.logs =~ "Found the result"
    loaded(state)
  end

  test "native steering and cancellation resolve the current owned capability", ctx do
    {group, ref, _worker, provider} = child(ctx)
    assert {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    assert :ok = Tasks.steer(ctx.parent, row.id, "Also inspect tests")

    assert Enum.any?(Session.snapshot(ctx.parent).entries, fn e ->
             e.type == :subagent_steer and e.payload["child_id"] == ref.id and
               e.payload["instruction"] == "Also inspect tests"
           end)

    assert :ok = Tasks.action(ctx.parent, row.id, :cancel)
    assert {:ok, %{results: [%{status: :cancelled}]}} = Subagent.await(group, 5000)
    assert length(Scripted.requests(provider)) == 1
  end

  test "a parent cannot discover or control another parent's agent", ctx do
    {group, _ref, _worker, _provider} = child(ctx)
    {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)

    {:ok, other} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: JSONL.new(ctx.dir),
        provider: Scripted.new([]),
        model: "test:model",
        tools: [],
        subscriber: self()
      )

    assert {:ok, %{rows: []}} = Tasks.snapshot(other)
    assert {:error, :task_unavailable} = Tasks.action(other, row.id, :cancel)
    assert {:error, :task_unavailable} = Tasks.steer(other, row.id, "Change scope")
    assert :ok = Subagent.cancel(group)
  end

  test "the native tray steers and cancels an agent while retaining the main draft", ctx do
    {group, _ref, _worker, provider} = child(ctx)

    state =
      tui(session: ctx.parent, id: Session.id(ctx.parent))
      |> type("keep the main draft")
      |> press("f6")
      |> loaded()

    assert screen(state) =~ "Agent"
    assert screen(state) =~ "Steer agent"
    refute screen(state) =~ "Pause tracking"
    state = press(state, "v")
    assert screen(state) =~ "Instructions · full brief"

    state =
      press(state, "t") |> type("Also inspect tests") |> press("enter", ["ctrl"]) |> updated()

    assert state.modal.form == nil
    assert typed(state) == "keep the main draft"
    state = state |> press("c") |> press("y") |> updated()
    assert state.modal.view == :history
    assert {:ok, %{results: [%{status: :cancelled}]}} = Subagent.await(group, 5000)
    assert length(Scripted.requests(provider)) == 1
    assert typed(state) == "keep the main draft"
  end

  test "resumed agent history remains observable without restoring a live control capability",
       ctx do
    {group, _ref, worker, _provider} = child(ctx)
    {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    send(worker, :finish)
    assert {:ok, _} = Subagent.await(group, 5000)
    id = Session.id(ctx.parent)

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(ctx.runtime),
        ctx.parent
      )

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: ctx.runtime,
        store: JSONL.new(ctx.dir),
        resume: id,
        provider: Scripted.new([]),
        model: "test:model",
        tools: [],
        subscriber: self()
      )

    assert {:ok, %{rows: [%{name: name, status: "success"}], detail: detail}} =
             Tasks.snapshot(resumed, row.id)

    assert name == row.name
    assert detail.logs =~ "Found the result"
    assert {:ok, []} = Subagent.current(resumed)
    assert {:error, :not_running} = Tasks.action(resumed, row.id, :cancel)
  end

  test "restricted child inspection cannot be replaced with an unrestricted transcript read",
       ctx do
    {group, ref, _worker, _provider} =
      child(ctx,
        authorize: fn
          :inspect, _ -> {:error, :private_child}
          _, _ -> :ok
        end
      )

    assert {:error, {:denied, :private_child}} = Subagent.inspect(ref, include_entries: false)

    assert {:ok, %{rows: [%{status: "restricted", active?: true}], detail: detail}} =
             Tasks.snapshot(ctx.parent)

    assert detail.logs =~ "private_child"
    refute detail.logs =~ "Found the result"
    assert :ok = Subagent.cancel(group)
    assert {:ok, _} = Subagent.await(group, 5000)
  end

  test "steering form stays bounded on resize and its Back button preserves the main draft",
       ctx do
    {group, _ref, _worker, provider} = child(ctx)

    state =
      tui(session: ctx.parent, id: Session.id(ctx.parent))
      |> type("main draft")
      |> press("f6")
      |> loaded()
      |> press("t")
      |> type("A private steering draft")

    for {width, height} <- [{1, 1}, {20, 8}, {42, 17}, {100, 40}] do
      resized = %{state | terminal: %{state.terminal | width: width, height: height}}

      for {_widget, rect} <- TaskPanel.render(resized, TUI.Screen.panes(resized)) do
        assert rect.x >= 0 and rect.y >= 0
        assert rect.x + rect.width <= width
        assert rect.y + rect.height <= height
      end
    end

    {_widget, back} =
      Enum.find(TaskPanel.render(state, TUI.Screen.panes(state)), fn
        {%ExRatatui.Widgets.Paragraph{text: "[Esc Back]"}, _} -> true
        _ -> false
      end)

    assert {:noreply, state} =
             TUI.handle_event(
               %ExRatatui.Event.Mouse{kind: "down", button: "left", x: back.x, y: back.y},
               state
             )

    assert state.modal.form == nil
    assert typed(state) == "main draft"
    assert length(Scripted.requests(provider)) == 1
    assert :ok = Subagent.cancel(group)
    assert {:ok, _} = Subagent.await(group, 5000)
  end

  defp loaded(state) do
    session = state.session
    token = TaskPanel.cache(state).token
    assert_receive {:tasks_result, ^session, ^token, :snapshot, {:ok, _}} = reply
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

  test "the task panel cannot bypass the delegate host's current control policy", ctx do
    {_group, _ref, worker, _provider} =
      child(ctx,
        authorize: fn
          action, _ when action in [:steer, :cancel] -> {:error, :withheld}
          _, _ -> :ok
        end
      )

    {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    assert {:error, {:denied, :withheld}} = Tasks.steer(ctx.parent, row.id, "Change scope")
    assert {:error, {:denied, :withheld}} = Tasks.action(ctx.parent, row.id, :cancel)
    send(worker, :finish)
    assert_receive {:lemieux, _, {:subagent, _, {:group_finished, _}}}
  end
end
