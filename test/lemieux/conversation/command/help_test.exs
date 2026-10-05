defmodule Lemieux.Conversation.Command.HelpTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Conversation.Command.Help
  alias Lemieux.Conversation.Command.Permissions
  alias Lemieux.Conversation.Dispatch

  doctest Help

  # What the screen said, oldest first, as one text.
  defp lmx_text(state) do
    state.lines
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:lmx, text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  describe "the terminal UI's /help" do
    # It printed the key map's grammar: "back_tab, shift-back_tab  cycle
    # mode" and "page_up  page up".
    test "names keys as a person says them" do
      text = tui() |> command("/help") |> lmx_text()

      assert text =~ ~r/shift-tab\s+cycle permission modes \(on with --permission-mode ask\)/
      assert text =~ ~r/page up\s+scroll the transcript a page up/
      assert text =~ ~r/page down\s+scroll the transcript a page down/
      refute text =~ "back_tab"
      refute text =~ "page_up"
    end

    test "ends with where the docs are and where to ask" do
      text = tui() |> command("/help") |> lmx_text()

      assert text =~ ~r/docs\s+https:\/\/hexdocs\.pm\/lemieux/
      assert text =~ ~r/issues\s+https:\/\/github\.com\/houllette\/lemieux\/issues/
      assert text =~ ~r/questions\s+https:\/\/github\.com\/houllette\/lemieux\/discussions/
    end
  end

  describe "with permissions off" do
    test "shift-tab says how to turn them on" do
      state = press(tui(), "back_tab")

      assert state.terminal.feedback.text =~ "permissions are off"
      assert state.terminal.feedback.text =~ "--permission-mode ask"
    end

    test "/permissions names the flag before the config key" do
      unused = fn said, _other -> said end

      host =
        Dispatch.new(
          say: fn said, text -> [text | said] end,
          write: unused,
          fold: unused,
          run: unused,
          react: unused,
          permissions: nil
        )

      [text] = Permissions.perform([], host, :permissions_status)

      assert text =~ "permissions are off in this session"
      assert text =~ "start lmx with --permission-mode ask to be asked first"
      assert text =~ "\"permissions\" in ~/.lmx/config.json"
    end
  end

  describe "key_label/1" do
    test "leaves modifiers and plain keys as they are" do
      assert Help.key_label("ctrl-c") == "ctrl-c"
      assert Help.key_label("alt-1") == "alt-1"
      assert Help.key_label("ctrl-shift-back_tab") == "ctrl-shift-tab"
      assert Help.key_label("ctrl-back_tab") == "ctrl-shift-tab"
    end

    # `_` and `-` are keys too; only a named key's underscores are spaces.
    test "a punctuation key keeps its character" do
      assert Help.key_label("ctrl-_") == "ctrl-_"
      assert Help.key_label("_") == "_"
      assert Help.key_label("ctrl--") == "ctrl--"
      assert Help.key_label("alt-caps_lock") == "alt-caps lock"
    end
  end
end
