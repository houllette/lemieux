defmodule Lemieux.Tools.ReadOnlyBashTest do
  use ExUnit.Case, async: true
  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Environment.Sandbox.{Bubblewrap, Seatbelt}
  alias Lemieux.Tool
  alias Lemieux.Tools.ReadOnlyBash
  @moduletag :tmp_dir

  test "read-only profiles remove workspace, cache and temp writes and IPC escapes" do
    sandbox = %Sandbox{
      backend: :seatbelt,
      executable: "/usr/bin/sandbox-exec",
      shell: "/bin/bash",
      inner: Local,
      read_only: true,
      writable: ["/tmp", "/work"],
      localhost: false
    }

    profile = Seatbelt.profile(sandbox, "/work")
    refute profile =~ ~s|(subpath "/work")|
    refute profile =~ ~s|(subpath "/tmp")|
    refute profile =~ "unix-socket"
    assert profile =~ "(deny signal)"
    assert profile =~ "(deny mach*)"
    assert profile =~ "(deny file-write*)"
    args = Bubblewrap.arguments(%{sandbox | backend: :bubblewrap}, "/work", "x")
    refute "--bind" in args
    assert "--unshare-pid" in args
    assert "--unshare-ipc" in args
    assert "--unshare-net" in args
    assert {:error, :erofs} = Environment.write_file({Sandbox, sandbox}, "/work", "x", "unsafe")
    assert {:error, :erofs} = Environment.delete_file({Sandbox, sandbox}, "/work", "x")
  end

  test "narrowing an existing sandbox retains secret exclusions and credential scrubbing" do
    sandbox = %Sandbox{
      backend: :seatbelt,
      executable: "/sandbox",
      shell: "/bin/bash",
      inner: Local.new(credentials: true),
      writable: ["/tmp"],
      hidden: ["/secret"],
      network: true
    }

    assert {:ok, {Sandbox, narrowed}} = ReadOnlyBash.environment({Sandbox, sandbox})
    assert narrowed.read_only
    assert narrowed.hidden == ["/secret"]
    assert narrowed.inner == sandbox.inner
    assert narrowed.writable == []
    refute narrowed.network or narrowed.localhost
    assert Tool.read_only?(ReadOnlyBash)
    assert {:error, message} = ReadOnlyBash.environment({__MODULE__, nil})
    assert message =~ "does not provide enforced"
  end

  test "real read-focused Python runs, while repository writes and network access fail closed", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "data.txt"), "one\ntwo\nthree\n")

    case Sandbox.new(read_only: true) do
      {:ok, environment} ->
        assert {"COUNT=3\n", 0} =
                 run(
                   environment,
                   dir,
                   "python3 -c 'from pathlib import Path; print(\"COUNT=\"+str(len(Path(\"data.txt\").read_text().splitlines())))'"
                 )

        assert {_output, status} =
                 run(
                   environment,
                   dir,
                   "python3 -c 'from pathlib import Path; Path(\"unsafe.txt\").write_text(\"bad\")'"
                 )

        assert status != 0
        refute File.exists?(Path.join(dir, "unsafe.txt"))

        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        on_exit(fn -> :gen_tcp.close(listener) end)
        {:ok, port} = :inet.port(listener)

        assert {_output, status} =
                 run(
                   environment,
                   dir,
                   "python3 -c 'import socket; socket.create_connection((\"127.0.0.1\", #{port}), timeout=.2)'"
                 )

        assert status != 0

        # A read-only mount still exposes filesystem Unix sockets on Linux.
        # This control must connect before confinement, then fail inside it.
        # Unix socket paths have a small OS limit; ExUnit's descriptive tmp
        # directory exceeds it on macOS.
        socket_path = "/tmp/lmx-readonly-#{Lemieux.ID.generate()}.sock"
        {:ok, unix} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, socket_path}])

        on_exit(fn ->
          :gen_tcp.close(unix)
          File.rm(socket_path)
        end)

        {:ok, client} = :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false])
        :ok = :gen_tcp.close(client)

        assert {_output, status} =
                 run(
                   environment,
                   dir,
                   "python3 -c " <>
                     LemieuxTest.Shell.quoted(
                       "import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(.2); s.connect(#{JSON.encode!(socket_path)})"
                     )
                 )

        assert status != 0

      {:error, message} ->
        if System.get_env("LMX_REQUIRE_SANDBOX") == "1", do: flunk(message)
        assert {:error, ^message} = ReadOnlyBash.environment(Local)
        assert is_binary(message)
    end
  end

  defp run(environment, dir, command) do
    {:ok, stream} = Environment.run(environment, command, cwd: dir, timeout_ms: 5000)

    Enum.reduce(stream, {"", nil}, fn
      {:data, bytes}, {text, status} -> {text <> bytes, status}
      {:exit_status, status}, {text, _} -> {text, status}
    end)
  end
end
