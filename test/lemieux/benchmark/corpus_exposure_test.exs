defmodule Lemieux.Benchmark.CorpusExposureTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Manifest

  setup do
    manifest =
      Manifest.from_map(
        %{
          "version" => 1,
          "tasks" =>
            Enum.map(~w(A B C), fn id ->
              %{
                "id" => id,
                "prompt" => "case #{id}",
                "fixture" => ".",
                "grader" => %{"type" => "command", "command" => ["true"]}
              }
            end)
        },
        File.cwd!()
      )
      |> elem(1)

    {:ok, corpus} =
      Corpus.new(manifest, %{"A" => :development, "B" => :validation, "C" => :holdout})

    %{corpus: corpus}
  end

  test "derived exposure records the complete nested source closure", %{corpus: corpus} do
    derivations = %{
      "finding" => %{"source_case_ids" => ["A"], "source_derivation_ids" => ["summary"]},
      "summary" => %{"source_case_ids" => ["B"], "source_derivation_ids" => []}
    }

    metadata = %{
      exposure_id: "exposure-1",
      consumer_role: "discovery_proposer",
      consumer_id: "discovery-1",
      lineage_id: "lineage-1"
    }

    assert {:ok, exposed} =
             Corpus.expose_derived(corpus, ["finding"], derivations, metadata)

    assert {:ok, exposed_again} =
             Corpus.expose_derived(exposed, ["finding"], derivations, metadata)

    assert [%Exposure{} = exposure] = Corpus.exposures(exposed_again, "A")
    assert exposure.source_case_ids == ["A", "B"]
    assert exposure.derived_artifact_ids == ["finding"]
    assert Corpus.exposures(exposed_again, "B") == [exposure]
    assert {:error, {:case_exposed, "A"}} = Corpus.assign(exposed_again, "A", :holdout)
    refute Exposure.encode!(exposure) =~ "case A"
  end

  test "nested cycles terminate deterministically without losing direct sources" do
    derivations = %{
      "one" => %{"source_case_ids" => ["B"], "source_derivation_ids" => ["two"]},
      "two" => %{"source_case_ids" => ["A"], "source_derivation_ids" => ["one"]}
    }

    assert Corpus.source_closure(derivations, ["one"]) == {:ok, ["A", "B"]}
    assert Corpus.source_closure(derivations, ["two", "one"]) == {:ok, ["A", "B"]}
  end

  test "the same exposure id is idempotent and a conflicting reuse fails", %{corpus: corpus} do
    metadata = %{
      exposure_id: "same",
      consumer_role: "analyzer",
      consumer_id: "ixway-job"
    }

    assert {:ok, once} = Corpus.expose(corpus, ["A"], metadata)
    assert {:ok, twice} = Corpus.expose(once, ["A"], metadata)
    assert length(Corpus.exposures(twice, "A")) == 1

    assert {:error, {:exposure_id_conflict, "same"}} = Corpus.expose(twice, ["B"], metadata)
  end

  test "exposure encoding rejects tampering and unknown versions", %{corpus: corpus} do
    assert {:ok, exposed} =
             Corpus.expose(corpus, ["A"], %{
               exposure_id: "wire",
               consumer_role: "analyzer",
               consumer_id: "ixway-job"
             })

    [exposure] = Corpus.exposures(exposed, "A")
    assert {:ok, ^exposure} = exposure |> Exposure.encode!() |> Exposure.decode()

    assert {:error, :digest_mismatch} =
             exposure
             |> Exposure.to_map()
             |> Map.put("consumer_id", "tampered")
             |> Exposure.verify()

    assert {:error, {:unsupported_version, 3}} =
             exposure
             |> Exposure.to_map()
             |> Map.put("schema_version", 3)
             |> JSON.encode!()
             |> Exposure.decode()
  end
end
