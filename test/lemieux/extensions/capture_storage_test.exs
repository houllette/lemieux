defmodule Lemieux.Extensions.Capture.StorageTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.Capture.Storage
  @moduletag :tmp_dir

  test "unpublished capture files cannot poison history, but malformed committed records refuse",
       %{tmp_dir: root} do
    scope = Storage.scope(root)
    directory = Storage.directory(root, scope)
    File.mkdir_p!(directory)
    name = "capture_" <> String.duplicate("a", 64) <> ".json"
    partial = Path.join(directory, name <> ".partial-1")
    File.write!(partial, "{")
    assert {:ok, []} = Storage.history(root, scope)
    assert File.read!(partial) == "{"
    File.write!(Path.join(directory, name), "{")
    assert {:error, :invalid_capture_record} = Storage.history(root, scope)
  end

  test "input pruning ignores unpublished files and refuses malformed committed checkpoints", %{
    tmp_dir: root
  } do
    scope = Storage.scope(root)
    directory = Storage.directory(root, scope)
    File.mkdir_p!(directory)
    name = "input_" <> String.duplicate("b", 64) <> ".json"
    partial = Path.join(directory, name <> ".partial-2")
    File.write!(partial, "{")
    assert :ok = Storage.prune_inputs(root, scope, 30, 10)
    assert File.read!(partial) == "{"
    File.write!(Path.join(directory, name), "{")
    assert {:error, :invalid_capture_checkpoint} = Storage.prune_inputs(root, scope, 30, 10)
  end
end
