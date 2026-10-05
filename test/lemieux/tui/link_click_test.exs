defmodule Lemieux.TUI.LinkClickTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Event.Mouse
  alias Lemieux.TUI

  # A modifier on a click changes nothing about a link: it opens on release,
  # so a drag that starts on one still selects. Super+click used to open on
  # the press instead, a path no terminal could reach: mouse reports carry
  # Shift, Alt and Ctrl, and no bit for Super.
  test "a link opens on release whatever modifier the press reports" do
    owner = self()
    opener = fn target -> send(owner, {:opened, target}) end
    state = sized(tui(lines: [{:model, "Visit https://example.com/guide"}], open_link: opener))

    for modifiers <- [["super"], ["ctrl"], []] do
      assert {:noreply, pressed} =
               TUI.handle_event(
                 %Mouse{kind: "down", button: "left", x: 9, y: 1, modifiers: modifiers},
                 state
               )

      assert {"https://example.com/guide", _point} = pressed.terminal.link_press

      assert {:noreply, released} =
               TUI.handle_event(
                 %Mouse{kind: "up", button: "left", x: 9, y: 1, modifiers: modifiers},
                 pressed
               )

      assert_receive {:opened, "https://example.com/guide"}
      assert released.terminal.link_press == nil
    end
  end
end
