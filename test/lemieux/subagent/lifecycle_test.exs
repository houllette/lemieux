defmodule Lemieux.Subagent.LifecycleTest do
  @moduledoc """
  Generated lifecycle sequences over one real fan-out.

  The individual behaviours — a child that answers, one that times out, one
  whose session crashes — each have their own test. What those cannot catch is
  the interaction: a cancellation that arrives while one sibling is already
  terminal and another is still queued, a duplicate delivery of a completion,
  a parent that exits mid-flight. Those are orderings, and orderings are what
  a hand-written test picks one of.

  So the scripts below are generated from a small vocabulary of child
  behaviours and control actions, and every combination is run against a real
  group with real sessions. Each run then has to satisfy the same invariants,
  which are the ones the delegation plan says must hold before the tree gets
  any wider than this.
  """

  use ExUnit.Case, async: true

  # A read-only store over a fixed map of transcripts, for replaying prefixes
  # without touching the disk. See `assert_replayable_prefixes/3`.
  defmodule PrefixStore do
    @moduledoc false
    @behaviour Lemieux.Store

    def new(sessions) when is_map(sessions), do: {__MODULE__, sessions}

    @impl Lemieux.Store
    def append(_sessions, _session_id, _entries), do: {:error, :read_only}

    @impl Lemieux.Store
    def read(sessions, session_id) do
      case Map.fetch(sessions, session_id) do
        {:ok, entries} -> {:ok, entries}
        :error -> {:error, :not_found}
      end
    end

    @impl Lemieux.Store
    def list_sessions(sessions), do: {:ok, Map.keys(sessions)}
  end

  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Admission
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Replay
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tools.Read

  @moduletag :tmp_dir

  @terminal [:ok, :failed, :timeout, :cancelled, :budget_exhausted]

  # How each child behaves. Every script is a combination of these.
  @behaviours [:answers, :prose, :errors, :hangs]

  # What the controller does while they run.
  @actions [:none, :cancel_group, :cancel_child, :steer, :duplicate_finish, :parent_exit]

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(context.tmp_dir)

    %{runtime: runtime, store: store}
  end

  # Two behaviours per group is enough to produce an ordering: one child that
  # settles and one that does something else, in both orders.
  defp scripts do
    for first <- @behaviours,
        second <- @behaviours,
        action <- @actions,
        first != second or action != :none,
        do: {[first, second], action}
  end

  # Ninety-two fan-outs, one after another: four seconds on a quiet machine
  # (2026-10-04), and many times that under outside load, where each of them
  # waits for a CPU. A slow machine is not a failed lifecycle, so the test has
  # more than the suite's sixty seconds.
  @tag timeout: :timer.minutes(3)
  test "every generated lifecycle leaves exactly one terminal result per child", context do
    for {behaviours, action} <- scripts() do
      run(context, behaviours, action)
    end
  end

  defp run(context, behaviours, action) do
    parent = start_parent(context)

    requests =
      behaviours
      |> Enum.with_index()
      |> Enum.map(fn {behaviour, index} ->
        Request.new(definition("child-#{index}", behaviour), task("investigate #{behaviour}"))
      end)

    providers =
      behaviours
      |> Enum.with_index()
      |> Map.new(fn {behaviour, index} -> {"child-#{index}", provider(behaviour)} end)

    {:ok, group_ref} =
      Subagent.spawn_many(parent, requests,
        max_cost_usd: 1.0,
        # Generous, and never reached: only the hanging child has a short
        # deadline, so a group deadline this long costs nothing while leaving
        # a child that is merely slow — this suite runs a case per scheduler
        # at once — room to finish rather than being recorded as a timeout.
        timeout: 5_000,
        cancel_grace_ms: 100,
        providers: providers
      )

    {:ok, children} = Subagent.children(group_ref)
    perform(action, group_ref, children, parent)

    {:ok, result} = Subagent.await(group_ref, 10_000)
    label = "#{inspect(behaviours)} + #{action}"

    assert_one_terminal_result(result, children, label)
    assert_no_lost_success(result, behaviours, action, label)
    assert_inclusive_usage(result, label)
    assert_no_escalation(context.store, result, label)
    assert_reservations_released(context.runtime, label)
    assert_replayable_prefixes(context, parent, label)
  end

  # One result per child, in input order, and every one of them terminal. A
  # group that answered with a missing or duplicated child would be a group a
  # parent cannot reason about at all.
  defp assert_one_terminal_result(result, children, label) do
    ids = Enum.map(result.results, & &1.child_id)

    assert ids == Enum.map(children, & &1.id), "#{label}: results are not the children, in order"
    assert length(ids) == length(Enum.uniq(ids)), "#{label}: a child reported twice"

    Enum.each(result.results, fn child ->
      assert child.status in @terminal, "#{label}: #{child.child_id} is #{child.status}"
    end)
  end

  # A sibling that answered is never discarded because another one did not.
  # Without a cancellation, a child that answered at all — in the envelope or
  # in prose — reports its answer.
  defp assert_no_lost_success(result, behaviours, :none, label) do
    behaviours
    |> Enum.zip(result.results)
    |> Enum.each(fn
      {behaviour, child} when behaviour in [:answers, :prose] ->
        assert child.status == :ok, "#{label}: #{behaviour} child reported #{child.status}"
        refute child.answer == "", "#{label}: #{behaviour} child lost its answer"

      {_behaviour, _child} ->
        :ok
    end)
  end

  defp assert_no_lost_success(_result, _behaviours, _action, _label), do: :ok

  # The group's usage is its children's, exactly. An aggregate that dropped a
  # cancelled child's tokens would under-report what the tree cost.
  defp assert_inclusive_usage(result, label) do
    expected =
      result.results
      |> Enum.map(&(&1.usage["input_tokens"] || 0))
      |> Enum.sum()

    assert result.usage["input_tokens"] == expected, "#{label}: usage is not inclusive"
  end

  # No child ever holds more authority than its definition declared, whatever
  # happened to it: read-only tools, no delegate, depth one.
  defp assert_no_escalation(store, result, label) do
    Enum.each(result.results, fn child ->
      case Store.read(store, child.transcript_id) do
        {:ok, entries} -> assert_child_authority(entries, child, label)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp assert_child_authority(entries, child, label) do
    session = Enum.find(entries, &(&1.type == :session))
    tools = if session, do: session.payload["tools"] || [], else: []

    # The definition declared exactly one read-only tool; a child that started
    # at all has that and nothing else.
    assert tools in [[], [to_string(Read)]], "#{label}: #{child.child_id} had #{inspect(tools)}"

    refute Enum.any?(tools, &String.contains?(to_string(&1), "Delegate")),
           "#{label}: a child was given delegate"

    refute Enum.any?(entries, &(&1.type == :subagent_spawn)),
           "#{label}: a child spawned its own children"
  end

  # Every reservation taken is released, whatever terminal state its child
  # reached. A leak here is a tree budget that shrinks with every fan-out.
  defp assert_reservations_released(runtime, label) do
    snapshot = Admission.snapshot(Sup.subagent_admission(runtime))

    Enum.each(snapshot.roots, fn {root, account} ->
      assert account.reserved_micros == 0, "#{label}: #{root} still reserves #{inspect(account)}"
      assert account.children == 0, "#{label}: #{root} still holds children"
    end)
  end

  # Every durable prefix of the parent transcript replays, and a child never
  # moves backwards: once a prefix shows it terminal, no longer prefix says it
  # is incomplete again.
  #
  # Each prefix is replayed from memory, in the form the JSONL store keeps it:
  # every entry is encoded and decoded once, so a prefix is still the durable
  # form. Writing each prefix to disk put a directory removal, a mkdir and an
  # append per prefix length through the node's single file server, and under
  # the parallel suite on CI that alone ran this test past its 60-second
  # timeout (2026-09-29).
  defp assert_replayable_prefixes(context, parent, label) do
    parent_id = Lemieux.Session.id(parent)
    {:ok, entries} = Store.read(context.store, parent_id)
    durable = Enum.map(entries, &(&1 |> Lemieux.Entry.encode!() |> Lemieux.Entry.decode!()))

    Enum.reduce(1..length(durable)//1, %{}, fn length, seen ->
      prefix_store = PrefixStore.new(%{parent_id => Enum.take(durable, length)})

      assert {:ok, tree} = Replay.tree(prefix_store, parent_id), "#{label}: prefix #{length}"

      tree.groups
      |> Enum.flat_map(& &1.children)
      |> Enum.reduce(seen, &assert_monotone(&1, &2, label, length))
    end)
  end

  defp assert_monotone(child, seen, label, prefix) do
    assert Map.get(seen, child.id) not in @terminal or child.status in @terminal,
           "#{label}: #{child.id} went back to #{child.status} at prefix #{prefix}"

    Map.put(seen, child.id, child.status)
  end

  defp perform(:none, _group_ref, _children, _parent), do: :ok

  defp perform(:cancel_group, group_ref, _children, _parent),
    do: Subagent.cancel(group_ref, "the operator changed their mind")

  defp perform(:cancel_child, _group_ref, [first | _rest], _parent),
    do: Subagent.cancel(first, {:superseded, "a newer question"})

  defp perform(:steer, _group_ref, [first | _rest], _parent),
    do: Subagent.steer(first, "look at the config first")

  # The same completion delivered twice, which a monitor and a session event
  # can both produce for one child.
  defp perform(:duplicate_finish, group_ref, [first | _rest], _parent) do
    {:ok, group} = Subagent.group(group_ref)
    send(group, {:lemieux, first.id, {:finished, :stop}})
    send(group, {:lemieux, first.id, {:finished, :stop}})
  end

  defp perform(:parent_exit, group_ref, _children, parent) do
    {:ok, group} = Subagent.group(group_ref)
    send(group, {:parent_cancel, :parent_went_away})
    _alive = Process.alive?(parent)
    :ok
  end

  defp start_parent(context) do
    provider = Scripted.new([[{:text_delta, "parent"}, {:done, :stop}]], estimated_cost_usd: 0.01)

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir
      )

    parent
  end

  defp definition(id, behaviour) do
    Definition.new(
      id: id,
      description: "Investigates #{behaviour}",
      system_prompt: "Return concise sourced findings.",
      model: "test:child",
      tools: [Read],
      timeout: child_timeout(behaviour),
      max_cost_usd: 0.1
    )
  end

  # Only the child that is supposed to miss its deadline gets a short one.
  # Sharing a short deadline with the others made a scripted child that was
  # merely slow under a loaded suite come back as a timeout, which is the
  # suite measuring the machine.
  defp child_timeout(:hangs), do: 150
  defp child_timeout(_behaviour), do: 5_000

  defp task(objective) do
    Task.new(objective: objective, snapshot: %{"git_commit" => "abc123"})
  end

  defp usage, do: %{"input_tokens" => 7, "output_tokens" => 2, "cost_usd" => 0.01}

  defp provider(:answers) do
    body = %{
      "answer" => "the answer",
      "findings" => [],
      "artifacts" => [],
      "uncertainties" => [],
      "coverage" => %{"searched" => ["lib"], "skipped" => []}
    }

    Scripted.new([Scripted.complete(JSON.encode!(body), usage: usage())],
      estimated_cost_usd: 0.01
    )
  end

  defp provider(:prose),
    do: Scripted.new([Scripted.complete("just words", usage: usage())], estimated_cost_usd: 0.01)

  defp provider(:errors),
    do: Scripted.new([Scripted.error(:closed)], estimated_cost_usd: 0.01)

  defp provider(:hangs) do
    Scripted.new([Scripted.delayed(10_000, Scripted.complete("too late"))],
      estimated_cost_usd: 0.01
    )
  end
end
