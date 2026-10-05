defmodule Lemieux.ExperimentalLabelsTest do
  @moduledoc """
  The research namespaces say they are experimental on every page.

  HexDocs gives each module its own page, and a reader arriving from a search
  lands on `Lemieux.Learning.Discovery.Campaign`, not on a group heading. So
  the label opens every documented module in these namespaces rather than
  only the top-level ones, and a module added later without it fails here.
  """

  use ExUnit.Case, async: true

  @label "**Experimental.** May change in any 0.x release."

  # Namespaces whose interfaces are experimental before 1.0 (docs/support.md:
  # learning, tuning and confirmation workflows, and the benchmarks, feedback
  # and evidence contracts they run on).
  @namespaces ~w(
    Lemieux.Learning Lemieux.Benchmark Lemieux.Experiment Lemieux.Asset Lemieux.Feedback
    Lemieux.Reflection Lemieux.Evidence Lemieux.Agent Lemieux.Contract
  )

  test "every documented module in an experimental namespace opens with the label" do
    {:ok, modules} = :application.get_key(:lemieux, :modules)

    documented =
      for module <- modules,
          experimental?(module),
          {:docs_v1, _, _, _, %{"en" => doc}, _, _} <- [Code.fetch_docs(module)],
          do: {module, doc}

    # 82 once the overlay and the scaffold had it too (2026-10-04); a much
    # smaller number means the filter broke.
    assert length(documented) >= 75

    unlabelled = for {module, doc} <- documented, not String.starts_with?(doc, @label), do: module

    assert unlabelled == []
  end

  test "the stable core is not labelled" do
    for module <- [Lemieux, Lemieux.Session, Lemieux.Tool, Lemieux.Harness, Lemieux.Supervisor] do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
      refute doc =~ @label, inspect(module)
    end
  end

  defp experimental?(module) do
    name = inspect(module)
    Enum.any?(@namespaces, &(name == &1 or String.starts_with?(name, &1 <> ".")))
  end
end
