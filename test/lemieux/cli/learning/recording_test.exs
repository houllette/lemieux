defmodule Lemieux.CLI.Learning.RecordingTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Recording
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request

  test "physical dispatches and incomplete usage are retained separately from reservations" do
    meter = start_supervised!({Agent, fn -> %{} end})

    provider =
      Recording.new(
        meter,
        Scripted.new([
          Scripted.complete("ok", usage: %{"input_tokens" => 4, "output_tokens" => 3}),
          Scripted.error(:unavailable)
        ]),
        role: :reflection
      )

    request = %Request{model: "test:model", entries: [], tools: []}
    assert :ok = Provider.run(provider, request, fn _ -> :ok end)
    owner = self()
    assert :ok = Provider.run(provider, request, &send(owner, &1))
    assert_receive {:error, :unavailable}
    records = Agent.get(meter, &Map.values/1)
    assert length(records) == 2
    assert Enum.all?(records, &(&1["model"] == "test:model" and &1["role"] == "reflection"))
    assert Enum.any?(records, &(&1["tokens"] == 7 and &1["terminal"]))
    assert Enum.any?(records, &(is_nil(&1["tokens"]) and &1["terminal"]))
    assert Provider.reasoning_efforts(provider, "test:model") == []
  end

  test "subscription quota ignores informational dollar estimates while keeping actual usage and outer dollar ceilings" do
    meter = start_supervised!({Agent, fn -> %{} end})
    usage = %{"input_tokens" => 4, "output_tokens" => 3, "cost_usd" => 2.0}

    raw =
      Scripted.new(List.duplicate(Scripted.complete("ok", usage: usage), 3),
        estimated_cost_usd: 0.01
      )

    provider = Recording.new(meter, raw, cost_mode: :quota)
    request = %Request{model: "test:model", entries: [], tools: []}
    assert Provider.estimate_cost(raw, request) == 0.01
    assert Provider.estimate_cost(provider, request) == nil
    budget = start_supervised!({JobBudget, [max_requests: 4]})

    opts = [
      job_id: "quota",
      job_budget: budget,
      max_tokens: 100,
      max_time_ms: 60_000,
      cost_mode: :quota,
      learning: [max_requests: 4, max_tokens: 100, max_time_ms: 60_000, max_cost_usd: nil]
    ]

    controller = start_supervised!({Controller, opts})
    controlled = Controller.provider(controller, :task, provider, token_bound: fn _ -> 20 end)
    assert :ok = Provider.run(controlled, request, fn _ -> :ok end)
    assert :ok = Provider.run(controlled, request, fn _ -> :ok end)
    assert Controller.snapshot(controller)["stop"] == nil
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 14
    assert JobBudget.snapshot(budget).spent_usd == 4.0
    assert Enum.all?(Agent.get(meter, &Map.values/1), &(&1["usage"]["cost_usd"] == 2.0))

    capped =
      start_supervised!(
        Supervisor.child_spec({JobBudget, [max_requests: 1, max_cost_usd: 0.5]},
          id: :capped_quota
        )
      )

    capped_opts =
      opts
      |> Keyword.put(:job_budget, capped)
      |> Keyword.put(:learning,
        max_requests: 1,
        max_tokens: 100,
        max_time_ms: 60_000,
        max_cost_usd: 0.5
      )

    capped_controller =
      start_supervised!(Supervisor.child_spec({Controller, capped_opts}, id: :capped_controller))

    bounded = Controller.provider(capped_controller, :task, provider, token_bound: fn _ -> 20 end)
    assert {:error, _} = Provider.run(bounded, request, fn _ -> :ok end)
    assert map_size(Agent.get(meter, & &1)) == 2
  end
end
