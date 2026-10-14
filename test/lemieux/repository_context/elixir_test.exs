defmodule Lemieux.RepositoryContext.ElixirTest do
  use ExUnit.Case, async: true
  alias Lemieux.RepositoryContext
  alias Lemieux.RepositoryContext.Elixir, as: Indexer
  alias Lemieux.RepositoryContext.Index

  @moduletag :tmp_dir
  @code "defmodule Example do\n  def greet(name), do: Other.hello(name)\nend\n"

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "example.ex"), @code)
    %{root: root, env: Lemieux.Environment.local()}
  end

  test "indexes definitions, syntactic references and dependencies with source evidence", %{
    root: root,
    env: env
  } do
    assert {:ok, index, metrics} = Indexer.build(env, root, ["example.ex"])
    assert metrics.parsed == 1
    assert metrics.read_bytes == byte_size(@code)

    assert Enum.any?(
             index.items,
             &(&1.kind == "definition" and &1.symbol == "Example.greet/1" and &1.line == 2)
           )

    assert Enum.any?(index.items, &(&1.kind == "reference" and &1.symbol == "Other.hello/1"))
    assert Enum.any?(index.items, &(&1.kind == "dependency" and &1.symbol == "Other"))
    tool = RepositoryContext.new(repositories: [%{id: "app", backend: {Index, index}}])

    assert {:ok, result} =
             RepositoryContext.run(tool, %{"operation" => "definitions", "query" => "greet"}, %{
               cwd: root,
               environment: env
             })

    assert result.model_text =~ "Example.greet/1"
    assert result.model_text =~ "syntax index"
    assert [%{"freshness" => "verified"}] = result.structured_content["items"]
  end

  test "warm builds hash bytes, reuse unchanged parses and drop deleted files", %{
    root: root,
    env: env
  } do
    assert {:ok, cold, _} = Indexer.build(env, root, ["example.ex"])
    assert {:ok, warm, metrics} = Indexer.build(env, root, ["example.ex"], previous: cold)
    assert metrics.reused == 1
    assert metrics.parsed == 0
    assert warm.revision == cold.revision
    File.write!(Path.join(root, "example.ex"), String.replace(@code, "greet", "hello"))
    assert {:ok, updated, metrics} = Indexer.build(env, root, ["example.ex"], previous: warm)
    assert metrics.parsed == 1
    assert updated.revision != cold.revision
    assert {:ok, deleted, _} = Indexer.build(env, root, [], previous: updated)
    assert deleted.items == []
  end

  test "denied, outside, oversized and over-budget files make coverage explicitly partial", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "other.ex"), @code)

    assert {:ok, index, metrics} =
             Indexer.build(env, root, ["example.ex", "other.ex"], max_files: 1)

    refute index.complete?
    assert metrics.parsed == 1

    assert {:ok, index, metrics} =
             Indexer.build(env, root, ["../outside", "example.ex"], allow: fn _ -> false end)

    refute index.complete?
    assert metrics.omitted == 2
    assert metrics.read_bytes == 0

    assert {:ok, index, metrics} =
             Indexer.build(env, root, ["example.ex", "other.ex"], max_source_bytes: 10)

    assert index.items == []
    assert metrics.read_bytes <= 10
    refute index.complete?
  end

  test "parse errors remain partial after incremental reuse and become diagnostics", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "example.ex"), "defmodule Broken do\n")
    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    refute index.complete?
    assert [%{kind: "diagnostic", severity: "error"}] = index.items
    assert {:ok, reused, %{reused: 1}} = Indexer.build(env, root, ["example.ex"], previous: index)
    refute reused.complete?
    tool = RepositoryContext.new(repositories: [%{id: "app", backend: {Index, reused}}])

    assert {:ok, result} =
             RepositoryContext.run(tool, %{"operation" => "diagnostics"}, %{
               cwd: root,
               environment: env
             })

    assert result.model_text =~ "parse_error"
    assert result.model_text =~ "incomplete"
  end

  test "record caps are partial, revision bound and reparsed when the host raises the cap", %{
    root: root,
    env: env
  } do
    assert {:ok, partial, _} = Indexer.build(env, root, ["example.ex"], max_items: 1)
    assert length(partial.items) == 1
    refute partial.complete?
    assert {:ok, restored, metrics} = Indexer.build(env, root, ["example.ex"], previous: partial)
    assert restored.complete?
    assert metrics.parsed == 1
    assert length(restored.items) > 1
    assert restored.revision != partial.revision
  end

  test "repository source is never evaluated and identifiers do not become atoms", %{
    root: root,
    env: env
  } do
    name = "uninterned_#{System.unique_integer([:positive])}"
    marker = Path.join(root, "executed")

    File.write!(
      Path.join(root, "example.ex"),
      "File.write!(#{inspect(marker)}, \"bad\")\ndef #{name}(), do: :ok\n"
    )

    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    assert Enum.any?(index.items, &(&1.symbol == name <> "/0"))
    refute File.exists?(marker)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
