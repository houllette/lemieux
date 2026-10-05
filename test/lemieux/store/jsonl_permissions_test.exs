defmodule Lemieux.Store.JSONLPermissionsTest do
  # Transcripts hold whole prompts, tool output and the contents of files the
  # agent read — `.env` included when it read one — so they are kept the way
  # lmx keeps its config and tokens: owner-only.
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  import Bitwise

  @moduletag :tmp_dir

  if match?({:win32, _}, :os.type()) do
    @moduletag skip: "POSIX modes; NTFS has none to assert"
  end

  defp entry(text), do: Entry.new(:user, %{"text" => text})
  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "a new sessions directory is 0700 and a new transcript 0600", %{tmp_dir: tmp_dir} do
    dir = Path.join([tmp_dir, "lmx", "sessions"])
    store = JSONL.new(dir)

    :ok = Store.append(store, "s1", [entry("hello")])

    assert mode(dir) == 0o700
    assert mode(Path.join(dir, "s1.jsonl")) == 0o600
    assert {:ok, [%Entry{payload: %{"text" => "hello"}}]} = Store.read(store, "s1")
  end

  # The lock is the first file a session writes, before any transcript line.
  test "a lock taken before anything is written makes the directory private too",
       %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "sessions")
    store = JSONL.new(dir)

    {:ok, lock} = Store.lock(store, "s1")

    assert mode(dir) == 0o700
    :ok = Store.unlock(store, "s1", lock)
  end

  test "a transcript an earlier build left open is tightened on its next write",
       %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "sessions")
    store = JSONL.new(dir)

    :ok = Store.append(store, "old", [entry("first")])
    transcript = Path.join(dir, "old.jsonl")
    File.chmod!(transcript, 0o644)

    :ok = Store.append(store, "old", [entry("second")])

    assert mode(transcript) == 0o600
    assert {:ok, [_first, _second]} = Store.read(store, "old")
  end

  # `/tmp`, a project, a shared volume: a store run as root used to chmod
  # whatever directory it was given, sticky bit and all.
  test "a directory that already existed keeps its mode", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "shared")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o777)
    store = JSONL.new(dir)

    {:ok, lock} = Store.lock(store, "s1")
    :ok = Store.append(store, "s1", [entry("hello")])
    :ok = Store.unlock(store, "s1", lock)

    assert mode(dir) == 0o777
    assert mode(Path.join(dir, "s1.jsonl")) == 0o600
  end
end
