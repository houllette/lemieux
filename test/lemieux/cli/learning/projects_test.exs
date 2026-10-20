defmodule Lemieux.CLI.Learning.ProjectsTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Projects
  alias Lemieux.Environment.Local
  @moduletag :tmp_dir

  defmodule HostPython do
    @behaviour Lemieux.Environment
    @impl true
    def read_file(state, cwd, path), do: Local.read_file(state, cwd, path)
    @impl true
    def write_file(state, cwd, path, bytes), do: Local.write_file(state, cwd, path, bytes)
    @impl true
    def run(state, command, opts),
      do: Local.run(state, String.replace_prefix(command, "python ", "python3 "), opts)
  end

  test "source and generated runtime must both pass; private cases remain outside workspaces", %{
    tmp_dir: dir
  } do
    fixture =
      Projects.materialize(dir, "development", 1) |> Enum.find(&(&1.cluster == "allocation"))

    {Local, state} = Local.new(credentials: {:scrub, []})
    environment = {HostPython, state}

    source = """
    def solve(x):
        n, weights = x['total'], x['weights']
        if type(n) is not int or n < 0 or any(type(w) is not int or w < 0 for w in weights): return None
        total = sum(weights)
        if not total: return [0]*len(weights) if n == 0 else None
        result = [n*w//total for w in weights]
        order = sorted(range(len(weights)), key=lambda i: (-(n*weights[i]%total),i))
        for i in order[:n-sum(result)]: result[i] += 1
        return result
    """

    built = Path.join(fixture.task.cwd, ".build/project/core.py")
    implementation = Path.join(fixture.task.cwd, "src/project/core.py")
    File.write!(built, source)
    refute Projects.grade(fixture, fixture.task.cwd, environment)["passed"]
    File.write!(implementation, source)
    assert Projects.grade(fixture, fixture.task.cwd, environment)["passed"]
    File.write!(implementation, "def solve(value):\n    return None\n")
    refute Projects.grade(fixture, fixture.task.cwd, environment)["passed"]
    refute File.exists?(Path.join(fixture.task.cwd, "cases.json"))
    assert length(fixture.cases) > length(fixture.probe_cases)
  end
end
