defmodule Lemieux.TUI.BlocksTest do
  @moduledoc """
  Recognising Markdown blocks in an answer that arrives one fragment at a
  time.

  Every test drives the same three functions the screen does — `open/2` for
  a line that has just begun, `extend/2` for text streamed onto it, and
  `close/2` once the next line has started — because a block that is only
  right when the whole answer is known would be wrong on the screen, where
  the whole answer is never known until the end.
  """

  use ExUnit.Case, async: true

  alias Lemieux.TUI.Blocks
  alias Lemieux.TUI.Theme

  @theme Theme.default()

  # Streams `text` line by line into a newest-first transcript, exactly as
  # `Lemieux.TUI` does on `{:write, …}`, and leaves the last line open.
  defp stream(text, lines \\ []) do
    text
    |> String.split("\n")
    |> Enum.reduce(lines, fn line, acc ->
      acc = closed(acc)
      [Blocks.open(List.first(acc), line) | acc]
    end)
  end

  defp closed(lines) do
    {count, rows} = Blocks.close(lines, @theme)
    rows ++ Enum.drop(lines, count)
  end

  defp finished(text), do: text |> stream() |> closed() |> Enum.reverse()

  defp spans_text(spans), do: Enum.map_join(spans, & &1.content)

  describe "a line being written" do
    test "is a paragraph line until it closes, whatever it will turn out to be" do
      assert Blocks.open(nil, "# not yet") == {:model, "# not yet"}
      assert Blocks.open({:model, "above"}, "``") == {:model, "``"}
      assert Blocks.open?({:model, "``"})
    end

    test "grows by exactly the text streamed onto it" do
      line = Blocks.open(nil, "the code")
      assert Blocks.extend(line, "word is") == {:model, "the codeword is"}
    end

    test "inside a fence it is code from the first character, not a paragraph" do
      [fence | _rest] = stream("```elixir\n") |> Enum.reverse() |> Enum.reverse()
      assert {:model_code, "elixir", "", nil} = fence
      assert Blocks.open?(fence)

      grown = Blocks.extend(fence, "x = a * b")
      assert grown == {:model_code, "elixir", "x = a * b", nil}
    end

    test "a tab in code is drawn as spaces because a span cannot measure one" do
      [line | _rest] = stream("```\n\tindented")
      assert {:model_code, nil, "    indented", nil} = line
    end
  end

  describe "closing a line" do
    test "leaves plain text alone" do
      assert Blocks.close([{:model, "just words"}], @theme) == {1, [{:model, "just words"}]}
    end

    test "is a no-op on anything that is not a line being written" do
      assert Blocks.close([{:you, "typed"}], @theme) == {0, []}
      assert Blocks.close([], @theme) == {0, []}
      assert Blocks.close([{:model_heading, 1, "done"}], @theme) == {0, []}
    end

    test "recognises headings, quotes, rules and list items" do
      assert finished("## The plan") == [{:model_heading, 2, "The plan"}]
      assert finished("# Title ##") == [{:model_heading, 1, "Title"}]
      assert finished("#hashtag") == [{:model, "#hashtag"}]
      assert finished("> quoted words") == [{:model_quote, "quoted words"}]
      assert finished(">bare") == [{:model_quote, "bare"}]
      assert finished("---") == [{:model_rule, ""}]
      assert finished("* * *") == [{:model_rule, ""}]
      assert finished("- first") == [{:model_item, 0, "-", "first"}]
      assert finished("  * nested") == [{:model_item, 2, "*", "nested"}]
      assert finished("12. twelfth") == [{:model_item, 0, "12.", "twelfth"}]
    end

    test "an asterisk with no space after it is emphasis, not a bullet" do
      assert finished("*emphasis* here") == [{:model, "*emphasis* here"}]
    end
  end

  describe "a fenced block" do
    test "opens on the fence and its language, and closes on the matching fence" do
      rows = finished("```elixir\ndef f, do: 1\n```")

      assert [
               {:model_fence, :open, "elixir", "```"},
               {:model_code, "elixir", "def f, do: 1", spans},
               {:model_fence, :close, "elixir", "```"}
             ] = rows

      assert spans_text(spans) == "def f, do: 1"
      # Highlighted: `def` is a keyword, so it does not share the colour of
      # what follows it.
      assert length(spans) > 1
    end

    test "lines are highlighted as they close, before the block does" do
      lines = stream("```elixir\ndef f, do: 1\n")

      assert [
               {:model_code, "elixir", "", nil},
               {:model_code, "elixir", "def f, do: 1", spans} | _
             ] =
               lines

      assert is_list(spans)
    end

    test "closing re-highlights the block as one source" do
      # A heredoc body is a string only if the highlighter saw the opening
      # quotes on the line before it. Line by line it is a bare word.
      lines = stream("```elixir\n\"\"\"\nbody")
      lines = closed(lines)
      [{:model_code, "elixir", "body", alone} | _rest] = lines

      rows = closed(stream("```", lines))

      assert [{:model_fence, :close, "elixir", "```"}, {:model_code, "elixir", "body", whole} | _] =
               rows

      assert spans_text(alone) == "body"
      assert spans_text(whole) == "body"
      refute Enum.map(alone, & &1.style.fg) == Enum.map(whole, & &1.style.fg)
    end

    test "a shorter fence inside a longer one is code, not the end" do
      rows = finished("````markdown\n```elixir\n````")

      assert [
               {:model_fence, :open, "markdown", "````"},
               {:model_code, "markdown", "```elixir", _spans},
               {:model_fence, :close, "markdown", "````"}
             ] = rows
    end

    test "a tilde fence is not closed by backticks" do
      rows = finished("~~~\n```\n~~~")

      assert [
               {:model_fence, :open, nil, "~~~"},
               {:model_code, nil, "```", _spans},
               {:model_fence, :close, nil, "~~~"}
             ] = rows
    end

    test "the info string's first word is the language, folded onto what the highlighter knows" do
      assert [{:model_fence, :open, "bash", _} | _] = finished("```sh title=x")
      assert [{:model_fence, :open, "bash", _} | _] = finished("```console")
      assert [{:model_fence, :open, nil, _} | _] = finished("```text")
      assert [{:model_fence, :open, "elixir", _} | _] = finished("```heex")
      assert [{:model_fence, :open, "diff", _} | _] = finished("```patch")
      assert [{:model_fence, :open, "rust", _} | _] = finished("```Rust")
    end

    test "a diff is coloured by its own rule: added green, removed red" do
      rows = finished("```diff\n+added\n-removed\n@@ -1 +1 @@\n context\n```")

      colours =
        for {:model_code, "diff", _text, spans} <- rows, do: Enum.map(spans, & &1.style.fg)

      assert colours == [
               [@theme.blocks.add],
               [@theme.blocks.delete],
               [@theme.blocks.code],
               [@theme.text.muted]
             ]
    end

    test "the mono theme leaves code uncoloured rather than highlighted and then discarded" do
      rows = Blocks.rows("```elixir\ndef f, do: 1\n```", Theme.mono())

      assert [_open, {:model_code, "elixir", "def f, do: 1", [span]}, _close] = rows
      assert span.style.fg == nil
    end

    test "an empty line inside a block is an empty row, still inside the block" do
      rows = finished("```\n\nafter\n```")

      assert [
               _open,
               {:model_code, nil, "", []},
               {:model_code, nil, "after", _spans},
               _close
             ] = rows
    end

    test "a block that never closes stays a block" do
      rows = finished("```elixir\ndef f")

      assert [{:model_fence, :open, "elixir", "```"}, {:model_code, "elixir", "def f", spans}] =
               rows

      assert is_list(spans)
    end
  end

  describe "a table" do
    test "is one row, grown a line at a time, with a header once the delimiter arrives" do
      rows = finished("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |")

      assert rows == [
               {:model_table,
                %{header: ["a", "b"], aligns: [:left, :centre], rows: [["1", "2"], ["3", "4"]]}}
             ]
    end

    test "grows while it streams, so the rows above the open line are already a table" do
      lines = stream("| a | b |\n|---|---|\n| 1 |")

      assert [{:model, "| 1 |"}, {:model_table, %{header: ["a", "b"], rows: []}}] = lines
    end

    test "without a delimiter it is a headerless table" do
      assert finished("| x | y |\n| 1 | 2 |") ==
               [{:model_table, %{header: nil, aligns: nil, rows: [["x", "y"], ["1", "2"]]}}]
    end

    test "a delimiter with nothing to describe is the text it looks like" do
      assert finished("|---|---|") == [{:model, "|---|---|"}]
    end

    test "a second delimiter row does not make a second header" do
      rows = finished("| a |\n|---|\n| 1 |\n|---|")
      assert [{:model_table, %{header: ["a"], rows: [["1"]]}}, {:model, "|---|"}] = rows
    end

    test "an escaped pipe is a character in a cell, not a column" do
      assert [{:model_table, %{rows: [["a|b", "c"]]}}] = finished("| a\\|b | c |")
    end

    test "a paragraph after the table starts fresh" do
      rows = finished("| a |\n| 1 |\nthen words")
      assert [{:model_table, %{rows: [["a"], ["1"]]}}, {:model, "then words"}] = rows
    end
  end

  describe "a whole answer" do
    test "is classified as the stream would have classified it" do
      text = "# Plan\n\n- do a\n- do b\n\n```elixir\n:ok\n```\n\n> note\n\ndone"

      assert Blocks.rows(text, @theme) == finished(text)

      assert [
               {:model_heading, 1, "Plan"},
               {:model, ""},
               {:model_item, 0, "-", "do a"},
               {:model_item, 0, "-", "do b"},
               {:model, ""},
               {:model_fence, :open, "elixir", "```"},
               {:model_code, "elixir", ":ok", _spans},
               {:model_fence, :close, "elixir", "```"},
               {:model, ""},
               {:model_quote, "note"},
               {:model, ""},
               {:model, "done"}
             ] = Blocks.rows(text, @theme)
    end

    test "every row it produces is a row of the model's answer" do
      rows = Blocks.rows("# h\n> q\n- i\n---\n| t |\n```\nc\n```\np", @theme)

      assert rows != []
      assert Enum.all?(rows, &Blocks.model_row?/1)
      refute Blocks.model_row?({:you, "typed"})
      refute Blocks.model_row?({:tool_heading, "id", :run, "Ran", "ls"})
    end
  end
end
