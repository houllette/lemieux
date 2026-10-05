defmodule Lemieux.TUI.HeadlessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.TUI
  alias Lemieux.TUI.Callbacks
  alias Lemieux.TUI.Notify

  describe "a screen on ExRatatui's headless test terminal" do
    test "has inert local effects, so nothing reaches the terminal or clipboard running it" do
      state = TUI.new(id: "01HEADLESS", model: "test:model", test_mode: {80, 24})

      assert state.terminal.notify == (&Callbacks.inert/1)
      assert state.terminal.clipboard == (&Callbacks.inert/1)
      assert state.terminal.editor == nil
      assert state.terminal.paste_image == nil

      # A long turn finishing is exactly when a live screen notifies; here
      # nothing may be written to the stream the test runner owns.
      assert capture_io(fn -> Notify.finished(state, 60) end) == ""
    end

    test "still takes a callback a test passes explicitly" do
      test = self()
      notify = fn text -> send(test, {:notified, text}) end

      state = TUI.new(id: "01HEADLESS", model: "test:model", test_mode: {80, 24}, notify: notify)
      Notify.finished(state, 60)

      assert_received {:notified, "lmx: finished (60s)"}
    end
  end

  describe "a terminal that reports no size" do
    test "renders instead of failing every frame" do
      state = TUI.new(id: "01NOSIZE", model: "test:model", test_mode: {80, 24})

      assert [_ | _] = TUI.render(state, %ExRatatui.Frame{width: 0, height: 0})
    end
  end

  describe "a screen on a real local terminal" do
    test "keeps the live defaults" do
      state = TUI.new(id: "01LIVE", model: "test:model")

      refute state.terminal.notify == (&Callbacks.inert/1)
      refute state.terminal.clipboard == (&Callbacks.inert/1)
      assert is_function(state.terminal.editor, 1)
      assert is_function(state.terminal.paste_image, 0)
    end
  end
end
