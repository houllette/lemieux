defmodule Lmx.CLITest do
  # Restart receipt consumption changes the process environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lmx.CLI

  test "the release host dispatches provider-free learning controls through the library host" do
    caller = self()

    assert CLI.run(["learning", "inspect"],
             configure: fn -> :ok end,
             native_loader: fn -> :ok end,
             runner: fn argv ->
               send(caller, {:learning_command, argv})
               :ok
             end
           ) == 0

    assert_received {:learning_command, ["learning", "inspect"]}
    assert "learning" in Lemieux.CLI.commands()
  end

  test "loads the native TUI before dispatching any command" do
    caller = self()

    status =
      CLI.run(["--version"],
        configure: fn ->
          send(caller, :configured)
          :ok
        end,
        native_loader: fn ->
          send(caller, :native_loaded)
          :ok
        end,
        runner: fn argv ->
          send(caller, {:ran, argv})
          :ok
        end
      )

    assert status == 0
    assert_received :configured
    assert_received :native_loaded
    assert_received {:ran, ["--version"]}
  end

  @tag :tmp_dir
  test "a restart receipt preserves launch flags but removes one-shot and old resume arguments",
       %{tmp_dir: dir} do
    argv = [
      "tui",
      "--config",
      "state dir",
      "--model",
      "openai:gpt-5.6",
      "--prompt",
      "do not repeat",
      "--resume=old",
      "--cwd",
      "/old project",
      "-c"
    ]

    path = Path.join(dir, "restart.json")
    assert :ok = CLI.prepare_restart(argv, %{id: "exact-session", cwd: "/work space"}, path)
    assert {:ok, bytes} = File.read(path)

    assert JSON.decode!(bytes) == [
             "--config",
             "state dir",
             "--resume",
             "exact-session",
             "-C",
             "/work space"
           ]

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  @tag :tmp_dir
  test "restart flag values are not mistaken for command names or one-shot flags", %{tmp_dir: dir} do
    argv = [
      "--config",
      "tui",
      "--model=openai:gpt-5.6",
      "--prompt=hello",
      "--system",
      "initial instructions",
      "--mcp-config",
      "old.json",
      "--no-mouse",
      "--sessions-dir",
      "my sessions"
    ]

    path = Path.join(dir, "restart.json")
    assert :ok = CLI.prepare_restart(argv, %{id: "changed-session", cwd: "/project"}, path)

    assert JSON.decode!(File.read!(path)) == [
             "--config",
             "tui",
             "--no-mouse",
             "--sessions-dir",
             "my sessions",
             "--resume",
             "changed-session",
             "-C",
             "/project"
           ]
  end

  @tag :tmp_dir
  test "a restart receipt is consumed before dispatch and cannot replay twice", %{tmp_dir: dir} do
    path = Path.join(dir, "restart.json")
    previous = System.get_env("LMX_RESTART_FILE")
    System.put_env("LMX_RESTART_FILE", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("LMX_RESTART_FILE", previous),
        else: System.delete_env("LMX_RESTART_FILE")
    end)

    args = ["--resume", "exact-session", "-C", "/work space"]
    File.write!(path, JSON.encode!(args))

    opts = [
      configure: fn -> :ok end,
      native_loader: fn -> :ok end,
      runner: fn argv ->
        assert File.read!(path) == ""
        assert argv == args
        :ok
      end
    ]

    assert CLI.run(["--prompt", "do not repeat"], opts) == 0

    assert CLI.run(
             ["--version"],
             Keyword.put(opts, :runner, fn argv ->
               assert argv == ["--version"]
               :ok
             end)
           ) == 0
  end

  test "preserves a command's non-zero status" do
    assert CLI.run(["run"],
             configure: fn -> :ok end,
             native_loader: fn -> :ok end,
             runner: fn _argv -> {:error, 7} end
           ) == 7
  end

  # The release runs this boundary through Lmx.Boot.main/0, the only process
  # entry, as `run(argv, &Lmx.CLI.run/1)`: a native library that cannot load
  # becomes a message and status 1, and nothing here halts the VM.
  test "a boundary crash becomes stderr and status 1 through the release's entry" do
    stderr =
      capture_io(:stderr, fn ->
        assert Lmx.Boot.run(
                 ["--version"],
                 &CLI.run(&1,
                   configure: fn -> :ok end,
                   native_loader: fn -> raise "wrong NIF" end
                 )
               ) == 1
      end)

    assert stderr =~ "lmx crashed: wrong NIF"
  end
end
