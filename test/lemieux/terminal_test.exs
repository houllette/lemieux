defmodule Lemieux.TerminalTest do
  use ExUnit.Case, async: true

  alias Lemieux.Terminal

  test "a title is an OSC 0 sequence, so it sets the tab as well as the window" do
    assert Terminal.sequence("lmx | holden-gretzky") == "\e]0;lmx | holden-gretzky\a"
  end

  # The text comes from `/name`, which is whatever somebody typed. A BEL ends
  # the sequence early and the rest of it lands on the screen as garbage the
  # drawing code does not know is there.
  test "control characters cannot break out of the sequence" do
    assert Terminal.sequence("lmx | a\ab\e]0;c\nd") == "\e]0;lmx | ab]0;cd\a"
  end

  test "an empty title clears it, leaving the shell free to set its own" do
    assert Terminal.sequence("") == "\e]0;\a"
  end

  test "a byte-stream transport is written through its own writer" do
    parent = self()

    assert Terminal.title(
             "lmx | holden-gretzky",
             {:session, :ignored,
              fn bytes ->
                send(parent, {:wrote, IO.iodata_to_binary(bytes)})
                :ok
              end}
           ) == :ok

    assert_receive {:wrote, "\e]0;lmx | holden-gretzky\a"}
  end

  # The title belongs to the terminal showing the interface. A transport with
  # no stream to write to has no terminal here to retitle, and guessing at
  # this OS process's own tty would retitle the wrong machine's window.
  test "a transport with nowhere to write says so rather than retitling stdio" do
    assert Terminal.title("lmx", :cell) == {:error, :unsupported_transport}
    assert Terminal.title("lmx", {:distributed, :node@host}) == {:error, :unsupported_transport}
  end

  test "a writer that fails or misbehaves is reported rather than raised" do
    assert Terminal.title("lmx", {:session, nil, fn _bytes -> {:error, :closed} end}) ==
             {:error, :closed}

    assert Terminal.title("lmx", {:session, nil, fn _bytes -> :whatever end}) ==
             {:error, {:unexpected_writer_result, :whatever}}

    assert {:error, message} =
             Terminal.title("lmx", {:session, nil, fn _bytes -> raise "the pipe went away" end})

    assert message =~ "the pipe went away"
  end

  describe "a notification" do
    test "is OSC 9 with the text, then a bell for the terminals that ignore it" do
      assert Terminal.notification("lmx: finished (40s)") == "\e]9;lmx: finished (40s)\a\a"
    end

    test "cannot break out of its sequence either" do
      assert Terminal.notification("done\a\e]9;x") == "\e]9;done]9;x\a\a"
    end

    test "goes through a byte-stream transport's writer, and nowhere for others" do
      parent = self()

      writer = fn bytes ->
        send(parent, {:wrote, IO.iodata_to_binary(bytes)})
        :ok
      end

      assert :ok = Terminal.notify("waiting", {:session, :ignored, writer})
      assert_received {:wrote, "\e]9;waiting\a\a"}
      assert {:error, :unsupported_transport} = Terminal.notify("waiting", :distributed)
    end
  end
end
