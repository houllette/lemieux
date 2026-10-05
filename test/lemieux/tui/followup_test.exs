defmodule Lemieux.TUI.FollowupTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Followup

  defmodule Quiet do
    @moduledoc false
    @behaviour Lemieux.TUI.Followup

    @impl Lemieux.TUI.Followup
    def suggest(_signals), do: nil
  end

  defp signals(names, errors \\ 0) do
    names
    |> Enum.reduce(Followup.empty(), &Followup.called(&2, &1))
    |> then(fn signals ->
      Enum.reduce(1..errors//1, signals, fn _index, signals ->
        Followup.returned(signals, true)
      end)
    end)
  end

  test "a turn that did nothing worth naming offers nothing" do
    assert Followup.suggest(Followup.empty()) == nil
    assert Followup.suggest(signals(["ask_user"])) == nil
  end

  test "an unverified change points at the tests" do
    assert Followup.suggest(signals(["read", "edit"])) == "run the tests"
    assert Followup.suggest(signals(["write"])) == "run the tests"
  end

  test "a change that was already run points past it" do
    assert Followup.suggest(signals(["edit", "bash"])) == "commit this"
  end

  # The ordering the counters would lose: `bash` is as often "where is this
  # defined" as it is "does it still pass".
  test "a command that ran before the edit does not count as checking it" do
    assert Followup.suggest(signals(["bash", "edit"])) == "run the tests"
  end

  test "a failure outranks everything else the turn did" do
    assert Followup.suggest(signals(["edit", "bash"], 1)) == "fix what failed and try again"
  end

  # The README's first prompt says "Do not change files" and is answered by
  # reading; suggesting "make the change" after it put the one thing the
  # person had ruled out in their input box.
  test "a turn that only looked at code offers nothing, rather than a change" do
    assert Followup.suggest(signals(["read", "read", "web_search"])) == nil
    assert Followup.suggest(signals(["read"])) == nil
  end

  test "a turn that only ran commands offers nothing to guess at" do
    assert Followup.suggest(signals(["bash"])) == nil
  end

  # The contract and the shipped guess are one module, so the default cannot
  # drift from what a host is asked to implement.
  test "the shipped guess is itself an implementation of the behaviour" do
    assert {:suggest, 1} in Followup.behaviour_info(:callbacks)
    assert Followup.module(nil) == Followup
    assert Followup.module(Quiet) == Quiet
    assert Quiet.suggest(signals(["edit"])) == nil
  end
end
