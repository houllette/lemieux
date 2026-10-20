defmodule Lemieux.TUI.TaskTextTest do
  use ExUnit.Case, async: true
  alias Lemieux.TUI.{TaskText, Theme, Width}

  test "source keeps literal whitespace and complete wide characters when wrapped" do
    source = "printf 'a    b';    echo 長いコマンド"

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      lines = TaskText.lines(source, :command, :command, 12, theme)
      assert Enum.map_join(lines, &text/1) == source
      assert Enum.all?(lines, &(Width.of(text(&1)) <= 12))
      assert hd(hd(lines).spans).style.fg == theme.blocks.code
    end
  end

  test "warnings errors and success have distinct semantic styles and monochrome emphasis" do
    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      [info, warning, error, success] =
        TaskText.lines(
          "INFO: reading\nWARNING: slow\nERROR: missing\nPASS build",
          :output,
          :command,
          80,
          theme
        )

      assert hd(warning.spans).style.fg == theme.children.warn
      assert hd(error.spans).style.fg == theme.children.fail
      assert hd(success.spans).style.fg == theme.children.ok
      assert :bold in hd(error.spans).style.modifiers
      refute hd(info.spans).style == hd(warning.spans).style
      assert text(error) == "ERROR: missing"
    end
  end

  test "agent answers keep paragraphs and render headings emphasis and inline code" do
    for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
      lines =
        TaskText.lines("# Result\n\n**Verified** using `git status`", :output, :agent, 80, theme)

      assert Enum.map(lines, &text/1) == ["Result", "", "Verified using git status"]
      spans = Enum.flat_map(lines, & &1.spans)
      assert Enum.any?(spans, &(:bold in &1.style.modifiers))

      unless is_nil(theme.blocks.code_bg) do
        assert Enum.any?(
                 spans,
                 &(&1.content == "git status" and &1.style.bg == theme.blocks.code_bg)
               )
      end
    end
  end

  defp text(line), do: Enum.map_join(line.spans, & &1.content)
end
