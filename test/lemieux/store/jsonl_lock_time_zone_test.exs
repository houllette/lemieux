defmodule Lemieux.Store.JSONLLockTimeZoneTest do
  # Two lmx processes need not agree on the time zone — a script with `TZ`
  # set, a laptop that changed zones while lmx was open — and `ps` prints a
  # process's start in local time. Read that way, one live holder's start was
  # two different strings, and the second lmx took over its lock: two writers
  # in one transcript.
  #
  # `TZ` is read by every command this VM starts, so this module sets it for
  # the whole VM and does not run beside other tests.
  use ExUnit.Case, async: false

  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  unless match?({:unix, _}, :os.type()) do
    @moduletag skip: "process start times are read from /proc or ps"
  end

  setup do
    previous = System.get_env("TZ")

    on_exit(fn ->
      if previous, do: System.put_env("TZ", previous), else: System.delete_env("TZ")
    end)
  end

  test "a live holder keeps its lock whichever zone each lmx runs in", %{tmp_dir: tmp_dir} do
    holder = other_process()

    System.put_env("TZ", "JST-9")
    recorded = JSONL.os_started(holder)
    assert is_binary(recorded)
    write_lock(tmp_dir, "s1", holder, recorded)

    System.put_env("TZ", "EST5EDT")

    assert JSONL.os_started(holder) == recorded
    assert {:error, {:locked, %{"os_pid" => ^holder}}} = Store.lock(JSONL.new(tmp_dir), "s1")
  end

  # A process of this machine that is not this VM, alive until the port closes.
  defp other_process do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    Integer.to_string(os_pid)
  end

  defp write_lock(dir, id, os_pid, started) do
    {:ok, host} = :inet.gethostname()

    holder = %{
      "token" => "written-elsewhere",
      "host" => List.to_string(host),
      "os_pid" => os_pid,
      "os_started" => started,
      "node" => "nonode@nohost",
      "process" => "<0.100.0>",
      "since" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write!(Path.join(dir, id <> ".lock"), JSON.encode!(holder))
  end
end
