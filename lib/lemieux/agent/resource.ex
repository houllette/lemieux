defmodule Lemieux.Agent.Resource do
  @moduledoc false
  alias Lemieux.RepositoryContext.Worker

  # Start under the guardian, after its owner monitor exists. Creating a
  # session first and then monitoring the caller leaves an orphan on kill.
  @spec acquire(
          start ::
            (pid() -> {:ok, term()} | {:error, term()})
            | (pid(), pid() -> {:ok, term()} | {:error, term()}),
          stop :: (term() -> term()),
          opts :: keyword()
        ) ::
          {:ok, term(), pid()} | {:error, term()}
  def acquire(start, stop, opts \\ []) do
    owner = self()
    token = make_ref()
    {guard, monitor} = spawn_monitor(fn -> guard(owner, token, start, stop, opts) end)

    receive do
      {^token, {:ok, resource}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, resource, guard}

      {^token, {:error, _reason} = error} ->
        Process.demonitor(monitor, [:flush])
        error

      {:DOWN, ^monitor, :process, ^guard, _reason} ->
        {:error, :resource_start_failed}
    end
  end

  @spec release(guard :: pid()) :: :ok | {:error, atom()}
  def release(guard) do
    monitor = Process.monitor(guard)
    send(guard, :release)

    receive do
      {:DOWN, ^monitor, :process, ^guard, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^guard, _reason} -> {:error, :resource_cleanup_failed}
    end
  end

  # Acquisition must remain cancellable while the callback is running, not
  # only after it returns a handle. A host with partially created external
  # resources supplies :abort to reconcile them after the worker is stopped.
  defp guard(owner, token, start, stop, opts) do
    monitor = Process.monitor(owner)
    guardian = self()

    {worker, worker_ref} =
      spawn_monitor(fn -> send(guardian, {token, safe_start(start, owner, guardian)}) end)

    receive do
      {^token, result} ->
        stop_worker(worker, worker_ref)
        acquired(result, owner, monitor, token, stop, opts)

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        send(owner, {token, {:error, :resource_start_failed}})
        abort(opts)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        stop_worker(worker, worker_ref)
        interrupted(token, stop, opts)
    after
      Keyword.get(opts, :timeout_ms, 5000) ->
        stop_worker(worker, worker_ref)
        interrupted(token, stop, opts)
        send(owner, {token, {:error, :resource_start_timeout}})
    end
  end

  defp acquired({:ok, resource}, owner, monitor, token, stop, _opts) do
    send(owner, {token, {:ok, resource}})
    await_release(owner, monitor)
    cleanup(stop, resource)
  end

  defp acquired({:error, _reason} = error, owner, _monitor, token, _stop, opts) do
    abort(opts)
    send(owner, {token, error})
  end

  # A result sent before worker termination precedes its DOWN message. Drain
  # that race before falling back to partial-acquisition reconciliation.
  defp interrupted(token, stop, opts) do
    receive do
      {^token, {:ok, resource}} -> cleanup(stop, resource)
      {^token, _failed} -> abort(opts)
    after
      0 -> abort(opts)
    end
  end

  defp abort(opts) do
    if callback = opts[:abort], do: cleanup(fn _ -> callback.() end, nil), else: :ok
  end

  defp stop_worker(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp await_release(owner, monitor) do
    receive do
      :release -> :ok
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end
  end

  defp cleanup(stop, resource) do
    case Worker.run(fn -> stop.(resource) end, 5000) do
      {:ok, :ok} -> :ok
      _failed -> exit(:resource_cleanup_failed)
    end
  end

  defp safe_start(start, owner, guardian) do
    if is_function(start, 2), do: start.(owner, guardian), else: start.(owner)
  rescue
    _failure -> {:error, :resource_start_failed}
  catch
    _kind, _failure -> {:error, :resource_start_failed}
  end
end
