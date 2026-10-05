defmodule Lemieux.Store.JSONLTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{store: JSONL.new(tmp_dir)}
  end

  describe "append/3 and read/2" do
    test "append then read returns entries in order", %{store: store} do
      first = Entry.new(:user, %{"text" => "one"})
      second = Entry.new(:assistant, %{"content" => []}, parent: first)

      :ok = Store.append(store, "s1", [first])
      :ok = Store.append(store, "s1", [second])

      assert Store.read(store, "s1") == {:ok, [first, second]}
    end

    test "a batch is appended in the order given", %{store: store} do
      entries = for n <- 1..5, do: Entry.new(:user, %{"text" => "#{n}"})

      :ok = Store.append(store, "s1", entries)

      assert {:ok, ^entries} = Store.read(store, "s1")
    end

    test "read on an unknown session returns {:error, :not_found}", %{store: store} do
      assert Store.read(store, "nope") == {:error, :not_found}
    end

    test "entries survive reopening the store", %{store: store, tmp_dir: tmp_dir} do
      entry = Entry.new(:user, %{"text" => "durable"})
      :ok = Store.append(store, "s1", [entry])

      assert Store.read(JSONL.new(tmp_dir), "s1") == {:ok, [entry]}
    end

    test "a torn final append does not hide the committed prefix", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      entry = Entry.new(:user, %{"text" => "committed"})
      :ok = Store.append(store, "s1", [entry])
      :ok = File.write(Path.join(tmp_dir, "s1.jsonl"), ~s({"v":1,"payload":), [:append])

      assert Store.read(store, "s1") == {:ok, [entry]}
    end

    # The half of surviving a torn tail that a read cannot do: the next append
    # used to land on the end of the fragment, making one corrupt line in the
    # committed prefix, and the session that had survived the crash was lost to
    # resume one entry later.
    test "an append after a torn tail cuts the fragment and stays readable", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      committed = Entry.new(:user, %{"text" => "committed"})
      later = Entry.new(:assistant, %{"content" => []}, parent: committed)
      :ok = Store.append(store, "s1", [committed])
      :ok = File.write(Path.join(tmp_dir, "s1.jsonl"), ~s({"v":2,"payload":{"te), [:append])

      :ok = Store.append(store, "s1", [later])

      assert Store.read(store, "s1") == {:ok, [committed, later]}
      assert File.read!(Path.join(tmp_dir, "s1.jsonl")) |> String.ends_with?("\n")
    end

    test "a whole entry that only lost its newline is kept, not cut", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      first = Entry.new(:user, %{"text" => "first"})
      unterminated = Entry.new(:user, %{"text" => "written, newline lost"})
      later = Entry.new(:user, %{"text" => "after the crash"})
      :ok = Store.append(store, "s1", [first])
      :ok = File.write(Path.join(tmp_dir, "s1.jsonl"), Entry.encode!(unterminated), [:append])

      # A read already returns it, so a resumed session is building on it.
      assert Store.read(store, "s1") == {:ok, [first, unterminated]}

      :ok = Store.append(store, "s1", [later])

      assert Store.read(store, "s1") == {:ok, [first, unterminated, later]}
    end

    test "a file that is one torn line is cut back to nothing, then appended", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "s1.jsonl"), ~s({"v":2,"id":"half))
      entry = Entry.new(:user, %{"text" => "fresh"})

      :ok = Store.append(store, "s1", [entry])

      assert Store.read(store, "s1") == {:ok, [entry]}
    end

    # A torn tail is the one corruption an append can produce, so it is
    # tolerated. Anything in the committed prefix is somebody else's file
    # format, and the difference between "I skipped part of this" and "I
    # cannot read this" is a conversation with a hole in the middle.
    test "corruption in the committed prefix is an error, not a shorter transcript", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      :ok = Store.append(store, "s1", [Entry.new(:user, %{"text" => "committed"})])
      :ok = File.write(Path.join(tmp_dir, "s1.jsonl"), ~s({"v":7,"id":"x"}\n), [:append])
      :ok = Store.append(store, "s1", [Entry.new(:user, %{"text" => "later"})])

      assert {:error, {:unreadable, "s1", reason}} = Store.read(store, "s1")
      assert reason =~ "7"
    end

    # `read/2`'s contract is `{:ok, _} | {:error, _}`. An escaping exception
    # made every caller's error handling a lie, and the caller that mattered
    # was `lmx --resume`, which answered a person with a stacktrace.
    test "an unreadable transcript never raises out of read/2", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "s1.jsonl"), "not json at all\nnor this\n")

      assert {:error, {:unreadable, "s1", _reason}} = Store.read(store, "s1")
    end

    test "appending nothing is a no-op that does not create a session", %{store: store} do
      assert Store.append(store, "s1", []) == :ok
      assert Store.read(store, "s1") == {:error, :not_found}
    end

    test "sessions do not bleed into each other", %{store: store} do
      mine = Entry.new(:user, %{"text" => "mine"})
      yours = Entry.new(:user, %{"text" => "yours"})

      :ok = Store.append(store, "s1", [mine])
      :ok = Store.append(store, "s2", [yours])

      assert Store.read(store, "s1") == {:ok, [mine]}
      assert Store.read(store, "s2") == {:ok, [yours]}
    end
  end

  describe "list_sessions/1" do
    test "returns session ids, oldest first", %{store: store} do
      for id <- ["01J0000000000000000000000B", "01J0000000000000000000000A"] do
        :ok = Store.append(store, id, [Entry.new(:user, %{"text" => id})])
      end

      assert Store.list_sessions(store) ==
               {:ok, ["01J0000000000000000000000A", "01J0000000000000000000000B"]}
    end

    test "is empty when nothing has been written", %{store: store} do
      assert Store.list_sessions(store) == {:ok, []}
    end

    test "ignores files that are not transcripts", %{store: store, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "README.md"), "not a session")

      assert Store.list_sessions(store) == {:ok, []}
    end
  end

  describe "lock/2 and unlock/3" do
    test "a claim is exclusive while its holder lives", %{store: store, tmp_dir: tmp_dir} do
      assert {:ok, lock} = Store.lock(store, "s1")

      owner = self()

      contender =
        spawn(fn -> send(owner, {:contended, Store.lock(store, "s1")}) end)

      assert_receive {:contended, {:error, {:locked, holder}}}
      refute Process.alive?(contender)
      assert holder["os_pid"] == System.pid()
      assert holder["path"] == Path.join(tmp_dir, "s1.lock")
      refute Map.has_key?(holder, "token")

      :ok = Store.unlock(store, "s1", lock)
      assert {:ok, _again} = Store.lock(store, "s1")
    end

    test "a claim whose holder process died is taken over", %{store: store} do
      owner = self()

      holder =
        spawn(fn ->
          send(owner, {:claimed, Store.lock(store, "s1")})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:claimed, {:ok, _lock}}
      ref = Process.monitor(holder)
      send(holder, :exit)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}

      assert {:ok, _taken_over} = Store.lock(store, "s1")
    end

    test "a claim from a process on this machine that has exited is taken over", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
      write_lock(tmp_dir, "s1", %{"os_pid" => String.trim(pid), "node" => "elsewhere@host"})

      assert {:ok, _lock} = Store.lock(store, "s1")
    end

    test "a claim from another host is refused, because it cannot be checked", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      write_lock(tmp_dir, "s1", %{"host" => "some-other-machine", "os_pid" => "1"})

      assert {:error, {:locked, %{"host" => "some-other-machine"}}} = Store.lock(store, "s1")
    end

    test "releasing a claim that was taken over leaves the successor's in place", %{
      store: store,
      tmp_dir: tmp_dir
    } do
      {:ok, stale} = Store.lock(store, "s1")
      {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
      write_lock(tmp_dir, "s1", %{"os_pid" => String.trim(pid), "node" => "elsewhere@host"})
      {:ok, _successor} = Store.lock(store, "s1")

      :ok = Store.unlock(store, "s1", stale)

      assert File.exists?(Path.join(tmp_dir, "s1.lock"))
    end

    test "a store without the callbacks claims nothing and releases nothing" do
      store = {Lemieux.Store.JSONLTest.Plain, :state}

      assert Store.lock(store, "s1") == {:ok, nil}
      assert Store.unlock(store, "s1", nil) == :ok
    end

    test "lock files are not listed as sessions", %{store: store} do
      {:ok, _lock} = Store.lock(store, "s1")

      assert Store.list_sessions(store) == {:ok, []}
    end
  end

  defmodule Plain do
    @moduledoc false
    @behaviour Lemieux.Store

    @impl true
    def append(_state, _id, _entries), do: :ok
    @impl true
    def read(_state, _id), do: {:error, :not_found}
    @impl true
    def list_sessions(_state), do: {:ok, []}
  end

  defp write_lock(dir, id, fields) do
    {:ok, host} = :inet.gethostname()

    holder =
      Map.merge(
        %{
          "token" => "t",
          "host" => List.to_string(host),
          "process" => "<0.1.0>",
          "since" => "2026-09-28T00:00:00Z"
        },
        fields
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".lock"), JSON.encode!(holder))
  end

  describe "session ids that are not ids" do
    test "a path separator in a session id is refused rather than escaping the directory",
         %{store: store} do
      # The session id reaches this store from a CLI argument, so treating it
      # as a filename without checking is a directory traversal.
      assert {:error, {:invalid_session_id, _}} = Store.append(store, "../escape", [])
      assert {:error, {:invalid_session_id, _}} = Store.read(store, "../escape")
      assert {:error, {:invalid_session_id, _}} = Store.read(store, "sub/dir")
    end
  end
end
