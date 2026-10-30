defmodule RepositoryRulesTest do
  use ExUnit.Case, async: true

  test "the protected branch requires every CI and public-readiness check from GitHub Actions" do
    policy = read_json(".github/rulesets/main.json")
    rule = Enum.find(policy["rules"], &(&1["type"] == "required_status_checks"))
    checks = rule["parameters"]["required_status_checks"]

    expected =
      for file <- ~w(ci public-readiness),
          {_, job} <- workflow(file)["jobs"],
          name <- names(job),
          do: name

    assert Enum.sort(Enum.map(checks, & &1["context"])) == Enum.sort(expected)
    assert Enum.all?(checks, &(&1["integration_id"] == 15_368))
    assert rule["parameters"]["strict_required_status_checks_policy"]
    assert policy["enforcement"] == "active"
    assert policy["bypass_actors"] == []
    assert policy["conditions"]["ref_name"]["include"] == ["refs/heads/main"]
  end

  test "sole-maintainer merges still require a pull request and resolved conversations" do
    rules = read_json(".github/rulesets/main.json")["rules"]
    pull = Enum.find(rules, &(&1["type"] == "pull_request"))["parameters"]

    assert pull["required_approving_review_count"] == 0
    assert pull["required_review_thread_resolution"]
    assert pull["allowed_merge_methods"] == ["squash"]

    assert Enum.all?(~w(deletion non_fast_forward required_linear_history), fn type ->
             Enum.any?(rules, &(&1["type"] == type))
           end)
  end

  test "version tags allow creation but cannot be moved or deleted through a bypass" do
    policy = read_json(".github/rulesets/releases.json")
    assert policy["target"] == "tag"
    assert policy["enforcement"] == "active"
    assert policy["bypass_actors"] == []
    assert policy["conditions"]["ref_name"]["include"] == ["refs/tags/v*"]

    assert Enum.sort(Enum.map(policy["rules"], & &1["type"])) ==
             ~w(deletion non_fast_forward update)
  end

  defp read_json(path), do: path |> File.read!() |> JSON.decode!()

  defp workflow(name) do
    {:ok, data} = YamlElixir.read_from_string(File.read!(".github/workflows/#{name}.yml"))
    data
  end

  defp names(%{"name" => name, "strategy" => %{"matrix" => %{"include" => rows}}}) do
    Enum.map(rows, fn row ->
      Regex.replace(~r/\$\{\{ matrix\.(\w+) \}\}/, name, fn _, key -> Map.fetch!(row, key) end)
    end)
  end

  defp names(%{"name" => name}), do: [name]
end
