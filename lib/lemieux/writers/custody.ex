defmodule Lemieux.Writers.Custody do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Lemieux.Background.Completion
  alias Lemieux.Session
  alias Lemieux.Session.Core
  alias Lemieux.Store
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Writers.Workspace

  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @spec prepare(server :: GenServer.server(), plan :: Lemieux.Writers.Plan.t()) :: term()
  def prepare(pid, plan), do: GenServer.call(pid, {:prepare, plan}, :infinity)
  @spec session(server :: GenServer.server(), id :: String.t(), opts :: keyword()) :: term()
  def session(pid, id, opts), do: GenServer.call(pid, {:session, id, opts}, :infinity)
  @spec release(server :: GenServer.server(), id :: String.t()) :: term()
  def release(pid, id), do: GenServer.call(pid, {:release, id}, :infinity)
  @spec drain(server :: GenServer.server()) :: term()
  def drain(pid), do: GenServer.call(pid, :drain, :infinity)

  @spec captured(server :: GenServer.server(), id :: String.t()) :: :ok
  def captured(pid, id), do: GenServer.call(pid, {:captured, id})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    parent = Keyword.fetch!(opts, :parent)

    {:ok,
     %{
       owner: owner,
       parent: parent,
       owner_ref: Process.monitor(owner),
       parent_ref: Process.monitor(parent),
       adapter: opts[:workspace],
       group_id: opts[:id],
       runtime: opts[:supervisor],
       store: opts[:store],
       leases: %{},
       closed?: false
     }}
  end

  @impl true
  def handle_call({:prepare, plan}, {worker, _}, state) do
    if live?(state) do
      case Workspace.call(state.adapter, :prepare, [state.group_id, plan]) do
        {:ok, workspace} ->
          lease = %{
            workspace: workspace,
            plan: plan,
            captured?: false,
            session_id: nil,
            session: nil,
            worker: worker,
            monitor: Process.monitor(worker)
          }

          state = put_in(state.leases[plan.id], lease)

          prepared_reply(state, plan.id, workspace)

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:session, id, opts}, _from, state) do
    if live?(state) and Map.has_key?(state.leases, id) do
      case Lemieux.start_session(opts) do
        {:ok, session} ->
          lease = %{state.leases[id] | session: session, session_id: opts[:id]}
          {:reply, {:ok, session}, put_in(state.leases[id], lease)}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:captured, id}, _from, state),
    do: {:reply, :ok, put_in(state.leases[id].captured?, true)}

  def handle_call({:release, id}, _from, state), do: reply_release(state, id, :ok)

  def handle_call(:drain, _from, state) do
    {state, errors} = release_all(%{state | closed?: true})
    {:reply, if(errors == [], do: :ok, else: {:error, errors}), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when ref == state.owner_ref or ref == state.parent_ref do
    {state, _errors} = release_all(%{state | closed?: true})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.leases, fn {_id, lease} -> lease.monitor == ref end) do
      nil ->
        {:noreply, state}

      {id, _lease} ->
        {state, result} = release_one(state, id)
        if result != :ok, do: send(state.owner, {:cleanup_failed, id, result})
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, :normal}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: release_all(state)

  defp live?(state),
    do: not state.closed? and Process.alive?(state.owner) and Process.alive?(state.parent)

  defp reply_release(state, id, reply) do
    {state, outcome} = release_one(state, id)
    {:reply, if(outcome == :ok, do: reply, else: outcome), state}
  end

  defp release_one(state, id) do
    case state.leases[id] do
      nil ->
        {state, :ok}

      lease ->
        stop_session(lease.session, state.runtime, lease.session_id)

        outcome =
          with :ok <- preserve_work(state, id, lease),
               do: Workspace.call(state.adapter, :release, [lease.workspace])

        if outcome == :ok do
          Process.demonitor(lease.monitor, [:flush])
          {%{state | leases: Map.delete(state.leases, id)}, :ok}
        else
          {state, outcome}
        end
    end
  end

  defp preserve_work(_state, _id, %{captured?: true}), do: :ok
  defp preserve_work(_state, _id, %{session_id: nil}), do: :ok

  defp preserve_work(state, id, lease) do
    entries =
      case Store.read(state.store, lease.session_id) do
        {:ok, entries} -> entries
        _unavailable -> []
      end

    result = %{
      session_id: lease.session_id,
      entries: entries,
      report: %{
        "summary" => "Writer did not finish verified work",
        "critical_findings" => [],
        "critical_findings_unavailable" => true,
        "uncertainties" => ["Read the complete transcript; this is an interrupted attempt"]
      }
    }

    evidence = %{"status" => "unverified", "check" => "interruption capture"}

    case Workspace.call(state.adapter, :export, [lease.workspace, lease.plan, result, evidence]) do
      {:ok, artifact} ->
        send(state.owner, {:writer_preserved, id, artifact})
        :ok

      {:error, :missing_patch} ->
        :ok

      error ->
        {:error, {:uncaptured_work, error}}
    end
  end

  defp prepared_reply(state, id, workspace) do
    if live?(state),
      do: {:reply, {:ok, workspace}, state},
      else: reply_release(state, id, {:error, :cancelled})
  end

  defp stop_session(session, runtime, id) when is_pid(session) do
    if Process.alive?(session) do
      Completion.cancel(runtime, id)
      cancel_busy(session)
      DynamicSupervisor.terminate_child(Sup.session_supervisor(runtime), session)
    end
  end

  defp stop_session(_session, _runtime, _id), do: :ok

  # Cleanup cannot consult an accounting snapshot after a shared ledger loss.
  # Session disappearance between the liveness check and call is a cleanup boundary.
  defp cancel_busy(session) do
    if Core.status(:sys.get_state(session)) == :busy, do: Session.cancel(session)
  catch
    :exit, _gone -> :ok
  end

  defp release_all(state) do
    Enum.each(state.leases, fn {_id, lease} ->
      if Process.alive?(lease.worker), do: Process.exit(lease.worker, :kill)
    end)

    Enum.reduce(Map.keys(state.leases), {state, []}, fn id, {state, errors} ->
      {state, result} = release_one(state, id)
      {state, if(result == :ok, do: errors, else: [{id, result} | errors])}
    end)
  end
end
