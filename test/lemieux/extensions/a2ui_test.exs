defmodule Lemieux.Extensions.A2UITest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI
  alias Lemieux.Extensions.A2UI.Document
  alias Lemieux.Harness
  alias Lemieux.Request

  defp message(kind, data), do: %{"version" => "v0.9.1", kind => data}

  defp create(id \\ "view"),
    do: message("createSurface", %{"surfaceId" => id, "catalogId" => A2UI.catalog_id()})

  defp components(nodes),
    do: message("updateComponents", %{"surfaceId" => "view", "components" => nodes})

  defp stream(messages), do: Enum.map_join(messages, "\n", &JSON.encode!/1)
  defp leaf(type, properties), do: Map.merge(%{"id" => "root", "component" => type}, properties)

  test "the extension advertises a catalog and read-only preview without terminal dependencies" do
    harness = A2UI.apply(Harness.new(system: "original"), [])
    assert Enum.any?(harness.tools, &(Lemieux.Tool.name(&1) == "diagram_preview"))
    assert {:ok, request} = A2UI.prepare(%Request{model: "test:model", system: "original"}, %{})
    assert String.starts_with?(request.system, "original\n\n")
    assert request.system =~ A2UI.catalog_id()
    assert request.system =~ "sampleRate"
    assert request.system =~ "Column/Row"
    assert request.system =~ "compact=true"
  end

  test "data bindings update through escaped JSON Pointer keys and arrays" do
    messages = [
      create(),
      message("updateDataModel", %{"surfaceId" => "view", "value" => %{"a/b" => [20, 40]}}),
      components([leaf("ProgressBar", %{"label" => "checks", "value" => %{"path" => "/a~1b/1"}})])
    ]

    assert {:ok, [%{"value" => 40}]} = Document.decode(stream(messages))

    changed =
      messages ++
        [
          message("updateDataModel", %{
            "surfaceId" => "view",
            "path" => "/a~1b",
            "value" => [10, 75]
          })
        ]

    assert {:ok, [%{"value" => 75}]} = Document.decode(stream(changed))
    deleted = changed ++ [message("updateDataModel", %{"surfaceId" => "view", "path" => "/a~1b"})]
    assert Document.decode(stream(deleted)) == :error
  end

  test "containers retain tree order and surfaces are isolated" do
    nodes = [
      %{"id" => "b", "component" => "Text", "text" => "second"},
      %{"id" => "root", "component" => "Column", "children" => ["a", "b"]},
      %{"id" => "a", "component" => "Text", "text" => "first"}
    ]

    assert {:ok, [%{"text" => "first"}, %{"text" => "second"}]} =
             Document.decode(stream([create(), components(nodes)]))

    assert {:ok, []} =
             Document.decode(
               stream([
                 create(),
                 components(nodes),
                 message("deleteSurface", %{"surfaceId" => "view"})
               ])
             )

    assert Document.decode(stream([create(), create()])) == :error
    assert Document.decode(stream([components(nodes)])) == :error
  end

  test "unknown catalogs, actions, functions, controls, invalid graphs and oversized streams stay source" do
    text = leaf("Text", %{"text" => "hello"})

    for invalid <- [
          [
            message("createSurface", %{
              "surfaceId" => "view",
              "catalogId" => "https://untrusted.invalid/catalog"
            }),
            components([text])
          ],
          [create(), components([Map.put(text, "action", %{"event" => %{"name" => "bash"}})])],
          [create(), components([leaf("Text", %{"text" => %{"call" => "eval", "args" => %{}}})])],
          [create(), components([leaf("Text", %{"text" => "\e[2J"})])],
          [create(), components([leaf("Column", %{"children" => ["root"]})])],
          [create(), components([leaf("Column", %{"children" => ["missing"]})])],
          [create(), components([leaf("ProgressBar", %{"label" => "checks", "value" => 101})])],
          [
            create(),
            components([
              leaf("Sparkline", %{"label" => "cpu", "values" => [], "sampleRate" => 1})
            ])
          ],
          [create(), components([leaf("FileTree", %{"paths" => []})])],
          [create(), components([leaf("Button", %{"text" => "run"})])]
        ],
        do: assert(Document.decode(stream(invalid)) == :error)

    assert Document.decode(String.duplicate(" ", 16_385)) == :error
    assert Document.decode(JSON.encode!(List.duplicate(create(), 33))) == :error
  end

  test "shared graph references cannot expand exponentially" do
    nodes =
      for i <- 0..6 do
        id = if i == 0, do: "root", else: "n#{i}"

        if i == 6,
          do: %{"id" => id, "component" => "Text", "text" => "leaf"},
          else: %{"id" => id, "component" => "Column", "children" => ["n#{i + 1}", "n#{i + 1}"]}
      end

    assert Document.decode(stream([create(), components(nodes)])) == :error
  end

  test "all data components require explicit, well-shaped values" do
    for node <- [
          leaf("ProgressBar", %{"label" => "checks", "value" => 0}),
          leaf("Sparkline", %{"label" => "latency", "values" => [2, 5, 3], "sampleRate" => 0.5}),
          leaf("BarChart", %{"title" => "runs", "labels" => ["a", "b"], "values" => [3, 5]}),
          leaf("Table", %{"headers" => ["name", "count"], "rows" => [["a", 3]]}),
          leaf("FileTree", %{"paths" => ["lib/a.ex", "README.md"]})
        ] do
      assert {:ok, [^node]} = Document.decode(stream([create(), components([node])]))
    end
  end

  test "resolved layouts preserve nesting and accept bounded data-bound positioning" do
    nodes = [
      leaf("Column", %{"children" => ["pair"], "padding" => 1}),
      %{
        "id" => "pair",
        "component" => "Row",
        "width" => %{"path" => "/width"},
        "gap" => 2,
        "children" => ["a", "b"]
      },
      %{"id" => "a", "component" => "Text", "text" => "first"},
      %{"id" => "b", "component" => "Text", "text" => "second"}
    ]

    messages = [
      create(),
      components(nodes),
      message("updateDataModel", %{"surfaceId" => "view", "value" => %{"width" => 20}})
    ]

    assert {:ok, [%{"component" => "Column", "padding" => 1, "children" => [pair]}]} =
             Document.layout(stream(messages))

    assert %{
             "component" => "Row",
             "width" => 20,
             "children" => [%{"text" => "first"}, %{"text" => "second"}]
           } = pair

    assert {:ok, [%{"text" => "first"}, %{"text" => "second"}]} =
             Document.decode(stream(messages))

    assert Document.layout(
             stream(
               messages ++
                 [
                   message("updateDataModel", %{
                     "surfaceId" => "view",
                     "path" => "/width",
                     "value" => 201
                   })
                 ]
             )
           ) == :error

    assert Document.layout(
             stream([create(), components([leaf("Row", %{"children" => ["root"]})])])
           ) == :error
  end

  test "the shipped catalog validates layout controls and rejects unbounded positioning" do
    catalog =
      :lemieux
      |> :code.priv_dir()
      |> Path.join("a2ui/catalog.json")
      |> File.read!()
      |> JSON.decode!()

    for type <- ["Column", "Row"] do
      validator = catalog["components"][type] |> local_schema() |> JSV.build!()

      valid =
        leaf(type, %{
          "children" => ["a"],
          "width" => 20,
          "height" => 5,
          "align" => "center",
          "justify" => "spaceBetween",
          "padding" => 1,
          "gap" => 2,
          "compact" => true
        })

      assert {:ok, ^valid} = JSV.validate(valid, validator)

      assert {:ok, _bound} =
               JSV.validate(Map.put(valid, "width", %{"path" => "/width"}), validator)

      for {key, value} <- [
            {"width", 201},
            {"padding", 5},
            {"gap", -1},
            {"height", 41},
            {"align", "absolute"},
            {"compact", "yes"},
            {"x", 1}
          ] do
        assert {:error, _reason} = JSV.validate(Map.put(valid, key, value), validator)
      end
    end
  end

  # Common identifier refs are irrelevant to positioning validation. Resolve
  # their types locally so this test never fetches the upstream schema.
  defp local_schema(%{
         "$ref" => "https://a2ui.org/specification/v0_9_1/common_types.json#/$defs/ComponentId"
       }),
       do: %{"type" => "string"}

  defp local_schema(%{
         "$ref" => "https://a2ui.org/specification/v0_9_1/common_types.json#/$defs/ChildList"
       }),
       do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp local_schema(schema) when is_map(schema),
    do: Map.new(schema, fn {key, value} -> {key, local_schema(value)} end)

  defp local_schema(schema) when is_list(schema), do: Enum.map(schema, &local_schema/1)
  defp local_schema(schema), do: schema
end
