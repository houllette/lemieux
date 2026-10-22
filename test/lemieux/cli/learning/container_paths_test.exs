defmodule Lemieux.CLI.Learning.ContainerPathsTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Container
  @moduletag :tmp_dir

  test "logical container paths and file tools share one confined workspace", %{tmp_dir: cwd} do
    state = %{workdir: "/app"}
    assert {:ok, :created} = Container.write_file(state, cwd, "/app/result.txt", "inside")
    assert {:ok, "inside"} = Container.read_file(state, cwd, "result.txt")
    assert {:ok, "inside"} = Container.read_file(state, cwd, "/app/result.txt")
    assert {:error, :outside_worktree} = Container.read_file(state, cwd, "/app/../../outside.txt")
    assert {:error, :outside_worktree} = Container.read_file(state, cwd, "/Users/other/secret")
  end
end
