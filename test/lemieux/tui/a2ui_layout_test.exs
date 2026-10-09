defmodule Lemieux.TUI.A2UILayoutTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.Extensions.A2UI, as: Catalog
  alias Lemieux.TUI.{A2UI, Blocks, RichText, Theme, TranscriptPresentation, Width}

  defp source(nodes) do
    [
      %{
        "version" => "v0.9.1",
        "createSurface" => %{"surfaceId" => "layout", "catalogId" => Catalog.catalog_id()}
      },
      %{
        "version" => "v0.9.1",
        "updateComponents" => %{"surfaceId" => "layout", "components" => nodes}
      }
    ]
    |> Enum.map_join("\n", &JSON.encode!/1)
  end

  defp node(id, type, options), do: Map.merge(%{"id" => id, "component" => type}, options)

  defp render(nodes, width) do
    assert {:ok, rows} = A2UI.rows(source(nodes))
    RichText.lines(rows, width, Theme.mono())
  end

  defp text(lines), do: Enum.map(lines, fn line -> Enum.map_join(line.spans, & &1.content) end)

  test "a column starts every component at the same edge without gallery blank rows" do
    lines =
      render(
        [
          node("root", "Column", %{"children" => ["first", "second", "end"]}),
          node("first", "ProgressBar", %{"label" => "first", "value" => 25}),
          node("second", "ProgressBar", %{"label" => "second", "value" => 75}),
          node("end", "Text", %{"text" => "done"})
        ],
        80
      )
      |> text()

    assert length(lines) == 3
    assert String.starts_with?(Enum.at(lines, 0), "first")
    assert String.starts_with?(Enum.at(lines, 1), "second")
    assert List.last(lines) == "done"
  end

  test "column alignment, width, padding and explicit gaps survive the projection" do
    lines =
      render(
        [
          node("root", "Column", %{
            "children" => ["a", "b"],
            "width" => 12,
            "align" => "end",
            "padding" => 1,
            "gap" => 1
          }),
          node("a", "Text", %{"text" => "one"}),
          node("b", "Text", %{"text" => "two"})
        ],
        40
      )
      |> text()

    assert length(lines) == 5
    assert Enum.at(lines, 1) == "        one "
    assert Enum.at(lines, 3) == "        two "
  end

  test "rows place siblings beside each other and stack when their minimum widths do not fit" do
    nodes = [
      node("root", "Row", %{"children" => ["a", "b"], "gap" => 2}),
      node("a", "Text", %{"text" => "one", "width" => 3}),
      node("b", "Text", %{"text" => "two", "width" => 3})
    ]

    assert render(nodes, 20) |> text() == ["one  two"]
    assert render(nodes, 5) |> text() |> Enum.reject(&(String.trim(&1) == "")) == ["one", "two"]
  end

  test "nested rows keep their own alignment and columns keep the declared order" do
    nodes = [
      node("root", "Column", %{"children" => ["heading", "pair"], "gap" => 1}),
      node("heading", "Text", %{"text" => "summary"}),
      node("pair", "Row", %{"children" => ["a", "b"], "width" => 20, "justify" => "spaceBetween"}),
      node("a", "Text", %{"text" => "left"}),
      node("b", "Text", %{"text" => "right"})
    ]

    assert render(nodes, 40) |> text() == ["summary", "", "left           right"]
  end

  test "layout dimensions are bounded data; oversized or executable positioning gets a diagnostic" do
    for options <- [
          %{"width" => 201},
          %{"padding" => 5},
          %{"gap" => -1},
          %{"height" => 41},
          %{"align" => "absolute"},
          %{"width" => %{"call" => "eval"}}
        ] do
      assert {:error, message} =
               A2UI.rows(
                 source([
                   node("root", "Column", Map.merge(%{"children" => ["a"]}, options)),
                   node("a", "Text", %{"text" => "a"})
                 ])
               )

      assert message =~ "Invalid A2UI tree"
      assert message =~ "root"
    end
  end

  test "wide text and nested charts stay within native terminal cells on resize" do
    nodes = [
      node("root", "Row", %{"children" => ["a", "b"], "gap" => 1, "padding" => 1}),
      node("a", "Text", %{"text" => "測試結果"}),
      node("b", "ProgressBar", %{"label" => "checks", "value" => 42})
    ]

    for width <- [1, 12, 40, 80] do
      lines = render(nodes, width)
      assert Enum.all?(text(lines), &(Width.of(&1) <= width))
      session = CellSession.new(width, max(length(lines), 1))

      assert :ok =
               CellSession.draw(session, [
                 {%Paragraph{text: lines},
                  %Rect{x: 0, y: 0, width: width, height: max(length(lines), 1)}}
               ])

      assert CellSession.take_cells(session).width == width
      assert :ok = CellSession.close(session)
    end
  end

  test "parent alignment positions the child's box without overriding its internal alignment" do
    nodes = [
      node("root", "Column", %{"children" => ["a"], "width" => 20, "align" => "end"}),
      node("a", "Text", %{"text" => "one", "width" => 12, "align" => "center"})
    ]

    assert render(nodes, 40) |> text() == [String.duplicate(" ", 12) <> "one"]
  end

  test "vertical alignment and minimum height add room without cropping contents" do
    nodes = [
      node("root", "Row", %{
        "children" => ["short", "long"],
        "gap" => 1,
        "align" => "end",
        "height" => 3
      }),
      node("short", "Text", %{"text" => "s"}),
      node("long", "Text", %{"text" => "a\nb"})
    ]

    assert render(nodes, 20) |> text() == ["   ", "  a", "s b"]
    assert render(nodes, 2) |> text() == ["s", "", "a", "b"]

    column = [
      node("root", "Column", %{
        "children" => ["a", "b"],
        "height" => 5,
        "justify" => "spaceBetween"
      }),
      node("a", "Text", %{"text" => "first"}),
      node("b", "Text", %{"text" => "last"})
    ]

    assert render(column, 20) |> text() == ["first", "", "", "", "last"]
  end

  test "compact is inherited and can retain a gallery frame explicitly" do
    nodes = [
      node("root", "Column", %{"children" => ["bar"], "compact" => false}),
      node("bar", "ProgressBar", %{"label" => "checks", "value" => 42})
    ]

    assert length(render(nodes, 80)) == 3
    assert length(render(List.update_at(nodes, 1, &Map.put(&1, "compact", true)), 80)) == 1
  end

  test "row composition preserves styles and monochrome rendering" do
    nodes = [
      node("root", "Row", %{"children" => ["a", "b"], "gap" => 2}),
      node("a", "Text", %{"text" => "**passed**"}),
      node("b", "ProgressBar", %{"label" => "checks", "value" => 100})
    ]

    assert {:ok, rows} = A2UI.rows(source(nodes))
    dark = RichText.lines(rows, 80, Theme.default())
    assert text(dark) |> hd() |> String.starts_with?("passed  checks")

    assert Enum.any?(
             hd(dark).spans,
             &(String.contains?(&1.content, "passed") and :bold in &1.style.modifiers)
           )

    assert Enum.any?(hd(dark).spans, &(not is_nil(&1.style.fg)))
    mono = RichText.lines(rows, 80, Theme.mono())
    assert text(dark) == text(mono)
    assert Enum.all?(hd(mono).spans, &(is_nil(&1.style.fg) and is_nil(&1.style.bg)))
  end

  test "compact frames preserve branch indentation while removing space before the root" do
    lines =
      render(
        [
          node("root", "FileTree", %{
            "root" => "fixture",
            "paths" => ["lib/a.ex", "lib/nested/b.ex", "README.md"]
          })
        ],
        80
      )
      |> text()

    assert String.starts_with?(hd(lines), "fixture")
    assert Enum.all?(lines, &(String.trim(&1) != ""))
    assert Enum.any?(lines, &(String.contains?(&1, "b.ex") and String.starts_with?(&1, "│")))
  end

  test "nested layout styling and responsive stacking are rebuilt identically on resume" do
    nodes = [
      node("root", "Column", %{"children" => ["heading", "pair"], "gap" => 1}),
      node("heading", "Text", %{"text" => "**Checks**"}),
      node("pair", "Row", %{"children" => ["a", "b"], "gap" => 2}),
      node("a", "ProgressBar", %{"label" => "unit", "value" => 100}),
      node("b", "ProgressBar", %{"label" => "docs", "value" => 75})
    ]

    answer = "```a2ui\n" <> source(nodes) <> "\n```"
    entry = %{type: :assistant, payload: %{"content" => [%{"type" => "text", "text" => answer}]}}

    for theme <- [Theme.default(), Theme.light(), Theme.mono()] do
      live = Blocks.rows(answer, theme)
      restored = TranscriptPresentation.lines([entry], %{theme: theme, renderers: %{}})

      for width <- [12, 40, 80] do
        assert RichText.lines(live, width, theme) == RichText.lines(restored, width, theme)
      end
    end
  end

  test "a narrow pane reduces horizontal padding while retaining requested vertical padding" do
    nodes = [node("root", "Text", %{"text" => "x", "padding" => 2})]
    assert render(nodes, 1) |> text() == ["", "", "x", "", ""]
  end
end
