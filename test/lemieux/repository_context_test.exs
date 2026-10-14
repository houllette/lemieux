defmodule Lemieux.RepositoryContextTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.RepositoryContext, as: Extension
  alias Lemieux.Harness
  alias Lemieux.RepositoryContext
  alias Lemieux.RepositoryContext.Index
  alias Lemieux.Tool

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "a.ex"), "def hello, do: World.call()\n")
    %{context: %{cwd: root, environment: Lemieux.Environment.local()}, root: root}
  end

  defp item(text, fields \\ %{}) do
    Map.merge(
      %{
        kind: "definition",
        path: "a.ex",
        line: 1,
        symbol: "hello/0",
        digest: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      },
      fields
    )
  end

  defp tool(items, opts \\ []) do
    index = Index.new(items, revision: "fixture-revision")

    RepositoryContext.new(
      Keyword.merge(
        [repositories: [%{id: "app", backend: {Index, index}, paths: ["a.ex"]}]],
        opts
      )
    )
  end

  test "extension is opt in, preserves restricted profiles and supplies search fallback" do
    opts = [repositories: [%{id: "app", backend: nil}]]
    assert {:ok, harness} = Harness.assemble(Harness.new(), [{Extension, opts}])

    assert Enum.map(harness.tools, &Tool.name/1) ==
             ~w(read grep glob write edit bash repository_context)

    assert {:ok, restricted} =
             Harness.assemble(Harness.new(tools: [Lemieux.Tools.Bash]), [{Extension, opts}])

    assert restricted.tools == [Lemieux.Tools.Bash]
    assert Tool.read_only?(List.last(harness.tools))
  end

  test "verified definitions carry current source, revision and bounded evidence", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    assert {:ok, result} =
             RepositoryContext.run(
               tool([item(text)]),
               %{"operation" => "definitions", "query" => "hello"},
               ctx
             )

    assert result.model_text =~ "app:a.ex:1"
    assert result.model_text =~ "fixture-revision"
    assert result.model_text =~ "def hello"
    assert [%{"freshness" => "verified", "sha256" => digest}] = result.structured_content["items"]
    assert digest == item(text).digest
    assert result.metadata["source_bytes"] == byte_size(text)
  end

  test "stale context is withheld and a current literal search answers instead", %{context: ctx} do
    stale = item("old bytes")

    assert {:ok, result} =
             RepositoryContext.run(
               tool([stale]),
               %{"operation" => "definitions", "query" => "hello"},
               ctx
             )

    assert result.model_text =~ "stale"
    assert result.model_text =~ "literal search"
    assert [%{"kind" => "text", "freshness" => "verified"}] = result.structured_content["items"]
    refute result.model_text =~ "hello/0"
  end

  test "missing backend reports a limitation and uses the host manifest", %{context: ctx} do
    tool = RepositoryContext.new(repositories: [%{id: "app", backend: nil, paths: ["a.ex"]}])

    assert {:ok, result} =
             RepositoryContext.run(tool, %{"operation" => "references", "query" => "hello"}, ctx)

    assert result.model_text =~ "unavailable"
    assert result.model_text =~ "app:a.ex:1"
    assert result.metadata["fallback"]
  end

  test "permissions filter index and fallback before reading or disclosure", %{context: ctx} do
    tool =
      RepositoryContext.new(
        repositories: [
          %{
            id: "app",
            backend: {Index, Index.new([item("x", %{symbol: "SECRET"})], revision: "x")},
            paths: ["a.ex"],
            allow: fn _path, _ctx -> false end
          }
        ]
      )

    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx)
    refute result.model_text =~ "SECRET"
    assert result.structured_content["items"] == []
    assert result.metadata["source_bytes"] == 0
    assert result.model_text =~ "omitted"
  end

  test "output and candidate budgets are visible", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    records =
      Enum.map(
        1..50,
        &item(text, %{symbol: String.duplicate("hello", 20) <> Integer.to_string(&1)})
      )

    assert {:ok, result} =
             RepositoryContext.run(
               tool(records, max_tokens: 700, max_candidates: 3),
               %{"operation" => "map"},
               ctx
             )

    assert byte_size(result.model_text) <= 700
    assert result.metadata["truncated"]
    assert result.model_text =~ "limited"
  end

  test "query cannot select an unconfigured repository or raise host budgets", %{context: ctx} do
    configured = tool([])

    assert {:error, _} =
             RepositoryContext.run(
               configured,
               %{"operation" => "map", "repositories" => ["outside"]},
               ctx
             )

    assert {:error, _} =
             RepositoryContext.run(
               configured,
               %{"operation" => "map", "max_tokens" => 100_000},
               ctx
             )

    assert {:error, _} = RepositoryContext.run(configured, %{"operation" => "execute"}, ctx)
  end

  test "maps prioritize referenced definitions and report result caps", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    records = [
      item(text, %{symbol: "A"}),
      item(text, %{symbol: "Z"}),
      item(text, %{kind: "reference", symbol: "Z"})
    ]

    assert {:ok, result} =
             RepositoryContext.run(tool(records, max_results: 1), %{"operation" => "map"}, ctx)

    assert [%{"symbol" => "Z", "kind" => "definition"}] = result.structured_content["items"]
    assert result.metadata["truncated"]
  end

  test "targeted snapshot lookups do not spend candidates on unrelated symbols", %{
    context: ctx,
    root: root
  } do
    lines = Enum.map(1..50, &"def other#{&1}(), do: :ok") ++ ["def hello(), do: :ok"]
    text = Enum.join(lines, "\n") <> "\n"
    File.write!(Path.join(root, "a.ex"), text)

    records =
      Enum.map(1..50, &item(text, %{symbol: "other#{&1}/0", line: &1})) ++
        [item(text, %{line: 51})]

    assert {:ok, result} =
             RepositoryContext.run(
               tool(records, max_candidates: 2),
               %{"operation" => "definitions", "query" => "hello"},
               ctx
             )

    assert [%{"symbol" => "hello/0", "line" => 51}] = result.structured_content["items"]
    assert result.metadata["candidates"] == 1
  end

  test "a verified but nonmatching index still allows literal-search fallback", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    assert {:ok, result} =
             RepositoryContext.run(
               tool([item(text)]),
               %{"operation" => "definitions", "query" => "World"},
               ctx
             )

    assert result.metadata["fallback"]
    assert [%{"kind" => "text"}] = result.structured_content["items"]
  end

  test "selected diagnostics from a host adapter retain evidence and severity", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    diagnostic =
      item(text, %{
        kind: "diagnostic",
        symbol: "hello",
        severity: "warning",
        message: "unknown remote call"
      })

    assert {:ok, result} =
             RepositoryContext.run(
               tool([diagnostic]),
               %{"operation" => "diagnostics", "query" => "hello"},
               ctx
             )

    assert result.model_text =~ "warning: unknown remote call"

    assert [%{"kind" => "diagnostic", "freshness" => "verified"}] =
             result.structured_content["items"]
  end

  test "a path prefix filters both semantic and literal results", %{context: ctx, root: root} do
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/other.ex"), "hello from sub\n")
    repo = %{id: "app", backend: nil, paths: ["a.ex", "sub/other.ex"]}
    configured = RepositoryContext.new(repositories: [repo])

    assert {:ok, result} =
             RepositoryContext.run(
               configured,
               %{"operation" => "search", "query" => "hello", "path" => "sub"},
               ctx
             )

    assert [%{"path" => "sub/other.ex"}] = result.structured_content["items"]
    refute result.model_text =~ "app:a.ex"
  end

  test "configured state stays out of inspection and assembly explanations" do
    configured =
      RepositoryContext.new(
        repositories: [%{id: "app", backend: {Index, "PRIVATE_BACKEND_STATE"}}]
      )

    refute inspect(configured) =~ "PRIVATE_BACKEND_STATE"

    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [{Extension, repositories: configured.repositories}])

    refute inspect(Harness.explain(harness)) =~ "PRIVATE_BACKEND_STATE"
  end

  test "snapshot operations select definitions before the candidate allowance", %{context: ctx} do
    text = "def hello, do: World.call()\n"

    records = [
      item(text, %{kind: "reference"}),
      item(text, %{kind: "dependency"}),
      item(text)
    ]

    assert {:ok, result} =
             RepositoryContext.run(
               tool(records, max_candidates: 1),
               %{"operation" => "definitions", "query" => "hello"},
               ctx
             )

    assert [%{"kind" => "definition", "symbol" => "hello/0"}] = result.structured_content["items"]
    assert result.metadata["candidates"] == 1
    refute result.metadata["fallback"]
  end

  test "exact symbol matches rank before heavily referenced substring matches", %{
    context: ctx,
    root: root
  } do
    text = String.duplicate("hello\n", 112)
    File.write!(Path.join(root, "a.ex"), text)

    records =
      [item(text, %{symbol: "hello"}), item(text, %{symbol: "hello_extra", line: 2})] ++
        Enum.map(3..112, &item(text, %{kind: "reference", symbol: "hello_extra", line: &1}))

    assert {:ok, result} =
             RepositoryContext.run(
               tool(records, max_results: 1),
               %{"operation" => "map", "query" => "hello"},
               ctx
             )

    assert [%{"symbol" => "hello"}] = result.structured_content["items"]
  end

  test "references in another repository do not promote an unrelated same-named definition", %{
    context: ctx
  } do
    text = "def hello, do: World.call()\n"
    definitions = [item(text, %{symbol: "A"}), item(text, %{symbol: "Z"})]

    repos = [
      %{id: "app", backend: {Index, Index.new(definitions, revision: "app")}},
      %{
        id: "other",
        backend:
          {Index, Index.new([item(text, %{kind: "reference", symbol: "Z"})], revision: "other")}
      }
    ]

    assert {:ok, result} =
             RepositoryContext.run(
               RepositoryContext.new(repositories: repos, max_results: 1),
               %{"operation" => "map"},
               ctx
             )

    assert [%{"repository" => "app", "symbol" => "A"}] = result.structured_content["items"]
  end

  test "duplicate index edges cannot inflate a map's reference ranking", %{
    context: ctx,
    root: root
  } do
    text = "hello\nhello\nhello\n"
    File.write!(Path.join(root, "a.ex"), text)

    records =
      [item(text, %{symbol: "A"}), item(text, %{symbol: "B"})] ++
        List.duplicate(item(text, %{kind: "reference", symbol: "A"}), 10) ++
        [
          item(text, %{kind: "reference", symbol: "B", line: 2}),
          item(text, %{kind: "reference", symbol: "B", line: 3})
        ]

    assert {:ok, result} =
             RepositoryContext.run(tool(records, max_results: 1), %{"operation" => "map"}, ctx)

    assert [%{"symbol" => "B"}] = result.structured_content["items"]
  end
end
