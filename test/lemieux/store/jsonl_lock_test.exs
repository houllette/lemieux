defmodule Lemieux.Store.JSONLLockTest do
  # A lock left behind must never strand a transcript: a session releases its
  # claim when it stops, and a claim whose process id the system has since
  # given to somebody else is recognised as stale.
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  if match?({:win32, _}, :os.type()) do
    @moduletag skip: "process start times are read from /proc or ps"
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  # A process of this machine that is not this VM, alive until the port closes.
  defp other_process do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    Integer.to_string(os_pid)
  end

  defp write_lock(dir, id, fields) do
    holder =
      Map.merge(
        %{
          "token" => "written-elsewhere",
          "host" => hostname(),
          "node" => "nonode@nohost",
          "process" => "<0.100.0>",
          "since" => "2026-10-01T08:00:00Z"
        },
        fields
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".lock"), JSON.encode!(holder))
  end

  test "a claim records when its process started, beside its pid", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)
    {:ok, _lock} = Store.lock(store, "s1")

    holder = tmp_dir |> Path.join("s1.lock") |> File.read!() |> JSON.decode!()

    assert holder["os_pid"] == System.pid()
    assert is_binary(holder["os_started"])
    assert holder["os_started"] == JSONL.os_started(System.pid())
  end

  test "a claim whose pid now belongs to a different process is taken over", %{
    tmp_dir: tmp_dir
  } do
    reused = other_process()
    write_lock(tmp_dir, "s1", %{"os_pid" => reused, "os_started" => "long before"})

    assert {:ok, _lock} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  test "a claim whose process is still the one that wrote it is refused", %{tmp_dir: tmp_dir} do
    holder = other_process()

    write_lock(tmp_dir, "s1", %{
      "os_pid" => holder,
      "os_started" => JSONL.os_started(holder)
    })

    assert {:error, {:locked, %{"os_pid" => ^holder}}} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  # An earlier lmx whose pid this very VM was given later: the same pid and
  # node name, an Erlang process id that may well be alive here, and a start
  # time that is not this VM's.
  test "a claim from an earlier VM that had this VM's pid is taken over", %{tmp_dir: tmp_dir} do
    write_lock(tmp_dir, "s1", %{
      "os_pid" => System.pid(),
      "node" => Atom.to_string(node()),
      "process" => self() |> :erlang.pid_to_list() |> List.to_string(),
      "os_started" => "long before"
    })

    assert {:ok, _lock} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  # A different string is not proof on its own where the reading is a
  # wall-clock time: the process holding the pid now must also have started
  # after the lock was taken. Here the holder's start was read in another
  # zone — as a reader before the zone was pinned would have — and the holder
  # is the one that took the lock.
  @tag skip:
         if(match?({:unix, :linux}, :os.type()),
           do: "Linux reads exact start ticks; a different one is a different process",
           else: false
         )
  test "a holder that started before its lock is not taken over for a reading that differs",
       %{tmp_dir: tmp_dir} do
    holder = other_process()

    {elsewhere, 0} =
      System.cmd("ps", ["-o", "lstart=", "-p", holder], env: [{"LC_ALL", "C"}, {"TZ", "JST-9"}])

    refute String.trim(elsewhere) == JSONL.os_started(holder)

    write_lock(tmp_dir, "s1", %{
      "os_pid" => holder,
      "os_started" => String.trim(elsewhere),
      "since" => DateTime.to_iso8601(DateTime.utc_now())
    })

    assert {:error, {:locked, %{"os_pid" => ^holder}}} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  test "a claim written before start times were recorded is judged by its pid alone", %{
    tmp_dir: tmp_dir
  } do
    write_lock(tmp_dir, "s1", %{"os_pid" => other_process()})

    assert {:error, {:locked, _holder}} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  test "a session releases its claim when it stops", %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_lock_release_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(tmp_dir)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: store,
        provider: Scripted.new([]),
        model: "test:lock"
      )

    id = Lemieux.Session.id(session)
    lock = Path.join(tmp_dir, id <> ".lock")
    assert File.exists?(lock)

    :ok = GenServer.stop(session, :normal)

    refute File.exists?(lock)
  end
end
