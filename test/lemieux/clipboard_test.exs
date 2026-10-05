defmodule Lemieux.ClipboardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.Clipboard

  test "encodes text as an OSC 52 clipboard sequence" do
    assert Clipboard.sequence("one\ntwo") == "\e]52;c;b25lCnR3bw==\a"
  end

  test "writes OSC 52 to a local terminal with no clipboard tool, and to a byte stream" do
    # Linux with neither Wayland nor X11: nothing native to copy with.
    assert capture_io(fn ->
             assert :ok = Clipboard.copy("local", :local, os: {:unix, :linux}, env: %{})
           end) == Clipboard.sequence("local")

    owner = self()

    writer = fn bytes ->
      send(owner, {:clipboard_bytes, IO.iodata_to_binary(bytes)})
      :ok
    end

    assert :ok = Clipboard.copy("remote", {:session, :session, writer})
    assert_receive {:clipboard_bytes, bytes}
    assert bytes == Clipboard.sequence("remote")
  end

  test "does not write clipboard bytes to an unrelated transport" do
    assert {:error, :unsupported_transport} = Clipboard.copy("text", :distributed)
  end

  describe "the local machine's clipboard tool" do
    test "is never used over SSH, where it would fill the wrong machine's clipboard" do
      assert Clipboard.native_tool({:unix, :darwin}, %{"SSH_CONNECTION" => "1.2.3.4 5 6.7.8.9 22"}) ==
               :none

      assert Clipboard.native_tool({:unix, :linux}, %{
               "SSH_TTY" => "/dev/ttys001",
               "DISPLAY" => ":0"
             }) ==
               :none
    end

    test "is not guessed at on a platform it does not know" do
      assert Clipboard.native_tool({:win32, :nt}, %{}) == :none
      assert Clipboard.native_tool({:unix, :linux}, %{}) == :none
    end

    test "copies through the tool when there is one, and writes nothing to the terminal" do
      owner = self()

      native = fn tool, text ->
        send(owner, {:native, tool, text})
        :ok
      end

      output =
        capture_io(fn ->
          assert :ok =
                   Clipboard.copy("copied", :local,
                     os: {:unix, :darwin},
                     env: %{},
                     native: native
                   )
        end)

      case Clipboard.native_tool({:unix, :darwin}, %{}) do
        {:ok, tool} ->
          assert_received {:native, ^tool, "copied"}
          assert output == ""

        :none ->
          # No pbcopy on this machine: OSC 52 is the only way.
          assert output == Clipboard.sequence("copied")
      end
    end

    test "falls back to OSC 52 when the tool fails" do
      native = fn _tool, _text -> {:error, {:exit_status, 1}} end

      output =
        capture_io(fn ->
          assert :ok =
                   Clipboard.copy("again", :local, os: {:unix, :darwin}, env: %{}, native: native)
        end)

      assert output == Clipboard.sequence("again")
    end
  end
end
