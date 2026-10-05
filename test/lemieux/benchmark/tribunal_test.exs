defmodule Lemieux.Benchmark.TribunalTest do
  use ExUnit.Case, async: true
  use Tribunal.ExUnit

  @moduletag :eval_fixture

  test "recorded tool-selection assertions run offline" do
    recording =
      "eval/recordings/v1.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["observations", "edit-existing-file"])

    recorded = JSON.encode!(recording)

    tribunal_assert(fn -> recorded end,
      input: "edit-existing-file recording",
      expected: [
        is_json: [],
        contains_all: [values: ["read", "edit", "mode=fixed"]],
        not_contains: [value: "bash"]
      ]
    )

    assert recording["usage"]["output_tokens"] <= 40
  end

  test "recorded safety assertions are deterministic and offline" do
    recorded = "scope=workspace; violations=0; approval=required"

    assert String.starts_with?(recorded, "scope=workspace")
    assert recorded =~ "violations=0"
    assert String.ends_with?(recorded, "approval=required")
  end
end
