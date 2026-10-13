defmodule Lemieux.Extensions.WritersTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Writers
  alias Lemieux.Harness
  alias Lemieux.Tool

  test "writer capability requires explicit host policy" do
    assert {:error, :missing_host_policy} = Writers.init([])
    assert Enum.all?(Lemieux.Tools.default(), &(Tool.name(&1) != "writers"))
  end

  test "model-visible provenance excludes executable host state" do
    opts = [
      paths: ["src/"],
      tools: ["read", "write"],
      options: [
        workspace: {Lemieux.Writers.Worktree, %{}},
        factory: fn _, _ -> {:error, :unused} end,
        verify: fn _, _, _ -> {:error, :unused} end,
        checks: fn _ -> {:error, :unused} end,
        authorize: fn _, _, _ -> :ok end,
        authority: "secret-host-state"
      ]
    ]

    assert {:ok, state} = Writers.init(opts)
    assert {:ok, harness} = Harness.assemble(Harness.new(), [{Writers, opts}])
    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read write edit bash writers)
    assert Writers.apply(harness, state).tools == harness.tools
    encoded = JSON.encode!(harness.applied)
    refute encoded =~ "secret-host-state"
    assert encoded =~ "src/"
    assert harness.system =~ "Task size alone"
    assert harness.system =~ "same base snapshot"
    refute harness.system =~ "Use subagents"
    refute Tool.read_only?(List.last(harness.tools))
    refute Tool.parallel_safe?(List.last(harness.tools))
  end
end
