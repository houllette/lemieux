defmodule Lemieux.CLI.HarnessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.TestSupport.HarnessLearningFixtures

  @moduletag :tmp_dir

  test "verifies a golden contract and rejects a tampered one", %{tmp_dir: tmp_dir} do
    snapshot = HarnessLearningFixtures.contracts()["harness_snapshot"]
    valid = Path.join(tmp_dir, "snapshot.json")
    tampered = Path.join(tmp_dir, "tampered.json")
    File.write!(valid, JSON.encode!(snapshot))
    File.write!(tampered, snapshot |> Map.put("model", "tampered:model") |> JSON.encode!())

    assert capture_io(fn -> assert :ok = CLI.run(["harness", "verify", "snapshot", valid]) end) ==
             "verified snapshot #{valid}\n"

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} = CLI.run(["harness", "verify", "snapshot", tampered])
      end)

    assert stderr =~ "could not verify snapshot"
    assert stderr =~ "semantic_digest_mismatch"
  end

  test "materializes a supplied bundle using local id-addressed artifacts", %{tmp_dir: tmp_dir} do
    bundle = HarnessLearningFixtures.contracts()["experience_bundle"]
    bundle_path = Path.join(tmp_dir, "bundle.json")
    artifact_dir = Path.join(tmp_dir, "artifacts")
    destination = Path.join(tmp_dir, "discovery")
    File.mkdir_p!(artifact_dir)
    File.write!(bundle_path, JSON.encode!(bundle))
    File.write!(Path.join(artifact_dir, "artifact-fixture"), "fixture bytes")
    on_exit(fn -> make_tree_writable(destination) end)

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "harness",
                   "materialize",
                   bundle_path,
                   artifact_dir,
                   destination
                 ])
      end)

    assert output == destination <> "\n"
    assert File.read!(Path.join(destination, ".complete")) == bundle["sha256"]

    assert File.read!(Path.join(destination, "candidates/candidate-fixture/raw/transcript.bin")) ==
             "fixture bytes"
  end

  test "prints the bounded harness command usage for an unsupported type" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} = CLI.run(["harness", "verify", "wat", "x"])
      end)

    assert stderr =~ "lmx harness verify TYPE FILE"
    assert stderr =~ "snapshot"
    refute stderr =~ "activate"
  end

  test "materialization never resolves an artifact id outside its supplied directory", %{
    tmp_dir: tmp_dir
  } do
    fixture = HarnessLearningFixtures.contracts()["experience_bundle"]
    [descriptor] = fixture["artifacts"]
    escaped_reference = Map.put(descriptor["reference"], "id", "../outside")

    assert {:ok, bundle} =
             fixture
             |> Map.delete("sha256")
             |> put_in(["artifacts", Access.at(0), "reference"], escaped_reference)
             |> Bundle.new()

    bundle_path = Path.join(tmp_dir, "bundle.json")
    artifact_dir = Path.join(tmp_dir, "artifacts")
    destination = Path.join(tmp_dir, "discovery")
    File.mkdir_p!(artifact_dir)
    File.write!(bundle_path, Bundle.encode!(bundle))
    File.write!(Path.join(tmp_dir, "outside"), "fixture bytes")

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 CLI.run([
                   "harness",
                   "materialize",
                   bundle_path,
                   artifact_dir,
                   destination
                 ])
      end)

    assert stderr =~ "could not materialize bundle"
    refute File.exists?(destination)
  end

  defp make_tree_writable(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> then(&[root | &1])
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(&File.chmod(&1, 0o755))
  end
end
