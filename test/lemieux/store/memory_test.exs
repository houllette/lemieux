defmodule Lemieux.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.Memory

  test "preserves append order and rejects a batch atomically when it exceeds the store limit" do
    first = Entry.new(:user, %{"text" => "first"})
    second = Entry.new(:user, %{"text" => "second"})
    third = Entry.new(:user, %{"text" => "third"})
    limit = byte_size("test") + :erlang.external_size(first) + :erlang.external_size(second)
    assert {:ok, store} = Memory.new(max_bytes: limit)

    assert :ok = Store.append(store, "test", [first])
    assert {:error, :limit_exceeded} = Store.append(store, "test", [second, third])
    assert {:ok, [^first]} = Store.read(store, "test")
    assert :ok = Store.append(store, "test", [second])
    assert {:ok, [^first, ^second]} = Store.read(store, "test")

    assert {:error, :limit_exceeded} = Store.append(store, "other", [third])
    assert {:error, :not_found} = Store.read(store, "other")
    assert {:ok, ["test"]} = Store.list_sessions(store)
    assert :ok = Memory.close(store)
    assert {:error, :closed} = Store.read(store, "test")
  end

  test "releases the store when its owner exits normally" do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        {:ok, {Memory, pid} = store} = Memory.new()
        :ok = Store.append(store, "test", [Entry.new(:user, %{"text" => "temporary"})])
        send(parent, {:store, store, pid})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:store, store, pid}
    monitor = Process.monitor(pid)
    assert {:ok, ["test"]} = Store.list_sessions(store)
    send(owner, :exit)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert {:error, :closed} = Store.list_sessions(store)
  end

  test "a dead writer releases its claim and its stale token cannot release a replacement" do
    {:ok, store} = Memory.new()
    parent = self()

    {writer, monitor} =
      spawn_monitor(fn ->
        {:ok, lock} = Store.lock(store, "test")
        send(parent, {:locked, lock})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:locked, old_lock}
    assert {:error, {:locked, %{"process" => _pid}}} = Store.lock(store, "test")
    send(writer, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}
    assert {:ok, new_lock} = Store.lock(store, "test")
    assert :ok = Store.unlock(store, "test", old_lock)
    assert {:error, {:locked, _holder}} = Store.lock(store, "test")
    assert :ok = Store.unlock(store, "test", new_lock)
  end

  @tag :tmp_dir
  test "a one-shot tool round trip retains a resumable transcript without creating a file", %{
    tmp_dir: tmp_dir
  } do
    runtime = __MODULE__.Runtime
    start_supervised!({Lemieux.Supervisor, name: runtime})
    assert {:ok, store} = Memory.new()
    File.write!(Path.join(tmp_dir, "note.txt"), "memory store fixture")

    provider =
      Scripted.new([
        Scripted.tool_call("read-1", "read", %{"path" => "note.txt"}),
        Scripted.complete("Read the note."),
        Scripted.complete("Resumed.")
      ])

    opts = [
      supervisor: runtime,
      model: "test:model",
      provider: provider,
      tools: [Lemieux.Tools.Read],
      cwd: tmp_dir,
      store: store
    ]

    assert {:ok, %{session_id: id, text: "Read the note.", stop_reason: :stop}} =
             Lemieux.run("Read the note.", opts)

    assert Lemieux.sessions(runtime) == []
    assert {:ok, entries} = Store.read(store, id)
    assert Enum.map(entries, & &1.seq) == Enum.to_list(0..(length(entries) - 1))

    assert Enum.any?(
             entries,
             &(&1.type == :tool_result and inspect(&1.payload) =~ "memory store fixture")
           )

    assert {:ok, %{session_id: ^id, text: "Resumed."}} =
             Lemieux.run("Continue.", Keyword.put(opts, :resume, id))

    assert File.ls!(tmp_dir) == ["note.txt"]
  end
end
