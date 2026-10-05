defmodule Lemieux.Subagent.HardeningTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Admission
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Subagent.Group
  alias Lemieux.Subagent.Group.Result
  alias Lemieux.Subagent.Money
  alias Lemieux.Subagent.Replay
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Result, as: ChildResult
  alias Lemieux.Subagent.Task
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(context.tmp_dir)

    parent_provider = Scripted.new([Scripted.complete("parent")], estimated_cost_usd: 0.01)

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: parent_provider,
        store: store,
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    %{runtime: runtime, store: store, parent: parent}
  end

  describe "cancellation" do
    test "carries the caller's reason into the child's own envelope", context do
      {group, [first, _second]} = fan_out(context, [:hangs, :hangs])

      assert :ok = Subagent.cancel(first, {:superseded, "a newer question"})
      assert {:ok, result} = Subagent.await(first, 5_000)

      assert result.status == :cancelled
      assert Enum.any?(result.uncertainties, &(&1 =~ "superseded"))
      assert Enum.any?(result.uncertainties, &(&1 =~ "a newer question"))

      assert :ok = Subagent.cancel(group, "the operator stopped it")
      assert {:ok, %{results: [_, second]}} = Subagent.await(group, 5_000)
      assert Enum.any?(second.uncertainties, &(&1 =~ "the operator stopped it"))
    end

    test "cancels every child at once rather than one behind another", context do
      {group, _children} = fan_out(context, [:slow_stop, :slow_stop, :slow_stop])

      assert :ok = Subagent.cancel(group, :enough)
      assert {:ok, result} = Subagent.await(group, 5_000)
      assert Enum.map(result.results, & &1.status) == [:cancelled, :cancelled, :cancelled]

      # Asserted on the order of the events rather than on a stopwatch: under a
      # loaded suite a wall-clock bound measures the machine. Every child was
      # asked to stop before any of them had stopped, which is what concurrent
      # means here; cancelled one behind another, the first `child_finished`
      # would sit between two `child_cancelling`s.
      assert [:cancelling, :cancelling, :cancelling | rest] = lifecycle_order()
      assert :finished in rest
    end

    defp lifecycle_order(collected \\ []) do
      receive do
        {:lemieux, _id, {:subagent, _path, {:child_cancelling, _payload}}} ->
          lifecycle_order([:cancelling | collected])

        {:lemieux, _id, {:subagent, _path, {:child_finished, _payload}}} ->
          lifecycle_order([:finished | collected])

        {:lemieux, _id, _event} ->
          lifecycle_order(collected)
      after
        0 -> Enum.reverse(collected)
      end
    end

    test "stops waiting on a child that will not settle, and says it terminated one",
         context do
      handler = attach(self(), [[:lemieux, :subagent, :cancel, :stop]])
      on_exit(fn -> :telemetry.detach(handler) end)

      # A grace long enough that its real timer never fires inside this test,
      # and a child whose session is deliberately unreachable, so the only
      # thing that can end the cancellation is the grace expiring. Firing that
      # by hand is what makes the assertion deterministic rather than a race
      # against a timer.
      {group_ref, [first]} = fan_out(context, [:hangs], cancel_grace_ms: 60_000, timeout: 30_000)
      {:ok, group} = Subagent.group(group_ref)
      {:ok, child_session} = Lemieux.session(context.runtime, first.id)

      # A session that will not answer, which is the case the grace exists for.
      # Suspending it is the deterministic version of "the child is wedged":
      # its `cancel/2` never completes, so nothing but the grace can end this.
      :sys.suspend(child_session)

      # `Task` is the subagent brief in this file, so the OTP one is explicit.
      canceller = Elixir.Task.async(fn -> Subagent.cancel(group_ref, :enough) end)
      assert_receive {:lemieux, _id, {:subagent, _path, {:child_cancelling, _payload}}}

      send(group, :cancel_grace)

      assert :ok = Elixir.Task.await(canceller, 5_000)
      assert {:ok, result} = Subagent.await(group_ref, 5_000)
      assert Enum.map(result.results, & &1.status) == [:cancelled]
      refute Process.alive?(child_session), "the straggler was not terminated"

      # Telemetry handlers are global, so the group id is what tells this
      # cancellation from every other one running beside it.
      group_id = group_ref.id

      assert_receive {:telemetry, [:lemieux, :subagent, :cancel, :stop], measurements,
                      %{group_id: ^group_id} = metadata}

      assert measurements.terminated == 1
      assert metadata.outcome == :terminated
    end
  end

  describe "admission" do
    test "writes no spawn intent for a fan-out it refuses, and records the refusal",
         context do
      # Two children whose reservations exceed the tree budget.
      requests = [
        Request.new(definition("first", max_cost_usd: 0.4), task("one")),
        Request.new(definition("second", max_cost_usd: 0.4), task("two"))
      ]

      assert {:error, %{reason: :tree_budget} = refusal} =
               Subagent.spawn_many(context.parent, requests,
                 max_cost_usd: 0.5,
                 providers: %{"first" => provider(:answers), "second" => provider(:answers)}
               )

      # Reported in dollars and computed in micros.
      assert refusal.cap == 0.5
      assert refusal.micros.cap == 500_000
      assert refusal.micros.requested == 800_000

      {:ok, entries} = Store.read(context.store, Lemieux.Session.id(context.parent))

      # No spawn intent describes a child that never existed …
      refute Enum.any?(entries, &(&1.type == :subagent_spawn))

      # … and the refusal itself is on the record, because the parent asked.
      assert [refused] = Enum.filter(entries, &(&1.type == :subagent_group_result))
      assert refused.payload["results"] == []
      assert refused.payload["refused"]["by"] == "admission"
      assert refused.payload["refused"]["requested_children"] == 2
      assert refused.payload["refused"]["reason"] =~ "tree_budget"
    end

    test "reserves and releases in exact integers, and charges an unpriced child in full",
         context do
      admission = Sup.subagent_admission(context.runtime)
      {group, _children} = fan_out(context, [:answers, :unpriced])

      assert {:ok, _result} = Subagent.await(group, 5_000)

      %{roots: roots} = Admission.snapshot(admission)
      assert [{_root, account}] = Map.to_list(roots)

      # Nothing is still reserved, and the arithmetic is integers throughout.
      assert account.reserved_micros == 0
      assert is_integer(account.spent_micros)
      assert account.unmeasured_children == 1

      # The measured child cost two cents; the unpriced one consumed its whole
      # reservation of ten. Charging it nothing would make an unpriced tree free.
      assert account.spent_micros == Money.to_micros(0.02) + Money.to_micros(0.1)
      assert account.spent_usd == 0.12
    end
  end

  # These run on a manual clock: the deadline is the subject, so it fires when
  # the test moves time to it, not when a loaded machine gets round to it.
  describe "the composed deadline" do
    test "a host allowance shorter than the definition binds every child", context do
      clock = Manual.new()
      {group, [child]} = fan_out(context, [:hangs], deadline_ms: 150, clock: clock)
      {:ok, pid} = Subagent.group(group)

      # A millisecond short of the host's allowance the child is still running.
      Manual.advance(clock, 149, settle: pid)
      assert {:ok, %{status: :running}} = Subagent.inspect(child)

      Manual.advance(clock, 1, settle: pid)
      assert {:ok, result} = Subagent.await(group, 5_000)
      assert Enum.map(result.results, & &1.status) == [:timeout]

      {:ok, entries} = Store.read(context.store, Lemieux.Session.id(context.parent))
      assert [spawn] = Enum.filter(entries, &(&1.type == :subagent_spawn))

      # The definition asked for five seconds; the host allowed 150ms, and the
      # record says which clock actually bound the child.
      assert spawn.payload["child_timeout_ms"] == 5_000
      assert spawn.payload["effective_deadline_ms"] == 150
      assert spawn.payload["deadline_source"] == "host"
    end

    test "the group's own timeout binds when nothing shorter does", context do
      clock = Manual.new()
      {group, _children} = fan_out(context, [:hangs], timeout: 200, clock: clock)
      {:ok, pid} = Subagent.group(group)

      Manual.advance(clock, 200, settle: pid)
      assert {:ok, result} = Subagent.await(group, 5_000)
      assert Enum.map(result.results, & &1.status) == [:timeout]

      {:ok, entries} = Store.read(context.store, Lemieux.Session.id(context.parent))
      assert [spawn] = Enum.filter(entries, &(&1.type == :subagent_spawn))
      assert spawn.payload["effective_deadline_ms"] == 200
      assert spawn.payload["deadline_source"] == "group"
    end
  end

  describe "the optional host authorization callback" do
    test "is consulted after the capability, and a denial is not a capability failure",
         context do
      test = self()

      authorize = fn action, ctx ->
        send(test, {:authorize, action, ctx})
        if action == :steer, do: {:error, :read_only_operator}, else: :ok
      end

      {group, [first | _rest]} = fan_out(context, [:hangs], authorize: authorize)

      assert {:error, {:denied, :read_only_operator}} = Subagent.steer(first, "look here")
      assert {:ok, _snapshot} = Subagent.inspect(first)

      assert_receive {:authorize, :steer, steer_context}
      assert steer_context.child_id == first.id
      assert steer_context.group_id == group.id
      assert steer_context.definition_id == "child-0"
      # A policy sees ids, never the brief or the transcript.
      refute Map.has_key?(steer_context, :task)
      refute Map.has_key?(steer_context, :prompt)

      assert :ok = Subagent.cancel(group, :done)
      assert {:ok, _result} = Subagent.await(group, 5_000)
    end

    test "a callback that fails denies rather than falling open", context do
      # Installed after the refs are in hand, because a policy that denies
      # everything denies listing the children too — which is the point.
      clock = Manual.new()
      {group, [first | _rest]} = fan_out(context, [:hangs], timeout: 200, clock: clock)
      {:ok, pid} = Subagent.group(group)

      _state =
        :sys.replace_state(pid, &%{&1 | authorize: fn _a, _c -> raise "policy is down" end})

      assert {:error, {:denied, message}} = Subagent.inspect(first)
      assert message =~ "policy is down"
      assert {:error, {:denied, _reason}} = Subagent.children(group)
      assert {:error, {:denied, _reason}} = Subagent.cancel(group, :done)
      assert {:error, {:denied, _reason}} = Subagent.await(group, 5_000)

      # Nothing a broken policy can do stops the group's own deadline, and the
      # durable record is the one thing it cannot deny.
      Manual.advance(clock, 200, settle: pid)
      assert_receive {:lemieux, _id, {:subagent, _path, {:group_finished, _payload}}}, 5_000

      assert {:ok, durable} =
               Replay.group_result(context.store, Lemieux.Session.id(context.parent), group.id)

      assert Enum.map(durable.results, & &1.status) == [:timeout]
    end

    test "names the actions a host writes policy against" do
      assert Group.authorized_actions() == [:child_refs, :await, :inspect, :steer, :cancel]
    end
  end

  # ---------------------------------------------------------------------------

  defp fan_out(context, behaviours, opts \\ []) do
    requests =
      behaviours
      |> Enum.with_index()
      |> Enum.map(fn {behaviour, index} ->
        Request.new(definition("child-#{index}"), task("investigate #{behaviour}"))
      end)

    providers =
      behaviours
      |> Enum.with_index()
      |> Map.new(fn {behaviour, index} -> {"child-#{index}", provider(behaviour)} end)

    opts =
      [max_cost_usd: 1.0, timeout: 5_000, providers: providers]
      |> Keyword.merge(opts)

    {:ok, group} = Subagent.spawn_many(context.parent, requests, opts)
    {:ok, children} = Subagent.children(group)

    {group, children}
  end

  defp definition(id, overrides \\ []) do
    Definition.new(
      Keyword.merge(
        [
          id: id,
          description: "Investigates #{id}",
          system_prompt: "Return concise sourced findings.",
          model: "test:child",
          tools: [Tools.Read],
          timeout: 5_000,
          max_cost_usd: 0.1
        ],
        overrides
      )
    )
  end

  defp task(objective), do: Task.new(objective: objective, snapshot: %{"git" => "abc"})

  defp body(answer) do
    JSON.encode!(%{
      "answer" => answer,
      "findings" => [],
      "artifacts" => [],
      "uncertainties" => [],
      "coverage" => %{"searched" => ["lib"], "skipped" => []}
    })
  end

  defp provider(:answers) do
    Scripted.new(
      [Scripted.complete(body("the answer"), usage: %{"input_tokens" => 7, "cost_usd" => 0.02})],
      estimated_cost_usd: 0.01
    )
  end

  # Reports tokens and no price, which is what a quota provider does.
  defp provider(:unpriced) do
    Scripted.new([Scripted.complete(body("the answer"), usage: %{"input_tokens" => 7})],
      estimated_cost_usd: 0.01
    )
  end

  defp provider(:hangs) do
    Scripted.new([Scripted.delayed(30_000, Scripted.complete("too late"))],
      estimated_cost_usd: 0.01
    )
  end

  # Long enough that cancelling three of these serially is visibly slower than
  # cancelling them together, short enough not to dominate the suite.
  defp provider(:slow_stop) do
    Scripted.new([Scripted.delayed(150, Scripted.complete(body("eventually")))],
      estimated_cost_usd: 0.01
    )
  end

  # Never answers and never stops early: only the grace deadline ends it.
  defp provider(:unstoppable) do
    Scripted.new([Scripted.delayed(60_000, Scripted.complete("never"))],
      estimated_cost_usd: 0.01
    )
  end

  defp attach(pid, events) do
    handler = "test-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(handler, events, &__MODULE__.forward/4, pid)

    handler
  end

  @doc false
  def forward(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  # A delegation that produced nothing used to arrive as a *successful* tool
  # result, leaving the parent to notice the emptiness inside a JSON blob.
  # Measured: three attempts of three where every child returned empty and the
  # parent answered 30000 anyway — a number it held no tool to read.
  describe "a delegation that returned no findings" do
    defp group(statuses) do
      %Result{
        group_id: "g1",
        parent_id: "p1",
        status: if(Enum.any?(statuses, &(&1 == :ok)), do: :partial, else: :failed),
        usage: %{},
        results:
          Enum.with_index(statuses, fn status, i ->
            %ChildResult{
              child_id: "c#{i}",
              definition_id: "scout",
              definition_digest: "d",
              status: status,
              answer: if(status == :ok, do: "found it", else: ""),
              uncertainties: if(status == :ok, do: [], else: ["stopped after 8 turns"]),
              transcript_id: "t#{i}"
            }
          end)
      }
    end

    test "is a failed call, and says what happened before the detail" do
      assert {:error, message} = Delegate.outcome(group([:failed, :failed, :timeout]))

      assert message =~ "no findings: all 3 investigations ended without an answer"
      assert message =~ "stopped after 8 turns"

      # The detail still follows: the reasons are what the parent should relay.
      assert message =~ "\"group_id\""
    end

    test "one child that answered keeps the whole call successful" do
      assert {:ok, rendered} = Delegate.outcome(group([:failed, :ok, :failed]))

      assert rendered =~ "found it"
      refute rendered =~ "no findings"
    end

    test "singular reads as one investigation, not one investigations" do
      assert {:error, message} = Delegate.outcome(group([:failed]))

      assert message =~ "all 1 investigation ended"
    end
  end

  # A child whose own budget exceeds the tree's can never be admitted, so every
  # call fails with `:root_request_budget_exhausted` and the model spends a
  # turn learning that each time. Measured: an experiment with a 150-request
  # child under a 96-request tree refused every delegation in both arms and
  # looked like a result.
  test "a tree that cannot admit its own child is refused at construction" do
    definition =
      Definition.new(
        id: "scout",
        description: "Look",
        system_prompt: "Read only.",
        model: "test:model",
        tools: [Tools.Read],
        max_requests: 150
      )

    message = ~r/cannot admit a child that reserves more: scout asks for 150/

    assert_raise ArgumentError, message, fn ->
      Delegate.new([definition], snapshot: %{"kind" => "t"}, max_cost_usd: 1.0, max_requests: 96)
    end

    assert %Delegate{} =
             Delegate.new([definition],
               snapshot: %{"kind" => "t"},
               max_cost_usd: 1.0,
               max_requests: 450
             )

    # No tree ceiling declared is no constraint, which is the metered case.
    assert %Delegate{} =
             Delegate.new([definition], snapshot: %{"kind" => "t"}, max_cost_usd: 1.0)
  end

  describe "a task the model shaped loosely" do
    defp task_from(fields) do
      definition =
        Definition.new(
          id: "scout",
          description: "Look at things",
          system_prompt: "Read only.",
          model: "test:model",
          tools: [Tools.Read],
          max_cost_usd: 0.5
        )

      tool =
        Delegate.new([definition],
          snapshot: %{"kind" => "working_tree"},
          max_cost_usd: 1.0
        )

      {:ok, request} =
        Delegate.request(tool, Map.put(fields, "definition_id", "scout"))

      request.task
    end

    # `"references": {}` killed a whole delegate call with
    # `invalid subagent task references: %{}`, discarding three children's
    # work — the same strictness-at-the-boundary defect as the result envelope.
    test "an object where an array was asked for is read, not refused" do
      assert %{references: [], non_goals: []} =
               task_from(%{"objective" => "look", "references" => %{}, "non_goals" => %{}})

      assert %{references: [%{"path" => "lib/x.ex"}]} =
               task_from(%{"objective" => "look", "references" => %{"path" => "lib/x.ex"}})

      assert %{acceptance_criteria: ["one thing"]} =
               task_from(%{"objective" => "look", "acceptance_criteria" => "one thing"})
    end

    test "an array still arrives untouched" do
      assert %{references: [%{"a" => 1}], non_goals: ["no"]} =
               task_from(%{
                 "objective" => "look",
                 "references" => [%{"a" => 1}],
                 "non_goals" => ["no"]
               })
    end
  end
end
