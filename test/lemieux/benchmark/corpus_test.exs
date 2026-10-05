defmodule Lemieux.Benchmark.CorpusTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Grader.Command
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Task

  test "prevents an exposed development case from being relabeled as hidden holdout" do
    manifest = %Manifest{tasks: [task("one"), task("two")]}

    assert {:ok, corpus} =
             Corpus.new(manifest, %{"one" => :development, "two" => :holdout})

    assert {:ok, exposed} =
             Corpus.expose(corpus, ["one"], %{
               model: "model",
               context_digest: "context",
               experiment_id: "experiment"
             })

    assert {:error, {:case_exposed, "one"}} = Corpus.assign(exposed, "one", :holdout)
    assert [%{experiment_id: "experiment"}] = Corpus.exposures(exposed, "one")
    assert Enum.map(Corpus.cases(exposed, :holdout), & &1.id) == ["two"]
  end

  test "requires every manifest case to have exactly one known split" do
    manifest = %Manifest{tasks: [task("one")]}
    assert {:error, {:missing_split, ["one"]}} = Corpus.new(manifest, %{})

    assert {:error, {:unknown_split, "one", :training}} =
             Corpus.new(manifest, %{"one" => :training})
  end

  test "rejects incomplete exposure metadata without raising" do
    manifest = %Manifest{tasks: [task("one")]}
    assert {:ok, corpus} = Corpus.new(manifest, %{"one" => :development})

    assert {:error, {:missing_exposure_field, :context_digest}} =
             Corpus.expose(corpus, ["one"], %{model: "model", experiment_id: "experiment"})
  end

  defp task(id) do
    %Task{id: id, prompt: id, cwd: ".", grader: %Command{command: ["true"]}}
  end
end
