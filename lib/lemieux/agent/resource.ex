defmodule Lemieux.Agent.Resource do
  @moduledoc false
  alias Lemieux.RepositoryContext.Worker

  # Start under the guardian, after its owner monitor exists. Creating a
  # session first and then monitoring the caller leaves an orphan on kill.
  @spec acquire(start :: (pid() -> {:ok, term()} | {:error, term()}), stop :: (term() -> term())) ::
          {:ok, term(), pid()} | {:error, term()}
  def acquire(start, stop) do
    owner = self()
    token = make_ref()
    {guard, monitor} = spawn_monitor(fn -> guard(owner, token, start, stop) end)

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

  defp guard(owner, token, start, stop) do
    monitor = Process.monitor(owner)

    case safe_start(start, owner) do
      {:ok, resource} ->
        send(owner, {token, {:ok, resource}})

        await_release(owner, monitor)
        cleanup(stop, resource)

      {:error, _reason} = error ->
        send(owner, {token, error})
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

  defp safe_start(start, owner) do
    start.(owner)
  rescue
    _failure -> {:error, :resource_start_failed}
  catch
    _kind, _failure -> {:error, :resource_start_failed}
  end
end
