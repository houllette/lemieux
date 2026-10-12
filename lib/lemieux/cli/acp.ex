defmodule Lemieux.CLI.ACP do
  @moduledoc """
  The stdio ACP host. Standard output contains only newline-delimited JSON-RPC.

  The connection owns its sessions. EOF cancels active work and releases
  transcript locks; an editor disconnect must not leave an invisible agent
  spending. The server uses the same public session API and CLI authority as
  the terminal host, rather than introducing a second agent loop.
  """

  alias Lemieux.CLI.ACP.Server
  alias Lemieux.CLI.Options

  @max_line 1_048_576

  @doc "Runs the ACP connection until its input closes."
  @spec main(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, integer()}
  def main(argv, opts) do
    with {:ok, options} <- Options.parse(argv, command: :acp),
         true <- options.argv == [],
         {:ok, server} <-
           Server.start_link(options: options, host: opts, emit: &emit/1) do
      try do
        read(server, "")
      after
        GenServer.stop(server)
      end
    else
      false -> error("acp takes no positional arguments")
      {:error, reason} -> error(inspect(reason))
    end
  end

  defp emit(packet), do: IO.puts(JSON.encode!(packet))

  # Bounded reads avoid allocating an arbitrary-length line before checking
  # its size. Partial frames are discarded at EOF, never executed.
  defp read(server, buffer) do
    case IO.read(:stdio, 1) do
      :eof -> :ok
      {:error, _reason} -> {:error, 1}
      bytes -> frames(server, buffer <> bytes)
    end
  end

  defp frames(server, buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] when byte_size(line) <= @max_line ->
        Server.receive_line(server, line)
        frames(server, rest)

      [buffer] when byte_size(buffer) <= @max_line ->
        read(server, buffer)

      _oversized ->
        error("ACP frame exceeds 1 MiB")
    end
  end

  defp error(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
