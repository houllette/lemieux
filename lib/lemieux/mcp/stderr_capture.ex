defmodule Lemieux.MCP.StderrCapture do
  @moduledoc """
  Bounded, separate diagnostics for the default stdio launcher.

  A loopback pipe carries stderr, never JSON-RPC stdout. Bash's socket
  redirection works on the supported Unix hosts and in Windows' required Git
  Bash. Arguments are passed positionally, never interpolated into shell code.
  A random preamble authenticates the local writer. The reader acknowledges
  one bounded socket chunk at a time; after the diagnostic budget is spent it
  keeps draining and discarding. There are no spool files or growing buffers.

  Only complete, bounded lines are logged. Credential-bearing lines and known
  secret values are withheld; escapes and terminal controls are removed. Both
  the capture and reader follow the client, including an untrappable kill.
  Host launchers retain ownership of their own stderr and can use this helper
  or their own diagnostic sink without changing the launcher result contract.
  """
  use GenServer
  require Logger

  alias Lemieux.Environment.Credentials
  alias Lemieux.Tool.Escapes

  @budget 16_384
  @line_limit 2_048
  @chunk 4_096

  @doc false
  @spec start(server :: String.t(), env :: map()) :: {:ok, pid(), [String.t()]} | {:error, term()}
  def start(server, env) do
    case GenServer.start(__MODULE__, {self(), server, env}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :arguments)}
      error -> error
    end
  end

  @doc false
  @spec close(capture :: pid()) :: :ok
  def close(capture) do
    GenServer.stop(capture, :normal)
  catch
    :exit, _closed -> :ok
  end

  @impl true
  def init({owner, server, env}) do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             active: false,
             ip: {127, 0, 0, 1},
             buffer: @chunk,
             recbuf: @chunk
           ]),
         {:ok, {_address, port}} <- :inet.sockname(socket) do
      token = Base.encode16(:crypto.strong_rand_bytes(16))
      manager = self()
      reader = spawn_link(fn -> accept(socket, token, manager) end)

      secrets =
        Map.merge(System.get_env(), env)
        |> Enum.filter(fn {key, _value} -> Credentials.sensitive?(key, {:scrub, []}) end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&(byte_size(&1) >= 4))

      {:ok,
       %{
         socket: socket,
         port: port,
         token: token,
         reader: reader,
         owner_ref: Process.monitor(owner),
         server: clean(server),
         secrets: secrets,
         buffer: "",
         dropping?: false,
         remaining: @budget
       }}
    end
  end

  @impl true
  def handle_call(:arguments, _from, state) do
    # Silence shell errors before attempting the socket. No startup failure
    # may inherit the active terminal. The endpoint preamble is not a log.
    script =
      "exec 2>/dev/null; exec 2>/dev/tcp/127.0.0.1/" <>
        to_string(state.port) <>
        " || exit 1; printf '%s' \"$0\" >&2; exec \"$@\""

    {:reply, ["--noprofile", "--norc", "-p", "-c", script, state.token], state}
  end

  def handle_call({:chunk, bytes}, _from, state), do: {:reply, :ok, consume(state, bytes)}

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    Process.unlink(state.reader)
    Process.exit(state.reader, :kill)
    :ok
  end

  defp accept(listener, token, manager) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        if :gen_tcp.recv(socket, byte_size(token), 5_000) == {:ok, token},
          do: drain(socket, manager)

        :gen_tcp.close(socket)
        accept(listener, token, manager)

      {:error, _closed} ->
        :ok
    end
  end

  defp drain(socket, manager) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, bytes} ->
        GenServer.call(manager, {:chunk, bytes}, :infinity)
        drain(socket, manager)

      {:error, _closed} ->
        :ok
    end
  end

  defp consume(%{remaining: 0} = state, _bytes), do: state

  defp consume(state, bytes) do
    bytes = binary_part(bytes, 0, min(byte_size(bytes), state.remaining))
    remaining = state.remaining - byte_size(bytes)
    state = lines(state, :binary.split(bytes, "\n", [:global]))
    %{state | remaining: remaining, buffer: if(remaining == 0, do: "", else: state.buffer)}
  end

  defp lines(state, [tail]) do
    buffer = state.buffer <> tail

    if byte_size(buffer) > @line_limit,
      do: %{state | buffer: "", dropping?: true},
      else: %{state | buffer: buffer}
  end

  defp lines(state, [line | rest]) do
    line = state.buffer <> line
    unless state.dropping? or byte_size(line) > @line_limit, do: log(state, line)
    lines(%{state | buffer: "", dropping?: false}, rest)
  end

  defp log(state, line) do
    text = clean(line)

    secret? =
      Regex.match?(
        ~r/authorization|bearer|token|secret|password|api.?key|code[=:]|https?:\/\/|[A-Za-z0-9_-]{32,}/i,
        text
      ) or
        Enum.any?(state.secrets, &String.contains?(text, &1))

    text = if secret?, do: "[credential-bearing diagnostic withheld]", else: text
    if text != "", do: Logger.debug("MCP #{state.server} stderr: #{text}")
  end

  defp clean(text) do
    text
    |> String.replace_invalid()
    |> Escapes.strip()
    |> String.replace(
      ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}]/u,
      ""
    )
    |> String.slice(0, @line_limit)
  end
end
