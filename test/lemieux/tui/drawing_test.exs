defmodule Lemieux.TUI.DrawingTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI, as: Catalog
  alias Lemieux.Extensions.A2UI.{DiagramPreview, Document}
  alias Lemieux.TUI
  alias Lemieux.TUI.{Blocks, Clipboard, Effects, RichText, Selection, Theme, Transcript, Turn}

  defp text(rows),
    do:
      rows
      |> RichText.lines(100, Theme.mono())
      |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

  defp write(state, chunk) do
    assert {:noreply, state} = Effects.run(state, [{:write, chunk}])
    state
  end

  test "arbitrary streamed fragments display one captioned Drawing row, then the complete diagram" do
    answer = "Before\n```mermaid Request path\nflowchart LR\nA[Client] --> B[Service]\n```"

    chunks = [
      "Before\n``",
      "`mer",
      "maid Request path\nflow",
      "chart LR\nA[Client]",
      " --> B[Service]\n",
      "``",
      "`"
    ]

    pending = Enum.reduce(Enum.drop(chunks, -1), TUI.new(theme: "mono"), &write(&2, &1))
    assert text(Enum.reverse(pending.lines)) == "Before\n• Drawing Request path"
    refute text(Enum.reverse(pending.lines)) =~ "flowchart"
    assert length(pending.lines) == 2

    done = pending |> write(List.last(chunks)) |> Turn.stop_processing()
    assert text(Enum.reverse(done.lines)) == text(Blocks.rows(answer, Theme.mono()))
    assert text(Enum.reverse(done.lines)) =~ "Service"
    refute text(Enum.reverse(done.lines)) =~ "Drawing"
    assert Clipboard.presentation(answer, 100, Theme.mono()) =~ "─"
  end

  test "JSONL never flashes as code and scrolling stays anchored while the drawing grows" do
    source = File.read!("test/fixtures/a2ui/invalid_diagram_gallery.jsonl")

    state =
      TUI.new(theme: "mono") |> Transcript.say(:model, "older text") |> Transcript.close_line()

    state = %{state | scroll: 3, selection: Selection.start({0, 2})}
    pending = write(state, "\n```a2ui Diagram examples\n")
    anchor = pending.selection.anchor
    scroll = pending.scroll

    pending =
      source
      |> String.graphemes()
      |> Enum.chunk_every(43)
      |> Enum.reduce(pending, fn chunk, state ->
        state = write(state, Enum.join(chunk))
        assert text(Enum.reverse(state.lines)) =~ "Drawing Diagram examples"
        refute text(Enum.reverse(state.lines)) =~ "updateComponents"
        state
      end)

    assert pending.selection.anchor == anchor
    assert pending.scroll == scroll
    rejected = pending |> write("```") |> Turn.stop_processing()
    assert text(Enum.reverse(rejected.lines)) =~ "Drawing unavailable"
    assert text(Enum.reverse(rejected.lines)) =~ "c4"
    assert text(Enum.reverse(rejected.lines)) =~ "/copy source"
    refute text(Enum.reverse(rejected.lines)) =~ "updateComponents"

    assert Clipboard.presentation("```a2ui\n" <> source <> "```", 100, Theme.mono()) ==
             "```a2ui\n" <> source <> "```"
  end

  test "unfinished and oversized drawings end with a compact diagnostic and preserve ordinary code" do
    pending = write(TUI.new(theme: "mono"), "~~~a2ui Status\n" <> String.duplicate("x", 20_000))
    assert byte_size(:erlang.term_to_binary(pending.lines)) < 18_000
    done = Turn.stop_processing(pending)
    assert text(Enum.reverse(done.lines)) =~ "16 KiB"
    after_close = pending |> write("\n~~~\nAfter the drawing") |> Turn.stop_processing()
    assert text(Enum.reverse(after_close.lines)) =~ "16 KiB"
    assert text(Enum.reverse(after_close.lines)) =~ "After the drawing"
    assert text(Blocks.rows("```mermaid\nflowchart LR", Theme.mono())) =~ "closing fence"
    assert text(Blocks.rows("```elixir\nanswer = 42\n```", Theme.mono())) =~ "answer = 42"
  end

  test "the observed invalid gallery gets an actionable component diagnostic" do
    source = File.read!("test/fixtures/a2ui/invalid_diagram_gallery.jsonl")
    assert {:error, message} = Document.validate(source)
    assert message =~ "c4"
    assert message =~ "C4Diagram"
    assert message =~ "componentSchema"
  end

  test "native schemas are available on demand without enlarging every model request" do
    assert {:ok, result} = DiagramPreview.run(%{"componentSchema" => "SequenceDiagram"}, %{})
    schema = result.structured_content["schema"]
    assert schema["properties"]["participants"]["items"]["required"] == ["id"]
    assert result.model_text =~ "participants"
    validator = JSV.build!(DiagramPreview.schema())
    assert {:ok, _} = JSV.validate(%{"componentSchema" => "ERDiagram"}, validator)
    assert {:error, _} = DiagramPreview.run(%{"componentSchema" => "Button"}, %{})

    assert {:error, _} =
             DiagramPreview.run(%{"componentSchema" => "ERDiagram", "source" => "x"}, %{})
  end

  test "all six corrected native examples render in bounded fences and copy without JSON" do
    nodes = File.read!("test/fixtures/a2ui/diagram_components.json") |> JSON.decode!()

    for node <- nodes do
      assert {:ok, result} = DiagramPreview.run(%{"componentSchema" => node["component"]}, %{})
      assert {:ok, ^node} = JSV.validate(node, JSV.build!(result.structured_content["schema"]))
    end

    assert {:error, message} = Document.validate(gallery(nodes))
    assert message =~ "6 diagrams; maximum 4"

    answer =
      nodes
      |> Enum.chunk_every(4)
      |> Enum.map_join("\n\n", &("```a2ui Diagram examples\n" <> gallery(&1) <> "\n```"))

    live =
      answer
      |> String.graphemes()
      |> Enum.chunk_every(79)
      |> Enum.reduce(TUI.new(theme: "mono"), fn chunk, state -> write(state, Enum.join(chunk)) end)
      |> Turn.stop_processing()

    displayed = text(Enum.reverse(live.lines))
    assert displayed == text(Blocks.rows(answer, Theme.mono()))

    for label <- ["Request", "Do work", "Database", "Example app", "Idle", "places"],
        do: assert(displayed =~ label)

    refute displayed =~ "Drawing unavailable"
    refute displayed =~ "updateComponents"
    copy = Clipboard.presentation(answer, 100, Theme.mono())
    assert copy =~ "─"
    assert copy =~ "Database"
    refute copy =~ "updateComponents"
  end

  defp gallery(nodes) do
    root = %{
      "id" => "root",
      "component" => "Column",
      "gap" => 1,
      "children" => Enum.map(nodes, & &1["id"])
    }

    [
      %{
        "version" => "v0.9.1",
        "createSurface" => %{"surfaceId" => "gallery", "catalogId" => Catalog.catalog_id()}
      },
      %{
        "version" => "v0.9.1",
        "updateComponents" => %{"surfaceId" => "gallery", "components" => [root | nodes]}
      }
    ]
    |> Enum.map_join("\n", &JSON.encode!/1)
  end
end
