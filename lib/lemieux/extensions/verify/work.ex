defmodule Lemieux.Extensions.Verify.Work do
  @moduledoc """
  Owns a post-answer check independently of the stop-hook caller.

  The caller waits for the result, but Tasks can inspect or cancel the check
  without waiting for its output stream. If the hook is cancelled, its monitor
  stops the check and records that ending before retaining its bounded logs.
  Keeping this in the extension leaves the session ignorant of verifier policy.
  """
  use GenServer, restart: :temporary

  alias Lemieux.ID
  alias Lemieux.Supervisor, as: Sup

  @doc false
  @spec run(context :: map(), command :: String.t(), work :: function(), record :: function()) ::
          map()
  def run(context, command, work, record) do
    opts = [context: context, command: command, work: work, record: record, owner: self()]

    {:ok, server} =
      DynamicSupervisor.start_child(
        Sup.background_supervisor(context.supervisor),
        {__MODULE__, opts}
      )

    GenServer.call(server, :await, :infinity)
  end

  @doc false
  @spec list(supervisor :: atom(), session_id :: String.t()) :: [map()]
  def list(supervisor, session_id) do
    Sup.background_registry(supervisor)
    |> Registry.select([{{{:verification, session_id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.take(256)
    |> Enum.flat_map(fn server ->
      case call(server, :snapshot) do
        {:ok, snapshot} -> [snapshot]
        _gone -> []
      end
    end)
  end

  @doc false
  @spec cancel(supervisor :: atom(), session_id :: String.t(), id :: String.t()) ::
          :ok | {:error, term()}
  def cancel(supervisor, session_id, id) do
    case Registry.lookup(Sup.background_registry(supervisor), {:verification, session_id, id}) do
      [{server, _}] -> call(server, :cancel)
      [] -> {:error, :task_unavailable}
    end
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _gone -> {:error, :task_unavailable}
  end

  @doc false
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    context = opts[:context]
    id = ID.generate()

    {:ok, _} =
      Registry.register(
        Sup.background_registry(context.supervisor),
        {:verification, context.session_id, id},
        nil
      )

    state = %{
      id: id,
      owner_id: context.session_id,
      session: context.session,
      session_ref: Process.monitor(context.session),
      owner_ref: Process.monitor(opts[:owner]),
      supervisor: context.supervisor,
      command: opts[:command],
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started: System.monotonic_time(:millisecond),
      logs: "",
      work: opts[:work],
      record: opts[:record],
      task: nil,
      waiter: nil,
      result: nil
    }

    record(state, lifecycle(state, %{"status" => "running"}))
    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    server = self()
    work = state.work

    task =
      Task.Supervisor.async_nolink(Sup.task_supervisor(state.supervisor), fn ->
        work.(fn output -> GenServer.call(server, {:output, output}) end)
      end)

    {:noreply, %{state | task: task, work: nil}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state), do: {:noreply, %{state | waiter: from}}
  def handle_call(:await, _from, state), do: {:reply, state.result, state}

  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        id: state.id,
        owner_id: state.owner_id,
        command: state.command,
        started_at: state.started_at,
        duration_ms: System.monotonic_time(:millisecond) - state.started,
        logs: state.logs,
        result: state.result
      }}, state}
  end

  def handle_call({:output, output}, _from, state), do: {:reply, :ok, %{state | logs: output}}

  def handle_call(:cancel, _from, %{result: result} = state) when not is_nil(result),
    do: {:reply, {:error, :already_finished}, state}

  def handle_call(:cancel, _from, state),
    do: {:reply, :ok, state |> stop_worker() |> finish(%{"status" => "cancelled"})}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do:
      {:noreply,
       finish(%{state | task: nil}, %{
         "status" => "failed_to_run",
         "reason" => Exception.format_exit(reason)
       })}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{session_ref: ref} = state),
    do: {:stop, :normal, stop_worker(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref, result: nil} = state),
    do: {:noreply, state |> stop_worker() |> finish(%{"status" => "cancelled"})}

  def handle_info(:expire, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, result) do
    result = lifecycle(state, Map.put_new(result, "output", state.logs))
    record(state, result)
    if state.waiter, do: GenServer.reply(state.waiter, result)
    Process.send_after(self(), :expire, :timer.minutes(5))
    %{state | result: result, logs: result["output"], waiter: nil, record: nil}
  end

  defp lifecycle(state, result) do
    result =
      Map.merge(result, %{
        "task_id" => state.id,
        "command" => state.command,
        "started_at" => state.started_at,
        "duration_ms" => System.monotonic_time(:millisecond) - state.started
      })

    if result["status"] == "running",
      do: result,
      else: Map.put(result, "finished_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp record(state, result) do
    state.record.(result)
  catch
    :exit, _session_gone -> :ok
  end

  defp stop_worker(%{task: nil} = state), do: state

  defp stop_worker(state) do
    Task.shutdown(state.task, :brutal_kill)
    %{state | task: nil}
  end

  @impl true
  def terminate(_reason, state) do
    stop_worker(state)
    :ok
  end
end
