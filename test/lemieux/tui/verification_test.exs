defmodule Lemieux.TUI.VerificationTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.CLI.Tasks
  alias Lemieux.Extensions.Verify
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI

  @moduletag :tmp_dir

  defmodule Environment do
    @behaviour Lemieux.Environment
    def read_file(_owner, _cwd, _path), do: {:error, :enoent}
    def write_file(_owner, _cwd, _path, _contents), do: {:ok, :created}

    def run(owner, command, _opts) when command in ["held-check", "mix test"] do
      {:ok,
       Stream.resource(
         fn -> :start end,
         fn
           :start ->
             send(owner, {:check_started, self()})
             {[{:data, "checking\e[31m fixture\e[0m\n"}], :held}

           :held ->
             receive do
               {:output, output} -> {[{:data, output}], :held}
               {:finish, event} -> {[event], :done}
             after
               60_000 -> {[{:failed, :fixture_not_released}], :done}
             end

           :done ->
             {:halt, :done}
         end,
         fn _ -> :ok end
       )}
    end
  end

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, dir: dir}
  end

  defp start(ctx, command) do
    {:ok, harness} = Harness.assemble(Harness.new(), [{Verify, command: command}])

    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{"path" => "file", "content" => "edited"}),
        Scripted.complete("Answer already received."),
        Scripted.complete("Next answer.")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        provider: provider,
        model: "test:model",
        cwd: ctx.dir,
        store: JSONL.new(Path.join(ctx.dir, "sessions")),
        harness: harness,
        environment: {Environment, self()},
        subscriber: self()
      )

    {session, provider}
  end

  defp held(ctx, command \\ "held-check") do
    {session, provider} = start(ctx, command)
    id = Session.id(session)
    assert {:ok, state} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert :ok = Session.prompt(session, "edit")
    assert_receive {:check_started, pump}

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{
                       type: :extension_state,
                       payload: %{
                         "namespace" => "lemieux.verify",
                         "value" => %{"last" => %{"status" => "running"}}
                       }
                     }}} = event

    assert {:noreply, state} = TUI.handle_info(event, put_in(state.conversation.busy?, true))
    assert state.turn.phase.kind == :verification
    assert screen(state) =~ "Answer received · verifying #{command}"
    assert Session.info(session).status == :busy
    assert {:error, :busy} = Session.prompt(session, "too soon")

    answers =
      for %{type: :assistant, payload: payload} <- Session.snapshot(session).entries,
          do: payload["content"]

    assert [%{"text" => "Answer already received.", "type" => "text"}] in answers

    assert {:ok, %{rows: [%{kind: :verification, running?: true} = row]}} =
             Tasks.snapshot(session)

    [{work, _}] =
      Registry.lookup(
        Lemieux.Supervisor.background_registry(ctx.runtime),
        {:verification, id, row.work_id}
      )

    assert :ok = LemieuxTest.Sync.state(work, &(&1.logs =~ "checking"))
    assert {:ok, %{detail: detail}} = Tasks.snapshot(session, row.id)
    assert detail.logs =~ "checking fixture"
    refute detail.logs =~ "\e"
    assert {:ok, reattached} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert reattached.turn.phase.kind == :verification
    refute_receive {:lemieux, ^id, {:finished, _}}, 20
    {session, provider, row, pump, state}
  end

  test "Mix prerequisite failures finish with a blocked status without asking for repair", ctx do
    {session, provider, row, pump, state} = held(ctx, "mix test")

    send(
      pump,
      {:output,
       """
       Unchecked dependencies for environment test:
       * fixture_dependency (Hex package)
         the dependency is not available
       ** (Mix) Can't continue due to errors on dependencies
       """}
    )

    send(pump, {:finish, {:exit_status, 1}})
    state = fold_to_finish(Session.id(session), state)
    assert length(Scripted.requests(provider)) == 2
    assert screen(state) =~ "Verification blocked · mix test"
    assert {:ok, %{detail: %{status: "blocked", logs: logs}}} = Tasks.snapshot(session, row.id)
    assert logs =~ "Unchecked dependencies"
  end

  test "post-answer verification is visible and targeted cancellation preserves the answer",
       ctx do
    {session, provider, row, pump, state} = held(ctx)
    monitor = Process.monitor(pump)
    assert {:ok, _} = Verify.set_enabled(session, false)
    assert :ok = Tasks.action(session, row.id, :cancel)
    assert_receive {:DOWN, ^monitor, :process, ^pump, _}
    id = Session.id(session)
    done = fold_to_finish(id, state)
    refute done.conversation.busy?
    assert screen(done) =~ "Verification cancelled · held-check"
    assert Session.info(session).status == :idle

    assert {:ok,
            %{last: %{"status" => "cancelled", "command" => "held-check", "output" => output}}} =
             Verify.status(session)

    assert output =~ "checking fixture"
    assert {:ok, %{enabled: false}} = Verify.status(session)
    assert length(Scripted.requests(provider)) == 2
    assert :ok = Session.prompt(session, "continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 3
  end

  test "turn cancellation stops verification and records its specific lifecycle", ctx do
    {session, _provider, _row, pump, _state} = held(ctx)
    monitor = Process.monitor(pump)
    assert :ok = Session.cancel(session)
    assert_receive {:DOWN, ^monitor, :process, ^pump, _}
    id = Session.id(session)

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{
                       type: :extension_state,
                       payload: %{
                         "namespace" => "lemieux.verify",
                         "value" => %{"last" => %{"status" => "cancelled"}}
                       }
                     }}}

    assert Session.info(session).status == :idle
  end

  test "long assertion output stays in Tasks and the repair prompt stays in context", ctx do
    {session, provider, row, pump, state} = held(ctx)
    id = Session.id(session)
    diagnostics = Enum.map_join(1..120, "\n", &"assertion failure #{&1}")
    send(pump, {:output, diagnostics})
    send(pump, {:finish, {:exit_status, 1}})

    state = fold_to_finish(id, state)
    assert length(Scripted.requests(provider)) == 3

    assert Enum.any?(Session.snapshot(session).entries, fn entry ->
             entry.type == :user && entry.payload["stop_hook"] &&
               entry.payload["text"] =~ "assertion failure 120"
           end)

    [{work, _}] =
      Registry.lookup(
        Lemieux.Supervisor.background_registry(ctx.runtime),
        {:verification, id, row.work_id}
      )

    monitor = Process.monitor(work)
    send(work, :expire)
    assert_receive {:DOWN, ^monitor, :process, ^work, :normal}
    assert {:ok, %{detail: detail}} = Tasks.snapshot(session, row.id)
    assert detail.status == "failed"
    assert detail.logs =~ "assertion failure 1\n"
    assert detail.logs =~ "assertion failure 120"

    assert {:ok, reopened} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)

    for ui <- [state, reopened] do
      assert Enum.count(ui.lines, &match?({:verification, _, _}, &1)) == 2
      assert length(ui.lines) < 25
      text = screen(ui)
      assert text =~ "Verification failed (exit 1)"
      assert text =~ "F6 Tasks"
      refute text =~ "✓ Verification"
      refute text =~ "assertion failure"
      refute text =~ "Fix what your changes broke"
    end

    assert screen(reopened) =~ ~r/Answer already received.*Verification failed.*Next answer/s
    refute state.conversation.busy?
  end

  defp fold_to_finish(id, state) do
    assert_receive {:lemieux, ^id, event}
    assert {:noreply, state} = TUI.handle_info({:lemieux, id, event}, state)
    if match?({:finished, :stop}, event), do: state, else: fold_to_finish(id, state)
  end

  test "an authorized later result is labeled as a new follow-up in live and saved views" do
    value = %{"follow_up" => true, "text" => "result arrived", "display_text" => "Result ready"}

    entry =
      Lemieux.Entry.new(:extension_state, %{
        "namespace" => "lemieux.notification",
        "value" => value
      })

    state = tui(lines: [{:model, "Earlier answer"}])
    assert {:noreply, state} = TUI.handle_info({:lemieux, state.id, {:entry, entry}}, state)
    assert screen(state) =~ "Follow-up · new results"

    rows =
      TUI.TranscriptPresentation.lines([entry], %{
        width: 80,
        theme: TUI.Theme.dark(),
        renderers: %{}
      })

    assert Enum.find_index(rows, &(&1 == {:lmx, "Follow-up · new results"})) <
             Enum.find_index(rows, &(&1 == {:lmx, "Result ready"}))
  end

  for {event, status, requests} <- [
        {{:exit_status, 0}, "passed", 2},
        {{:exit_status, 1}, "failed", 3},
        {{:timeout, 300_000}, "timed_out", 3}
      ] do
    test "#{status} verification settles coherently and preserves queued follow-ups", ctx do
      {session, provider, _row, pump, state} = held(ctx)
      id = Session.id(session)

      if unquote(status) == "passed",
        do: assert(:ok = Session.follow_up(session, "queued question"))

      send(pump, {:finish, unquote(Macro.escape(event))})
      state = fold_to_finish(id, state)
      assert screen(state) =~ "Verification " <> String.replace(unquote(status), "_", " ")
      assert {:ok, %{last: %{"status" => unquote(status)}}} = Verify.status(session)
      expected = if unquote(status) == "passed", do: 3, else: unquote(requests)

      if unquote(status) == "passed" do
        assert_receive {:lemieux, ^id, {:finished, :stop}}
      end

      assert length(Scripted.requests(provider)) == expected
      assert Session.info(session).status == :idle
    end
  end
end
