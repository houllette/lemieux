defmodule Lmx.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lmx.CLI

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
