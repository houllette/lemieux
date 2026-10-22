defmodule Lemieux.Learning.Refinement.SupportTest do
  use ExUnit.Case, async: true
  alias Lemieux.Learning.Refinement.Support

  @research %{"id" => "experimental_mean/v1", "minimum_gain" => 0.1, "minimum_repetitions" => 2}

  test "the strict default and experimental repeated mean answer different questions" do
    control = records([0, 1])
    candidate = records([1, 1])
    refute Support.supported?(control, candidate, true, Support.strict())
    assert Support.supported?(control, candidate, true, @research)
    refute Support.supported?(candidate, candidate, true, @research)
    refute Support.supported?(candidate, control, true, @research)
  end

  test "experimental adoption permits observed task failures, never safety or missing evidence" do
    control = records([0, 0, 1])
    candidate = records([0, 1, 1])
    assert Support.supported?(control, candidate, true, @research)
    [first | rest] = candidate

    for unsafe <- [
          Map.put(first, "safety_failure", true),
          Map.delete(first, "safety_failure"),
          Map.put(first, "evidence_complete", false),
          Map.put(first, "score", nil)
        ] do
      refute Support.supported?(control, [unsafe | rest], true, @research)
      refute Support.supported?([unsafe | rest], candidate, true, @research)
    end

    refute Support.supported?(control, tl(candidate), true, @research)
    refute Support.supported?(records([0]), records([1]), true, @research)
  end

  test "policies are bounded, explicit and frozen data" do
    assert :ok = Support.verify(Support.strict())
    assert :ok = Support.verify(@research)
    assert {:error, _} = Support.verify(Map.put(@research, "minimum_gain", 0))
    assert {:error, _} = Support.verify(Map.put(@research, "minimum_repetitions", 1))
    assert {:error, _} = Support.verify(Map.put(@research, "override_safety", true))
    refute Support.supported?(records([0, 0]), records([1, 1]), true, %{})
  end

  test "version 2 tries repeated verified perfect ties without calling them a quality gain" do
    policy = @research |> Map.put("id", "experimental_mean/v2") |> Map.put("verified_ties", true)
    assert :ok = Support.verify(policy)
    assert Support.supported?(records([1, 1]), records([1, 1]), true, policy)
    refute Support.supported?(records([1, 1]), records([1, 1]), false, policy)
    refute Support.supported?(records([1, 1]), records([1, 0]), true, policy)
    refute Support.supported?(records([0, 0]), records([0, 0]), true, policy)
    refute Support.supported?(records([1, 1]), records([1, 1]), true, @research)
    refute Support.supported?(records([1, 1]), records([1, 1]), true, Support.strict())
  end

  defp records(scores) do
    Enum.map(
      scores,
      &%{
        "score" => &1,
        "regression" => &1 == 0,
        "safety_failure" => false,
        "evidence_complete" => true,
        "verified_success" => &1 == 1
      }
    )
  end
end
