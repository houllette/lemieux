defmodule Lemieux.Subagent.AccountingTest do
  @moduledoc """
  What a delegation costs, as the front end watching it is told.

  The coordinator's own aggregate was already inclusive — the lifecycle suite
  asserts a cancelled child's tokens are in it. What was missing was the trip
  from there to a screen: the parent published its position when a prompt
  finished and when it stopped, and never when a child's result envelope
  landed or when somebody cancelled. So a fan-out's tokens sat on the
  transcript, correct and invisible, and cancelling one lost them entirely.

  These run a real group against real child sessions, and assert on the
  `{:context, position}` events a subscriber actually receives.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Context
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task
  alias Lemieux.Tools.Read

  @moduletag :tmp_dir

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(context.tmp_dir)}
  end

  test "a fan-out that finishes puts its children's tokens on the parent", context do
    parent = start_parent(context)

    {:ok, group} =
      Subagent.spawn_many(parent, [request("scout-a"), request("scout-b")],
        max_cost_usd: 1.0,
        timeout: 5_000,
        providers: %{"scout-a" => answering(), "scout-b" => answering()}
      )

    assert {:ok, _result} = Subagent.await(group, 10_000)

    # Two children at 700 input and 200 output each. The parent asked nothing
    # itself, so its own position stays zero and every token here is
    # delegated — which is the distinction the status line has to keep.
    position = settled()

    assert Context.delegated_tokens(position) == 1_800
    assert Context.cumulative(position) == 1_800
    assert position.tokens == 0
  end

  # The point of the exercise. A cancelled child still writes its envelope, so
  # the tokens it burned are known; before this they were known and unsaid.
  test "a cancelled fan-out's tokens reach the parent too", context do
    parent = start_parent(context)

    # On a manual clock the grace never lapses on its own, so the cancelled
    # child's envelope is always the one it wrote while checkpointing — not,
    # on a busy machine, the one the group writes for it when 200 ms run out.
    {:ok, group} =
      Subagent.spawn_many(parent, [request("scout-a"), request("scout-b")],
        max_cost_usd: 1.0,
        timeout: 5_000,
        cancel_grace_ms: 200,
        providers: %{"scout-a" => answering(), "scout-b" => slow()},
        clock: Manual.new()
      )

    # The first child has answered and the second has not, which is the shape
    # a person cancels in: something is taking too long and something else
    # has already been paid for.
    assert {:ok, [first, _second]} = Subagent.children(group)
    assert {:ok, _answer} = Subagent.await(first, 10_000)

    assert :ok = Subagent.cancel(group, "the operator changed their mind")

    position = settled()

    assert Context.delegated_tokens(position) >= 900
    assert Context.cumulative(position) == Context.delegated_tokens(position)
  end

  # The last position *published* is the one a status line is showing, so this
  # deliberately does not fall back to a snapshot: reading the transcript
  # would pass whether or not anything ever told the front end, which is the
  # bug these tests are about. Drained rather than matched once, because a
  # group of two publishes several.
  #
  # Two timeouts, not one. Waiting generously for the first and briefly for
  # the rest is what keeps this from measuring the machine: a loaded suite
  # can take longer than a short drain window to publish anything at all, and
  # a single short window would then read as "nothing was ever published".
  defp settled do
    assert_receive {:lemieux, _id, {:context, first}}, 5_000

    drain(first)
  end

  defp drain(seen) do
    receive do
      {:lemieux, _id, {:context, position}} -> drain(position)
    after
      250 -> seen
    end
  end

  defp start_parent(context) do
    {:ok, parent} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: Scripted.new([Scripted.complete("parent")]),
        store: context.store,
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    parent
  end

  defp request(id) do
    definition =
      Definition.new(
        id: id,
        description: "Investigates the repository",
        system_prompt: "Return concise sourced findings.",
        model: "test:child",
        tools: [Read],
        timeout: 5_000,
        max_cost_usd: 0.1
      )

    Request.new(
      definition,
      Task.new(objective: "investigate #{id}", snapshot: %{"git_commit" => "abc123"})
    )
  end

  defp answering do
    body = %{
      "answer" => "the answer",
      "findings" => [],
      "artifacts" => [],
      "uncertainties" => [],
      "coverage" => %{"searched" => ["lib"], "skipped" => []}
    }

    # `estimated_cost_usd` or admission refuses the child before it runs: a
    # cost it cannot estimate is one it cannot hold against the cap.
    Scripted.new(
      [
        Scripted.complete(JSON.encode!(body),
          usage: %{"input_tokens" => 700, "output_tokens" => 200, "cost_usd" => 0.01}
        )
      ],
      estimated_cost_usd: 0.01
    )
  end

  defp slow do
    Scripted.new([Scripted.delayed(10_000, Scripted.complete("too late"))],
      estimated_cost_usd: 0.01
    )
  end
end
