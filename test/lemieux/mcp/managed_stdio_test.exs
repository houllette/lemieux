defmodule Lemieux.MCP.ManagedStdioTest do
  use ExUnit.Case, async: true
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.ManagedStdio
  alias Lemieux.MCP.StdioLifecycle
  alias Lemieux.MCP.Transport.Stdio
  alias LemieuxTest.CommandGate
  @moduletag :tmp_dir

  defp launch(script, dir, opts) do
    path = Path.join(dir, "server.py")
    File.write!(path, script)
    assert {:ok, process} = ManagedStdio.launch("python3", [path], %{}, dir, opts)
    on_exit(fn -> ManagedStdio.close(process) end)
    process
  end

  test "output uses one demand window even when the consumer stops", %{tmp_dir: dir} do
    process =
      launch("import os\nwhile True: os.write(1, b'x' * 4096)\n", dir,
        chunk_bytes: 64,
        observer: self()
      )

    pid = process.pid
    assert_receive {^pid, {:data, data}}
    assert byte_size(data) <= 64
    refute_receive {^pid, {:data, _}}, 100
    assert ManagedStdio.info(process).outstanding_bytes == byte_size(data)
    ManagedStdio.ack(process)
    assert_receive {^pid, {:data, next}}
    assert byte_size(next) <= 64
    assert :ok = ManagedStdio.close(process)
    assert :ok = ManagedStdio.close(process)

    assert_receive {:mcp_stdio, ^pid,
                    %StdioLifecycle{kind: :interrupted, target_outcome: :unknown}}

    refute Process.alive?(pid)
  end

  test "stdin EOF is distinct from close and local wrapper exit", %{tmp_dir: dir} do
    process =
      launch("import sys\nsys.stdin.read()\nprint('done', flush=True)\n", dir, observer: self())

    pid = process.pid
    assert :ok = ManagedStdio.finish_input(process)
    assert_receive {^pid, {:data, "done\n"}}
    ManagedStdio.ack(process)
    assert_receive {^pid, {:exit_status, 0}}

    assert_receive {:mcp_stdio, ^pid,
                    %StdioLifecycle{kind: :wrapper_exit, status: 0, target_outcome: :unknown}}
  end

  test "owner death closes pipes even when the owner is killed", %{tmp_dir: dir} do
    parent = self()

    owner =
      spawn(fn ->
        path = Path.join(dir, "owner.py")
        File.write!(path, "import sys\nsys.stdin.read()\n")
        {:ok, process} = ManagedStdio.launch("python3", [path], %{}, dir, observer: parent)
        send(parent, {:managed, process})

        receive do
          :hold -> :ok
        end
      end)

    assert_receive {:managed, process}
    pid = process.pid
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:mcp_stdio, ^pid, %StdioLifecycle{kind: :interrupted}}
  end

  test "startup failures are typed and do not export command or arguments", %{tmp_dir: dir} do
    assert {:error, _} =
             ManagedStdio.launch("secret-nonexistent-server", ["secret-token"], %{}, dir,
               observer: self()
             )

    assert_receive {:mcp_stdio, nil, %StdioLifecycle{kind: :launch_failed} = event}
    refute inspect(event) =~ "secret"
  end

  test "native handshake uses managed pipes and framing without another protocol", %{tmp_dir: dir} do
    fixture = Path.expand("../../fixtures/mcp_server.py", __DIR__)
    launcher = fn command, args, env, cwd -> ManagedStdio.launch(command, args, env, cwd) end

    assert {:ok, config} =
             Stdio.configure(%{"command" => "python3", "args" => [fixture, "modern"]},
               cwd: dir,
               stdio_launcher: launcher
             )

    assert {:ok, state} = Stdio.connect(config)
    on_exit(fn -> Stdio.close(state) end)

    assert {:ok, %{"result" => result}, _state} =
             Stdio.call(
               state,
               %{"id" => 1, "method" => "server/discover", "jsonrpc" => "2.0"},
               5000
             )

    assert "2026-07-28" in result["supportedVersions"]
  end

  test "a cancelled request leaves the managed multiplexed server usable", %{tmp_dir: dir} do
    fixture = Path.expand("../../fixtures/mcp_server.py", __DIR__)
    launcher = fn command, args, env, cwd -> ManagedStdio.launch(command, args, env, cwd) end

    {:ok, config} =
      Stdio.configure(%{"command" => "python3", "args" => [fixture, "duplex"]},
        cwd: dir,
        stdio_launcher: launcher
      )

    client =
      start_supervised!({Client, server: "managed", transport: {Stdio, config}})

    gate = CommandGate.new()
    {:ok, port} = :inet.port(gate.listener)

    caller =
      spawn(fn -> Client.call_tool(client, "slow", %{"control_port" => port}) end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    socket = CommandGate.ready(gate)
    Process.exit(caller, :kill)

    assert {:ok, %{model_text: withdrawn}} =
             Client.call_tool(client, "cancelled", %{"wait" => true})

    assert [_id] = JSON.decode!(withdrawn)
    assert :ok = CommandGate.closed(socket)

    assert {:ok, %{model_text: "fast: next"}} =
             Client.call_tool(client, "fast", %{"text" => "next"})
  end

  test "bounded or blocked stdin writes end the connection", %{tmp_dir: dir} do
    process =
      launch("import time\ntime.sleep(60)\n", dir, max_write_bytes: 4, close_grace_ms: 100)

    assert {:error, :write_limit} = ManagedStdio.write(process, "12345")
    assert {:error, :closed} = ManagedStdio.info(process)

    process =
      launch("import time\ntime.sleep(60)\n", dir, write_timeout_ms: 100, close_grace_ms: 100)

    assert {:error, :write_timeout} =
             ManagedStdio.write(process, String.duplicate("x", 1_000_000))

    assert {:error, :closed} = ManagedStdio.info(process)
  end

  test "an abrupt relay kill closes the direct command's socket", %{tmp_dir: dir} do
    gate = CommandGate.new()
    {:ok, process} = ManagedStdio.launch("sh", ["-c", gate.command], %{}, dir)
    socket = CommandGate.ready(gate)
    Process.exit(process.pid, :kill)
    assert :ok = CommandGate.closed(socket)
  end

  test "close proves only wrapper teardown; a detached descendant remains", %{tmp_dir: dir} do
    gate = CommandGate.new()
    {:ok, port} = :inet.port(gate.listener)

    script =
      "import subprocess, sys\n" <>
        "p = subprocess.Popen([sys.executable, '-c', " <>
        "\"import socket; s=socket.create_connection(('127.0.0.1', #{port})); s.sendall(b'ready\\\\n'); s.recv(1)\"], " <>
        "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)\n" <>
        "sys.stdin.read()\n"

    process = launch(script, dir, close_grace_ms: 100)
    socket = CommandGate.ready(gate)
    assert :ok = ManagedStdio.close(process)
    refute Process.alive?(process.pid)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    # Releasing the fixture's socket lets the detached child end on its own.
    assert :ok = CommandGate.release(socket)
    assert :ok = CommandGate.closed(socket)
  end
end
