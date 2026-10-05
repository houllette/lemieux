defmodule Lemieux.Background.Task do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Lemieux.Clock
  alias Lemieux.Environment
  alias Lemieux.Supervisor, as: Sup

  @terminal ~w(exited timed_out failed cancelled)a

  defstruct [
    :id,
    :clock,
    :session_id,
    :supervisor,
    :command,
    :cwd,
    :environment,
    :env,
    :runner,
    :timeout_ms,
    :retention_ms,
    :max_output_bytes,
    :owner_ref,
    :worker,
    :command_timer,
    :retention_timer,
    :started_at,
    :started_monotonic,
    :finished_at,
    :finished_monotonic,
    :status,
    :exit_status,
    :error,
    :output_head,
    :output_tail,
    :output_bytes,
    :waiters,
    :subscribers
  ]

  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    session_id = Keyword.fetch!(opts, :session_id)
    id = Keyword.fetch!(opts, :id)
    name = {:via, Registry, {Sup.background_registry(supervisor), {session_id, id}}}

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    owner_ref =
      case Keyword.get(opts, :owner) do
        owner when is_pid(owner) -> Process.monitor(owner)
        _no_owner -> nil
      end

    # Every deadline this process keeps — the command's, an await's, the
    # finished task's retention — is measured on this clock, so a test can
    # move them without waiting. The command's own OS-level timeout is the
    # environment's and stays real.
    clock = Keyword.get(opts, :clock)

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      clock: clock,
      session_id: Keyword.fetch!(opts, :session_id),
      supervisor: Keyword.fetch!(opts, :supervisor),
      command: Keyword.fetch!(opts, :command),
      cwd: Keyword.fetch!(opts, :cwd),
      environment: Keyword.fetch!(opts, :environment),
      env: Keyword.get(opts, :env, []),
      runner: Keyword.get(opts, :runner),
      timeout_ms: positive!(opts, :timeout_ms),
      retention_ms: positive!(opts, :retention_ms),
      max_output_bytes: positive!(opts, :max_output_bytes),
      owner_ref: owner_ref,
      started_at: timestamp(),
      started_monotonic: Clock.now_ms(clock),
      status: :running,
      output_head: "",
      output_tail: "",
      output_bytes: 0,
      waiters: %{},
      subscribers: %{}
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    server = self()

    worker =
      Elixir.Task.Supervisor.async_nolink(Sup.task_supervisor(state.supervisor), fn ->
        execute(server, state)
      end)

    timer = Clock.send_after(state.clock, self(), :command_timeout, state.timeout_ms)
    {:noreply, %{state | worker: worker, command_timer: timer}}
  end

  @impl GenServer
  def handle_call(:poll, _from, state), do: {:reply, {:ok, snapshot(state)}, state}

  def handle_call({:subscribe, subscriber}, _from, %{status: status} = state)
      when status in @terminal do
    notify(subscriber, state)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    subscribers =
      Map.put_new_lazy(state.subscribers, subscriber, fn -> Process.monitor(subscriber) end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {ref, subscribers} = Map.pop(state.subscribers, subscriber)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:await, _timeout}, _from, %{status: status} = state)
      when status in @terminal do
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:await, 0}, _from, state) do
    {:reply, {:error, {:timeout, snapshot(state)}}, state}
  end

  def handle_call({:await, :infinity}, from, state) do
    token = make_ref()
    {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, nil})}}
  end

  def handle_call({:await, timeout_ms}, from, state) do
    token = make_ref()
    timer = Clock.send_after(state.clock, self(), {:wait_timeout, token}, timeout_ms)
    {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, timer})}}
  end

  def handle_call(:cancel, _from, %{status: status} = state) when status in @terminal do
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call(:cancel, _from, state) do
    state = state |> stop_worker() |> finish(:cancelled)
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:command_event, {:data, data}}, _from, %{status: :running} = state)
      when is_binary(data) do
    {:reply, :continue, append_output(state, data)}
  end

  def handle_call({:command_event, {:exit_status, status}}, _from, state)
      when is_integer(status) and status >= 0 do
    state = finish(state, :exited, exit_status: status)
    {:reply, :stop, state}
  end

  def handle_call({:command_event, {:timeout, timeout_ms}}, _from, state) do
    state = finish(state, :timed_out, error: "timed out after #{timeout_ms}ms and was killed")
    {:reply, :stop, state}
  end

  def handle_call({:command_event, {:failed, reason}}, _from, state) do
    state =
      finish(state, :failed, error: "the command's output stream failed: #{describe(reason)}")

    {:reply, :stop, state}
  end

  def handle_call({:command_event, {:output_limit, bytes}}, _from, state) do
    state = finish(state, :failed, error: "command output exceeded the #{bytes}-byte limit")
    {:reply, :stop, state}
  end

  def handle_call({:command_event, event}, _from, state) do
    state = finish(state, :failed, error: "invalid command event: #{inspect(event)}")
    {:reply, :stop, state}
  end

  @impl GenServer
  def handle_info(:command_timeout, %{status: :running} = state) do
    state =
      state
      |> stop_worker()
      |> finish(:timed_out, error: "timed out after #{state.timeout_ms}ms and was killed")

    {:noreply, state}
  end

  def handle_info(:command_timeout, state), do: {:noreply, state}

  def handle_info({:wait_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, {:timeout, snapshot(state)}})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(:expire, state), do: {:stop, :normal, state}

  def handle_info({ref, result}, %{worker: %Elixir.Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | worker: nil}

    state =
      case {state.status, result} do
        {:running, :complete} ->
          finish(state, :failed, error: "command stream ended without an exit status")

        {:running, {:error, reason}} ->
          finish(state, :failed, error: describe(reason))

        {_terminal, _result} ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: %Elixir.Task{ref: ref}} = state) do
    state = %{state | worker: nil}

    state =
      if state.status == :running,
        do:
          finish(state, :failed,
            error: "command worker crashed: #{Exception.format_exit(reason)}"
          ),
        else: state

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, stop_worker(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      if state.subscribers[pid] == ref,
        do: Map.delete(state.subscribers, pid),
        else: state.subscribers

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _state = stop_worker(state)
    :ok
  end

  # `max_output_bytes: :infinity` because this process bounds its own memory —
  # a head and a tail, with the omitted count — and the environment's cap
  # exists for callers that hold everything. With that cap a dev server was
  # killed as a failure once its log passed eight megabytes, which is an
  # afternoon of ordinary requests.
  defp execute(server, %{runner: nil} = state) do
    case Environment.run(state.environment, state.command,
           cwd: state.cwd,
           timeout_ms: state.timeout_ms,
           env: state.env,
           max_output_bytes: :infinity
         ) do
      {:ok, events} -> consume(server, events)
      {:error, reason} -> {:error, {:command_start_failed, reason}}
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute(server, %{runner: runner} = state) do
    case runner.(state.command, cwd: state.cwd, timeout_ms: state.timeout_ms) do
      {:ok, output, status} when is_binary(output) and is_integer(status) and status >= 0 ->
        :continue = GenServer.call(server, {:command_event, {:data, output}}, :infinity)
        _result = GenServer.call(server, {:command_event, {:exit_status, status}}, :infinity)
        :complete

      {:error, reason} ->
        {:error, {:command_start_failed, reason}}

      other ->
        {:error, {:invalid_runner_result, other}}
    end
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp consume(server, events) do
    Enum.reduce_while(events, :complete, fn event, :complete ->
      case GenServer.call(server, {:command_event, event}, :infinity) do
        :continue -> {:cont, :complete}
        :stop -> {:halt, :complete}
      end
    end)
  end

  defp append_output(state, data) do
    head_limit = div(state.max_output_bytes, 2)
    tail_limit = state.max_output_bytes - head_limit
    needed = max(head_limit - byte_size(state.output_head), 0)
    head_bytes = min(needed, byte_size(data))
    <<for_head::binary-size(^head_bytes), remainder::binary>> = data
    tail = keep_tail(state.output_tail <> remainder, tail_limit)

    %{
      state
      | output_head: state.output_head <> for_head,
        output_tail: tail,
        output_bytes: state.output_bytes + byte_size(data)
    }
  end

  defp keep_tail(bytes, limit) when byte_size(bytes) <= limit, do: bytes
  defp keep_tail(bytes, limit), do: binary_part(bytes, byte_size(bytes) - limit, limit)

  defp finish(state, status, opts \\ [])
  defp finish(%{status: status} = state, _status, _opts) when status in @terminal, do: state

  defp finish(state, status, opts) do
    if state.command_timer, do: Clock.cancel(state.clock, state.command_timer)

    state = %{
      state
      | status: status,
        exit_status: Keyword.get(opts, :exit_status),
        error: Keyword.get(opts, :error),
        finished_at: timestamp(),
        finished_monotonic: Clock.now_ms(state.clock),
        command_timer: nil,
        retention_timer: Clock.send_after(state.clock, self(), :expire, state.retention_ms)
    }

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      if timer, do: Clock.cancel(state.clock, timer)
      GenServer.reply(from, {:ok, snapshot(state)})
    end)

    Enum.each(state.subscribers, fn {pid, ref} ->
      Process.demonitor(ref, [:flush])
      notify(pid, state)
    end)

    %{state | waiters: %{}, subscribers: %{}}
  end

  defp notify(subscriber, state) do
    send(
      subscriber,
      {:lemieux_background,
       %{
         event_id: "#{state.session_id}:#{state.id}:terminal",
         task: snapshot(state)
       }}
    )
  end

  defp stop_worker(%{worker: %Elixir.Task{} = worker} = state) do
    _result = shutdown(worker)
    %{state | worker: nil}
  end

  defp stop_worker(state), do: state

  defp shutdown(worker) do
    Elixir.Task.shutdown(worker, :brutal_kill)
  catch
    :exit, _reason -> nil
  end

  defp snapshot(state) do
    %{
      id: state.id,
      session_id: state.session_id,
      command: state.command,
      status: state.status,
      exit_status: state.exit_status,
      output: output(state),
      output_bytes: state.output_bytes,
      error: state.error,
      started_at: state.started_at,
      finished_at: state.finished_at,
      duration_ms: duration(state)
    }
  end

  defp output(state) when state.output_bytes <= state.max_output_bytes do
    sanitize(state.output_head <> state.output_tail)
  end

  defp output(state) do
    omitted = state.output_bytes - byte_size(state.output_head) - byte_size(state.output_tail)

    sanitize(state.output_head) <>
      "\n\n… [#{omitted} bytes cut from the middle by lemieux] …\n\n" <>
      sanitize(state.output_tail)
  end

  defp duration(%{finished_monotonic: nil} = state),
    do: max(Clock.now_ms(state.clock) - state.started_monotonic, 0)

  defp duration(state), do: max(state.finished_monotonic - state.started_monotonic, 0)

  defp positive!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp sanitize(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
