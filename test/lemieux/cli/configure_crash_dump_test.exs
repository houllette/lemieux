defmodule Lemieux.CLI.ConfigureCrashDumpTest do
  # Every source command keeps its crash dump out of the directory it runs
  # in: only the terminal UI used to point `ERL_CRASH_DUMP` at the state
  # directory, so `mix lmx run …` left an `erl_crash.dump`, which can hold
  # keys, where it ran. `Lemieux.CLI.configure/0` runs before every command,
  # from the release and from `mix lmx`, and sets it there — in the place
  # the release launcher does, whatever `LMX_CONFIG` says.
  #
  # `ERL_CRASH_DUMP` is this VM's OS environment, which every test shares,
  # and `configure/1` also replaces the VM's log handlers, so these run
  # alone, outside log capture (`Lemieux.ProviderPoolTest` says why), and
  # put back what they found.
  use ExUnit.Case, async: false

  alias Lemieux.CLI

  @moduletag :tmp_dir
  @moduletag capture_log: false

  setup do
    previous = System.get_env("ERL_CRASH_DUMP")
    level = Logger.level()
    handlers = :logger.get_handler_config()

    on_exit(fn ->
      if previous,
        do: System.put_env("ERL_CRASH_DUMP", previous),
        else: System.delete_env("ERL_CRASH_DUMP")

      Logger.configure(level: level)
      for handler <- [:lmx_file, :lmx_stderr], do: :logger.remove_handler(handler)

      for %{id: id} = config <- handlers do
        _ = :logger.remove_handler(id)
        :ok = :logger.add_handler(id, config.module, config)
      end
    end)

    System.delete_env("ERL_CRASH_DUMP")
    :ok
  end

  defp configure(state_dir),
    do: CLI.configure(logs: [dir: nil, stderr?: false], state_dir: state_dir)

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "points the crash dump into a private directory in the state directory",
       %{tmp_dir: dir} do
    state = Path.join(dir, "fresh/.lmx")

    assert :ok = configure(state)

    assert System.get_env("ERL_CRASH_DUMP") == Path.join([state, "crash", "erl_crash.dump"])
    assert mode(Path.join(state, "crash")) == 0o700
    assert mode(state) == 0o700
  end

  test "a crash dump somebody chose is left where they chose", %{tmp_dir: dir} do
    System.put_env("ERL_CRASH_DUMP", "/elsewhere/erl_crash.dump")

    assert :ok = configure(dir)

    assert System.get_env("ERL_CRASH_DUMP") == "/elsewhere/erl_crash.dump"
    refute File.exists?(Path.join(dir, "crash"))
  end

  # The launcher's `${ERL_CRASH_DUMP:-}` reads an empty one as unset.
  test "an empty ERL_CRASH_DUMP is unset", %{tmp_dir: dir} do
    System.put_env("ERL_CRASH_DUMP", "")

    assert :ok = configure(dir)

    assert System.get_env("ERL_CRASH_DUMP") == Path.join([dir, "crash", "erl_crash.dump"])
  end

  # Tests elsewhere call `configure/1` with `:logs` alone; the default
  # directory is in the home directory, and the variable is every test's.
  test "configure/1 without a state directory leaves the crash dump alone" do
    assert :ok = CLI.configure(logs: [dir: nil, stderr?: false])
    assert System.get_env("ERL_CRASH_DUMP") == nil

    assert :ok = configure(nil)
    assert System.get_env("ERL_CRASH_DUMP") == nil
  end

  test "configure/0 names the state directory the release launcher does", %{tmp_dir: dir} do
    assert System.get_env("LMX_CONFIG") == "none"
    System.put_env("LMX_HOME", dir)

    try do
      assert :ok = CLI.configure()
    after
      System.delete_env("LMX_HOME")
    end

    assert System.get_env("ERL_CRASH_DUMP") == Path.join([dir, "crash", "erl_crash.dump"])
  end

  describe "crash_state_dir/2" do
    test "is LMX_HOME, else .lmx in the home directory, whatever LMX_CONFIG says" do
      assert CLI.crash_state_dir(%{"LMX_HOME" => "/state"}, "/home/p") == "/state"
      assert CLI.crash_state_dir(%{}, "/home/p") == "/home/p/.lmx"

      # The log file's state directory follows these; a crash dump does not.
      assert CLI.crash_state_dir(%{"LMX_CONFIG" => "none"}, "/home/p") == "/home/p/.lmx"

      assert CLI.crash_state_dir(%{"LMX_CONFIG" => "/etc/lmx/config.json"}, "/home/p") ==
               "/home/p/.lmx"
    end

    test "a blank LMX_HOME is unset, and with no home there is none" do
      assert CLI.crash_state_dir(%{"LMX_HOME" => " "}, "/home/p") == "/home/p/.lmx"
      assert CLI.crash_state_dir(%{"LMX_HOME" => ""}, nil) == nil
    end
  end

  # The whole way, in a VM of its own that crashes: `configure/0` under
  # `LMX_CONFIG=none`, as a hermetic source run has it, then a crash. ERTS
  # reads the variable when it writes the dump, so one set while the VM runs
  # is the one it uses.
  @script """
  Application.put_env(:req_llm, :load_dotenv, false)
  {:ok, _} = Application.ensure_all_started(:lemieux)
  :ok = Lemieux.CLI.configure()
  :erlang.halt(~c"lmx-crash-probe")
  """

  @tag timeout: 120_000
  test "a source command's crash dump lands in ~/.lmx/crash, not where it ran",
       %{tmp_dir: dir} do
    elixir = System.find_executable("elixir") || flunk("no elixir executable on the path")
    home = Path.join(dir, "home")
    project = Path.join(dir, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(project)

    {output, _status} =
      System.cmd(elixir, ["-e", @script],
        env:
          [
            {"ERL_LIBS", Path.join(Mix.Project.build_path(), "lib")},
            {"HOME", home},
            {"LMX_CONFIG", "none"},
            {"LMX_PROJECT_MCP", "0"},
            # A contributor's own 0 would switch dumps off altogether.
            {"ERL_CRASH_DUMP_SECONDS", "60"}
          ] ++ Enum.map(~w(ERL_CRASH_DUMP LMX_HOME LMX_LOG_LEVEL), &{&1, nil}),
        cd: project,
        stderr_to_stdout: true
      )

    dump = Path.join([home, ".lmx", "crash", "erl_crash.dump"])

    assert File.regular?(dump), "no dump in #{Path.dirname(dump)}:\n#{output}"
    assert File.read!(dump) =~ "Slogan: lmx-crash-probe"
    assert mode(Path.dirname(dump)) == 0o700
    refute File.exists?(Path.join(project, "erl_crash.dump"))
  end
end
