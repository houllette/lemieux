defmodule Lemieux.CLI.Learning.ContainerPathsTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Container
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tools.Bash
  @moduletag :tmp_dir

  test "auto mode recognizes the container boundary while current deny rules still win", %{
    tmp_dir: cwd
  } do
    environment =
      {Container,
       %{image: "sha256:" <> String.duplicate("a", 64), user: "1000:1000", workdir: "/workspace"}}

    assert Sandbox.sandboxed?(environment)
    {:ok, policy} = Permissions.init(mode: :auto, non_interactive: :deny)
    call = %{id: "verify", name: "bash", arguments: %{"command" => "make test"}}

    context = %{
      cwd: cwd,
      environment: environment,
      tool_descriptor: Bash |> Tool.descriptor() |> Descriptor.to_map()
    }

    assert :allow = Permissions.check(policy, call, context)

    {:ok, restricted} =
      Permissions.init(mode: :auto, non_interactive: :deny, deny: ["Bash(make test)"])

    assert {:deny, reason} = Permissions.check(restricted, call, context)
    assert reason =~ "denied by the permission rule"
  end

  test "logical container paths and file tools share one confined workspace", %{tmp_dir: cwd} do
    state = %{workdir: "/app"}
    assert {:ok, :created} = Container.write_file(state, cwd, "/app/result.txt", "inside")
    assert {:ok, "inside"} = Container.read_file(state, cwd, "result.txt")
    assert {:ok, "inside"} = Container.read_file(state, cwd, "/app/result.txt")
    assert {:error, :outside_worktree} = Container.read_file(state, cwd, "/app/../../outside.txt")
    assert {:error, :outside_worktree} = Container.read_file(state, cwd, "/Users/other/secret")
  end
end
