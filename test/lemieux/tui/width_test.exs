defmodule Lemieux.TUI.WidthTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI.Layout
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.Width
  alias Lemieux.TUI.Window

  @cjk "你好，世界！这是一个测试。日本語のテキストも表示します。한국어 텍스트입니다."

  test "counts columns, not graphemes" do
    assert Width.of("abc") == 3
    assert Width.of("你好") == 4
    assert Width.of("ＡＢＣ") == 6
    assert Width.of("한국어") == 6
    assert Width.of("🙂") == 2
    assert Width.of("👍🏽") == 2
    assert Width.of("🇨🇦") == 2
    assert Width.of("❤️") == 2
    assert Width.of("❤") == 1
  end

  # The renderer is the authority: a row this module measures narrower than
  # the renderer draws it loses its last characters off the edge. Each sample
  # is drawn between two markers on a real (headless) terminal buffer, and the
  # cells between them are the renderer's answer.
  test "agrees with the columns the renderer actually draws" do
    samples = [
      "x",
      "你",
      "Ａ",
      "한",
      "🙂",
      "👍🏽",
      "☝🏽",
      "☝",
      "🇨🇦",
      "🇨",
      "❤️",
      "❤",
      "🌡",
      "🌡️",
      "⌚\u{FE0E}",
      "䷀",
      "☰",
      "👨‍👩‍👧",
      "🏳️‍🌈",
      "é",
      "1\u{FE0F}⃣",
      "각"
    ]

    for sample <- samples do
      assert Width.of(sample) == drawn_width(sample),
             "#{inspect(sample)}: measured #{Width.of(sample)}, drawn #{drawn_width(sample)}"
    end
  end

  test "fit/3 walks a list of items through an accessor, and always makes progress" do
    styled = Enum.map(String.graphemes("ab你好"), &{&1, :style})

    assert Width.fit(styled, 4, &elem(&1, 0)) == 3
    assert Width.fit(styled, 5, &elem(&1, 0)) == 3
    assert Width.fit(styled, 6, &elem(&1, 0)) == 4
    # Wider than the whole row: one grapheme anyway, so a wrapper loops on.
    assert Width.fit(["你"], 1) == 1
    assert Width.fit([], 5) == 0
  end

  test "a CJK line that needs wrapping keeps every character and fits its rows" do
    for width <- [10, 39, 40, 50, 60, 70] do
      rows = Window.wrap(@cjk, width)
      assert Enum.all?(rows, &(Width.of(&1) <= width)), "a row overflowed #{width} columns"

      assert rows |> Enum.join() |> String.replace(" ", "") == String.replace(@cjk, " ", "")
    end
  end

  test "the model's own rows wrap CJK by columns too" do
    for width <- [10, 40, 58, 60] do
      rows = RichText.lines([{:model, @cjk}], width, Theme.dark())
      texts = Enum.map(rows, fn line -> Enum.map_join(line.spans, & &1.content) end)

      assert Enum.all?(texts, &(Width.of(&1) <= width)), "a row overflowed #{width} columns"
      assert texts |> Enum.join() |> String.replace(" ", "") == String.replace(@cjk, " ", "")
    end
  end

  test "a table of CJK cells keeps its columns aligned and inside the row" do
    table = %{
      header: ["名前", "value"],
      aligns: [:left, :left],
      rows: [["日本語のテキスト", "x"], ["ab", "y"]]
    }

    texts = table |> table_rows(40) |> Enum.reject(&(&1 =~ "─"))
    assert Enum.all?(texts, &(Width.of(&1) <= 40))

    [header, first, second] = texts
    assert column(header, "value") == column(first, "x")
    assert column(first, "x") == column(second, "y")

    # Squeezed below its natural width, a wide cell is clipped by columns.
    for width <- [8, 9, 12] do
      assert table |> table_rows(width) |> Enum.all?(&(Width.of(&1) <= width))
    end
  end

  test "the input box grows by the columns a draft of CJK takes" do
    # Twenty columns inside the box's borders.
    assert Layout.input_height(String.duplicate("你", 10), 22) == 3
    assert Layout.input_height(String.duplicate("你", 11), 22) == 4
    assert Layout.input_height(String.duplicate("a", 21), 22) == 4
  end

  test "preserved tool output is cut by columns, not graphemes" do
    rows =
      RichText.lines([{:tool_output, "call", :first, :ok, "输出：" <> @cjk}], 20, Theme.dark())

    texts = Enum.map(rows, fn line -> Enum.map_join(line.spans, & &1.content) end)

    assert Enum.all?(texts, &(Width.of(&1) <= 20))
    assert texts |> Enum.join() |> String.contains?("텍스트입니다.")
  end

  defp table_rows(table, width) do
    [{:model_table, table}]
    |> RichText.lines(width, Theme.dark())
    |> Enum.map(fn line -> Enum.map_join(line.spans, & &1.content) end)
  end

  defp column(text, needle) do
    {at, _length} = :binary.match(text, needle)
    Width.of(binary_part(text, 0, at))
  end

  defp drawn_width(sample) do
    terminal = ExRatatui.init_test_terminal(20, 1)
    paragraph = %Paragraph{text: "<" <> sample <> ">", wrap: false}
    :ok = ExRatatui.draw(terminal, [{paragraph, %Rect{x: 0, y: 0, width: 20, height: 1}}])

    terminal
    |> ExRatatui.get_buffer_content()
    |> String.split("\n")
    |> hd()
    |> String.graphemes()
    |> Enum.find_index(&(&1 == ">"))
    |> Kernel.-(1)
  end
end
