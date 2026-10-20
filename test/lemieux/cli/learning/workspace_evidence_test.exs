defmodule Lemieux.CLI.Learning.WorkspaceEvidenceTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.WorkspaceEvidence
  @moduletag :tmp_dir

  test "retains actual changed bytes and deletions rather than inferring shell effects", %{
    tmp_dir: root
  } do
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "old.txt"), "old")
    {:ok, _} = File.cp_r(source, workspace)
    File.rm!(Path.join(workspace, "old.txt"))
    File.write!(Path.join(workspace, "generated.txt"), "actual shell output")
    evidence = WorkspaceEvidence.capture(source, workspace)
    assert evidence["complete"]
    assert Enum.find(evidence["entries"], &(&1["path"] == "old.txt"))["type"] == "deleted"
    file = Enum.find(evidence["entries"], &(&1["path"] == "generated.txt"))
    assert Base.decode64!(file["base64"]) == "actual shell output"
  end

  test "oversized changes and unavailable snapshots explicitly refuse complete qualification", %{
    tmp_dir: root
  } do
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(source)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "large.bin"), :binary.copy("x", 1_048_577))
    evidence = WorkspaceEvidence.capture(source, workspace)
    refute evidence["complete"]
    assert hd(evidence["entries"])["reason"] == "size_or_type_limit"
    refute WorkspaceEvidence.capture(Path.join(root, "missing"), workspace)["complete"]
  end
end
