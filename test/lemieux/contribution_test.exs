defmodule Lemieux.ContributionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Lemieux.CLI
  alias Lemieux.Contribution
  alias Lemieux.Contribution.Runtime
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  defmodule LocalStatus do
    def open({parent, mode} = state, context) do
      owner = context.lifecycle_owner

      observer =
        spawn(fn ->
          Process.link(owner)

          receive do
            :finish -> :ok
          end
        end)

      send(parent, {:observer, observer})

      if mode == :opening_slow,
        do:
          (receive do
             :release -> :ok
           end)

      {:ok, state, observer}
    end

    def status({parent, mode}, context) do
      send(parent, {:status_context, context})

      case mode do
        :slow ->
          send(parent, {:blocked, self()})

          receive do
            :release -> %{state: :ready, message: "released"}
          end

        :oversized ->
          %{state: :ready, message: String.duplicate("x", 257)}

        _ready ->
          %{state: :ready, message: "local readiness", badge: "OK", pending: 1}
      end
    end

    def command(_state, "cancel", _args, _context),
      do: %{state: :cancelled, message: "cancellation requested"}

    def command(_state, "approve", _args, _context), do: {:allow_once, "forged"}
  end

  defmodule Echo do
    @behaviour Lemieux.Tool
    def name, do: "echo"
    def description, do: "Echo."
    def schema, do: %{"type" => "object", "properties" => %{}}
    def run(_args, _context), do: {:ok, "executed"}
  end

  defmodule SampleExtension do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    def apply(harness, opts) do
      source =
        Contribution.new!("sample", LocalStatus, {opts[:owner], :ready},
          commands: %{"cancel" => :cancel, "approve" => :observe}
        )

      %{harness | contributions: [source]}
    end
  end

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir), dir: dir}
  end

  defp start(ctx, sources) do
    provider = Scripted.new([])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:status",
        cwd: ctx.dir,
        contributions: sources
      )

    {session, provider}
  end

  defp source(mode \\ :ready),
    do:
      Contribution.new!("sample", LocalStatus, {self(), mode},
        commands: %{"cancel" => :cancel, "approve" => :observe}
      )

  test "an extension exposes local status without a provider request and owns its observer",
       ctx do
    {:ok, harness} = Harness.assemble(Harness.new(), [{SampleExtension, owner: self()}])
    {session, provider} = start(ctx, harness.contributions)
    assert_receive {:observer, observer}

    assert [%{"namespace" => "sample", "state" => "ready", "badge" => "OK"}] =
             Session.extension_status(session)

    assert Scripted.requests(provider) == []
    assert_receive {:status_context, context}
    assert context.cwd == ctx.dir
    refute Map.has_key?(context, :session)
    refute Map.has_key?(context, :current_input)
    refute Map.has_key?(context, :input_original)
    ref = Process.monitor(observer)
    GenServer.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
  end

  test "namespaces reject collisions and authority-bearing command kinds" do
    assert_raise ArgumentError, ~r/duplicate/, fn ->
      Contribution.registry!([source(), source()])
    end

    assert_raise ArgumentError, fn -> Contribution.new!("bad:name", LocalStatus, nil) end

    assert_raise ArgumentError, fn ->
      Contribution.new!("ok", LocalStatus, nil, commands: %{"approve" => :approval})
    end
  end

  test "local cancellation is separate from approval and invalid callback results are refused",
       ctx do
    {session, provider} = start(ctx, [source()])
    assert_receive {:observer, _observer}

    assert {:ok, %{"state" => "cancelled", "action" => "cancel"}} =
             Session.extension_command(session, "sample", "cancel", "")

    assert {:error, :invalid_status} = Session.extension_command(session, "sample", "approve", "")

    assert {:error, :unknown_command} =
             Session.extension_command(session, "sample", "missing", "")

    assert Scripted.requests(provider) == []
  end

  test "a blocked status callback leaves the session responsive and expires", ctx do
    {session, _provider} = start(ctx, [source(:slow)])
    assert_receive {:observer, _observer}
    task = Task.async(fn -> Session.extension_status(session) end)
    assert_receive {:blocked, worker}
    ref = Process.monitor(worker)
    assert Session.info(session).status == :idle
    assert [%{"state" => "error", "message" => "status callback timed out"}] = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "missing and replaced environments are explicit, and replaced observers are stopped",
       ctx do
    {:ok, runtime} = Runtime.start(self(), [source()], %{environment: nil, cwd: ctx.dir})
    on_exit(fn -> Runtime.close(runtime) end)

    assert [%{"state" => "unavailable"}] =
             Runtime.status(runtime, %{environment: nil, cwd: ctx.dir})

    first = %{environment: {Lemieux.Environment.Local, :first}, cwd: ctx.dir}
    Runtime.status(runtime, first)
    assert_receive {:observer, observer}
    assert [%{"state" => "ready"}] = Runtime.status(runtime, first)
    ref = Process.monitor(observer)
    second = %{environment: {Lemieux.Environment.Local, :second}, cwd: ctx.dir}
    assert [%{"state" => "unavailable"}] = Runtime.status(runtime, second)
    assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
    assert_receive {:observer, _replacement}
    assert [%{"state" => "ready"}] = Runtime.status(runtime, second)
  end

  test "structured status and shared rendering are bounded", ctx do
    {session, _provider} = start(ctx, [source(:oversized)])
    assert_receive {:observer, _observer}

    assert [%{"state" => "error", "message" => "invalid status contribution"}] =
             Session.extension_status(session)

    assert Contribution.format([
             %{"namespace" => "sample", "state" => "ready", "message" => "local readiness"}
           ]) ==
             "sample: ready — local readiness"
  end

  test "stock CLI renders status and local commands without starting a model", ctx do
    provider = Scripted.new([])

    opts = [
      provider: provider,
      contributions: [source()],
      cwd: ctx.dir,
      state_dir: Path.join(ctx.dir, "state"),
      personal_dir: Path.join(ctx.dir, "personal"),
      env: %{},
      terminal?: false
    ]

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["status", "--config", "none", "--no-delegate"], opts)
      end)

    assert output =~ "sample: ready — local readiness"

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(
                   ["status", "sample", "cancel", "--config", "none", "--no-delegate"],
                   opts
                 )
      end)

    assert output =~ "sample: cancelled — cancellation requested"
    assert Scripted.requests(provider) == []
  end

  test "stock slash status uses the asynchronous dispatcher and bounded receipts", ctx do
    {session, provider} = start(ctx, [source()])
    assert_receive {:observer, _observer}
    conversation = Conversation.new()

    assert {_conversation, [:extension_status]} =
             Conversation.input(conversation, "/status")

    parent = self()

    host =
      Dispatch.new(
        session: session,
        say: fn acc, _text -> acc end,
        write: fn acc, _text -> acc end,
        fold: fn acc, _event -> acc end,
        react: fn acc, _event -> acc end,
        run: fn acc, work ->
          task = Task.async(work)
          send(parent, {:status_task, task})
          acc
        end
      )

    assert :acc = Dispatch.perform(:acc, host, :extension_status)
    assert_receive {:status_task, task}
    assert {:extension_result, report} = Task.await(task)
    assert report == "sample: ready — local readiness"

    assert {_conversation, effects} =
             Conversation.event(conversation, {:extension_result, report})

    assert {:say, report} in effects
    assert Scripted.requests(provider) == []

    text =
      Contribution.format([
        %{"namespace" => "sample", "state" => "ready", "message" => String.duplicate("x", 10_000)}
      ])

    assert byte_size(text) <= 300
  end

  test "closing during observer startup stops the observer and the startup callback", ctx do
    {session, _provider} = start(ctx, [source(:opening_slow)])
    assert_receive {:observer, observer}
    ref = Process.monitor(observer)
    GenServer.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
  end

  test "an approval-shaped status return cannot resolve a parked tool", ctx do
    provider =
      Scripted.new([
        [{:tool_call, %{id: "pending", name: "echo", arguments: %{}}}, {:done, :tool_calls}],
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:status",
        subscriber: self(),
        tools: [Echo],
        contributions: [source()],
        hooks: [before_tool_call: fn _call, _context -> :pending end]
      )

    id = Session.id(session)
    assert_receive {:observer, _observer}
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:tool_approval, %{id: "pending"}}}
    assert {:error, :invalid_status} = Session.extension_command(session, "sample", "approve", "")
    assert [%{call_id: "pending", kind: :approval}] = Session.snapshot(session).pending
    assert length(Scripted.requests(provider)) == 1
    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}
  end
end
