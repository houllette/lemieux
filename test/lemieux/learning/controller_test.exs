defmodule Lemieux.Learning.ControllerTest do
  use ExUnit.Case, async: true
  alias Lemieux.Contract
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request

  defmodule TerminalBeforeReturn do
    @behaviour Lemieux.Provider
    @impl true
    def estimate_cost(_owner, _request), do: 0.001
    @impl true
    def run({owner, terminal, result}, _request, emit) do
      emit.({:text_delta, "done"})
      emit.({:usage, %{"input_tokens" => 2, "output_tokens" => 3, "cost_usd" => 0.001}})
      emit.(terminal)
      send(owner, {:provider_return_held, self()})

      receive do
        :release -> result
      after
        60_000 -> {:error, :fixture_expired}
      end
    end
  end

  test "nested providers settle every allowance before exposing terminal completion" do
    assert_terminal_settled({:done, :stop}, :ok)
  end

  test "nested providers settle usage before forwarding the original typed error" do
    reason = %{provider_code: "upstream_error", message: "original provider failure"}
    assert_terminal_settled({:error, reason}, {:error, reason})
  end

  defp assert_terminal_settled(terminal, result) do
    inner = controller(budget())
    outer = controller(budget())
    owner = self()

    provider =
      Controller.provider(inner, :reflection, {TerminalBeforeReturn, {owner, terminal, result}},
        token_bound: fn _ -> 8 end
      )

    provider = Controller.provider(outer, :reflection, provider, token_bound: fn _ -> 8 end)

    task =
      Task.async(fn ->
        Provider.run(provider, Request.new("test:model"), fn
          ^terminal ->
            send(
              owner,
              {:settled_terminal, Controller.snapshot(inner)["accounting"]["tokens"],
               Controller.snapshot(outer)["accounting"]["tokens"]}
            )

          event ->
            send(owner, {:streamed, event})
        end)
      end)

    assert_receive {:provider_return_held, worker}

    try do
      assert_receive {:streamed, {:text_delta, "done"}}
      assert_receive {:streamed, {:usage, _}}
      refute_receive {:settled_terminal, _, _}, 100
      send(worker, :release)
      assert ^result = Task.await(task)
      assert_receive {:settled_terminal, 5, 5}
    after
      send(worker, :release)
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp budget(opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {JobBudget, Keyword.merge([max_requests: 5, max_cost_usd: 1.0], opts)},
        id: make_ref()
      )
    )
  end

  defp controller(budget, opts \\ []) do
    defaults = [
      job_id: "job",
      job_budget: budget,
      max_tokens: 100,
      max_time_ms: 60_000,
      learning: [max_requests: 3, max_tokens: 40, max_time_ms: 10_000, max_cost_usd: 0.4]
    ]

    start_supervised!(
      Supervisor.child_spec({Controller, Keyword.merge(defaults, opts)}, id: make_ref())
    )
  end

  defp estimate(tokens \\ 10), do: %{tokens: tokens, time_ms: 1000, cost_usd: 0.1}
  defp usage(tokens \\ 8), do: %{tokens: tokens, time_ms: 10, cost_usd: 0.08}

  test "parent and concurrent children cannot reserve the same token or request remainder" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, _permit} = Controller.reserve(controller, "parent", :task, estimate(70))
    parent = self()

    tasks =
      for n <- 1..10 do
        Task.async(fn ->
          id = "child-#{n}"
          result = Controller.reserve(controller, id, :critic, estimate())
          send(parent, {:reserved, id, result})

          receive do
            :release ->
              if match?({:ok, _}, result), do: Controller.reconcile(controller, id, usage())
          end
        end)
      end

    results =
      for _ <- 1..10 do
        assert_receive {:reserved, id, result}
        {id, result}
      end

    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 3
    assert JobBudget.snapshot(budget).requests == 4
    assert JobBudget.snapshot(budget).reserved_usd <= 1.0
    Enum.each(tasks, &send(&1.pid, :release))
    Enum.each(tasks, &Task.await/1)
    assert :ok = Controller.reconcile(controller, "parent", usage(65))
    snapshot = Controller.snapshot(controller)
    assert snapshot["accounting"]["tokens"] == 89
    assert snapshot["accounting"]["learning_requests"] == 3

    assert {:skip, %{"reason" => "learning_allowance_exhausted"}} =
             Controller.reserve(controller, "extra", :reflection, estimate())
  end

  test "settlement and replayed settlement charge one request exactly once" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, _} = Controller.reserve(controller, "attempt", :proposer, estimate())
    assert :ok = Controller.reconcile(controller, "attempt", usage())
    assert :ok = Controller.reconcile(controller, "attempt", usage())

    assert {:skip, %{"reason" => "duplicate_attempt"}} =
             Controller.reserve(controller, "attempt", :proposer, estimate())

    assert JobBudget.snapshot(budget).requests == 1
    assert JobBudget.snapshot(budget).spent_usd == 0.08
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 8
  end

  test "a cancelled owner keeps consumed requests and unknown usage" do
    budget = budget()
    controller = controller(budget)
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:lease, Controller.reserve(controller, "cancelled", :probe, estimate())})

        receive do
          :finish -> :ok
        after
          60_000 -> :ok
        end
      end)

    assert_receive {:lease, {:ok, _}}
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    snapshot = Controller.snapshot(controller)
    assert snapshot["accounting"]["tokens"] == nil
    assert JobBudget.snapshot(budget).requests == 1
    assert JobBudget.snapshot(budget).spent_usd == nil

    assert {:skip, %{"decision" => "stop"}} =
             Controller.reserve(controller, "after-cancel", :critic, estimate())
  end

  test "restart reconciliation never refunds or repeats an interrupted attempt" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, _} = Controller.reserve(controller, "interrupted", :composition, estimate())
    recorded = Controller.snapshot(controller)
    GenServer.stop(controller)
    restored = controller(budget, recorded: recorded)
    assert :ok = Controller.reconcile(restored, "interrupted", usage())
    assert {:skip, _} = Controller.reserve(restored, "interrupted", :composition, estimate())

    assert {:skip, %{"decision" => "stop"}} =
             Controller.reserve(restored, "next", :confirmation, estimate())

    assert JobBudget.snapshot(budget).requests == 1
    assert Controller.snapshot(restored)["accounting"]["tokens"] == nil
  end

  test "healthy, unsupported and repeated signals abstain without provider work" do
    controller = controller(budget())

    for kind <- ["healthy", "correction"] do
      assert {:noop, receipt} =
               Controller.consider(controller, %{
                 "id" => kind,
                 "kind" => kind,
                 "hypothesis_supported" => false
               })

      assert receipt["reason"] in ["healthy_task", "no_supported_improvement"]
    end

    signal = %{
      "id" => "failure",
      "kind" => "verification_failure",
      "hypothesis_supported" => true
    }

    assert {:ready, _} = Controller.consider(controller, signal)
    assert {:noop, %{"reason" => "duplicate_signal"}} = Controller.consider(controller, signal)
    assert Controller.snapshot(controller)["job_budget"]["requests"] == 0
  end

  test "zero learning allowance keeps the task eligible but starts no learning work" do
    controller =
      controller(budget(),
        learning: [max_requests: 0, max_tokens: 0, max_time_ms: 0, max_cost_usd: 0]
      )

    assert {:skip, _} = Controller.reserve(controller, "learning", :reflection, estimate())
    assert {:ok, _} = Controller.reserve(controller, "task", :task, estimate())
    assert :ok = Controller.reconcile(controller, "task", usage())
  end

  test "metered unknown prices refuse admission and quota keeps unknown dollars unknown" do
    for mode <- [:metered, :quota] do
      budget = budget(max_cost_usd: nil)

      controller =
        controller(budget,
          cost_mode: mode,
          learning: [max_requests: 2, max_tokens: 40, max_time_ms: 10_000, max_cost_usd: nil]
        )

      unknown = %{estimate() | cost_usd: nil}

      if mode == :metered do
        assert {:skip, %{"reason" => "price_unknown"}} =
                 Controller.reserve(controller, "unknown", :critic, unknown)

        assert JobBudget.snapshot(budget).requests == 0
      else
        assert {:ok, _} = Controller.reserve(controller, "unknown", :critic, unknown)
        assert :ok = Controller.reconcile(controller, "unknown", %{usage() | cost_usd: nil})
        assert Controller.snapshot(controller)["job_budget"]["spent_usd"] == nil
        assert {:ok, _} = Controller.reserve(controller, "another", :critic, unknown)
        assert :ok = Controller.reconcile(controller, "another", %{usage() | cost_usd: nil})
      end
    end
  end

  test "diminishing information stops learning while preserving the baseline" do
    controller = controller(budget())

    for id <- ["first", "second"] do
      assert {:ok, _} = Controller.reserve(controller, id, :reflection, estimate())
      assert :ok = Controller.reconcile(controller, id, usage(), information: nil)
    end

    assert {:skip, %{"reason" => "diminishing_information"}} =
             Controller.reserve(controller, "third", :reflection, estimate())

    baseline = %{id: "baseline", value: "original answer", score: 0.8, uncertainty: 0.1}

    for candidate <- [
          %{id: "weaker", value: "new", score: 0.7, uncertainty: 0.0, supported: true},
          %{id: "tie", value: "same score", score: 0.8, uncertainty: 0.0, supported: true}
        ] do
      assert {:ok, ^baseline, %{"reason" => "baseline_retained"}} =
               Controller.select(controller, baseline, [candidate])
    end
  end

  test "a bounded multi-stage experiment is not killed by the source-reader heap ceiling" do
    controller =
      controller(budget(),
        max_time_ms: 120_000,
        learning: [max_requests: 3, max_tokens: 40, max_time_ms: 60_000, max_cost_usd: 0.4]
      )

    plan = %{
      "sha256" => String.duplicate("a", 64),
      "budget" => %{
        "maximum_tokens" => 30,
        "maximum_time_ms" => 60_000,
        "maximum_cost_usd" => 0.3
      }
    }

    required = %{tokens: 30, time_ms: 60_000, cost_usd: 0.3, requests: 2}

    assert {:ok, {1_100_000, 1_100_000, {1, 1, 1}}, %{"status" => "completed"}} =
             Controller.experiment(controller, "bounded-host-records", plan, required, fn _ ->
               source = Enum.to_list(1..1_100_000)
               mapped = Enum.map(source, &{&1, &1, &1})
               {length(source), length(mapped), hd(mapped)}
             end)

    assert Controller.snapshot(controller)["accounting"]["tokens"] == 0
  end

  test "a whole frozen experiment reserves its shared outer allocation before child work" do
    budget = budget()
    controller = controller(budget)

    plan = %{
      "sha256" => String.duplicate("a", 64),
      "budget" => %{"maximum_tokens" => 30, "maximum_time_ms" => 3000, "maximum_cost_usd" => 0.3}
    }

    required = %{tokens: 30, time_ms: 3000, cost_usd: 0.3, requests: 3}

    inner =
      Scripted.new(
        for(
          _ <- 1..3,
          do:
            Scripted.complete("done",
              usage: %{"input_tokens" => 2, "output_tokens" => 2, "cost_usd" => 0.02}
            )
        ),
        estimated_cost_usd: 0.1
      )

    assert {:ok, :completed, receipt} =
             Controller.experiment(controller, "frozen", plan, required, fn child ->
               assert JobBudget.snapshot(budget).requests == 3
               assert JobBudget.snapshot(budget).reserved_usd == 0.3
               assert Controller.snapshot(child)["limits"]["max_tokens"] == 30

               provider =
                 Controller.provider(child, :probe, inner,
                   token_bound: fn _ -> 10 end,
                   timeout_ms: 500
                 )

               for _ <- 1..3,
                   do:
                     assert(
                       :ok = Provider.run(provider, Request.new("test:model"), fn _ -> :ok end)
                     )

               :completed
             end)

    assert receipt["status"] == "completed"
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 12
    assert length(Scripted.requests(inner)) == 3
    assert JobBudget.snapshot(budget).requests == 3
    assert JobBudget.snapshot(budget).spent_usd == 0.06
  end

  test "unaffordable preregistered work is refused whole without changing its allocation" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, _} = Controller.reserve(controller, "parent", :task, estimate(80))
    assert :ok = Controller.reconcile(controller, "parent", usage(80))

    plan = %{
      "sha256" => String.duplicate("a", 64),
      "budget" => %{"maximum_tokens" => 30, "maximum_time_ms" => 3000, "maximum_cost_usd" => 0.3}
    }

    for {tokens, reason} <- [
          {20, "incomplete_experiment_allocation"},
          {30, "token_allowance_exhausted"}
        ] do
      assert {:skip, %{"reason" => ^reason}} =
               Controller.experiment(
                 controller,
                 "frozen-#{tokens}",
                 plan,
                 %{requests: 3, tokens: tokens, time_ms: 3000, cost_usd: 0.3},
                 fn _ -> flunk("cannot shrink a frozen experiment") end
               )
    end

    assert JobBudget.snapshot(budget).requests == 1
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 80
  end

  test "unknown provider usage stays a stop reason when admitting a whole experiment" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, _} = Controller.reserve(controller, "failed-provider", :task, estimate())
    assert :ok = Controller.reconcile(controller, "failed-provider", nil)

    plan = %{
      "sha256" => String.duplicate("a", 64),
      "budget" => %{"maximum_tokens" => 30, "maximum_time_ms" => 3000, "maximum_cost_usd" => 0.3}
    }

    assert {:skip, %{"decision" => "stop", "reason" => "usage_unknown"} = receipt} =
             Controller.experiment(
               controller,
               "frozen",
               plan,
               %{requests: 3, tokens: 30, time_ms: 3000, cost_usd: 0.3},
               fn _ -> flunk("unknown usage must not dispatch or resolve a child") end
             )

    snapshot = Controller.snapshot(controller)
    assert snapshot["records"][receipt["id"]] == receipt
    assert snapshot["accounting"]["tokens"] == nil
    assert JobBudget.snapshot(budget).requests == 1
    assert JobBudget.snapshot(budget).active == 0
  end

  test "untracked parent usage is not reported as an unaffordable experiment" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, lease} = JobBudget.reserve(budget, 0.1, 1)
    assert :ok = JobBudget.settle(budget, lease, 0.1)

    assert {:skip, %{"decision" => "stop", "reason" => "untracked_parent_usage"}} =
             Controller.admit(
               controller,
               %{"sha256" => String.duplicate("a", 64), "budget" => %{}},
               %{requests: 3, tokens: 30, time_ms: 3000, cost_usd: 0.3}
             )

    assert JobBudget.snapshot(budget).requests == 1
  end

  test "whole-experiment deadlines and outer request limits keep distinct causes" do
    plan = %{"sha256" => String.duplicate("a", 64), "budget" => %{}}
    required = %{requests: 3, tokens: 30, time_ms: 3000, cost_usd: 0.3}
    timed_budget = budget()

    opts = [
      max_time_ms: 300_000,
      learning: [max_requests: 3, max_tokens: 40, max_time_ms: 120_000, max_cost_usd: 0.4]
    ]

    original = controller(timed_budget, opts)

    recorded =
      original
      |> Controller.snapshot()
      |> Map.put("deadline_ms", System.system_time(:millisecond) + 60_000)
      |> Map.delete("sha256")
      |> then(&Map.put(&1, "sha256", Contract.digest(&1)))

    GenServer.stop(original)
    timed = controller(timed_budget, Keyword.put(opts, :recorded, recorded))

    assert {:skip, %{"reason" => "experiment_deadline_exceeded"}} =
             Controller.admit(timed, plan, %{required | time_ms: 120_000})

    small_budget = budget()
    limited = controller(small_budget)

    assert {:ok, _} =
             Controller.reserve(limited, "parent", :task, Map.put(estimate(), :requests, 3))

    assert :ok = Controller.reconcile(limited, "parent", usage())

    assert {:skip, %{"reason" => "outer_allowance_exhausted", "cause" => cause}} =
             Controller.admit(limited, plan, required)

    assert cause == %{"kind" => "requests", "spent" => 3, "estimate" => 3, "cap" => 5}
    assert JobBudget.snapshot(small_budget).requests == 3
  end

  test "an outer ledger with unknown cost preserves that cause without dispatch" do
    controller = controller(budget(spent_usd: nil))

    assert {:skip, %{"decision" => "stop", "reason" => "usage_unknown", "cause" => cause}} =
             Controller.admit(
               controller,
               %{"sha256" => String.duplicate("a", 64), "budget" => %{}},
               %{requests: 3, tokens: 30, time_ms: 3000, cost_usd: 0.3}
             )

    assert cause == %{"kind" => "cost", "spent" => nil, "estimate" => 0.3, "cap" => 1.0}
    assert Controller.snapshot(controller)["accounting"]["requests"] == 0
  end

  test "persistence precedes effects and write failure refuses the effect" do
    log = start_supervised!({Agent, fn -> [] end})

    callback = fn snapshot ->
      if Enum.any?(Map.values(snapshot["records"]), &(&1["decision"] == "run")),
        do: Agent.update(log, &[:reserved | &1])

      :ok
    end

    controller = controller(budget(), persist: callback)

    assert {:ok, :done, _} =
             Controller.run(controller, "durable", :task, estimate(), fn ->
               assert :reserved in Agent.get(log, & &1)
               {:done, usage()}
             end)

    failed =
      controller(budget(),
        persist: fn snapshot ->
          if Enum.any?(Map.values(snapshot["records"]), &(&1["decision"] == "run")),
            do: {:error, "private-storage-error"},
            else: :ok
        end
      )

    assert {:skip, %{"reason" => "persistence_unavailable"}} =
             Controller.run(failed, "denied", :task, estimate(), fn ->
               flunk("journal was not written")
             end)

    refute inspect(Controller.snapshot(failed)) =~ "private-storage-error"
  end

  test "actual overruns are retained and stop the next attempt" do
    controller = controller(budget())
    assert {:ok, _} = Controller.reserve(controller, "overrun", :task, estimate(10))
    assert :ok = Controller.reconcile(controller, "overrun", usage(11))
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 11

    assert {:skip, %{"reason" => "reservation_overrun"}} =
             Controller.reserve(controller, "next", :task, estimate())
  end

  test "unknown external parent usage closes token admission instead of assuming zero" do
    budget = budget()
    controller = controller(budget)
    assert {:ok, lease} = JobBudget.reserve(budget, 0.1, 1)

    assert {:skip, %{"reason" => "untracked_parent_usage"}} =
             Controller.reserve(controller, "learning", :critic, estimate())

    assert JobBudget.snapshot(budget).requests == 1
    assert :ok = JobBudget.settle(budget, lease, 0.08)
  end

  test "a host may join an existing ledger only with complete matching prior accounting" do
    budget = budget()
    assert {:ok, lease} = JobBudget.reserve(budget, 0.1, 1)
    assert :ok = JobBudget.settle(budget, lease, 0.08)

    for opts <- [
          [],
          [prior_usage: %{requests: 0, tokens: 0}],
          [prior_usage: %{requests: 1, tokens: nil}]
        ] do
      unknown = controller(budget, opts)

      assert {:skip, %{"reason" => "usage_unknown"}} =
               Controller.reserve(unknown, "unknown-parent", :proposer, estimate())
    end

    exhausted = controller(budget, prior_usage: %{requests: 1, tokens: 95})

    assert {:skip, %{"reason" => "token_allowance_exhausted"}} =
             Controller.reserve(exhausted, "over-token-cap", :proposer, estimate())

    joined = controller(budget, prior_usage: %{requests: 1, tokens: 60})
    assert {:ok, _} = Controller.reserve(joined, "auxiliary", :proposer, estimate())
    assert :ok = Controller.reconcile(joined, "auxiliary", usage())
    assert Controller.snapshot(joined)["accounting"]["tokens"] == 68
    assert JobBudget.snapshot(budget).requests == 2
    assert JobBudget.snapshot(budget).spent_usd == 0.16
  end

  test "a prior-usage declaration cannot settle an active parent or erase interrupted work" do
    budget = budget()
    assert {:ok, lease} = JobBudget.reserve(budget, 0.1, 1)
    unknown = controller(budget, prior_usage: %{requests: 1, tokens: 8})

    assert {:skip, %{"reason" => "usage_unknown"}} =
             Controller.reserve(unknown, "active-parent", :proposer, estimate())

    assert :ok = JobBudget.settle(budget, lease, 0.08)

    joined = controller(budget, prior_usage: %{requests: 1, tokens: 8})
    assert {:ok, _} = Controller.reserve(joined, "interrupted", :probe, estimate())
    recorded = Controller.snapshot(joined)
    GenServer.stop(joined)
    restored = controller(budget, recorded: recorded, prior_usage: %{requests: 2, tokens: 16})
    assert Controller.snapshot(restored)["accounting"]["tokens"] == nil
    assert {:skip, _} = Controller.reserve(restored, "do-not-replay", :probe, estimate())
    assert JobBudget.snapshot(budget).requests == 2
  end

  test "status and absent-provider capability checks make no model request" do
    controller = controller(budget())

    provider =
      Controller.provider(controller, :reflection, nil,
        token_bound: fn _ -> flunk("no provider") end
      )

    assert Provider.available_models(provider) == []
    assert Provider.context_window(provider, "test:model") == nil

    assert {:error,
            %{provider_code: "host_admission_denied", message: "controller: provider_unavailable"}} =
             Provider.run(provider, Request.new("test:model"), fn _ -> :ok end)

    assert Controller.snapshot(controller)["job_budget"]["requests"] == 0
  end

  test "a supported improvement can win, while uncertainty keeps the baseline" do
    controller = controller(budget())
    baseline = %{id: "baseline", value: "original", score: 0.8, uncertainty: 0.05}
    better = %{id: "better", value: "improved", score: 1.0, uncertainty: 0.05, supported: true}
    uncertain = %{better | uncertainty: 0.3}

    assert {:ok, ^better, %{"reason" => "supported_improvement"}} =
             Controller.select(controller, baseline, [better])

    assert {:ok, ^baseline, %{"reason" => "baseline_retained"}} =
             Controller.select(controller, baseline, [uncertain])
  end

  test "money reservations use the same integer precision as the outer ledger" do
    controller =
      controller(budget(),
        learning: [max_requests: 3, max_tokens: 40, max_time_ms: 10_000, max_cost_usd: 0.3]
      )

    for id <- ["one", "two", "three"],
        do: assert({:ok, _} = Controller.reserve(controller, id, :critic, estimate()))

    for id <- ["one", "two", "three"],
        do: assert(:ok = Controller.reconcile(controller, id, %{usage() | cost_usd: 0.1}))

    assert Controller.snapshot(controller)["accounting"]["learning_cost_usd"] == 0.3
  end

  test "cancelling guarded work kills the worker and retains unknown usage" do
    budget = budget()
    controller = controller(budget)
    parent = self()

    caller =
      spawn(fn ->
        Controller.run(controller, "guarded", :task, %{estimate() | time_ms: 60_000}, fn ->
          send(parent, {:worker_started, self()})

          receive do
            :finish -> {:finished, usage()}
          after
            60_000 -> {:too_late, usage()}
          end
        end)
      end)

    assert_receive {:worker_started, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert Controller.snapshot(controller)["accounting"]["tokens"] == nil
    assert JobBudget.snapshot(budget).requests == 1
  end

  test "a deadline or callback failure stops work without refunding its request" do
    controller = controller(budget())

    assert {:ok, {:error, :controller_work_incomplete}, receipt} =
             Controller.run(controller, "failed", :task, estimate(), fn ->
               raise("private callback failure")
             end)

    assert receipt["status"] == "unknown"
    refute inspect(receipt) =~ "private callback failure"
    assert Controller.snapshot(controller)["job_budget"]["requests"] == 1
  end

  test "decision storage remains bounded and stops instead of forgetting idempotency" do
    controller = controller(budget(), max_records: 3)

    for id <- 1..20,
        do:
          assert(
            {:noop, _} =
              Controller.consider(controller, %{
                "id" => Integer.to_string(id),
                "kind" => "healthy"
              })
          )

    snapshot = Controller.snapshot(controller)
    assert map_size(snapshot["records"]) == 4

    assert {:skip, %{"reason" => "decision_limit", "decision" => "stop"}} =
             Controller.reserve(controller, "task", :task, estimate())

    assert Controller.snapshot(controller)["job_budget"]["requests"] == 0
  end

  test "foreign, malformed or negative checkpoints cannot restore an allowance" do
    budget = budget()
    original = controller(budget)
    snapshot = Controller.snapshot(original)

    for changes <- [
          %{"job_id" => "foreign"},
          %{"initial_tokens" => -1},
          %{"seen" => ["invalid"]},
          %{"stagnant" => -1}
        ] do
      base = snapshot |> Map.delete("sha256") |> Map.merge(changes)
      recorded = Map.put(base, "sha256", Contract.digest(base))

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)

          Controller.start_link(
            job_budget: budget,
            job_id: "job",
            max_tokens: 100,
            max_time_ms: 60_000,
            recorded: recorded
          )
        end)

      assert {:error, :invalid_controller_checkpoint} = Task.await(task)
    end
  end

  test "cached input tokens participate in the shared token accounting" do
    controller = controller(budget())

    inner =
      Scripted.new(
        [
          Scripted.complete("cached",
            usage: %{
              "input_tokens" => 2,
              "output_tokens" => 2,
              "cache_read_tokens" => 6,
              "cost_usd" => 0.02
            }
          )
        ],
        estimated_cost_usd: 0.1
      )

    provider = Controller.provider(controller, :task, inner, token_bound: fn _ -> 10 end)
    assert :ok = Provider.run(provider, Request.new("test:model"), fn _ -> :ok end)
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 10
  end

  test "zero time allowance and expired checkpoints authorize no callback" do
    budget = budget()

    controller =
      controller(budget,
        max_time_ms: 0,
        learning: [max_requests: 0, max_tokens: 0, max_time_ms: 0, max_cost_usd: 0]
      )

    assert {:skip, %{"reason" => "deadline_exhausted"}} =
             Controller.run(controller, "expired", :task, estimate(), fn ->
               flunk("deadline elapsed")
             end)

    assert JobBudget.snapshot(budget).requests == 0
  end

  test "Scripted parent, retries and learning calls share one allowance" do
    budget = budget(max_requests: 3)
    controller = controller(budget)

    script = [
      Scripted.complete("parent",
        usage: %{"input_tokens" => 2, "output_tokens" => 2, "cost_usd" => 0.02}
      ),
      [
        {:usage, %{"input_tokens" => 2, "output_tokens" => 2, "cost_usd" => 0.02}},
        {:error, :retryable}
      ],
      Scripted.complete("retry",
        usage: %{"input_tokens" => 2, "output_tokens" => 2, "cost_usd" => 0.02}
      )
    ]

    inner = Scripted.new(script, estimated_cost_usd: 0.1)
    request = Request.new("test:model", params: [max_tokens: 8])

    for role <- [:task, :proposer, :proposer] do
      provider = Controller.provider(controller, role, inner, token_bound: fn _ -> 10 end)
      assert :ok = Provider.run(provider, request, fn _ -> :ok end)
    end

    provider = Controller.provider(controller, :critic, inner, token_bound: fn _ -> 10 end)

    assert {:error, %{provider_code: "host_admission_denied"}} =
             Provider.run(provider, request, fn _ -> :ok end)

    assert length(Scripted.requests(inner)) == 3
    assert JobBudget.snapshot(budget).requests == 3
    assert Controller.snapshot(controller)["accounting"]["tokens"] == 12
  end
end
