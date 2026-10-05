defmodule Lemieux.TUI.TtyTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Tty

  test "what ps prints becomes the device's path, and no terminal is nil" do
    assert Tty.device_path("ttys003\n") == "/dev/ttys003"
    assert Tty.device_path("pts/2") == "/dev/pts/2"
    assert Tty.device_path("/dev/pts/2") == "/dev/pts/2"

    for none <- ["??", "?", "", " \n", "-"] do
      assert Tty.device_path(none) == nil
    end
  end

  # What Linux's /proc says a descriptor points at. `/dev/tty` is the one
  # name a command the VM starts cannot open, so it is never the answer.
  test "a descriptor's link names the terminal when it is one" do
    assert Tty.terminal_link("/dev/pts/2") == "/dev/pts/2"
    assert Tty.terminal_link("/dev/tty1") == "/dev/tty1"
    assert Tty.terminal_link("/dev/ttyS0") == "/dev/ttyS0"

    for none <- ["/dev/tty", "pipe:[40213]", "socket:[99]", "/dev/null", "/tmp/out.log"] do
      assert Tty.terminal_link(none) == nil
    end
  end
end
