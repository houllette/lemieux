defmodule Lemieux.ExtensionBuilderRefinementTest do
  use ExUnit.Case, async: true

  @bench Path.expand("../../examples/extensions/builder/bench", __DIR__)
  Code.require_file("refinement_cases.exs", @bench)
  @moduletag :tmp_dir

  test "reopening a refinement campaign verifies its original inputs", %{tmp_dir: root} do
    inputs = Path.join(root, "inputs")
    ids = LemieuxBuilderBench.RefinementCases.prepare(inputs, File.cwd!())
    assert LemieuxBuilderBench.RefinementCases.prepare(inputs, "/not-used-for-a-reopen") == ids
    File.write!(Path.join(inputs, "audit_clean/brief.txt"), "changed")

    assert_raise MatchError, fn ->
      LemieuxBuilderBench.RefinementCases.prepare(inputs, File.cwd!())
    end

    assert File.read!(Path.join(inputs, "audit_clean/brief.txt")) == "changed"
  end

  test "audit grader detects the seeded defect and refuses a false finding", %{tmp_dir: root} do
    inputs = Path.join(root, "inputs")
    LemieuxBuilderBench.RefinementCases.create(inputs, File.cwd!())
    cwd = Path.join(root, "attempt")
    File.cp_r!(Path.join(inputs, "audit_bound"), cwd)
    File.write!(Path.join(cwd, "BUILDING.md"), String.duplicate("Evidence recorded. ", 4))

    finding = %{
      "file" => "lib/lemieux/learning/extension/workbench.ex",
      "quote" => "max(existing, maximum)",
      "description" => "The session request cap is widened instead of tightened."
    }

    File.write!(Path.join(cwd, "review.json"), JSON.encode!(%{"findings" => []}))
    assert grade(cwd, "audit_bound", inputs) == 1
    File.write!(Path.join(cwd, "review.json"), JSON.encode!(%{"findings" => [finding]}))
    assert grade(cwd, "audit_bound", inputs) == 0

    File.cp!(
      Path.join(inputs, "audit_clean/lib/lemieux/learning/extension/workbench.ex"),
      Path.join(cwd, "lib/lemieux/learning/extension/workbench.ex")
    )

    assert grade(cwd, "audit_clean", inputs) == 1
    File.write!(Path.join(cwd, "review.json"), JSON.encode!(%{"findings" => []}))
    assert grade(cwd, "audit_clean", inputs) == 0
  end

  test "repair grader requires the exact repair and preserves developer files", %{tmp_dir: root} do
    inputs = Path.join(root, "inputs")
    LemieuxBuilderBench.RefinementCases.create(inputs, File.cwd!())
    cwd = Path.join(root, "attempt")
    File.cp_r!(Path.join(inputs, "repair_profile"), cwd)
    path = Path.join(cwd, "priv/profile.json")
    profile = path |> File.read!() |> JSON.decode!()

    File.write!(
      Path.join(cwd, "outcome.json"),
      JSON.encode!(%{"benchmarked" => false, "qualification" => "unassessed"})
    )

    assert grade(cwd, "repair_profile", inputs) == 1
    File.write!(path, JSON.encode!(put_in(profile, ["options", "reasoning_effort"], "default")))
    assert grade(cwd, "repair_profile", inputs) == 0
    File.write!(Path.join(cwd, "README.md"), "replaced")
    assert grade(cwd, "repair_profile", inputs) == 1
  end

  defp grade(cwd, id, inputs) do
    {_output, status} =
      System.cmd(
        "elixir",
        ["--erl", "+S 2:2", Path.join(@bench, "refinement_grade.exs"), cwd, id, inputs],
        stderr_to_stdout: true
      )

    status
  end
end
