# Two layouts a host might write: one that turns the screen upside down, and
# one that gets the geometry wrong.
defmodule Lemieux.TUI.LayoutTest.InputOnTop do
  @moduledoc false
  @behaviour Lemieux.TUI.Layout

  alias ExRatatui.Layout.Rect

  @impl Lemieux.TUI.Layout
  def panes(%{width: width, height: height}, %{input: input, status: status}) do
    %{
      input: %Rect{x: 0, y: 0, width: width, height: input},
      status: %Rect{x: 0, y: input, width: width, height: status},
      transcript: %Rect{x: 0, y: input + status, width: width, height: height - input - status}
    }
  end
end

defmodule Lemieux.TUI.LayoutTest.Overlapping do
  @moduledoc false
  @behaviour Lemieux.TUI.Layout

  alias ExRatatui.Layout.Rect

  # The transcript is given the whole frame, so it sits under the other two.
  @impl Lemieux.TUI.Layout
  def panes(%{width: width, height: height}, %{input: input, status: status}) do
    %{
      transcript: %Rect{x: 0, y: 0, width: width, height: height},
      status: %Rect{x: 0, y: height - input - status, width: width, height: status},
      input: %Rect{x: 0, y: height - input, width: width, height: input}
    }
  end
end

defmodule Lemieux.TUI.LayoutTest do
  @moduledoc """
  The pane arithmetic on its own: what the shipped arrangement is, what a
  host's is held to, and what happens to one that breaks the rules.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Lemieux.TUI.Layout
  alias Lemieux.TUI.LayoutTest.InputOnTop
  alias Lemieux.TUI.LayoutTest.Overlapping

  @frame %{width: 80, height: 24}
  @needs %{input: 3, status: 1}

  describe "the shipped arrangement" do
    test "is transcript, input, status from the top, tiling the frame" do
      assert Layout.panes(@frame, @needs) == %{
               transcript: %Rect{x: 0, y: 0, width: 80, height: 20},
               input: %Rect{x: 0, y: 20, width: 80, height: 3},
               status: %Rect{x: 0, y: 23, width: 80, height: 1}
             }
    end

    test "gives the transcript what a taller status band leaves" do
      panes = Layout.panes(@frame, %{input: 3, status: 2})

      assert panes.transcript.height == 19
      assert panes.input.y == 19
      assert panes.status == %Rect{x: 0, y: 22, width: 80, height: 2}
    end

    test "keeps the input on a frame too short for anything else" do
      panes = Layout.panes(%{width: 40, height: 2}, @needs)

      assert panes.input == %Rect{x: 0, y: 0, width: 40, height: 2}
      assert panes.status.height == 0
      assert panes.transcript.height == 0
      assert Layout.check(panes, %{width: 40, height: 2}) == :ok
    end

    test "passes its own check on every size" do
      for width <- [1, 3, 40, 200], height <- [1, 2, 3, 4, 10, 24, 60], status <- [1, 2, 5] do
        frame = %{width: width, height: height}
        assert Layout.check(Layout.panes(frame, %{input: 3, status: status}), frame) == :ok
      end
    end

    test "is the input height the screen reserves" do
      assert Layout.input_height() == 3
      assert Layout.input_height("abcd abcd abcd", 10) == 5
      assert Layout.input_height("one\ntwo\nthree\nfour\nfive\nsix", 80) == 7
    end
  end

  describe "arrange/3" do
    test "the shipped module is the shipped arrangement" do
      assert {:ok, panes} = Layout.arrange(Layout, @frame, @needs)
      assert panes == Layout.panes(@frame, @needs)
      assert Layout.module(nil) == Layout
    end

    test "a host's arrangement that keeps the rules is drawn as it is" do
      assert {:ok, panes} = Layout.arrange(InputOnTop, @frame, @needs)

      assert panes.input.y == 0
      assert panes.status.y == 3
      assert panes.transcript == %Rect{x: 0, y: 4, width: 80, height: 20}
    end

    test "one that overlaps falls back to the shipped arrangement, and says why" do
      assert {:fallback, panes, reason} = Layout.arrange(Overlapping, @frame, @needs)

      assert panes == Layout.panes(@frame, @needs)
      assert reason =~ "Overlapping"
      assert reason =~ "transcript"
      assert reason =~ "overlap"
    end
  end

  describe "check/2" do
    defp shipped, do: Layout.panes(@frame, @needs)

    test "a pane outside the frame" do
      panes = %{shipped() | input: %Rect{x: 0, y: 22, width: 80, height: 3}}
      assert {:error, reason} = Layout.check(panes, @frame)
      assert reason =~ "input"
      assert reason =~ "outside"

      wide = %{shipped() | status: %Rect{x: 1, y: 20, width: 80, height: 1}}
      assert {:error, _reason} = Layout.check(wide, @frame)

      negative = %{shipped() | transcript: %Rect{x: -1, y: 0, width: 80, height: 20}}
      assert {:error, _reason} = Layout.check(negative, @frame)
    end

    test "a negative size" do
      panes = %{shipped() | transcript: %Rect{x: 0, y: 0, width: 80, height: -1}}
      assert {:error, reason} = Layout.check(panes, @frame)
      assert reason =~ "transcript"
    end

    test "an input with no room to type in" do
      flat = %{shipped() | input: %Rect{x: 0, y: 21, width: 80, height: 0}}
      assert {:error, reason} = Layout.check(flat, @frame)
      assert reason =~ "input"
      assert reason =~ "row"

      narrow = %{shipped() | input: %Rect{x: 0, y: 21, width: 0, height: 3}}
      assert {:error, _reason} = Layout.check(narrow, @frame)
    end

    test "two panes sharing a cell" do
      panes = %{shipped() | status: %Rect{x: 0, y: 19, width: 80, height: 2}}
      assert {:error, reason} = Layout.check(panes, @frame)
      assert reason =~ "overlap"
      assert reason =~ "transcript"
      assert reason =~ "status"
    end

    test "panes that touch without sharing are fine, and so are gaps" do
      gapped = %{shipped() | transcript: %Rect{x: 0, y: 0, width: 80, height: 10}}
      assert Layout.check(gapped, @frame) == :ok

      side_by_side = %{
        transcript: %Rect{x: 0, y: 0, width: 50, height: 24},
        status: %Rect{x: 50, y: 0, width: 30, height: 1},
        input: %Rect{x: 50, y: 1, width: 30, height: 23}
      }

      assert Layout.check(side_by_side, @frame) == :ok
    end

    test "an empty pane cannot overlap anything" do
      panes = %{shipped() | status: %Rect{x: 0, y: 0, width: 80, height: 0}}
      assert Layout.check(panes, @frame) == :ok
    end

    test "something that is not three rects" do
      assert {:error, reason} = Layout.check(%{transcript: shipped().transcript}, @frame)
      assert reason =~ "three"

      assert {:error, reason} = Layout.check([shipped().transcript], @frame)
      assert reason =~ "three"

      assert {:error, reason} =
               Layout.check(%{shipped() | input: %{x: 0, y: 21, width: 80, height: 3}}, @frame)

      assert reason =~ "input"
    end
  end
end
