defmodule Lemieux.Subagent.DefinitionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Result
  alias Lemieux.Subagent.Task

  defp definition(overrides \\ []) do
    Definition.new(
      Keyword.merge(
        [
          id: "code-scout",
          description: "Reads one bounded repository area",
          system_prompt: "Return evidence, uncertainty, and coverage.",
          model: "test:model",
          tools: [Lemieux.Tools.Read],
          max_cost_usd: 0.25
        ],
        overrides
      )
    )
  end

  test "accepts only certified read-only tools" do
    assert %Definition{} = definition()

    assert_raise ArgumentError, ~r/subagent tools must be read-only: write/, fn ->
      definition(tools: [Lemieux.Tools.Write])
    end
  end

  # These were ceilings *and* defaults, so the default was the maximum and a
  # host asking for a longer-running child got a raise. What stops a child
  # running forever is the deadline `Lemieux.Subagent.Group` composes and
  # clamps every child timer to, not a number here — so a generous turn count
  # is accepted and the clock remains the guarantee.
  test "a turn count and a deadline are bounds a host chooses, not ones it is given" do
    assert definition(max_turns: 500).max_turns == 500
    assert definition(timeout: :timer.minutes(10)).timeout == :timer.minutes(10)

    # Still bounds, though: zero and negative are not budgets.
    assert_raise ArgumentError, ~r/max_turns/, fn -> definition(max_turns: 0) end
    assert_raise ArgumentError, ~r/max_turns/, fn -> definition(max_turns: -1) end
    assert_raise ArgumentError, ~r/timeout/, fn -> definition(timeout: 0) end
  end

  # Neither default is what stops a child: budgets and the repeat rules are.
  # The turn count is above what a fast model gets through in the hour, and
  # the hour is the hard ceiling a working child never meets — it was two
  # minutes, and that killed scouts streaming complete answers.
  test "the default turn count and deadline are out of the way, so the checks decide" do
    assert definition([]).max_turns == 400
    assert definition([]).timeout == :timer.hours(1)
    assert definition([]).progress_interval == :timer.minutes(2)
  end

  test "the check interval is a positive bound a host chooses" do
    assert definition(progress_interval: 500).progress_interval == 500

    assert_raise ArgumentError, ~r/progress_interval/, fn ->
      definition(progress_interval: 0)
    end
  end

  # Stored transcripts pin the digest, so the field joins it only when a host
  # set it: a definition that never mentioned an interval digests exactly as
  # it did before the field existed.
  test "the check interval changes the digest only when it is chosen" do
    assert Definition.digest(definition()) ==
             Definition.digest(definition(progress_interval: :timer.minutes(2)))

    refute Definition.digest(definition()) ==
             Definition.digest(definition(progress_interval: 500))
  end

  test "digest changes with behavior but not construction order" do
    first = definition(metadata: %{"focus" => "tests", "rank" => 1})
    second = definition(metadata: %{"rank" => 1, "focus" => "tests"})

    assert Definition.digest(first) == Definition.digest(second)
    refute Definition.digest(first) == Definition.digest(%{first | system_prompt: "changed"})
  end

  test "task digest and duplicate key include the explicit snapshot" do
    task = Task.new(objective: "Find every caller", snapshot: %{"git" => "abc123"})
    changed = %{task | snapshot: %{"git" => "def456"}}

    refute Task.digest(task) == Task.digest(changed)

    refute Request.duplicate_key(Request.new(definition(), task)) ==
             Request.duplicate_key(Request.new(definition(), changed))
  end

  test "definition requires a result schema contract" do
    assert_raise ArgumentError, ~r/result_schema/, fn ->
      definition(result_schema: String)
    end

    assert definition().result_schema == Result
  end
end
