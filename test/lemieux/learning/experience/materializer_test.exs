defmodule Lemieux.Learning.Experience.MaterializerTest do
  use ExUnit.Case, async: true

  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Materializer

  @moduletag :tmp_dir

  test "materializes deterministic read-only history and one writable proposal tree", %{
    tmp_dir: tmp_dir
  } do
    {bundle, artifacts} = bundle_fixture()
    first = Path.join(tmp_dir, "first")
    second = Path.join(tmp_dir, "second")
    on_exit(fn -> Enum.each([first, second], &make_tree_writable/1) end)

    assert {:ok, ^first} = Materializer.materialize(bundle, artifacts, first)
    assert {:ok, ^second} = Materializer.materialize(bundle, artifacts, second)

    assert tree_bytes(first) == tree_bytes(second)
    assert File.read!(Path.join(first, ".complete")) == bundle.sha256
    assert File.read!(Path.join(first, "candidates/candidate-1/raw/trace.txt")) == "raw trace"
    assert File.exists?(Path.join(first, "derived/ixway/finding-1.json"))

    assert mode(Path.join(first, "bundle.json")) == 0o444
    assert mode(Path.join(first, "candidates")) == 0o555
    assert mode(first) == 0o555
    assert mode(Path.join(first, "proposal")) == 0o755
    assert Materializer.writable_path?(first, Path.join(first, "proposal/candidate.json"))
    refute Materializer.writable_path?(first, Path.join(first, "candidates/candidate-1"))
  end

  test "rejects traversal, duplicate paths, digest mismatch, and oversized artifacts", %{
    tmp_dir: tmp_dir
  } do
    {bundle, artifacts} = bundle_fixture()
    [artifact] = bundle.artifacts

    {:ok, traversal} =
      bundle
      |> Bundle.to_map()
      |> Map.delete("sha256")
      |> Map.put("artifacts", [%{artifact | "path" => "../escape"}])
      |> Bundle.new()

    assert {:error, {:invalid_artifact, "../escape", :path_traversal}} =
             Materializer.materialize(traversal, artifacts, Path.join(tmp_dir, "traversal"))

    {:ok, duplicate} =
      bundle
      |> Bundle.to_map()
      |> Map.delete("sha256")
      |> Map.put("artifacts", [artifact, artifact])
      |> Bundle.new()

    assert {:error, :duplicate_or_reserved_path} =
             Materializer.materialize(duplicate, artifacts, Path.join(tmp_dir, "duplicate"))

    assert {:error, {:invalid_artifact, _, :digest_mismatch}} =
             Materializer.materialize(
               bundle,
               %{artifact["reference"]["id"] => "raw tracz"},
               Path.join(tmp_dir, "digest")
             )

    assert {:error, {:artifact_too_large, _}} =
             Materializer.materialize(bundle, artifacts, Path.join(tmp_dir, "large"),
               max_artifact_bytes: 1
             )

    refute File.exists?(Path.join(tmp_dir, "traversal"))
    refute File.exists?(Path.join(tmp_dir, "duplicate"))
  end

  test "rejects a symlinked destination ancestor", %{tmp_dir: tmp_dir} do
    {bundle, artifacts} = bundle_fixture()
    real = Path.join(tmp_dir, "real")
    link = Path.join(tmp_dir, "link")
    File.mkdir!(real)
    File.ln_s!(real, link)

    assert {:error, {:symlink_component, ^link}} =
             Materializer.materialize(bundle, artifacts, Path.join(link, "bundle"))

    refute File.exists?(Path.join(real, "bundle"))
  end

  test "bundle validation rejects hidden exposure, missing derived sources, and cross-scope input" do
    {bundle, _artifacts} = bundle_fixture()
    attrs = Bundle.to_map(bundle) |> Map.delete("sha256")

    assert {:error, {:forbidden_exposure, "holdout"}} =
             attrs |> put_in(["exposures"], [%{"split" => "holdout"}]) |> Bundle.new()

    assert {:error, {:derived_item_missing_sources, "finding-1"}} =
             attrs
             |> put_in(["derived", Access.at(0), "source_references"], [])
             |> Bundle.new()

    assert {:error, {:scope_mismatch, "raw", "trace-1"}} =
             attrs
             |> put_in(["raw", Access.at(0), "scope"], %{"id" => "tenant-b/project-b"})
             |> Bundle.new()
  end

  test "bundle encoding is versioned and tamper evident" do
    {bundle, _artifacts} = bundle_fixture()
    assert {:ok, ^bundle} = bundle |> Bundle.encode!() |> Bundle.decode()

    assert {:error, :digest_mismatch} =
             bundle |> Bundle.to_map() |> Map.put("id", "tampered") |> Bundle.verify()

    assert {:error, {:unsupported_version, 2}} =
             bundle
             |> Bundle.to_map()
             |> Map.put("schema_version", 2)
             |> JSON.encode!()
             |> Bundle.decode()
  end

  defp bundle_fixture do
    scope = %{"id" => "tenant-a/project-a"}
    bytes = "raw trace"

    reference =
      ArtifactReference.from_bytes("request_trace", bytes,
        id: "trace-artifact",
        media_type: "text/plain",
        content_schema: "lemieux-request-trace/v1",
        scope: scope
      )

    attrs = %{
      "id" => "bundle-1",
      "scope" => scope,
      "plan" => %{"id" => "plan-1", "sha256" => String.duplicate("a", 64), "scope" => scope},
      "seeds" => [
        %{"id" => "seed-1", "scope" => scope, "sha256" => String.duplicate("b", 64)}
      ],
      "candidates" => [
        %{"id" => "candidate-1", "scope" => scope, "sha256" => String.duplicate("c", 64)}
      ],
      "evaluations" => [
        %{
          "id" => "evaluation-1",
          "candidate_id" => "candidate-1",
          "scope" => scope,
          "sha256" => String.duplicate("d", 64)
        }
      ],
      "raw" => [
        %{"id" => "trace-1", "scope" => scope, "reference" => ArtifactReference.to_map(reference)}
      ],
      "derived" => [
        %{
          "id" => "finding-1",
          "source" => "ixway",
          "scope" => scope,
          "source_references" => ["trace-artifact"],
          "finding_sha256" => String.duplicate("e", 64)
        }
      ],
      "exposures" => [%{"source_case_ids" => ["dev-1"], "consumer_role" => "proposer"}],
      "artifacts" => [
        %{
          "id" => "trace-file",
          "path" => "candidates/candidate-1/raw/trace.txt",
          "scope" => scope,
          "reference" => ArtifactReference.to_map(reference)
        }
      ],
      "frontier" => %{"candidate_ids" => ["candidate-1"]}
    }

    assert {:ok, bundle} = Bundle.new(attrs)
    {bundle, %{reference.id => bytes}}
  end

  defp tree_bytes(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&{Path.relative_to(&1, root), File.read!(&1)})
    |> Enum.sort()
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp make_tree_writable(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> then(&[root | &1])
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(&File.chmod(&1, 0o755))
  end
end
