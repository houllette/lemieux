defmodule Lemieux.RepositoryContext.EvaluationTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "the shipped offline comparison produces a valid receipt and verifies stale fallback" do
    output =
      capture_io(fn ->
        Code.eval_file(Path.expand("../../../scripts/eval_repository_context.exs", __DIR__))
      end)

    receipt = JSON.decode!(output)
    assert receipt["mode"] == "offline_mechanical"
    assert receipt["model"] == nil
    refute receipt["agent_quality_qualified"]
    assert length(receipt["pairs"]) == 2
    assert Enum.all?(receipt["pairs"], &(&1["baseline"]["hit"] and &1["candidate"]["hit"]))
    assert receipt["cold_index"]["parsed"] == 2
    assert receipt["warm_index"]["reused"] == 2
    assert receipt["update_index"]["parsed"] == 1
    assert receipt["stale_context"] == %{"withheld" => true, "literal_fallback" => true}
  end
end
