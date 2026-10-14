defmodule Lemieux.TUI.SkillLoadingTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Extensions.Workspace.AssetReader
  alias Lemieux.Extensions.Workspace.AssetReader.Local
  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI

  @moduletag :tmp_dir

  defmodule Remote do
    @behaviour AssetReader

    @impl true
    def resolve(state, path) do
      path = String.replace_prefix(path, state.host, state.remote)
      {:ok, Containment.real_path(path)}
    end

    @impl true
    def stat(_state, path), do: Local.stat(nil, path)

    @impl true
    def list_dir(_state, path, limit), do: Local.list_dir(nil, path, limit)

    @impl true
    def read_file(state, path, limit) do
      send(state.owner, {:reading, self(), path})

      if state.held? do
        receive do
          :continue -> :ok
        after
          :timer.minutes(1) -> exit(:fixture_was_not_released)
        end
      end

      Local.read_file(nil, path, limit)
    end
  end

  setup %{tmp_dir: root} do
    host = Path.join(root, "host")
    remote = Path.join(root, "remote")

    for {dir, text} <- [{host, "HOST BODY"}, {remote, "REMOTE BODY $ARGUMENTS"}] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: kit\ndescription: A kit.\n---\n#{text}")
    end

    {:ok, skill} = Skill.read(Path.join(host, "SKILL.md"))
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    environment = {Remote, :selected}
    provider = Scripted.new([Scripted.complete("done")])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(Path.join(root, "sessions")),
        model: "test:skill",
        environment: environment,
        subscriber: self()
      )

    supervisor = start_supervised!({Task.Supervisor, []})
    state = tui(session: session, skills: [skill], environment: environment)
    state = put_in(state.resume.task_supervisor, supervisor)

    %{
      host: host,
      remote: remote,
      state: state,
      environment: environment,
      provider: provider,
      session: session
    }
  end

  defp with_reader(ctx, held? \\ false) do
    reader =
      AssetReader.new(
        {Remote, %{host: ctx.host, remote: ctx.remote, owner: self(), held?: held?}},
        roots: [ctx.remote],
        home: Path.join(ctx.remote, "home")
      )

    environment = ctx.environment
    selector = fn ^environment -> {:ok, reader} end
    %{ctx.state | skills: Enum.map(ctx.state.skills, &%{&1 | asset_reader: selector})}
  end

  defp submit(state), do: press(type(state, "/kit task"), "enter")

  defp complete(state) do
    ref = state.references.skill_load.task.ref
    assert_receive {^ref, result}
    assert {:noreply, state} = TUI.handle_info({ref, result}, state)
    state
  end

  test "native slash commands use the session environment and preserve the original echo", ctx do
    state = ctx |> with_reader() |> submit()
    assert screen(state) =~ "/kit task"
    refute screen(state) =~ "REMOTE BODY"
    state = complete(state)
    assert state.conversation.busy?
    id = Lemieux.Session.id(ctx.session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert [%{entries: entries}] = Scripted.requests(ctx.provider)
    assert Enum.any?(entries, &(&1.type == :user and &1.payload["text"] =~ "REMOTE BODY task"))
    refute Enum.any?(entries, &(&1.type == :user and &1.payload["text"] =~ "HOST BODY"))
  end

  test "a custom environment without a reader cannot load the host copy", ctx do
    state = ctx.state |> submit() |> complete()
    assert screen(state) =~ "reader is unavailable"
    refute state.conversation.busy?
    assert Scripted.requests(ctx.provider) == []
  end

  test "a held reader leaves the UI responsive and holds subsequent prompts", ctx do
    state = ctx |> with_reader(true) |> submit()
    assert_receive {:reading, worker, _path}
    assert Process.alive?(worker)
    ref = state.references.skill_load.task.ref
    refute_receive {^ref, _result}, 20
    waiting = state |> type("another prompt") |> press("enter")
    assert typed(waiting) == "another prompt"
    refute waiting.conversation.busy?
    assert Scripted.requests(ctx.provider) == []
    send(worker, :continue)
    complete(waiting)
    id = Lemieux.Session.id(ctx.session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
  end

  test "a result from a replaced session or environment is discarded", ctx do
    for change <- [:session, :environment] do
      state = ctx |> with_reader(true) |> submit()
      assert_receive {:reading, worker, _path}

      changed =
        case change do
          :session -> %{state | session: self()}
          :environment -> put_in(state.references.environment, {Remote, :replaced})
        end

      send(worker, :continue)
      completed = complete(changed)
      assert completed.references.skill_load == nil
      refute completed.conversation.busy?
      assert Scripted.requests(ctx.provider) == []
    end
  end

  test "interrupting a pending load cannot send its instructions later", ctx do
    state = ctx |> with_reader(true) |> submit()
    assert_receive {:reading, worker, _path}
    monitor = Process.monitor(worker)
    cancelled = press(state, "c", ["ctrl"])
    assert cancelled.references.skill_load == nil
    assert cancelled.exit_armed == nil
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    refute cancelled.conversation.busy?
    assert Scripted.requests(ctx.provider) == []
  end

  test "closing the screen stops a pending asset task", ctx do
    state = ctx |> with_reader(true) |> submit()
    assert_receive {:reading, worker, _path}
    ref = state.references.skill_load.task.ref
    monitor = Process.monitor(worker)
    assert :ok = TUI.terminate(:normal, state)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    refute_receive {^ref, _result}, 20
    assert Scripted.requests(ctx.provider) == []
  end
end
