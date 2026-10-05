defmodule Lemieux.TUI.ProcessingTest do
  @moduledoc """
  The labels the status line calls a running turn, tested without a terminal.

  The module is deliberately outside `Lemieux.TUI`'s `Code.ensure_loaded?`
  guard — `Lemieux.CLI.Config` checks a configured list at load, on a machine
  that may never have installed the optional NIF — and this suite is why that
  separation is worth keeping.
  """

  use ExUnit.Case, async: true

  alias Lemieux.TUI.Processing

  describe "the shipped list" do
    test "fits the row it is drawn in" do
      for word <- Processing.words() do
        assert String.length(word) <= Processing.max_length(),
               "#{word} is wider than a configured label is allowed to be"
      end
    end

    # A list that failed its own validator would be a check nobody could
    # satisfy, and a caught-at-load error for every word somebody copied out
    # of the defaults.
    test "passes the check a configured one has to pass" do
      assert Processing.valid?(Processing.words())
    end

    # `Thinking… · thinking (40s)` reads as a stutter, and worse as two
    # different claims about the same thing. The phases own these words.
    test "borrows none of the phase vocabulary" do
      phases = ~w(thinking answering composing running waiting reading retrying)

      for word <- Processing.words(), phase <- phases do
        refute String.downcase(word) == phase
      end
    end

    test "has no duplicates" do
      assert Processing.words() == Enum.uniq(Processing.words())
    end
  end

  describe "picking one" do
    test "comes from the shipped list when nothing replaced it" do
      for words <- [nil, []] do
        assert Processing.pick(words) in Processing.words()
      end
    end

    test "comes from a configured list when one was given" do
      assert Processing.pick(["Deking"]) == "Deking"

      chosen = for _attempt <- 1..40, do: Processing.pick(["Deking", "Zamboniing"])
      assert Enum.uniq(Enum.sort(chosen)) == ["Deking", "Zamboniing"]
    end

    # Forty draws over a list this long landing on one word is a fixed label
    # wearing a random one's clothes.
    test "varies" do
      drawn = for _attempt <- 1..40, do: Processing.pick()

      assert length(Enum.uniq(drawn)) > 1
    end
  end

  describe "checking a configured list" do
    test "accepts a list of short, non-empty strings" do
      assert Processing.valid?(["Working"])
      assert Processing.valid?(["Working", "Deking", "Zamboniing"])
    end

    # An empty list is not "no labels", it is a configuration that left the
    # status line with nothing to say.
    test "refuses anything it could not draw from" do
      refute Processing.valid?([])
      refute Processing.valid?(nil)
      refute Processing.valid?("Working")
      refute Processing.valid?(["Working", 3])
      refute Processing.valid?(["   "])
      refute Processing.valid?([String.duplicate("z", Processing.max_length() + 1)])
      refute Processing.valid?(["Work\ning"])
    end
  end
end
