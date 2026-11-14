defmodule Lemieux.TUI.SnippetsTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias Lemieux.TUI.{Blocks, RichText, Selection, Theme, Transcript}

  test "selection omits frames, rejoins wrapping and retains source whitespace" do
    source = "\tbox ─ 42\n\n  中🙂 with a long tail  "
    rows = Blocks.rows("```text\n" <> source <> "\n```", Theme.dark()) |> RichText.lines(12)
    view = %{rows: rows, bottom: 0}
    selection = Selection.start({length(rows) - 1, 0}) |> Selection.extend({0, 40})
    assert Selection.text(selection, view) == source
    refute Selection.text(selection, view) =~ "╭─ text"
  end

  test "a release copies the full block and a drag copies only its selected source" do
    owner = self()

    state =
      tui(
        clipboard: fn text ->
          send(owner, {:copied, text})
          :ok
        end
      )
      |> sized()
      |> Transcript.say(:model, "before\n```text\n  hello\nworld\n```\nafter")
      |> Transcript.finish_line()

    # The frame is clickable, but contributes no characters to a drag.
    clicked = events(state, [{"down", 4, 2}, {"up", 4, 2}])
    assert_receive {:copied, "  hello\nworld"}
    assert clicked.terminal.feedback.text =~ "copied 13 characters"
    _dragged = events(state, [{"down", 3, 3}, {"drag", 7, 3}, {"up", 7, 3}])
    assert_receive {:copied, "hello"}
  end

  test "an unfinished block copies only the source currently available" do
    owner = self()

    state =
      tui(
        clipboard: fn text ->
          send(owner, {:copied, text})
          :ok
        end
      )
      |> sized()
      |> Transcript.say(:model, "```markdown\n# partial")

    _clicked = events(state, [{"down", 3, 1}, {"up", 3, 1}])
    assert_receive {:copied, "# partial"}
  end

  test "adjacent blocks, literal fences and a narrow wrapped block keep their own source" do
    alias Lemieux.TUI.Snippets
    source = "  中🙂 long source\n```literal\n\tend  "
    rows = Blocks.rows("````markdown\n" <> source <> "\n````\n```text\nother\n```", Theme.dark())
    renderer = &RichText.lines([&1], 10)
    assert {:snippet, _, "other"} = Snippets.at(Enum.reverse(rows), {1, 0}, renderer)
    assert {:snippet, _, ^source} = Snippets.at(Enum.reverse(rows), {4, 0}, renderer)
    [wide] = RichText.lines([{:model_code, nil, "中🙂", nil}], 10)
    selection = Selection.start({0, 2}) |> Selection.extend({0, 3})
    assert Selection.text(selection, %{rows: [wide], bottom: 0}) == "🙂"
  end

  test "a whole-block clipboard failure never shows successful copy feedback" do
    state =
      tui(clipboard: fn _text -> {:error, :unsupported_transport} end)
      |> sized()
      |> Transcript.say(:model, "```text\nsource\n```")
      |> Transcript.finish_line()

    failed = events(state, [{"down", 3, 1}, {"up", 3, 1}])
    assert screen(failed) =~ "no clipboard"
    refute screen(failed) =~ "copied 6 characters"
  end
end
