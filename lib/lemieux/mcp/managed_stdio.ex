defmodule Lemieux.MCP.ManagedStdio do
  @moduledoc """
  Demand-driven pipes for a host's existing stdio launcher.

  Return `launch/5` from the ordinary `:stdio_launcher` callback. The native
  transport still owns JSON framing, discovery, multiplexing and cancellation.
  This helper uses the already-shipped ExCmd executor: one stdout chunk is read
  per acknowledgement, so a slow client backpressures the OS pipe instead of
  accumulating Port messages. One bounded stdin write may be pending; a busy
  writer or its deadline ends the connection rather than truncating a message.
  Kernel/executor pipe buffers are additional to the single advertised chunk.

  The helper monitors the client, including an untrappable client kill. Close
  is idempotent. `finish_input/1` closes stdin while continuing to read stdout.
  Close first closes pipes, then ExCmd escalates TERM/KILL on the direct process
  within `:close_grace_ms`. It does not create or signal a process group. Hosts
  requiring group/container teardown retain their own launcher and close hook.
  Detached descendants and remote targets can outlive the wrapper. On helper
  or VM death ExCmd's executor closes its pipes and attempts direct-process
  cleanup, but no BEAM callback or observer is guaranteed to run. This is pipe
  lifetime support, not whole-process containment.

  The host chooses command, arguments, working directory and environment. `env`
  adds to the inherited environment; a host needing an allowlist must launch
  through its own scrubber/backend. Stderr is discarded, never mixed into JSON
  or automatically exported. Observer events contain only typed lifecycle
  facts, and wrapper exit leaves target outcome unknown.
  """
  use GenServer
  alias Lemieux.Environment.Inherited
  alias Lemieux.MCP.StdioLifecycle

  @derive {Inspect, only: [:pid]}
  defstruct [:pid]
  @type t :: %__MODULE__{pid: pid()}

  @doc "Launch a managed endpoint accepted by the native stdio transport."
  @spec launch(
          command :: String.t(),
          args :: [String.t()],
          env :: map(),
          cwd :: Path.t(),
          opts :: keyword()
        ) :: {:ok, t()} | {:error, term()}
  def launch(command, args, env, cwd, opts \\ []) do
    options =
      Keyword.merge(
        [
          chunk_bytes: 65_531,
          max_write_bytes: 4_194_305,
          write_timeout_ms: 5_000,
          close_grace_ms: 1_000
        ],
        opts
      )

    observer = Keyword.get(options, :observer)

    with :ok <- validate(options),
         executable when is_binary(executable) <- Inherited.find_executable(command),
         {:ok, pid} <-
           GenServer.start(__MODULE__, {self(), executable, args, env, cwd, options},
             timeout: 5_000
           ) do
      {:ok, %__MODULE__{pid: pid}}
    else
      _failed ->
        StdioLifecycle.emit(observer, nil, :launch_failed)
        {:error, :managed_stdio_launch_failed}
    end
  end

  defp validate(opts) do
    if Enum.all?(
         [:chunk_bytes, :max_write_bytes, :write_timeout_ms, :close_grace_ms],
         &valid_limit?(Keyword.fetch!(opts, &1))
       ) and
         opts[:chunk_bytes] <= 65_531 and opts[:write_timeout_ms] <= 60_000 and
         opts[:close_grace_ms] in 100..5_000, do: :ok, else: {:error, :invalid_limits}
  end

  defp valid_limit?(value), do: is_integer(value) and value in 1..67_108_864

  @doc "Send one bounded frame; a blocked write has a finite deadline."
  @spec write(process :: t(), data :: binary()) :: :ok | {:error, term()}
  def write(process, data), do: call(process, {:write, data})

  @doc "Release the previous stdout chunk and request the next one."
  @spec ack(process :: t()) :: :ok
  def ack(process) do
    send(process.pid, {:ack, self()})
    :ok
  end

  @doc "Close stdin without discarding subsequent stdout."
  @spec finish_input(process :: t()) :: :ok | {:error, term()}
  def finish_input(process), do: call(process, :finish_input)

  @doc "Safe current buffering counters, without command or output."
  @spec info(process :: t()) :: map() | {:error, term()}
  def info(process), do: call(process, :info)

  @doc "Idempotently close pipes and await direct-process termination."
  @spec close(process :: t()) :: :ok
  def close(process) do
    call(process, :close)
    :ok
  end

  defp call(process, message) do
    GenServer.call(process.pid, message, :infinity)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl true
  def init({owner, command, args, env, cwd, opts}) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    with {:ok, process} <-
           ExCmd.Process.start_link([command | args],
             cd: cwd,
             env: Map.to_list(env),
             stderr: :disable
           ),
         :ok <- startup_barrier(process) do
      manager = self()
      reader = spawn_link(fn -> reader(process, manager) end)
      writer = spawn_link(fn -> writer(process, manager) end)
      :ok = ExCmd.Process.change_pipe_owner(process, :stdout, reader)
      :ok = ExCmd.Process.change_pipe_owner(process, :stdin, writer)
      send(reader, {:read, opts[:chunk_bytes]})

      {:ok,
       %{
         owner: owner,
         owner_ref: owner_ref,
         process: process,
         reader: reader,
         writer: writer,
         outstanding_bytes: 0,
         pending: nil,
         options: opts,
         awaited?: false
       }}
    else
      _failed -> {:stop, :launch_failed}
    end
  end

  # ExCmd's os_pid/1 is specified as an integer but returns {:ok, pid} in
  # 0.18. Calling the same server message preserves its startup barrier without
  # letting that incorrect spec make the live tuple branch unreachable to
  # Dialyzer. The local command runner has the same upstream compatibility seam.
  defp startup_barrier(process) do
    case GenServer.call(process.pid, :os_pid, :infinity) do
      {:ok, pid} when is_integer(pid) -> :ok
      pid when is_integer(pid) -> :ok
      _unavailable -> {:error, :launch_failed}
    end
  end

  @impl true
  def handle_call(:info, _from, state),
    do:
      {:reply,
       %{outstanding_bytes: state.outstanding_bytes, write_pending?: state.pending != nil}, state}

  def handle_call(:close, _from, state) do
    StdioLifecycle.emit(state.options[:observer], self(), :interrupted)
    {:stop, :normal, :ok, state}
  end

  def handle_call(operation, {caller, _ref} = from, %{owner: caller, pending: nil} = state)
      when operation == :finish_input or elem(operation, 0) == :write do
    if valid_write?(operation, state.options[:max_write_bytes]) do
      token = make_ref()

      timer =
        Process.send_after(self(), {:write_timeout, token}, state.options[:write_timeout_ms])

      send(state.writer, {operation, token})
      {:noreply, %{state | pending: {from, token, timer}}}
    else
      {:stop, :normal, {:error, :write_limit}, interrupted(state)}
    end
  end

  def handle_call(_operation, _from, state),
    do: {:stop, :normal, {:error, :write_busy}, interrupted(state)}

  defp valid_write?(:finish_input, _limit), do: true
  defp valid_write?({:write, data}, limit), do: is_binary(data) and byte_size(data) <= limit

  @impl true
  def handle_info({:read, {:ok, data}}, state) do
    send(state.owner, {self(), {:data, data}})
    {:noreply, %{state | outstanding_bytes: byte_size(data)}}
  end

  def handle_info({:ack, owner}, %{owner: owner, outstanding_bytes: bytes} = state)
      when bytes > 0 do
    send(state.reader, {:read, state.options[:chunk_bytes]})
    {:noreply, %{state | outstanding_bytes: 0}}
  end

  def handle_info({:written, token, result}, %{pending: {from, token, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, result)

    if result == :ok,
      do: {:noreply, %{state | pending: nil}},
      else: {:stop, :normal, interrupted(%{state | pending: nil})}
  end

  def handle_info({:write_timeout, token}, %{pending: {from, token, _timer}} = state) do
    GenServer.reply(from, {:error, :write_timeout})
    {:stop, :normal, interrupted(%{state | pending: nil})}
  end

  def handle_info({:read, result}, state) when result == :eof or result == {:error, :epipe} do
    case await_exit(state) do
      {:ok, status} ->
        send(state.owner, {self(), {:exit_status, status}})
        StdioLifecycle.emit(state.options[:observer], self(), :wrapper_exit, status)

      _unknown ->
        send(state.owner, {self(), :eof})
        StdioLifecycle.emit(state.options[:observer], self(), :eof)
    end

    {:stop, :normal, %{state | awaited?: true}}
  end

  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %{owner_ref: ref, owner: owner} = state
      ),
      do: {:stop, :normal, interrupted(state)}

  def handle_info({:EXIT, _process, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _process, _reason}, state), do: {:stop, :normal, interrupted(state)}
  def handle_info({:read, {:error, _reason}}, state), do: {:stop, :normal, interrupted(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp interrupted(state) do
    send(state.owner, {self(), :eof})
    StdioLifecycle.emit(state.options[:observer], self(), :interrupted)
    state
  end

  @impl true
  def terminate(_reason, state) do
    if state.pending do
      {from, _token, timer} = state.pending
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :closed})
    end

    # Keep a blocked reader alive until the executor has answered the exit.
    ExCmd.Process.close_stdin(state.process)
    unless state.awaited?, do: await_exit(state)

    for worker <- [state.reader, state.writer],
        Process.alive?(worker),
        do: Process.exit(worker, :kill)

    :ok
  end

  defp await_exit(state) do
    ExCmd.Process.await_exit(state.process, state.options[:close_grace_ms])
  catch
    :exit, _reason -> {:error, :unknown}
  end

  defp reader(process, manager) do
    receive do
      {:read, bytes} ->
        send(manager, {:read, ExCmd.Process.read(process, bytes)})
        reader(process, manager)
    end
  end

  defp writer(process, manager) do
    receive do
      {{:write, data}, token} ->
        send(manager, {:written, token, ExCmd.Process.write(process, data)})
        writer(process, manager)

      {:finish_input, token} ->
        send(manager, {:written, token, ExCmd.Process.close_stdin(process)})
        writer(process, manager)
    end
  end
end
