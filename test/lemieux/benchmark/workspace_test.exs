defmodule Lemieux.Benchmark.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.Workspace
  alias Lemieux.Benchmark.WorkspaceSnapshot

  @moduletag :tmp_dir

  test "a copy is its own Git repository, so a commit inside it cannot reach an enclosing one",
       %{tmp_dir: root} do
    git = System.find_executable("git")
    enclosing = Path.join(root, "enclosing")
    fixture = Path.join(enclosing, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "state"), "original")
    {_output, 0} = System.cmd(git, ["init", "-q"], cd: enclosing)

    task = struct!(Task, id: "task", prompt: "Inspect", cwd: fixture, grader: nil)

    {:ok, copy, cleanup} =
      Workspace.copy(task, %{
        runtime: "r",
        attempt: 1,
        workspace_root: Path.join(enclosing, "attempts")
      })

    {top, 0} = System.cmd(git, ["rev-parse", "--show-toplevel"], cd: copy.cwd)
    assert Path.basename(String.trim(top)) == Path.basename(copy.cwd)
    refute String.ends_with?(String.trim(top), "/enclosing")

    # Committing inside the copy stays inside it and is invisible to the
    # snapshot the safety gate diffs.
    {:ok, before} = WorkspaceSnapshot.capture(copy.cwd)
    File.write!(Path.join(copy.cwd, "state"), "edited")

    {_output, 0} =
      System.cmd(
        git,
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "add", "-A"],
        cd: copy.cwd
      )

    {_output, 0} =
      System.cmd(
        git,
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "x"],
        cd: copy.cwd
      )

    {:ok, after_commit} = WorkspaceSnapshot.capture(copy.cwd)
    refute Enum.any?(Map.keys(after_commit), &String.starts_with?(&1, ".git"))
    assert Map.keys(after_commit) == Map.keys(before)

    {count, 0} = System.cmd(git, ["rev-list", "--all", "--count"], cd: enclosing)
    assert String.trim(count) == "0"
    cleanup.()
  end

  test "independent VMs cannot overwrite or clean up each other's attempt", %{tmp_dir: root} do
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "state"), "original")

    code = """
    [source, root] = System.argv()
    task = struct!(Lemieux.Benchmark.Task, id: "same-task", prompt: "Inspect", cwd: source, grader: nil)
    {:ok, copy, _cleanup} = Lemieux.Benchmark.Workspace.copy(task, %{runtime: "same-runtime", attempt: 1, workspace_root: root})
    IO.write(copy.cwd)
    """

    args = [
      "--erl",
      "+S 2",
      "-pa",
      Path.join(to_string(:code.lib_dir(:lemieux)), "ebin"),
      "-e",
      code,
      "--",
      source,
      Path.join(root, "attempts")
    ]

    {first, 0} = System.cmd(System.find_executable("elixir"), args)
    File.write!(Path.join(first, "state"), "first attempt's edit")
    {second, 0} = System.cmd(System.find_executable("elixir"), args)
    assert first != second
    assert File.read!(Path.join(first, "state")) == "first attempt's edit"
    assert File.read!(Path.join(second, "state")) == "original"
    File.rm_rf!(first)
    assert File.read!(Path.join(second, "state")) == "original"
  end
end
