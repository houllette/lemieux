defmodule Lemieux.TUI.StatusTest do
  @moduledoc """
  The two limits the status line contract puts on a host's own implementation.

  `Lemieux.TUI.ViewTest` covers the shipped layout through a rendered screen. What
  is here is the arithmetic that keeps a *replacement* inside the row it was
  given, which is the part with no screen in it and the part a host most wants
  to be able to rely on.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Lemieux.Context
  alias Lemieux.Conversation
  alias Lemieux.TUI.Activity
  alias Lemieux.TUI.Status

  test "warns near the enabled compaction threshold using measured context only" do
    conversation = Conversation.new(model: "test:model")
    context = %Context{measured?: true, tokens: 7_500, window: 10_000, fraction: 0.75}
    status = Status.new(conversation: %{conversation | context: context}, compact_at: 0.8)

    assert Status.compaction_warning(status) == "auto-compact in 5.0pp of context"

    assert Status.compaction_warning(%{status | compact_at: 0.7}) ==
             "auto-compact due on next request"

    assert Status.compaction_warning(%{status | compact_at: nil}) == nil

    assert Status.compaction_warning(%{
             status
             | conversation: %{conversation | context: %Context{}}
           }) == nil
  end

  defmodule Tall do
    @moduledoc false
    @behaviour Status

    @impl Status
    def height, do: 3

    @impl Status
    def render(_status, _area), do: []
  end

  defmodule Greedy do
    @moduledoc false
    @behaviour Status

    @impl Status
    def height, do: 400

    @impl Status
    def render(_status, _area), do: []
  end

  describe "choosing the implementation" do
    test "nothing configured is the shipped one" do
      assert Status.module(nil) == Status
    end

    test "a configured module is used as given" do
      assert Status.module(Tall) == Tall
    end
  end

  describe "how tall the row is" do
    # One row is what it was before it could be replaced, so a module that
    # says nothing about height gets exactly what it used to have.
    test "a module with no opinion is one row" do
      assert Status.height(Status, 24) == 1
    end

    test "a module with one gets it" do
      assert Status.height(Tall, 24) == 3
    end

    # The transcript is what this program is for, and a row count read from
    # an extension is exactly the number that eventually arrives as a hundred.
    test "is capped at a third of the frame" do
      assert Status.height(Greedy, 24) == 8
      assert Status.height(Greedy, 9) == 3
    end

    # A terminal too short to have thirds still has a status line.
    test "never falls below one row, however short the terminal" do
      assert Status.height(Status, 1) == 1
      assert Status.height(Greedy, 0) == 1
    end
  end

  describe "confining what comes back" do
    @area %Rect{x: 0, y: 20, width: 80, height: 1}

    test "leaves a rect that was already inside alone" do
      assert Status.confine(@area, @area) == @area
    end

    # The obvious mistake in writing one of these: placing a widget where it
    # goes *within* the row. Uncaught, that erases the conversation.
    test "clamps a rect that starts above the row" do
      whole = %Rect{x: 0, y: 0, width: 200, height: 99}

      assert Status.confine(whole, @area) == @area
    end

    test "clips a rect that runs off the right-hand edge" do
      wide = %Rect{x: 70, y: 20, width: 40, height: 1}

      assert Status.confine(wide, @area) == %Rect{x: 70, y: 20, width: 10, height: 1}
    end

    # Nothing to draw is a better outcome than something drawn in the wrong
    # place, and a much easier one to debug.
    test "a rect entirely outside the row draws nothing" do
      below = %Rect{x: 0, y: 22, width: 80, height: 2}
      confined = Status.confine(below, @area)

      assert confined.width == 0 or confined.height == 0
    end
  end

  # What the turn is doing is `Lemieux.TUI.Activity`'s to word and the
  # transcript's to draw. What is left on the row is the screen's own work,
  # and the conversation's standing beside it.
  describe "the shipped layout's own words" do
    test "says nothing about activity at all when nothing is happening" do
      assert Status.screen(%Status{}) == nil
      assert Status.segments(%Status{}) == []
    end

    # A resume is why the model is not answering, and an armed ctrl-c is about
    # to end the sitting: neither is something that happened in the
    # conversation, so neither belongs in the transcript.
    test "the screen's own work is what it still reports" do
      assert Status.screen(%Status{resuming?: true}) == "resuming…"
      assert Status.screen(%Status{exiting?: true}) == "ctrl-c again to leave"
    end

    # The row used to lead with the turn. It does not draw it any more, and a
    # host that liked it that way should not have to rebuild the sentence.
    test "a running turn is not on the row, but is still one call away" do
      turn = %Status{busy?: true, label: "Deking", elapsed: 12, frame: 2}

      assert Status.screen(turn) == nil
      assert Status.activity(turn) == Activity.spinner(2) <> " Deking (12s)"
      assert Status.activity(%{turn | resuming?: true}) == "resuming…"
      assert Status.activity(%Status{}) == nil
    end

    # The phase vocabulary is `Lemieux.TUI.ActivityTest`'s subject; what is
    # asserted here is that a host reaching for it through the status line
    # reaches the same words.
    test "the phase vocabulary is reachable from the snapshot" do
      status = %Status{
        busy?: true,
        phase: %{
          kind: :retrying,
          detail: %{attempt: 2, max: 2, delay_ms: 8_000, kind: "provider error"},
          for: 2,
          elapsed_ms: 2_000
        }
      }

      assert Status.phase(status) == "provider error, retrying in 6s (2/2)"
      assert Status.duration(125) == "2m"
      assert Status.bytes(2_048) == "2.0 KB"
      assert Status.investigations(3) == "3 read-only investigations"
    end
  end
end
