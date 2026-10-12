defmodule Lemieux.JobsJournalTest do
  use ExUnit.Case, async: true
  alias Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal.Files
  @moduletag :tmp_dir

  test "CAS refuses stale writers and bounded pages survive reconstruction", %{tmp_dir: dir} do
    journal = Files.new(dir)
    assert {:ok, first} = Journal.write(journal, "job-a", 0, %{"status" => "queued"})
    assert {:error, :conflict} = Journal.write(journal, "job-a", 0, %{"status" => "lost"})
    assert {:ok, _record} = Journal.write(journal, "job-b", 0, %{"status" => "queued"})
    assert {:ok, [^first]} = Journal.scan(Files.new(dir), "job-", nil, 1)
    assert {:ok, [%{key: "job-b"}]} = Journal.scan(journal, "job-", "job-a", 1)
    assert {:error, :invalid_key} = Journal.write(journal, "../escape", 0, %{})
    assert {:error, :not_found} = Journal.read(journal, "missing")
  end

  test "a live host claim excludes other writers and a dead holder can be recovered", %{
    tmp_dir: dir
  } do
    journal = Files.new(dir)
    owner = self()

    holder =
      spawn(fn ->
        {:ok, _lock} = Journal.lock(journal, "host")
        send(owner, :claimed)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :claimed
    assert {:error, {:locked, _holder}} = Journal.lock(journal, "host")
    monitor = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert {:ok, lock} = Journal.lock(journal, "host")
    assert :ok = Journal.unlock(journal, "host", lock)
  end

  test "symlink and malformed records are refused without skipping them", %{tmp_dir: dir} do
    journal = Files.new(dir)
    File.write!(Path.join(dir, "private"), "sensitive")
    File.ln_s!(Path.join(dir, "private"), Path.join(dir, "job-link.json"))
    assert {:error, :unreadable_record} = Journal.read(journal, "job-link")
    File.write!(Path.join(dir, "job-bad.json"), JSON.encode!(%{"version" => 99}))
    assert {:error, :unreadable_record} = Journal.scan(journal, "job-", nil, 10)
  end
end
