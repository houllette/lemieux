defmodule Lemieux.TUI.DiagramsTest do
  use ExUnit.Case, async: true
  alias Ascii.Diagram.Layout, as: NativeLayout
  alias Lemieux.Extensions.A2UI, as: Catalog
  alias Lemieux.TUI.{A2UI, Blocks, Diagrams, RichText, Theme, TranscriptPresentation, Width}

  defp source(nodes) do
    [
      %{
        "version" => "v0.9.1",
        "createSurface" => %{"surfaceId" => "view", "catalogId" => Catalog.catalog_id()}
      },
      %{
        "version" => "v0.9.1",
        "updateComponents" => %{"surfaceId" => "view", "components" => nodes}
      }
    ]
    |> Enum.map_join("\n", &JSON.encode!/1)
  end

  defp text(lines),
    do: Enum.map_join(lines, "\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

  defp diagram(id),
    do: %{
      "id" => id,
      "component" => "MermaidDiagram",
      "source" => "flowchart LR\nA[Request] -->|send| B(Worker)"
    }

  test "diagrams preserve geometry in columns and use complete text when the pane is narrow" do
    input =
      source([
        %{
          "id" => "root",
          "component" => "Column",
          "children" => ["heading", "graph"],
          "gap" => 1
        },
        %{"id" => "heading", "component" => "Text", "text" => "Request flow"},
        diagram("graph")
      ])

    assert {:ok, rows} = A2UI.rows(input)
    wide = RichText.lines(rows, 80, Theme.light())
    assert text(wide) =~ "Request flow"
    assert text(wide) =~ "─"
    assert text(wide) =~ "Worker"

    for width <- [1, 12, 24, 40, 80, 120] do
      lines = RichText.lines(rows, width, Theme.mono())

      assert Enum.all?(
               lines,
               &(Width.of(Enum.map_join(&1.spans, fn span -> span.content end)) <= max(width, 2))
             )
    end

    narrow = text(RichText.lines(rows, 24, Theme.mono()))
    assert narrow =~ "Request"
    assert narrow =~ "Worker"
    assert narrow =~ "send"
    refute narrow =~ "─"
  end

  test "a closed Mermaid fence renders and incomplete or unsupported input gives diagnostics" do
    source = "flowchart LR\nA[Request] --> B[Worker]"
    rows = Blocks.rows("```mermaid\n" <> source <> "\n```", Theme.mono())
    assert Enum.any?(rows, &match?({:model_diagram, _}, &1))

    assert Enum.any?(
             Blocks.rows("```mermaid\n" <> source, Theme.mono()),
             &match?({:model_drawing_error, _}, &1)
           )

    rejected = Blocks.rows("```mermaid\nflowchart LR\nclick A callback\n```", Theme.mono())
    assert Enum.any?(rejected, &match?({:model_drawing_error, _}, &1))
    assert text(RichText.lines(rejected, 80, Theme.mono())) =~ "line 2"
  end

  test "theme changes preserve geometry and mono removes colours" do
    assert {:ok, [{:model_diagram, prepared}]} =
             Diagrams.rows("sequenceDiagram\nA->>B: request\nB-->>A: response")

    dark = Diagrams.lines(prepared, 80, Theme.dark())
    light = Diagrams.lines(prepared, 80, Theme.light())
    mono = Diagrams.lines(prepared, 80, Theme.mono())
    assert text(dark) == text(light)
    assert text(dark) == text(mono)
    assert Enum.any?(dark, &Enum.any?(&1.spans, fn span -> span.style.fg != nil end))

    assert Enum.all?(
             mono,
             &Enum.all?(&1.spans, fn span -> span.style.fg == nil and span.style.bg == nil end)
           )
  end

  test "the original assistant source recreates diagrams on resume" do
    original = "```a2ui\n" <> source([Map.put(diagram("root"), "width", 60)]) <> "\n```"
    live = Blocks.rows(original, Theme.mono())

    restored =
      TranscriptPresentation.lines(
        [
          Lemieux.Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => original}]})
        ],
        %{theme: Theme.mono(), renderers: %{}}
      )

    assert text(RichText.lines(live, 80, Theme.mono())) ==
             text(RichText.lines(restored, 80, Theme.mono()))
  end

  test "a repeated diagram shares leaf and rendered-cell budgets across the whole fence" do
    participants = Enum.map(1..8, &%{"id" => "p#{&1}"})
    events = Enum.map(1..16, &%{"from" => "p1", "to" => "p8", "label" => "event #{&1}"})

    node = %{
      "id" => "d",
      "component" => "SequenceDiagram",
      "participants" => participants,
      "events" => events
    }

    container = %{"id" => "root", "component" => "Column", "children" => ["d", "d"]}
    assert {:ok, _} = A2UI.rows(source([container, node]))

    assert {:error, error} =
             A2UI.rows(source([%{container | "children" => ["d", "d", "d"]}, node]))

    assert error =~ "64,000"

    assert {:error, error} =
             A2UI.rows(source([%{container | "children" => List.duplicate("d", 5)}, node]))

    assert error =~ "maximum 4"
  end

  test "native diagrams bind data and row layouts stack without losing sibling relationships" do
    diagram = %{
      "id" => "graph",
      "component" => "Flowchart",
      "nodes" => %{"path" => "/nodes"},
      "edges" => []
    }

    messages =
      source([
        %{"id" => "root", "component" => "Row", "children" => ["graph", "caption"], "gap" => 1},
        diagram,
        %{"id" => "caption", "component" => "Text", "text" => "Sibling caption", "width" => 16}
      ])

    data =
      JSON.encode!(%{
        "version" => "v0.9.1",
        "updateDataModel" => %{
          "surfaceId" => "view",
          "value" => %{"nodes" => [%{"id" => "a", "label" => "Bound node"}]}
        }
      })

    assert {:ok, rows} = A2UI.rows(messages <> "\n" <> data)
    narrow = text(RichText.lines(rows, 20, Theme.mono()))
    assert narrow =~ "Bound node"
    assert narrow =~ "Sibling caption"
  end

  test "exterior trimming preserves internal rows and matching colour geometry" do
    alias Lemieux.Extensions.A2UI.Diagram

    assert {:ok, prepared} =
             Diagram.prepare(%{
               "component" => "MermaidDiagram",
               "source" => "flowchart TB\nA[First] --> B[Second]"
             })

    for variant <- prepared.variants do
      frame = variant.frame
      assert length(frame.lines) == frame.rows
      assert Enum.all?(frame.lines, &(String.length(&1) == frame.cols))
      assert byte_size(frame.colors) == frame.cols * frame.rows
      {:ok, original} = NativeLayout.frame(variant.layout)
      {left, top} = variant.offset

      expected =
        original.lines
        |> Enum.slice(top, frame.rows)
        |> Enum.map(&String.slice(&1, left, frame.cols))

      assert frame.lines == expected
      assert frame.rows > 10
      spans = Ascii.ExRatatui.lines(frame, ground: false)
      assert text(spans) == frame.text

      assert Enum.all?(
               spans,
               &(Width.of(Enum.map_join(&1.spans, fn span -> span.content end)) == frame.cols)
             )
    end
  end

  test "semantic fallback retains separate participants and ordered event rows" do
    assert {:ok, [{:model_diagram, prepared}]} =
             Diagrams.rows("sequenceDiagram\nA->>B: request\nB-->>A: response")

    lines = Diagrams.lines(%{prepared | variants: []}, 80, Theme.mono())
    assert length(lines) == 3
    assert text(lines) == "Participants: A, B\nA -> B: request\nB -> A: response [dashed]"
  end
end
