defmodule Lemieux.TUI.ClipboardTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI, as: Catalog
  alias Lemieux.TUI.{Blocks, Clipboard, RichText, Selection, Theme, Window}

  defp rendered(source, width),
    do:
      Blocks.rows(source, Theme.mono())
      |> RichText.lines(width, Theme.mono())
      |> Enum.map_join("\n", fn line ->
        Enum.map_join(line.spans, & &1.content) |> String.trim_trailing(" ")
      end)

  test "copy replaces closed visualizations with fenced exact geometry and preserves surrounding source" do
    fence = "```mermaid\nflowchart LR\nA[API] -->|request| B[Worker]\n```"
    answer = "**Request path**\n\n" <> fence <> "\n\nDone."
    expected = "**Request path**\n\n```text\n" <> rendered(fence, 80) <> "\n```\n\nDone."
    assert Clipboard.presentation(answer, 80, Theme.mono()) == expected
    assert expected =~ "─"
    refute expected =~ "flowchart"
  end

  test "word-wrapped Mermaid and native labels keep the displayed geometry when copied" do
    nodes = [
      %{"id" => "a", "label" => "Parse request\nCafé"},
      %{"id" => "b", "label" => "Run agent loop"},
      %{"id" => "c", "label" => "Render response"}
    ]

    messages = [
      %{
        "version" => "v0.9.1",
        "createSurface" => %{"surfaceId" => "s", "catalogId" => Catalog.catalog_id()}
      },
      %{
        "version" => "v0.9.1",
        "updateComponents" => %{
          "surfaceId" => "s",
          "components" => [
            %{
              "id" => "root",
              "component" => "Flowchart",
              "direction" => "LR",
              "labelWidth" => 12,
              "nodes" => nodes,
              "edges" => [%{"from" => "a", "to" => "b"}, %{"from" => "b", "to" => "c"}]
            }
          ]
        }
      }
    ]

    native = "```a2ui\n" <> Enum.map_join(messages, "\n", &JSON.encode!/1) <> "\n```"

    mermaid =
      ~s|```mermaid\nflowchart LR\nA["Parse request\\nCafé"] --> B[Run agent loop] --> C[Render response]\n```|

    for fence <- [mermaid, native], theme <- [Theme.light(), Theme.dark(), Theme.mono()] do
      copied = Clipboard.presentation(fence, 120, theme)
      assert copied == "```text\n" <> rendered(fence, 120) <> "\n```"
      assert copied =~ "─"

      for word <- ["Parse", "request", "Café", "Run agent", "loop", "Render", "response"],
          do: assert(copied =~ word)
    end
  end

  test "A2UI copy retains rows, leading space, gaps and whole answer beyond the viewport" do
    nodes = [
      %{
        "id" => "root",
        "component" => "Column",
        "padding" => 1,
        "gap" => 1,
        "children" => ["a", "b"]
      },
      %{"id" => "a", "component" => "Text", "text" => "First"},
      %{
        "id" => "b",
        "component" => "MermaidDiagram",
        "source" => "stateDiagram-v2\n[*] --> Ready\nReady --> Done: finish"
      }
    ]

    source =
      [
        %{
          "version" => "v0.9.1",
          "createSurface" => %{"surfaceId" => "s", "catalogId" => Catalog.catalog_id()}
        },
        %{
          "version" => "v0.9.1",
          "updateComponents" => %{"surfaceId" => "s", "components" => nodes}
        }
      ]
      |> Enum.map_join("\n", &JSON.encode!/1)

    fence = "~~~a2ui\n" <> source <> "\n~~~"
    output = Clipboard.presentation(fence, 80, Theme.dark())
    assert output == "```text\n" <> rendered(fence, 80) <> "\n```"
    assert output =~ " First"
    assert output =~ "\n\n"
    assert output =~ "Done"
    assert String.split(output, "\n") |> length() > 10
  end

  test "invalid, incomplete and ordinary code fences remain unchanged" do
    for source <- [
          "```mermaid\nstateDiagram-v2\n[*] --> Ready",
          "```mermaid\npie\nwrong\n```",
          "```elixir\n  call()\n```",
          "````markdown\n```mermaid\nflowchart LR\nA --> B\n```\n````",
          "```a2ui\n{}\n```"
        ] do
      assert Clipboard.presentation(source, 80, Theme.mono()) == source
    end
  end

  test "drag-copy covers all rendered geometry with its indentation and blank rows" do
    fence =
      "```mermaid\nerDiagram\nCUSTOMER ||--o{ ORDER : places\nCUSTOMER {\ninteger id PK\n}\n```"

    lines = Blocks.rows(fence, Theme.mono())

    view =
      Window.view(Enum.reverse(lines), 80, 100, 0, fn row, width ->
        RichText.lines([row], width, Theme.mono())
      end)

    last = length(view.rows) - 1
    selection = Selection.start({last, 0}) |> Selection.extend({0, 80})
    assert Selection.text(selection, view) == rendered(fence, 80)
  end

  test "literal backtick fences in labels cannot close the copied text block" do
    source = ~s|```mermaid\nflowchart TB\nA["```"]\n```|
    copied = Clipboard.presentation(source, 80, Theme.mono())
    assert String.starts_with?(copied, "````text\n")
    assert String.ends_with?(copied, "\n````")
    assert copied =~ "│ ```"
  end

  test "source copying shares the host's copy permission" do
    policy = fn
      :copy -> {:deny, "no clipboard here"}
      _other -> :allow
    end

    assert Lemieux.Conversation.command_decision(policy, {:copy, :source}) ==
             {:deny, "no clipboard here"}
  end
end
