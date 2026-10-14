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

  test "default arguments and guards retain their syntactic calls and callable arities", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "example.ex"), ~S"""
    defmodule Example do
      def greet(name \\ Defaults.name()) when Guards.valid?(name), do: Other.hello(name)
    end
    """)

    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    definitions = index.items |> Enum.filter(&(&1.kind == "definition")) |> Enum.map(& &1.symbol)
    references = index.items |> Enum.filter(&(&1.kind == "reference")) |> Enum.map(& &1.symbol)
    assert "Example.greet/0" in definitions
    assert "Example.greet/1" in definitions
    assert "Defaults.name/0" in references
    assert "Guards.valid?/1" in references
    assert "Other.hello/1" in references
  end

  test "explicit Elixir module names are absolute in nested definitions and calls", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "example.ex"), """
    defmodule Parent do
      defmodule Elixir.Absolute do
        def run(), do: Elixir.Other.hello()
      end
    end
    """)

    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    assert Enum.any?(index.items, &(&1.kind == "definition" and &1.symbol == "Absolute.run/0"))
    assert Enum.any?(index.items, &(&1.kind == "reference" and &1.symbol == "Other.hello/0"))
    refute Enum.any?(index.items, &String.contains?(&1.symbol, "Elixir."))
  end

  test "quoted and dynamic module definitions do not fabricate concrete symbols", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "example.ex"), """
    defmodule Example do
      defmacro template() do
        quote do
          def generated(), do: Ghost.call()
        end
      end
      defmodule unquote(name) do
        def dynamic(), do: Phantom.call()
      end
    end
    """)

    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    assert Enum.any?(index.items, &(&1.symbol == "Example.template/0"))
    refute Enum.any?(index.items, &String.contains?(&1.symbol, "generated"))
    refute Enum.any?(index.items, &String.contains?(&1.symbol, "dynamic"))
    refute Enum.any?(index.items, &(&1.symbol in ["Ghost.call/0", "Phantom.call/0"]))
    assert Enum.any?(index.limitations, &String.contains?(&1, "quoted"))
  end

  test "duplicate manifest entries do not overwrite records or consume the item allowance", %{
    root: root,
    env: env
  } do
    assert {:ok, single, _} = Indexer.build(env, root, ["example.ex"])

    assert {:ok, repeated, metrics} =
             Indexer.build(env, root, ["example.ex", "example.ex"],
               max_items: length(single.items) + 1
             )

    assert repeated.items == single.items
    assert repeated.complete?
    assert repeated.revision == single.revision
    assert metrics.parsed == 1
    assert metrics.read_bytes == byte_size(@code)
  end

  test "indexing repository source cannot emit parser warnings to stderr", %{root: root, env: env} do
    File.write!(Path.join(root, "example.ex"), "def hello(), do: 'legacy charlist'\n")

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
        assert Enum.any?(index.items, &(&1.symbol == "hello/0"))
      end)

    assert output == ""
  end

  test "nested names keep repeated parent segments and resolve lexical __MODULE__ aliases", %{
    root: root,
    env: env
  } do
    File.write!(Path.join(root, "example.ex"), """
    defmodule Parent do
      defmodule Parent.Child do
        def run(), do: __MODULE__.helper()
      end
      defmodule __MODULE__.Explicit do
        def run(), do: __MODULE__.Worker.call()
      end
    end
    """)

    assert {:ok, index, _} = Indexer.build(env, root, ["example.ex"])
    assert Enum.any?(index.items, &(&1.symbol == "Parent.Parent.Child.run/0"))
    assert Enum.any?(index.items, &(&1.symbol == "Parent.Parent.Child.helper/0"))
    assert Enum.any?(index.items, &(&1.symbol == "Parent.Explicit.run/0"))
    assert Enum.any?(index.items, &(&1.symbol == "Parent.Explicit.Worker.call/0"))
    refute Enum.any?(index.items, &(&1.symbol == "Parent.Child.run/0"))
  end
end
