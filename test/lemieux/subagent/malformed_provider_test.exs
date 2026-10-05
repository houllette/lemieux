defmodule Lemieux.Subagent.MalformedProviderTest do
  # A host's `:providers` map or `:provider_factory` decides each child's
  # provider. One that is not a `{module, state}` pair fails that child with
  # `{:start_failed, _}`, as any start failure does. When
  # `Lemieux.start_session/1` began raising in its caller for it, the caller
  # was the group's coordinator, and the whole group went down with the one
  # child — siblings, results and all.
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task
  alias Lemieux.Tools

  @moduletag :tmp_dir

  # What a host might hand over by mistake: the key instead of a provider
  # built from it. It must not reach the envelope the parent model reads.
  @secret "sk-live-not-a-provider"

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([Scripted.complete("parent")], estimated_cost_usd: 0.01),
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    %{parent: parent}
  end

  defp request(id) do
    definition =
      Definition.new(
        id: id,
        description: "Investigates #{id}",
        system_prompt: "Return concise sourced findings.",
        model: "test:child",
        tools: [Tools.Read],
        timeout: 5_000,
        max_cost_usd: 0.1
      )

    Request.new(definition, Task.new(objective: "investigate #{id}", snapshot: %{"git" => "a"}))
  end

  defp answers do
    body =
      JSON.encode!(%{
        "answer" => "the answer",
        "findings" => [],
        "artifacts" => [],
        "uncertainties" => [],
        "coverage" => %{"searched" => ["lib"], "skipped" => []}
      })

    Scripted.new([Scripted.complete(body, usage: %{"input_tokens" => 7, "cost_usd" => 0.02})],
      estimated_cost_usd: 0.01
    )
  end

  defp settle(ctx, opts) do
    requests = [request("broken"), request("sound")]
    opts = Keyword.merge([max_cost_usd: 1.0, timeout: 5_000], opts)

    assert {:ok, group} = Subagent.spawn_many(ctx.parent, requests, opts)
    assert {:ok, result} = Subagent.await(group, 10_000)
    result.results
  end

  defp failed_to_start?(child) do
    child.status == :failed and
      Enum.any?(child.uncertainties, &(&1 =~ "start_failed" and &1 =~ ":provider"))
  end

  test "a malformed provider in the map fails only its own child", ctx do
    [broken, sound] = settle(ctx, providers: %{"broken" => @secret, "sound" => answers()})

    assert failed_to_start?(broken)
    refute inspect(broken) =~ @secret
    assert sound.status == :ok
    assert sound.answer == "the answer"
  end

  test "so does one a provider factory returns, of either arity", ctx do
    one = fn
      %Request{definition: %{id: "broken"}} -> nil
      _request -> answers()
    end

    two = fn
      %Definition{id: "broken"}, _task -> Scripted
      _definition, _task -> answers()
    end

    for factory <- [one, two] do
      [broken, sound] = settle(ctx, provider_factory: factory)

      assert failed_to_start?(broken)
      assert sound.status == :ok
    end
  end
end
