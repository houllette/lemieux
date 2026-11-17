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

    def run(owner, "held-check", _opts) do
      {:ok,
       Stream.resource(
         fn -> :start end,
         fn
           :start ->
             send(owner, {:check_started, self()})
             {[{:data, "checking\e[31m fixture\e[0m\n"}], :held}

           :held ->
             receive do
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

  defp start(ctx) do
    {:ok, harness} = Harness.assemble(Harness.new(), [{Verify, command: "held-check"}])

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

  defp held(ctx) do
    {session, provider} = start(ctx)
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
    assert screen(state) =~ "Answer received · verifying held-check"
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

  test "post-answer verification is visible and targeted cancellation preserves the answer",
       ctx do
    {session, provider, row, pump, state} = held(ctx)
    monitor = Process.monitor(pump)
    assert {:ok, _} = Verify.set_enabled(session, false)
    assert :ok = Tasks.action(session, row.id, :cancel)
    assert_receive {:DOWN, ^monitor, :process, ^pump, _}
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}} = finished
    assert {:noreply, done} = TUI.handle_info(finished, state)
    refute done.conversation.busy?
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
      {session, provider, _row, pump, _state} = held(ctx)
      id = Session.id(session)

      if unquote(status) == "passed",
        do: assert(:ok = Session.follow_up(session, "queued question"))

      send(pump, {:finish, unquote(Macro.escape(event))})
      assert_receive {:lemieux, ^id, {:finished, :stop}}
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
