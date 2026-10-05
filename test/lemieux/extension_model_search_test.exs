defmodule Lemieux.Extension.ModelSearchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Learning.Extension.ModelSearch

  defmodule Catalog do
    def available_models(_state, _opts), do: ["one:a", "two:b"]
    def reasoning_efforts(_state, "one:a"), do: ["default", "low", "high"]
    def reasoning_efforts(_state, _model), do: []
    def validate_model(_state, _model, _tools), do: :ok
  end

  test "only user-selected, configured model and effort combinations become candidates" do
    provider = {Catalog, nil}

    assert {:ok, candidates} =
             ModelSearch.select(provider, [%{"model" => "one:a", "efforts" => ["low", "high"]}])

    assert Enum.map(candidates, & &1["reasoning_effort"]) == ["low", "high"]
    assert Enum.all?(candidates, &(&1["availability"] == "configured_catalog"))
    refute inspect(candidates) =~ "two:b"

    assert {:error, {:model_not_available, "absent:c"}} =
             ModelSearch.select(provider, [%{"model" => "absent:c", "efforts" => ["default"]}])

    assert {:error, {:effort_not_available, "two:b", "high"}} =
             ModelSearch.select(provider, [%{"model" => "two:b", "efforts" => ["high"]}])

    assert {:ok, [%{"reasoning_effort" => "default"}]} =
             ModelSearch.select(provider, [%{"model" => "two:b", "efforts" => ["default"]}])
  end

  test "duplicates and unbounded or malformed selections are refused" do
    selection = %{"model" => "one:a", "efforts" => ["low"]}

    assert {:error, :duplicate_candidates} =
             ModelSearch.select({Catalog, nil}, [selection, selection])

    assert {:error, :invalid_model_selection} = ModelSearch.select({Catalog, nil}, [])

    assert {:error, :invalid_model_selection} =
             ModelSearch.select({Catalog, nil}, [%{"model" => "one:a", "efforts" => []}])
  end
end
