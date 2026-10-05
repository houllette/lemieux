defmodule Lemieux.CLI.LogsTest do
  # Replaces this VM's log handlers for the length of a test, which is every
  # other test's logging too.
  use ExUnit.Case, async: false

  # Outside log capture: these tests swap the VM's log handlers and restore
  # the set they found. Under the suite's global `capture_log: true` that set
  # includes ExUnit's own capture handler, and restoring it after ExUnit had
  # removed it left a stale handler that crashed ExUnit.CaptureServer for
  # every later test.
  @moduletag capture_log: false

  require Logger

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Logs

  @moduletag :tmp_dir

  setup do
    handlers = :logger.get_handler_config()
    level = Logger.level()

    on_exit(fn ->
      for handler <- [:lmx_file, :lmx_stderr], do: :logger.remove_handler(handler)

      for %{id: id} = config <- handlers do
        _ = :logger.remove_handler(id)
        :ok = :logger.add_handler(id, config.module, config)
      end

      Logger.configure(level: level)
    end)

    :ok
  end

  # Where a log line can land. Nothing that writes to standard output or
  # standard error may be left: in the terminal UI both are the drawn frame,
  # and in `lmx run` standard output is the answer. `:ssl`'s own handler
  # writes to standard output too, and is muted rather than removed.
  defp console_handlers do
    for %{id: id, module: :logger_std_h, config: %{type: type}, level: level} <-
          :logger.get_handler_config(),
        type in [:standard_io, :standard_error],
        level != :none,
        do: {id, type}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "install/1" do
    test "puts a file in the state directory where the console handler was", %{tmp_dir: dir} do
      assert :ok = Logs.install(dir: dir, stderr?: false)

      assert console_handlers() == []
      assert Logs.file() == Path.join([dir, "logs", "lmx.log"])
      assert File.stat!(Path.join(dir, "logs")).mode |> Bitwise.band(0o777) == 0o700

      Logger.error("lmx-logs-test: the provider is unreachable")
      Logs.flush()

      assert File.read!(Logs.file()) =~ "[error] lmx-logs-test: the provider is unreachable"
    end

    test "LMX_LOG_LEVEL's case adds standard error, never standard output", %{tmp_dir: dir} do
      assert :ok = Logs.install(dir: dir, stderr?: true)

      assert console_handlers() == [{:lmx_stderr, :standard_error}]
      assert Logs.file() == Path.join([dir, "logs", "lmx.log"])
    end

    test "with no state directory there is no file, and still nothing on the terminal" do
      assert :ok = Logs.install(dir: nil, stderr?: false)

      assert console_handlers() == []
      assert Logs.file() == nil
      assert Logs.flush() == :ok
    end

    test "a directory that cannot be made costs the file, not the command", %{tmp_dir: dir} do
      blocker = Path.join(dir, "not-a-directory")
      File.write!(blocker, "")

      assert :ok = Logs.install(dir: blocker, stderr?: false)
      assert Logs.file() == nil
      assert console_handlers() == []
    end

    # `lmx --version` on a fresh machine runs this before anything else
    # touches `~/.lmx`. Made with the umask it came out 0755, and the config
    # file's own creation, finding it there, left it so: transcripts written
    # inside were readable by every local user.
    test "a state directory it has to create is private, and stays so", %{tmp_dir: dir} do
      state = Path.join([dir, "home", ".lmx"])

      assert :ok = Logs.install(dir: state, stderr?: false)
      assert Logs.file() == Path.join([state, "logs", "lmx.log"])
      assert mode(state) == 0o700
      assert mode(Path.join(dir, "home")) == 0o700
      assert mode(Path.join(state, "logs")) == 0o700

      assert {:ok, _config} = Config.load_default(Path.join(state, "config.json"), "test:model")
      assert mode(state) == 0o700
    end

    test "leaves the mode of a state directory that already existed", %{tmp_dir: dir} do
      File.chmod!(dir, 0o755)

      assert :ok = Logs.install(dir: dir, stderr?: false)
      assert mode(dir) == 0o755
      assert mode(Path.join(dir, "logs")) == 0o700
    end

    test "can be called again without stacking handlers", %{tmp_dir: dir} do
      assert :ok = Logs.install(dir: dir, stderr?: true)
      assert :ok = Logs.install(dir: dir, stderr?: true)

      ids = Enum.map(:logger.get_handler_config(), & &1.id)
      assert Enum.count(ids, &(&1 == :lmx_file)) == 1
      assert Enum.count(ids, &(&1 == :lmx_stderr)) == 1
    end
  end

  describe "configure/1" do
    test "installs the log file before any command runs", %{tmp_dir: dir} do
      assert :ok = CLI.configure(logs: [dir: dir, stderr?: false])

      assert console_handlers() == []
      assert Logs.file() == Path.join([dir, "logs", "lmx.log"])
    end
  end

  describe "follow/1" do
    # `--config` moves the state directory, so the log goes with it; the
    # environment's `LMX_HOME` would win over the flag, so it is put aside.
    setup do
      home = System.get_env("LMX_HOME")
      System.delete_env("LMX_HOME")
      on_exit(fn -> if home, do: System.put_env("LMX_HOME", home) end)
      :ok
    end

    test "--config none, which remembers nothing, keeps no log", %{tmp_dir: dir} do
      :ok = Logs.install(dir: dir, stderr?: false)

      assert :ok = Logs.follow(["run", "--config", "none", "hi"])
      assert Logs.file() == nil
      assert Logs.flush() == :ok
    end

    test "--config PATH puts the log beside the file it names", %{tmp_dir: dir} do
      :ok = Logs.install(dir: Path.join(dir, "default"), stderr?: false)
      elsewhere = Path.join(dir, "elsewhere")

      assert :ok = Logs.follow(["--config=#{elsewhere}/config.json", "--model", "x:y"])
      assert Logs.file() == Path.join([elsewhere, "logs", "lmx.log"])
      assert mode(elsewhere) == 0o700
    end

    test "the last --config counts, and one after -- is a prompt's", %{tmp_dir: dir} do
      :ok = Logs.install(dir: dir, stderr?: false)

      assert :ok = Logs.follow(["--config", "none", "--config", "#{dir}/config.json"])
      assert Logs.file() == Path.join([dir, "logs", "lmx.log"])

      assert :ok = Logs.follow(["run", "--", "--config", "none"])
      assert Logs.file() == Path.join([dir, "logs", "lmx.log"])
    end

    test "Lemieux.CLI.run/2 follows the line it was given", %{tmp_dir: dir} do
      :ok = Logs.install(dir: dir, stderr?: false)

      capture_io(fn -> assert :ok = CLI.run(["help", "sessions", "--config", "none"], []) end)

      assert Logs.file() == nil
    end

    # A test, or a host that kept its own handlers, never asked for the file.
    test "opens nothing when install/1 opened no file", %{tmp_dir: dir} do
      :ok = Logs.install(dir: nil, stderr?: false)

      assert :ok = Logs.follow(["--config", Path.join(dir, "config.json")])
      assert Logs.file() == nil
      refute File.exists?(Path.join(dir, "logs"))
    end
  end

  describe "mkdir_private/1" do
    test "makes every directory it creates private, and only those", %{tmp_dir: dir} do
      File.chmod!(dir, 0o755)
      deep = Path.join([dir, "a", "b", "c"])

      assert :ok = Logs.mkdir_private(deep)
      assert mode(dir) == 0o755

      for path <- [Path.join(dir, "a"), Path.join([dir, "a", "b"]), deep],
          do: assert(mode(path) == 0o700)

      assert :ok = Logs.mkdir_private(deep)
    end

    test "a file in the way is an error, not a directory", %{tmp_dir: dir} do
      blocker = Path.join(dir, "file")
      File.write!(blocker, "")

      assert {:error, :enotdir} = Logs.mkdir_private(blocker)
      assert {:error, _reason} = Logs.mkdir_private(Path.join(blocker, "below"))
    end
  end

  describe "default_dir/2" do
    test "follows LMX_HOME, then the config file's directory, then ~/.lmx" do
      assert Logs.default_dir(%{"LMX_HOME" => "/srv/lmx", "LMX_CONFIG" => "none"}) == "/srv/lmx"
      assert Logs.default_dir(%{"LMX_CONFIG" => "/etc/lmx/config.json"}) == "/etc/lmx"
      assert Logs.default_dir(%{}) == Path.expand("~/.lmx")
      assert Logs.default_dir(%{"LMX_HOME" => "", "LMX_CONFIG" => ""}) == Path.expand("~/.lmx")
    end

    test "LMX_CONFIG=none, which remembers nothing, has no log directory" do
      assert Logs.default_dir(%{"LMX_CONFIG" => "none"}) == nil
    end

    test "a --config flag's value comes before LMX_CONFIG, and LMX_HOME before both" do
      env = %{"LMX_CONFIG" => "/etc/lmx/config.json"}

      assert Logs.default_dir(env, "/srv/mine/config.json") == "/srv/mine"
      assert Logs.default_dir(env, "none") == nil
      assert Logs.default_dir(%{"LMX_CONFIG" => "none"}, "/srv/mine/config.json") == "/srv/mine"
      assert Logs.default_dir(Map.put(env, "LMX_HOME", "/home/x"), "none") == "/home/x"
      assert Logs.default_dir(env, "") == "/etc/lmx"
    end
  end
end
