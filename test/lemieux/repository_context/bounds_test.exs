defmodule Lemieux.RepositoryContext.BoundsTest do
  use ExUnit.Case, async: true
  alias Lemieux.Environment.Local
  alias Lemieux.RepositoryContext
  alias Lemieux.RepositoryContext.Index
  alias Lemieux.RepositoryContext.Reader

  @moduletag :tmp_dir

  defmodule Backend do
    @behaviour Lemieux.RepositoryContext.Source
    def query(fun, request), do: fun.(request)
  end

  defmodule Remote do
    @behaviour Lemieux.Environment
    def read_file(root, "/remote", path), do: Local.read_file(nil, root, path)
    def write_file(_root, _cwd, _path, _bytes), do: {:error, :denied}
    def run(_root, _command, _opts), do: {:error, :no_commands}
  end

  defmodule Observed do
    @behaviour Lemieux.Environment
    def read_file(_owner, _cwd, _path), do: {:error, :unsupported}
    def write_file(_owner, _cwd, _path, _bytes), do: {:error, :denied}
    def run(_owner, _command, _opts), do: {:error, :no_commands}

    def stream_file(owner, _cwd, path) do
      send(owner, {:source_read, path})
      {:ok, ["hello\nhello\n"]}
    end
  end

  defmodule BrokenSource do
    @behaviour Lemieux.Environment
    def read_file(_state, _cwd, _path), do: {:error, :unsupported}
    def write_file(_state, _cwd, _path, _bytes), do: {:error, :denied}
    def run(_state, _command, _opts), do: {:error, :no_commands}
    def stream_file(_state, _cwd, "a.ex"), do: {:ok, ["hello"]}

    def stream_file(_state, _cwd, "b.ex") do
      {:ok, Stream.repeatedly(fn -> raise "PRIVATE STREAM ERROR" end)}
    end
  end

  defp record(text, fields \\ %{}) do
    Map.merge(
      %{path: "a.ex", line: 1, kind: "definition", symbol: "hello", digest: Reader.digest(text)},
      fields
    )
  end

  defp repo(items),
    do: %{id: "app", backend: {Index, Index.new(items, revision: "r1")}, paths: ["a.ex"]}

  defp ctx(root), do: %{cwd: root, environment: Local}

  test "symlinks, traversal, absolute paths and malformed evidence never disclose indexed text",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "inside"))
    File.write!(Path.join(root, "outside"), "secret")
    File.ln_s!(Path.join(root, "outside"), Path.join(root, "inside/a.ex"))

    items = [
      record("secret"),
      record("secret", %{path: "../outside"}),
      record("secret", %{path: "/outside"}),
      record("secret", %{line: 0})
    ]

    tool = RepositoryContext.new(repositories: [repo(items)])

    assert {:ok, result} =
             RepositoryContext.run(tool, %{"operation" => "map"}, ctx(Path.join(root, "inside")))

    assert result.structured_content["items"] == []
    refute result.model_text =~ "secret"
    assert result.model_text =~ "omitted"
  end

  test "remote and cross-repository scopes verify through their own environment", %{tmp_dir: root} do
    File.write!(Path.join(root, "a.ex"), "hello")

    remote =
      Map.merge(repo([record("hello")]), %{
        id: "other",
        root: "/remote",
        environment: {Remote, root}
      })

    tool = RepositoryContext.new(repositories: [remote])

    assert {:ok, result} =
             RepositoryContext.run(
               tool,
               %{"operation" => "definitions", "query" => "hello"},
               ctx("/no-host-workspace")
             )

    assert result.model_text =~ "other:a.ex:1"
    assert result.metadata["source_bytes"] == 5

    assert_raise ArgumentError, fn ->
      RepositoryContext.new(repositories: [%{remote | environment: :session}])
    end

    assert_raise ArgumentError, fn ->
      RepositoryContext.new(repositories: [%{remote | root: :session}])
    end
  end

  test "default scope follows effective environment and every invocation rechecks permissions", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.ex"), "hello")

    repo =
      Map.put(repo([record("hello")]), :allow, fn _path, context -> context[:permit] == true end)

    tool = RepositoryContext.new(repositories: [repo])

    assert {:ok, allowed} =
             RepositoryContext.run(tool, %{"operation" => "map"}, %{
               cwd: "/remote",
               environment: {Remote, root},
               permit: true
             })

    assert length(allowed.structured_content["items"]) == 1

    assert {:ok, denied} =
             RepositoryContext.run(
               tool,
               %{"operation" => "map"},
               Map.put(ctx(root), :permit, false)
             )

    assert denied.structured_content["items"] == []
  end

  test "same relative names in multiple repositories have distinct source caches", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "a.ex"), "hello")
    other_root = Path.join(root, "other")
    File.mkdir_p!(other_root)
    File.write!(Path.join(other_root, "a.ex"), "other")

    other =
      Map.merge(repo([record("other")]), %{
        id: "other",
        root: "/remote",
        environment: {Remote, other_root}
      })

    tool = RepositoryContext.new(repositories: [repo([record("hello")]), other])
    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert Enum.map(result.structured_content["items"], & &1["repository"]) == ["app", "other"]
    assert Enum.map(result.structured_content["items"], & &1["text"]) == ["hello", "other"]
    assert result.metadata["source_bytes"] == 10
  end

  test "a local alias cannot bypass the policy for its in-workspace target", %{tmp_dir: root} do
    File.write!(Path.join(root, "private.ex"), "PRIVATE SOURCE")
    File.ln_s!("private.ex", Path.join(root, "alias.ex"))

    scoped = %{
      id: "app",
      backend:
        {Index, Index.new([record("PRIVATE SOURCE", %{path: "alias.ex"})], revision: "r1")},
      paths: ["alias.ex"],
      allow: fn path, _context -> path != "private.ex" end
    }

    tool = RepositoryContext.new(repositories: [scoped])
    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert result.structured_content["items"] == []
    refute result.model_text =~ "PRIVATE SOURCE"
    assert result.metadata["source_bytes"] == 0
  end

  test "source bytes are bounded globally including oversized files", %{tmp_dir: root} do
    File.write!(Path.join(root, "a.ex"), String.duplicate("x", 200))
    File.write!(Path.join(root, "b.ex"), "hello")

    tool =
      RepositoryContext.new(
        repositories: [repo([record("x"), record("hello", %{path: "b.ex"})])],
        max_source_bytes: 100
      )

    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert result.metadata["source_bytes"] <= 100
    assert result.structured_content["items"] == []
  end

  test "noncanonical spellings cannot bypass a logical path predicate", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/private.ex"), "PRIVATE SOURCE")

    scoped = %{
      id: "app",
      backend:
        {Index, Index.new([record("PRIVATE SOURCE", %{path: "sub//private.ex"})], revision: "r1")},
      allow: fn path, _context -> path != "sub/private.ex" end
    }

    assert {:ok, result} =
             RepositoryContext.run(
               RepositoryContext.new(repositories: [scoped]),
               %{"operation" => "map"},
               ctx(root)
             )

    assert result.structured_content["items"] == []
    assert result.metadata["source_bytes"] == 0
  end

  test "an authorized local alias still supplies attributed source context", %{tmp_dir: root} do
    File.write!(Path.join(root, "source.ex"), "hello")
    File.ln_s!("source.ex", Path.join(root, "alias.ex"))

    scoped = %{
      id: "app",
      backend: {Index, Index.new([record("hello", %{path: "alias.ex"})], revision: "r1")},
      allow: fn path, _context -> path in ["alias.ex", "source.ex"] end
    }

    assert {:ok, result} =
             RepositoryContext.run(
               RepositoryContext.new(repositories: [scoped]),
               %{"operation" => "map"},
               ctx(root)
             )

    assert [%{"path" => "alias.ex", "text" => "hello"}] = result.structured_content["items"]
  end

  test "infinite candidate streams stop without claiming completeness", %{tmp_dir: root} do
    File.write!(Path.join(root, "a.ex"), "hello")
    index = Index.new([], revision: "stream")

    backend = fn _request ->
      {:ok, %{index | items: Stream.repeatedly(fn -> record("hello") end)} |> Map.from_struct()}
    end

    tool =
      RepositoryContext.new(
        repositories: [%{id: "app", backend: {Backend, backend}}],
        max_candidates: 3
      )

    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert result.metadata["candidates"] == 3
    assert result.metadata["truncated"]
    assert length(result.structured_content["items"]) == 1
  end

  test "a blocked adapter is killed at the deadline without disclosing its state", %{
    tmp_dir: root
  } do
    owner = self()

    backend = fn _ ->
      send(owner, {:worker, self()})
      Process.sleep(60_000)
    end

    tool =
      RepositoryContext.new(
        repositories: [%{id: "app", backend: {Backend, backend}}],
        timeout_ms: 100
      )

    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    assert result.model_text =~ "time limited"
  end

  test "cancelling the caller kills an adapter still awaiting an external answer", %{
    tmp_dir: root
  } do
    owner = self()

    backend = fn _ ->
      send(owner, {:worker, self()})
      Process.sleep(60_000)
    end

    tool =
      RepositoryContext.new(
        repositories: [%{id: "app", backend: {Backend, backend}}],
        timeout_ms: 10_000
      )

    caller = spawn(fn -> RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root)) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end

  test "backend failures and malformed batches produce a bounded visible fallback", %{
    tmp_dir: root
  } do
    for backend <- [
          fn _ -> raise "PRIVATE ERROR" end,
          fn _ -> {:ok, %{}} end,
          fn _ -> {:error, :missing} end
        ] do
      tool =
        RepositoryContext.new(
          repositories: [%{id: "app", backend: {Backend, backend}}],
          max_tokens: 512
        )

      assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
      assert result.model_text =~ "unavailable"
      refute result.model_text =~ "PRIVATE ERROR"
      assert byte_size(JSON.encode!(result.model_text)) <= 512
    end
  end

  test "JSON escaping of adapter limitations cannot exhaust the output budget", %{tmp_dir: root} do
    limitations = [
      String.duplicate("\\", 128),
      String.duplicate("\"", 128),
      String.duplicate("\\\"", 64)
    ]

    index = Index.new([], revision: "r1", limitations: limitations)

    tool =
      RepositoryContext.new(
        repositories: [%{id: "app", backend: {Index, index}}],
        max_tokens: 512
      )

    assert {:ok, result} = RepositoryContext.run(tool, %{"operation" => "map"}, ctx(root))
    assert byte_size(JSON.encode!(result.model_text)) <= 512
    assert result.model_text =~ "Limited repository context"
    assert result.model_text =~ "Fallback"
    assert result.metadata["truncated"]
    assert Enum.all?(limitations, &(&1 in result.metadata["limitations"]))
  end

  test "literal matches share one result allowance across files and repositories" do
    repos =
      for id <- ["app", "other"] do
        %{
          id: id,
          backend: nil,
          paths: ["a.ex", "b.ex", "c.ex"],
          root: "/remote",
          environment: {Observed, self()}
        }
      end

    tool = RepositoryContext.new(repositories: repos, max_results: 1)

    assert {:ok, result} =
             RepositoryContext.run(tool, %{"operation" => "search", "query" => "hello"}, ctx("/"))

    assert_receive {:source_read, "a.ex"}
    refute_receive {:source_read, _path}, 20
    assert length(result.structured_content["items"]) == 1
    assert result.metadata["source_bytes"] == byte_size("hello\nhello\n")
    assert result.metadata["candidates"] == 1
    assert result.metadata["truncated"]
  end

  test "one failed source stream cannot discard verified context from another file" do
    records = [record("hello"), record("hello", %{path: "b.ex"})]

    scope = Map.merge(repo(records), %{root: "/remote", environment: BrokenSource})

    assert {:ok, result} =
             RepositoryContext.run(
               RepositoryContext.new(repositories: [scope]),
               %{"operation" => "definitions", "query" => "hello"},
               ctx("/")
             )

    assert [%{"path" => "a.ex", "freshness" => "verified"}] = result.structured_content["items"]
    assert result.model_text =~ "unreadable"
    refute result.model_text =~ "PRIVATE STREAM ERROR"
  end
end
