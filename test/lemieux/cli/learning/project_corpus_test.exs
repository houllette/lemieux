defmodule Lemieux.CLI.Learning.ProjectCorpusTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.Projects
  alias Lemieux.CLI.Learning.Projects.Corpus

  @tag :tmp_dir
  test "native materialization retains families, private cases and executable Python oracles", %{
    tmp_dir: root
  } do
    fixtures = Corpus.materialize(root, "development", 2)
    assert length(fixtures) == 16

    assert fixtures |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> Enum.sort() ==
             ~w(allocation cache graph intervals journal merge patch reconcile)

    assert_fresh_variants(fixtures, "development")

    for fixture <- fixtures do
      cwd = fixture["cwd"]
      cases = fixture["probe_cases"] ++ fixture["cases"]
      inputs = JSON.encode!(Enum.map(cases, &hd/1))
      expected = Enum.map(cases, &List.last/1)
      {broken, 0} = System.cmd("python3", ["main.py", inputs], cd: cwd)
      refute JSON.decode!(broken) == expected

      File.write!(Path.join(cwd, "src/project/core.py"), fixture["offline_oracle"])
      File.rm_rf!(Path.join(cwd, ".build"))
      File.cp_r!(Path.join(cwd, "src"), Path.join(cwd, ".build"))
      {actual, 0} = System.cmd("python3", ["main.py", inputs], cd: cwd)
      assert JSON.decode!(actual) == expected
      assert {"public checks passed\n", 0} = System.cmd("python3", ["checks.py"], cd: cwd)

      for {name, bytes} <- fixture["immutable"] do
        assert File.read!(Path.join(cwd, name)) == bytes
        refute bytes =~ "private-development-", "#{fixture["id"]}/#{name} leaked private inputs"

        refute bytes =~ fixture["offline_oracle"],
               "#{fixture["id"]}/#{name} leaked its reference solution"
      end

      refute Map.has_key?(fixture["immutable"], "src/project/core.py")
      refute fixture["probe_cases"] == fixture["cases"]
    end
  end

  @tag :tmp_dir
  test "fresh variants preserve their cluster and partitions keep distinct identities", %{
    tmp_dir: root
  } do
    # The executable development fixtures above already cover this partition;
    # rebuilding another sixteen repositories here adds no partition coverage.
    for partition <- ~w(seed confirmation) do
      fixtures = Corpus.materialize(root, partition, 2)
      assert_fresh_variants(fixtures, partition)

      [first, second] =
        fixtures
        |> Enum.filter(&(&1["cluster"] == "graph"))

      inputs = fn fixture ->
        fixture["cases"] |> Enum.map(&hd/1) |> Enum.reject(&(&1["nodes"] == [])) |> MapSet.new()
      end

      assert MapSet.disjoint?(inputs.(first), inputs.(second))
      assert first["id"] == "#{partition}-graph-1"
      assert second["id"] == "#{partition}-graph-2"
    end
  end

  @tag :tmp_dir
  test "host imports the native corpus into qualification tasks", %{tmp_dir: root} do
    [fixture | _] = Projects.materialize(root, "seed", 1)
    assert fixture.id == "seed-graph-1"
    assert fixture.cluster == "graph"
    assert fixture.task.id == fixture.id
    assert fixture.task.cwd == Path.join(root, fixture.id)
    assert {:ok, digest} = Leases.source_digest(fixture.task.cwd)
    assert fixture.source_sha256 == digest

    assert hd(fixture.cases) == {
             %{
               "nodes" => ~w(private-seed-1-c private-seed-1-b private-seed-1-a),
               "edges" => [["private-seed-1-c", "private-seed-1-a"]]
             },
             [~w(private-seed-1-a private-seed-1-b), ["private-seed-1-c"]]
           }

    assert fixture.task.timeout_ms == 480_000
  end

  defp assert_fresh_variants(fixtures, partition) do
    for {family, [first, second]} <- Enum.group_by(fixtures, & &1["cluster"]) do
      assert first["id"] == "#{partition}-#{family}-1"
      assert second["id"] == "#{partition}-#{family}-2"
      first_inputs = MapSet.new(first["cases"], &hd/1)
      second_inputs = MapSet.new(second["cases"], &hd/1)
      refute first_inputs == second_inputs, "#{family}: variants reused all of their inputs"
    end
  end
end
