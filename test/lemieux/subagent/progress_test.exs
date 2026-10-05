defmodule Lemieux.Subagent.ProgressTest do
  @moduledoc """
  A child's deadline is soft until its ceiling.

  The group runs on a `Lemieux.Clock.Manual`, so every check fires when the
  test says, after the child has done exactly what the check should see,
  rather than when a timer and a loaded machine agree it should. A child is
  gated on a provider turn for the same reason: the check has to find it
  running.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(context.tmp_dir)

    parent_provider =
      Scripted.new([[{:text_delta, "parent"}, {:done, :stop}]], estimated_cost_usd: 0.01)

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

    %{
      runtime: runtime,
      store: store,
      parent: parent,
      parent_id: Session.id(parent),
      clock: Manual.new()
    }
  end

  describe "a check that finds the child working" do
    test "asks the model, lets the child continue, and bills the question to the child", ctx do
      judge = judge(~s({"verdict":"progressing","reason":"reading new files"}))
      child = reading(~w(a b c), gate: self(), then: ~w(d e))
      {group, child_ref} = fan_out(ctx, child, judge: judge, progress_interval: 50)

      assert %{message: {:child_clock, child_id}, due_in: 50} = armed(ctx, group)
      assert child_id == child_ref.id

      gated = wait_for_gate(child_id, 3)
      fire(ctx, group)

      assert_receive {:lemieux, _, {:subagent, _, {:child_assessed, assessed}}}
      assert assessed["child_id"] == child_id
      assert assessed["outcome"] == "progressing"
      assert assessed["by"] == "model"
      assert assessed["note"] == "reading new files"
      assert assessed["checks"] == 1

      # Another interval, not the hard deadline.
      assert %{message: {:child_clock, ^child_id}, due_in: 50} = armed(ctx, group)

      send(gated, :release)
      assert {:ok, result} = Subagent.await(child_ref, 5_000)
      assert result.status == :ok
      assert result.answer == "done"

      # The judge saw the interval's three distinct reads and nothing else.
      assert [request] = Scripted.requests(judge)
      assert [%Entry{payload: %{"text" => text}}] = request.entries
      assert text =~ "all 3:"
      assert text =~ ~s({"path":"a"})
      refute text =~ ~s({"path":"d"})

      # 10 from the answer turn, 7 from the judge.
      assert result.usage["input_tokens"] == 17
      assert_in_delta result.usage["cost_usd"], 0.011, 0.0001
    end

    # A crash is the failure that would have mattered most: the check task
    # dies, no verdict is ever sent, and without the monitor the child would
    # run with no clock armed at all until the group's own deadline.
    @tag :capture_log
    test "a check that crashes falls open and the next interval is still armed", ctx do
      child = reading(~w(a b c), gate: self(), then: [])

      {group, child_ref} =
        fan_out(ctx, child,
          progress: [assess: fn _evidence -> raise "the host assessor exploded" end],
          progress_interval: 50
        )

      assert %{message: {:child_clock, child_id}, due_in: 50} = armed(ctx, group)
      gated = wait_for_gate(child_id, 3)
      fire(ctx, group)

      assert_receive {:lemieux, _, {:subagent, _, {:child_assessed, assessed}}}
      assert assessed["outcome"] == "progressing"
      assert assessed["by"] == "error"
      assert assessed["note"] =~ "stopped before answering"
      assert %{message: {:child_clock, ^child_id}, due_in: 50} = armed(ctx, group)

      send(gated, :release)
      assert {:ok, %{status: :ok}} = Subagent.await(child_ref, 5_000)
    end

    test "a judge that cannot answer lets the child run on, and says so", ctx do
      judge = Scripted.new([Scripted.error("the judge is down")], estimated_cost_usd: 0.0)
      child = reading(~w(a b c), gate: self(), then: [])
      {group, child_ref} = fan_out(ctx, child, judge: judge, progress_interval: 50)

      gated = wait_for_gate(child_ref.id, 3)
      fire(ctx, group)

      assert_receive {:lemieux, _, {:subagent, _, {:child_assessed, assessed}}}
      assert assessed["outcome"] == "progressing"
      assert assessed["by"] == "error"
      assert assessed["note"] =~ "fell open"

      send(gated, :release)
      assert {:ok, %{status: :ok}} = Subagent.await(child_ref, 5_000)
    end
  end

  describe "a check that finds the child stuck" do
    # Five distinct reads, repeated four times over. The session's own rules
    # never fire on this: no round is identical to the last, and the window
    # of eight never holds more repeats than it holds distinct calls. The
    # interval does, because it sees all twenty.
    test "is decided by the transcript rules without asking anyone", ctx do
      judge = Scripted.new([], estimated_cost_usd: 0.0)
      child = reading(List.duplicate(~w(a b c d e), 4) |> List.flatten(), gate: self(), then: [])
      {group, child_ref} = fan_out(ctx, child, judge: judge, progress_interval: 50)

      _gated = wait_for_gate(child_ref.id, 20)
      fire(ctx, group)

      assert_receive {:lemieux, _, {:subagent, _, {:child_assessed, assessed}}}
      assert assessed["outcome"] == "stalled"
      assert assessed["by"] == "activity"

      assert assessed["note"] ==
               "15 of the last 20 calls repeated an earlier call and got the same answer"

      assert {:ok, result} = Subagent.await(child_ref, 5_000)
      assert result.status == :failed
      assert result.answer == ""

      assert "cancelled: stalled: 15 of the last 20 calls repeated an earlier call and got the same answer" in result.uncertainties

      assert Scripted.requests(judge) == []

      # The child's own transcript says what happened to it.
      {:ok, entries} = Store.read(ctx.store, child_ref.id)
      assert Enum.any?(entries, &(&1.type == :cancelled and &1.payload["reason"] == "stalled"))
    end

    test "is cancelled as failed with the model's reason when the model says so", ctx do
      judge = judge(~s({"verdict":"stalled","reason":"It is wandering."}))
      child = reading(~w(a b c), gate: self(), then: [])
      {group, child_ref} = fan_out(ctx, child, judge: judge, progress_interval: 50)
      assert %{message: {:child_clock, _child_id}, due_in: 50} = armed(ctx, group)

      _gated = wait_for_gate(child_ref.id, 3)
      fire(ctx, group)

      assert_receive {:lemieux, _,
                      {:subagent, _,
                       {:child_assessed, %{"outcome" => "stalled", "by" => "model"}}}}

      assert {:ok, result} = Subagent.await(child_ref, 5_000)
      assert result.status == :failed
      assert "cancelled: stalled: It is wandering." in result.uncertainties
      refute Enum.any?(Manual.pending(ctx.clock), &match?(%{message: {:child_clock, _}}, &1))
    end
  end

  describe "the hard deadline" do
    test "still cancels a child the checks would have let continue", ctx do
      judge = judge(~s({"verdict":"progressing","reason":"fine"}))
      child = reading(~w(a b c), gate: self(), then: [])
      {group, child_ref} = fan_out(ctx, child, judge: judge, progress_interval: 50, timeout: 1)

      # The first clock is the deadline, because it is nearer than the interval.
      assert %{message: {:child_clock, child_id}, due_in: 1} = armed(ctx, group)

      _gated = wait_for_gate(child_id, 3)
      fire(ctx, group)

      assert {:ok, result} = Subagent.await(child_ref, 5_000)
      assert result.status == :timeout
      refute_received {:lemieux, _, {:subagent, _, {:child_assessed, _}}}
      assert Scripted.requests(judge) == []
    end

    test "is the only clock when checks are off", ctx do
      child = reading(~w(a), gate: nil, then: [])

      {group, _child_ref} =
        fan_out(ctx, child, progress: [assess: false], progress_interval: 50, timeout: 5_000)

      # No time passes on the manual clock, so the one clock armed is exactly
      # what is left of the group's five seconds.
      assert %{message: {:child_clock, _child_id}, due_in: 5_000} = armed(ctx, group)
    end

    test "the spawn intent records both clocks and who decides", ctx do
      child = reading(~w(a), gate: nil, then: [])
      {_group, child_ref} = fan_out(ctx, child, judge: judge("{}"), progress_interval: 50)
      assert {:ok, _result} = Subagent.await(child_ref, 5_000)

      {:ok, entries} = Store.read(ctx.store, ctx.parent_id)
      assert [spawn] = Enum.filter(entries, &(&1.type == :subagent_spawn))
      assert spawn.payload["progress_interval_ms"] == 50
      assert spawn.payload["assess"] == "model"
      assert spawn.payload["child_timeout_ms"] == :timer.hours(1)
      assert spawn.payload["group_timeout_ms"] == :timer.hours(1)
      assert spawn.payload["deadline_source"] == "group"
    end
  end

  describe "the delegate tool" do
    # The group used to run on after the tool task that asked for it was
    # stopped at its own deadline, and wrote results the parent never read.
    test "tells its group the deadline the call actually got", ctx do
      child = reading(~w(a), gate: nil, then: [])
      tool = delegate(ctx, child)

      assert {:ok, _rendered} =
               Delegate.run(tool, %{"tasks" => [brief()]}, %{
                 session: ctx.parent,
                 deadline_ms: 60_000
               })

      {:ok, entries} = Store.read(ctx.store, ctx.parent_id)
      assert [spawn] = Enum.filter(entries, &(&1.type == :subagent_spawn))
      assert spawn.payload["deadline_source"] == "host"
      assert spawn.payload["effective_deadline_ms"] == 45_000
    end

    test "leaves the group's own clock alone when the call has none", ctx do
      child = reading(~w(a), gate: nil, then: [])
      tool = delegate(ctx, child)

      assert {:ok, _rendered} =
               Delegate.run(tool, %{"tasks" => [brief()]}, %{session: ctx.parent})

      {:ok, entries} = Store.read(ctx.store, ctx.parent_id)
      assert [spawn] = Enum.filter(entries, &(&1.type == :subagent_spawn))
      assert spawn.payload["deadline_source"] == "group"
      assert spawn.payload["effective_deadline_ms"] == :timer.hours(1)
    end

    test "declares a deadline long enough for a fan-out that runs for an hour" do
      assert Delegate.metadata(%Delegate{definitions: %{}, snapshot: %{}, max_cost_usd: 1.0}).runtime.timeout_ms ==
               :timer.hours(1)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # A child that reads the given paths one per turn, then, when `gate:` is a
  # pid, blocks on the next turn until released, then reads `then:` and
  # answers. Reads of files that do not exist are still distinct calls.
  defp reading(paths, opts) do
    gate = Keyword.fetch!(opts, :gate)
    rest = Keyword.fetch!(opts, :then)
    counter = :counters.new(1, [])

    turn = fn path ->
      :counters.add(counter, 1, 1)
      Scripted.tool_call("c#{:counters.get(counter, 1)}", "read", %{"path" => path})
    end

    gated =
      if gate do
        [
          fn _request ->
            send(gate, {:child_waiting, self()})
            receive do: (:release -> :ok)
            turn.("gate")
          end
        ]
      else
        []
      end

    script =
      Enum.map(paths, turn) ++
        gated ++
        Enum.map(rest, turn) ++
        [Scripted.complete(body("done"), usage: %{"input_tokens" => 10, "cost_usd" => 0.01})]

    Scripted.new(script, estimated_cost_usd: 0.01)
  end

  # A judge with the same answer for every question it is asked.
  defp judge(text) do
    Scripted.new(
      List.duplicate(
        Scripted.complete(text,
          usage: %{"input_tokens" => 7, "output_tokens" => 2, "cost_usd" => 0.001}
        ),
        10
      ),
      estimated_cost_usd: 0.0
    )
  end

  defp fan_out(ctx, child, opts) do
    {judge, opts} = Keyword.pop(opts, :judge)
    {definition_opts, opts} = Keyword.split(opts, [:progress_interval, :timeout])
    definition = definition("scout", definition_opts)

    opts =
      [
        max_cost_usd: 1.0,
        max_requests: 1_000,
        providers: %{"scout" => child},
        clock: ctx.clock,
        cancel_grace_ms: 200
      ]
      |> Keyword.merge(if(judge, do: [progress: [assess: :model, provider: judge]], else: []))
      |> Keyword.merge(opts)

    {:ok, group_ref} =
      Subagent.spawn_many(ctx.parent, [Request.new(definition, task("look"))], opts)

    {:ok, [child_ref]} = Subagent.children(group_ref)
    [{group, _}] = Registry.lookup(Sup.registry(ctx.runtime), {:subagent_group, group_ref.id})

    {group, child_ref}
  end

  # The child clock the group has armed, read off the manual clock once the
  # group has armed one. Each test runs a single child.
  defp armed(ctx, group) do
    LemieuxTest.Sync.state(group, fn state ->
      Enum.any?(state.children, fn {_id, child} -> child.timer != nil end)
    end)

    [timer] = Enum.filter(Manual.pending(ctx.clock), &match?(%{message: {:child_clock, _}}, &1))
    timer
  end

  # Moves the clock to the child's next clock and waits for the group to act
  # on it — the check begins, or the deadline cancels.
  defp fire(ctx, group) do
    %{due_in: due_in} = armed(ctx, group)
    Manual.advance(ctx.clock, due_in, settle: group)
  end

  # The child has appended `results` tool results and is blocked on its next
  # provider turn, which is exactly when a check must find it.
  defp wait_for_gate(child_id, results) do
    for _ <- 1..results do
      assert_receive {:lemieux, _,
                      {:subagent, [_root, ^child_id], {:entry, %Entry{type: :tool_result}}}}
    end

    assert_receive {:child_waiting, gated}
    gated
  end

  defp delegate(_ctx, child) do
    Delegate.new([definition("scout", [])],
      snapshot: %{"git" => "abc"},
      max_cost_usd: 1.0,
      max_requests: 1_000,
      providers: %{"scout" => child},
      progress: [assess: :activity]
    )
  end

  defp brief, do: %{"definition_id" => "scout", "objective" => "look"}

  defp definition(id, overrides) do
    Definition.new(
      Keyword.merge(
        [
          id: id,
          description: "Investigates #{id}",
          system_prompt: "Return concise sourced findings.",
          model: "test:child",
          tools: [Tools.Read],
          # In requests, not dollars: a scripted turn reports no price, and
          # the cost gate stops a child whose spend it cannot know.
          max_requests: 100
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
end
