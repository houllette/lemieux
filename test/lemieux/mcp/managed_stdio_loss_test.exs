defmodule Lemieux.MCP.ManagedStdioLossTest do
  use ExUnit.Case, async: true
  alias LemieuxTest.CommandGate
  @moduletag :tmp_dir
  unless match?({:unix, _}, :os.type()) do
    @moduletag skip: "SIGKILL qualification requires POSIX process signalling"
  end

  @script """
  {:ok, _apps} = Application.ensure_all_started(:ex_cmd)
  {:ok, _process} = Lemieux.MCP.ManagedStdio.launch("sh", ["-c", System.fetch_env!("MCP_GATE")],
    %{}, System.fetch_env!("MCP_DIR"))
  IO.puts("vm-ready:" <> System.pid())
  Process.sleep(:infinity)
  """

  test "abrupt VM loss closes a live direct command, without promising descendants", %{
    tmp_dir: dir
  } do
    gate = CommandGate.new()
    libraries = :lemieux |> :code.lib_dir() |> to_string() |> Path.dirname()

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        {:line, 1024},
        args: ["-e", @script],
        env: [
          {~c"ERL_LIBS", String.to_charlist(libraries)},
          {~c"ERL_FLAGS", ~c"+S 2:2 +SDcpu 1 +SDio 1"},
          {~c"MCP_GATE", String.to_charlist(gate.command)},
          {~c"MCP_DIR", String.to_charlist(dir)}
        ]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert_receive {^port, {:data, {:eol, "vm-ready:" <> vm_pid}}}
    socket = CommandGate.ready(gate)
    assert {_output, 0} = System.cmd("kill", ["-KILL", vm_pid])
    assert_receive {^port, {:exit_status, _status}}
    assert :ok = CommandGate.closed(socket)
  end
end
