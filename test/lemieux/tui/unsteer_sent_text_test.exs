defmodule Lemieux.TUI.UnsteerSentTextTest do
  @moduledoc """
  `/unsteer` and Alt-Z take a steer back by the text the session holds,
  which is the line trimmed and with any pending note ahead of it — not the
  text the row shows. Revoking with the row's text never matched, so the
  steer was reported sent and went out with the next request anyway.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Event.Paste
  alias Lemieux.Conversation
  alias Lemieux.TUI

  defp working do
    session = fake_session(snapshot("01SESSION"))
    state = tui(session: session) |> sized()
    %{state | conversation: %{state.conversation | busy?: true}}
  end

  defp pending?(state), do: Enum.any?(state.lines, &match?({:steer, :pending, _text}, &1))

  test "a steer typed with trailing whitespace is revoked" do
    pending = working() |> type("do this first ") |> press("enter")
    assert_receive {:steered, "do this first"}

    revoked = command(pending, "/unsteer")

    refute pending?(revoked)
    assert screen(revoked) =~ "steer revoked before the next model request"
    refute screen(revoked) =~ "already sent"
  end

  test "a pasted steer ending in a newline is revoked with Alt-Z" do
    {:noreply, pasted} = TUI.handle_event(%Paste{content: "fix the tests\n"}, working())
    pending = press(pasted, "enter")
    assert_receive {:steered, "fix the tests"}

    revoked = press(pending, "z", ["alt"])

    refute pending?(revoked)
    assert status_row(revoked) =~ "steer revoked"
  end

  test "a steer that carried a !command's note is revoked with the note" do
    state = working()
    noted = %{state | conversation: Conversation.note_for_next(state.conversation, "[note] $ ls")}

    pending = noted |> type("stop") |> press("enter")
    assert_receive {:steered, "[note] $ ls\n\nstop"}

    revoked = command(pending, "/unsteer")

    refute pending?(revoked)
    assert screen(revoked) =~ "steer revoked before the next model request"
    assert revoked.tools.sent_steers == []

    # Nothing is left with the session to deliver: a second revoke finds
    # nothing waiting rather than a steer already sent.
    assert screen(command(revoked, "/unsteer")) =~ "no steer is waiting"
  end

  test "a steer typed under a running tool call is revoked from where it waits" do
    call = %{id: "bash-1", name: "bash", arguments: %{"command" => "sleep 30"}}
    called = info(working(), {:tool_call, call})

    deferred = called |> type("use the other path ") |> press("enter")
    assert_receive {:steered, "use the other path"}
    assert deferred.tools.deferred_steer == {:pending, "use the other path "}

    revoked = command(deferred, "/unsteer")

    assert revoked.tools.deferred_steer == nil
    assert screen(revoked) =~ "steer revoked before the next model request"
  end
end
