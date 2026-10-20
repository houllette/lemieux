defmodule Lemieux.Learning.ExtensionReviewTest do
  use ExUnit.Case, async: true
  alias Lemieux.Contract
  alias Lemieux.Experiment.CodeGate
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Review

  test "complete declared dependency graphs reject transitively missing helpers" do
    manifest = %{
      "files" => ~w(mix.exs lib/main.ex priv/procedure.md),
      "dependencies" => %{
        "mix.exs" => [],
        "lib/main.ex" => ["priv/procedure.md"],
        "priv/procedure.md" => []
      },
      "capabilities" => ["workspace_read"]
    }

    assert :ok = Export.dependencies(manifest)

    for invalid <- [
          update_in(manifest["dependencies"], &Map.delete(&1, "priv/procedure.md")),
          put_in(manifest["dependencies"]["priv/procedure.md"], ["priv/missing.md"]),
          put_in(manifest["dependencies"]["lib/main.ex"], "invalid"),
          Map.delete(manifest, "capabilities")
        ],
        do: assert({:error, :incomplete_extension_dependencies} = Export.dependencies(invalid))
  end

  test "review binds all source bytes and releases only bounded evidence identities" do
    files = %{"lib/main.ex" => Contract.sha256("source")}
    digest = Contract.digest(files)

    evidence =
      Map.new(
        CodeGate.required_evidence(),
        &{&1, %{"passed" => true, "digest" => Contract.sha256(&1)}}
      )

    gate = %{"content_sha256" => digest, "evidence" => evidence}

    review = %{
      "actor" => "fixture-reviewer",
      "content_sha256" => digest,
      "decision" => "approved_for_export"
    }

    assert :ok = Review.verify(files, gate, review)

    for invalid <- [
          nil,
          %{},
          Map.put(gate, "content_sha256", "altered"),
          put_in(gate["evidence"]["precommit"]["passed"], false),
          put_in(gate["evidence"]["precommit"]["raw_log"], "must never be exported")
        ] do
      assert {:error, _} = Review.verify(files, invalid, review)
    end

    assert {:error, _} =
             Review.verify(Map.put(files, "helper.ex", Contract.sha256("extra")), gate, review)

    assert {:error, _} = Review.verify(files, gate, Map.put(review, "decision", "deploy"))
  end
end
