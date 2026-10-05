defmodule Lemieux.TelemetryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Telemetry
  alias Lemieux.Testing

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    handler = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler,
        Telemetry.events(),
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  def handle_event(event, measurements, metadata, owner) do
    send(owner, {:telemetry, event, measurements, metadata})
  end

  test "emits correlated redacted spans across a tool-using prompt", context do
    File.write!(Path.join(context.tmp_dir, "hello.txt"), "hello")

    provider =
      Scripted.new([
        Scripted.tool_call("call-1", "read", %{"path" => "hello.txt"}),
        Scripted.complete("done", fragments: ["do", "ne"])
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        cwd: context.tmp_dir,
        tools: [Lemieux.Tools.Read]
      )

    assert {:ok, %{stop_reason: :stop}} = Testing.prompt(session, "read the file")
    telemetry = drain_telemetry([])
    names = Enum.map(telemetry, &elem(&1, 0))

    for event <- [
          [:lemieux, :session, :prompt, :start],
          [:lemieux, :session, :prompt, :stop],
          [:lemieux, :turn, :start],
          [:lemieux, :turn, :stop],
          [:lemieux, :provider, :request, :start],
          [:lemieux, :provider, :request, :stop],
          [:lemieux, :provider, :first_delta],
          [:lemieux, :provider_limiter, :wait, :start],
          [:lemieux, :provider_limiter, :wait, :stop],
          [:lemieux, :tool, :call, :start],
          [:lemieux, :tool, :call, :stop]
        ] do
      assert event in names
    end

    # Read from the module rather than restated: telemetry handlers are global,
    # so this drains events from every test running beside it, and a list kept
    # here drifted the first time the module gained a key.
    assert Enum.all?(telemetry, fn {_event, _measurements, metadata} ->
             MapSet.subset?(
               MapSet.new(Map.keys(metadata)),
               MapSet.new(Telemetry.metadata_keys())
             )
           end)

    refute inspect(telemetry) =~ "read the file"
    refute inspect(telemetry) =~ "hello.txt"
    refute inspect(telemetry) =~ "hello"
  end

  test "compaction and cancellation have harness-owned events", context do
    provider =
      Scripted.new(
        List.duplicate(Scripted.complete("ok"), 4) ++
          [Scripted.complete("summary"), Scripted.delayed(5_000, Scripted.complete("late"))]
      )

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        tools: []
      )

    for n <- 1..4 do
      assert {:ok, _result} = Testing.prompt(session, "prompt #{n}")
    end

    assert {:ok, _result} = Session.compact(session)
    before_cancel = drain_telemetry([])
    assert :ok = Session.prompt(session, "cancel this")

    assert_receive {:telemetry, [:lemieux, :provider, :request, :start], _, %{kind: :turn}}

    assert :ok = Session.cancel(session)

    telemetry = before_cancel ++ drain_telemetry([])
    names = Enum.map(telemetry, &elem(&1, 0))

    assert [:lemieux, :compaction, :start] in names
    assert [:lemieux, :compaction, :stop] in names
    assert [:lemieux, :session, :cancel] in names
  end

  # `:telemetry` handlers are global and this suite is `async: true`, so every
  # turn every other test runs arrives at this handler too. Matching on a
  # session id nothing else uses is what makes `assert_receive` wait for *this*
  # test's span instead of comparing somebody else's metadata against ours —
  # which is what it did, at whatever rate the scheduler happened to interleave
  # a `[:lemieux, :turn, :start]` from another file.
  test "the telemetry boundary drops arbitrary content and non-scalar metadata" do
    id = "session-#{System.unique_integer([:positive])}"

    started_at =
      Telemetry.start([:turn], %{
        session_id: id,
        prompt: "secret prompt",
        arguments: %{"token" => "secret"},
        model: "test:model"
      })

    Telemetry.stop([:turn], started_at, %{session_id: id, output: "secret output"})

    assert_receive {:telemetry, [:lemieux, :turn, :start], _, %{session_id: ^id} = metadata}
    assert metadata == %{session_id: id, model: "test:model"}

    assert_receive {:telemetry, [:lemieux, :turn, :stop], _, %{session_id: ^id} = metadata}
    assert metadata == %{session_id: id}
  end

  defp drain_telemetry(events) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
