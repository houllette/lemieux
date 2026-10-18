defmodule Lemieux.AgentSessionOptionsTest do
  # `Lemieux.Agent.Session` answers every run with a result
  # (`t:Lemieux.Agent.result/0`). `Lemieux.start_session/1` began raising in
  # its caller for a provider or store that is not a `{module, state}` pair,
  # or no model — so the same mistakes, made through this module, raised
  # where a missing provider had always been `{:error, {:provider, :required}}`.
  # They are results again, naming the option and never its value.
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # A host passing the key instead of a provider built from it.
  @secret "sk-live-not-a-provider"

  setup %{tmp_dir: tmp_dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)

    %{
      runtime: runtime,
      store: JSONL.new(Path.join(tmp_dir, "sessions")),
      task: %{prompt: "Say hello.", cwd: cwd, timeout_ms: 10_000}
    }
  end

  defp run(ctx, opts) do
    defaults = [supervisor: ctx.runtime, store: ctx.store, model: "test:model"]
    Lemieux.Agent.run(Lemieux.Agent.Session, ctx.task, Keyword.merge(defaults, opts))
  end

  defp provider, do: Scripted.new([Scripted.complete("hello")])

  defmodule HeldStore do
    def lock(owner, _id) do
      send(owner, {:initializing, self()})

      receive do
        :never -> {:ok, :lock}
      after
        60_000 -> {:error, :late}
      end
    end
  end

  test "caller death interrupts session initialization inside a blocked host store", ctx do
    owner = self()
    worker = spawn(fn -> run(ctx, provider: provider(), store: {HeldStore, owner}) end)
    assert_receive {:initializing, session}
    monitor = Process.monitor(session)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}
    assert Lemieux.sessions(ctx.runtime) == []
  end

  test "acquisition timeout interrupts initialization even while the caller remains alive", ctx do
    owner = self()

    worker =
      Task.async(fn ->
        run(ctx, provider: provider(), store: {HeldStore, owner}, acquisition_timeout_ms: 5000)
      end)

    assert_receive {:initializing, session}
    monitor = Process.monitor(session)
    assert Task.await(worker, 10_000) == {:error, :resource_start_timeout}
    assert_receive {:DOWN, ^monitor, :process, ^session, _reason}
    assert Lemieux.sessions(ctx.runtime) == []
  end

  test "a provider that is not a {module, state} pair is an error naming it", ctx do
    for malformed <- [@secret, Scripted, {"Scripted", nil}] do
      assert run(ctx, provider: malformed) == {:error, {:provider, :invalid}}
    end
  end

  test "so is a malformed store, and one :session_options puts in place", ctx do
    assert run(ctx, provider: provider(), store: "sessions") == {:error, {:store, :invalid}}

    assert run(ctx, provider: provider(), session_options: [provider: @secret]) ==
             {:error, {:provider, :invalid}}
  end

  test "a model given as nil is a missing one", ctx do
    assert run(ctx, provider: provider(), model: nil) == {:error, {:model, :required}}
  end

  test "so is a store given as nil, rather than the default it would replace", ctx do
    assert run(ctx, provider: provider(), store: nil) == {:error, {:store, :required}}

    assert run(ctx, provider: provider(), session_options: [store: nil]) ==
             {:error, {:store, :required}}
  end

  test "a well-formed run still answers", ctx do
    assert {:ok, %{"status" => "completed", "answer" => "hello"}} =
             run(ctx, provider: provider())
  end

  test "inherits shipped retries and reports recovered provider faults", ctx do
    provider =
      Scripted.new([
        Scripted.http_error(503, headers: %{"retry-after" => "0"}),
        Scripted.complete("recovered")
      ])

    assert {:ok, observation} = run(ctx, provider: provider)
    assert observation["status"] == "completed"
    assert observation["answer"] == "recovered"
    assert length(Scripted.requests(provider)) == 2
    assert observation["provider_error"] == nil

    assert observation["provider_retries"] == %{
             "count" => 1,
             "delay_ms" => 0,
             "after_output" => 0,
             "delegated_count" => 0,
             "categories" => %{"server" => 1}
           }

    # The unanswered failed request still makes spend incomplete.
    assert observation["usage"]["cost_usd"] == nil

    assert policy(observation) == %{
             "enabled" => true,
             "max_attempts" => 6,
             "base_delay_ms" => 2_000,
             "max_delay_ms" => 60_000,
             "after_output" => true,
             "classifier" => "default"
           }
  end

  test "an explicit retry opt-out is recorded even when host context claims otherwise", ctx do
    provider = Scripted.new([Scripted.http_error(503), Scripted.complete("never sent")])

    assert {:error, :agent_failed, observation} =
             run(ctx,
               provider: provider,
               session_options: [
                 provider_retry: false,
                 harness_context: %{"workflow" => %{"provider_retry" => %{"enabled" => true}}}
               ]
             )

    assert observation["status"] == "failed"
    assert length(Scripted.requests(provider)) == 1
    assert observation["provider_retries"]["count"] == 0
    assert policy(observation) == %{"enabled" => false}
  end

  test "retains host retry tuning and reports it without serializing the classifier", ctx do
    provider = Scripted.new([Scripted.http_error(503), Scripted.complete("recovered")])

    assert {:ok, observation} =
             run(ctx,
               provider: provider,
               session_options: [
                 provider_retry: [
                   base_delay_ms: 1,
                   max_attempts: 2,
                   classify: fn _ -> :default end
                 ]
               ]
             )

    assert observation["status"] == "completed"
    assert observation["provider_retries"]["delay_ms"] == 1
    assert policy(observation)["base_delay_ms"] == 1
    assert policy(observation)["max_attempts"] == 2
    assert policy(observation)["classifier"] == "host"
  end

  test "a deadline during backoff retains the observed retry without sending another request",
       ctx do
    clock = start_supervised!(Manual)
    provider = Scripted.new([Scripted.http_error(503), Scripted.complete("never sent")])

    task =
      Task.async(fn ->
        run(ctx,
          provider: provider,
          clock: clock,
          session_options: [clock: clock, provider_retry: [base_delay_ms: 60_000]]
        )
      end)

    Manual.await_timer(clock, &match?({:provider_retry, _}, &1.message))
    Manual.advance(clock, ctx.task.timeout_ms)
    assert {:error, :timeout, observation} = Task.await(task, :infinity)
    assert observation["provider_retries"]["count"] == 1
    assert observation["provider_retries"]["delay_ms"] == 60_000
    assert length(Scripted.requests(provider)) == 1
    assert Manual.pending(clock) == []
  end

  defp policy(observation) do
    snapshot = Enum.find(observation["transcript"], &(&1["type"] == "harness_snapshot"))
    snapshot["payload"]["workflow"]["provider_retry"]
  end
end
