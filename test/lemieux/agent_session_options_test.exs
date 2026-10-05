defmodule Lemieux.AgentSessionOptionsTest do
  # `Lemieux.Agent.Session` answers every run with a result
  # (`t:Lemieux.Agent.result/0`). `Lemieux.start_session/1` began raising in
  # its caller for a provider or store that is not a `{module, state}` pair,
  # or no model — so the same mistakes, made through this module, raised
  # where a missing provider had always been `{:error, {:provider, :required}}`.
  # They are results again, naming the option and never its value.
  use ExUnit.Case, async: true

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
end
