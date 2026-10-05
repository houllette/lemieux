defmodule Lemieux.Conversation.ShellInvalidUTF8Test do
  @moduledoc """
  A person's own command that prints bytes which are not UTF-8 — `!cat` of a
  Latin-1 file — and an editor that saves them. Both used to reach the
  screen's Unicode regex or the input widget as they came, which raised in
  the screen's process and took `lmx` down with it.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Shell
  alias Lemieux.Environment
  alias Lemieux.TUI

  @moduletag :tmp_dir

  # `caf\351 cr\350me`: "café crème" in Latin-1.
  @latin1 "printf 'caf\\351 cr\\350me\\n'"

  defp latin1_result(dir) do
    assert {:ok, result} = Shell.run(Environment.local(), @latin1, dir)
    result
  end

  test "a command's output is repaired to UTF-8, each bad byte a replacement character",
       %{tmp_dir: dir} do
    result = latin1_result(dir)

    assert String.valid?(result.output)
    assert result.output == "caf� cr�me\n"
    assert String.valid?(Shell.display(result))
    assert String.valid?(Shell.context(result))
  end

  test "the screen shows it, and the note it leaves makes a valid next prompt",
       %{tmp_dir: dir} do
    result = latin1_result(dir)

    assert {:noreply, state} =
             TUI.handle_info({:shell_result, @latin1, {:ok, result}}, sized(tui()))

    assert screen(state) =~ "caf� cr�me"

    {_conversation, effects} = Conversation.input(state.conversation, "what does it say?")
    assert [{:prompt, text}] = effects
    assert String.valid?(text)
    assert text =~ "caf�"
  end

  test "an editor that saves Latin-1 leaves valid text in the box" do
    editor = fn _draft -> {:ok, <<"caf", 0xE9>>} end
    state = tui(editor: editor) |> type("draft") |> press("g", ["ctrl"])

    assert typed(state) == "caf�"
  end
end
