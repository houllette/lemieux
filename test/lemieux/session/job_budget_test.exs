defmodule Lemieux.Session.JobBudgetTest do
  use ExUnit.Case, async: true

  alias Lemieux.JobBudget
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task

  @moduletag :tmp_dir

  defmodule Paid do
    @behaviour Lemieux.Tool
    alias Lemieux.Tool.Result
    def name, do: "paid"
    def description, do: "A paid fixture."
    def schema, do: %{"type" => "object"}
    def metadata, do: %{"effects" => %{"external_cost" => %{"maximum_usd" => 0.4}}}

    def run(_args, context) do
      File.write!(Path.join(context.cwd, "paid-ran"), "ran")
      {:ok, Result.new("paid result", cost: %{"usd" => 0.2})}
    end
  end

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir), cwd: dir}
  end

  defp start(ctx, provider, opts) do
    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: ctx.runtime,
            store: ctx.store,
            cwd: ctx.cwd,
            provider: provider,
            model: "test:job",
            tools: []
          ],
          opts
        )
      )

    session
  end

  defp answer(text, cost),
    do:
      Scripted.complete(text,
        usage: %{"cost_usd" => cost, "input_tokens" => 10, "output_tokens" => 2}
      )

  test "children and parent consume the same request allowance", ctx do
    parent_provider = Scripted.new([answer("parent", 0.01)], estimated_cost_usd: 0.01)
    parent = start(ctx, parent_provider, job_limits: [max_requests: 1, max_cost_usd: 1])

    definition =
      Definition.new(
        id: "scout",
        description: "inspect",
        system_prompt: "inspect",
        model: "test:child",
        tools: [],
        max_cost_usd: 0.1
      )

    body =
      JSON.encode!(%{
        "answer" => "found",
        "findings" => [],
        "artifacts" => [],
        "uncertainties" => [],
        "coverage" => %{"searched" => [], "skipped" => []}
      })

    child_provider = Scripted.new([answer(body, 0.01)], estimated_cost_usd: 0.01)

    request =
      Request.new(definition, Task.new(objective: "inspect", snapshot: %{"revision" => "abc"}))

    assert {:ok, group} =
             Subagent.spawn_many(parent, [request],
               max_cost_usd: 1,
               providers: %{"scout" => child_provider}
             )

    assert {:ok, _result} = Subagent.await(group)

    assert {:ok, %{stop_reason: {:budget, %{kind: :requests}}}} =
             Lemieux.Testing.prompt(parent, "work")

    assert Scripted.requests(parent_provider) == []
    assert length(Scripted.requests(child_provider)) == 1
    assert %{job: %{requests: 1, spent_usd: 0.01}} = Session.budget(parent)
  end

  test "resume retains inclusive accounting with current host limits", ctx do
    provider =
      Scripted.new([answer("first", 0.2), answer("second", 0.2)], estimated_cost_usd: 0.2)

    parent = start(ctx, provider, job_limits: [max_requests: 1, max_cost_usd: 1])
    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(parent, "one")
    id = Session.id(parent)
    GenServer.stop(parent)

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: ctx.store,
               provider: provider,
               resume: id,
               cwd: ctx.cwd,
               job_limits: [max_requests: 1, max_cost_usd: 1]
             )

    assert %{job: %{requests: 1, spent_usd: 0.2}} = Session.budget(resumed)

    assert {:ok, %{stop_reason: {:budget, %{kind: :requests}}}} =
             Lemieux.Testing.prompt(resumed, "two")

    assert length(Scripted.requests(provider)) == 1
  end

  test "auxiliary requests reserve and settle against the same ledger", ctx do
    provider = Scripted.new([answer("judge", 0.3)], estimated_cost_usd: 0.3)
    budget = start_supervised!({JobBudget, max_cost_usd: 0.5, max_requests: 1})
    request = %Lemieux.Request{model: "test:job", entries: [], tools: [], system: nil, params: []}
    assert :ok = JobBudget.run(budget, provider, request, fn _event -> :ok end)
    assert %{requests: 1, spent_usd: 0.3} = JobBudget.snapshot(budget)
    parent = start(ctx, provider, job_budget: budget)

    assert {:ok, %{stop_reason: {:budget, %{kind: :requests}}}} =
             Lemieux.Testing.prompt(parent, "work")
  end

  test "paid tools reserve declared maxima and settle their actual cost", ctx do
    for {cap, ran?} <- [{0.5, true}, {0.3, false}] do
      File.rm(Path.join(ctx.cwd, "paid-ran"))

      provider =
        Scripted.new(
          [
            [
              {:usage, %{"cost_usd" => 0.1}},
              {:tool_call, %{id: "paid", name: "paid", arguments: %{}}},
              {:done, :tool_calls}
            ],
            answer("done", 0.1)
          ],
          estimated_cost_usd: 0.1
        )

      parent = start(ctx, provider, tools: [Paid], job_limits: [max_cost_usd: cap])
      assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(parent, "work")
      assert File.exists?(Path.join(ctx.cwd, "paid-ran")) == ran?
      expected = if ran?, do: 0.4, else: 0.2
      assert %{job: %{spent_usd: ^expected}} = Session.budget(parent)
    end
  end
end
