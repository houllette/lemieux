defmodule LemieuxTest.CommandGate do
  @moduledoc false
  import ExUnit.Assertions

  @fixture Path.expand("../fixtures/command_gate.py", __DIR__)

  @spec new(first :: String.t(), last :: String.t()) :: map()
  def new(first \\ "ready", last \\ "") do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listener) end)

    args = [System.find_executable("python3"), @fixture, to_string(port), first, last]
    command = "exec " <> Enum.map_join(args, " ", &quote_argument/1)
    %{listener: listener, command: command}
  end

  @spec ready(gate :: map()) :: port()
  def ready(gate) do
    assert {:ok, socket} = :gen_tcp.accept(gate.listener, 5_000)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)
    assert {:ok, "ready\n"} = :gen_tcp.recv(socket, 0, 5_000)
    socket
  end

  @spec release(socket :: port()) :: :ok
  def release(socket), do: :gen_tcp.send(socket, "x")

  @spec closed(socket :: port()) :: :ok
  def closed(socket) do
    # This socket belongs to the OS command itself, not the BEAM worker that
    # collects stdout. Killing only the worker cannot satisfy this assertion.
    #
    # Five seconds, like the waits above. Two was the odd one out, and it is
    # the wait with the most to do: accepting a connection is the BEAM
    # answering itself, while this one is an operating system reaping a
    # process. Under a suite running twenty-eight cases at once that came
    # back `:timeout` about one full run in five — the suite measuring the
    # machine. What is asserted is unchanged: the socket has to close, and a
    # worker killed on its own still cannot make it.
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    :ok
  end

  defp quote_argument(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
