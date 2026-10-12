defmodule Lemieux.JobBudgetTest do
  use ExUnit.Case, async: true

  alias Lemieux.JobBudget

  test "admission is durably recorded before returning and restored reservations stay held" do
    parent = self()

    persist = fn snapshot ->
      send(parent, {:saved, snapshot})
      :ok
    end

    budget = start_supervised!({JobBudget, max_requests: 2, max_cost_usd: 1, persist: persist})
    assert {:ok, _lease} = JobBudget.reserve(budget, 0.4, 1)
    assert_receive {:saved, %{requests: 1, reserved_usd: 0.4, active: 1} = recorded}
    GenServer.stop(budget)

    {:ok, restored} = JobBudget.start_link(max_requests: 2, max_cost_usd: 1, recorded: recorded)
    assert %{requests: 1, reserved_usd: 0.4, spent_usd: nil} = JobBudget.snapshot(restored)
    assert {:error, %{kind: :cost}} = JobBudget.reserve(restored, 0.1, 1)
    GenServer.stop(restored)
  end

  test "concurrent reservations cannot spend the same remaining allowance" do
    budget = start_supervised!({JobBudget, max_cost_usd: 1, max_requests: 2})
    tasks = for _ <- 1..3, do: Task.async(fn -> JobBudget.reserve(budget, 0.6, 1) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 2
    assert %{requests: 1} = JobBudget.snapshot(budget)
  end

  test "reconciliation releases unused money but retains consumed requests" do
    budget = start_supervised!({JobBudget, max_cost_usd: 1, max_requests: 2})
    assert {:ok, lease} = JobBudget.reserve(budget, 0.8, 1)
    assert :ok = JobBudget.settle(budget, lease, 0.2)
    assert {:ok, second} = JobBudget.reserve(budget, 0.8, 1)
    assert :ok = JobBudget.settle(budget, second, 0.3)
    assert %{spent_usd: 0.5, reserved_usd: reserved, requests: 2} = JobBudget.snapshot(budget)
    assert reserved == 0
    assert {:error, %{kind: :requests}} = JobBudget.reserve(budget, 0, 1)
  end

  test "unknown estimates and missing usage never become free" do
    budget = start_supervised!({JobBudget, max_cost_usd: 1})
    assert {:error, %{kind: :cost}} = JobBudget.reserve(budget, nil, 1)
    assert {:ok, lease} = JobBudget.reserve(budget, 0.4, 1)
    assert :ok = JobBudget.settle(budget, lease, nil)
    assert %{spent_usd: nil, unmeasured: 1} = JobBudget.snapshot(budget)
    assert {:error, %{kind: :cost}} = JobBudget.reserve(budget, 0, 1)
  end

  test "known history is charged when the host reconstructs a job" do
    budget =
      start_supervised!(
        {JobBudget, max_requests: 3, max_cost_usd: 1, requests: 2, spent_usd: 0.8}
      )

    assert {:error, %{kind: :cost}} = JobBudget.reserve(budget, 0.3, 1)
    assert {:ok, lease} = JobBudget.reserve(budget, 0.1, 1)
    JobBudget.settle(budget, lease, 0.1)
    assert {:error, %{kind: :requests}} = JobBudget.reserve(budget, 0, 1)
  end

  test "lost owners settle outstanding reservations as unmeasured" do
    budget = start_supervised!({JobBudget, max_cost_usd: 1})
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _lease} = JobBudget.reserve(budget, 0.5, 1)
        send(parent, :reserved)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :reserved
    monitor = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    # The ledger's barrier follows its monitor message, rather than a sleep.
    assert %{spent_usd: nil, reserved_usd: reserved} = JobBudget.snapshot(budget)
    assert reserved == 0
  end
end
