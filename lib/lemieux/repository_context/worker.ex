defmodule Lemieux.RepositoryContext.Worker do
  @moduledoc false

  # The guardian owns the worker's lifetime. Task.async_nolink alone leaves
  # work alive when a session cancels the tool that is awaiting it.
  @spec run(work :: (-> term()), timeout_ms :: pos_integer()) :: {:ok, term()} | {:error, atom()}
  def run(work, timeout_ms), do: run(work, timeout_ms, [])

  @spec run(work :: (-> term()), timeout_ms :: pos_integer(), opts :: keyword()) ::
          {:ok, term()} | {:error, atom()}
  def run(work, timeout_ms, opts) do
    owner = self()
    token = make_ref()
    heap_words = Keyword.get(opts, :max_heap_words, 8_000_000)

    {guardian, monitor} =
      spawn_monitor(fn -> guard(owner, token, work, timeout_ms, heap_words) end)

    receive do
      {^token, outcome} ->
        Process.demonitor(monitor, [:flush])
        outcome

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        {:error, :worker_failed}
    end
  end

  defp guard(owner, token, work, timeout, heap_words) do
    owner_ref = Process.monitor(owner)
    guardian = self()

    {worker, worker_ref} =
      :erlang.spawn_opt(
        fn -> send(guardian, {:result, self(), boundary(work)}) end,
        [:monitor, {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}]
      )

    receive do
      {:result, ^worker, result} ->
        stop(worker, worker_ref)
        send(owner, {token, {:ok, result}})

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        send(owner, {token, {:error, :worker_failed}})

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        stop(worker, worker_ref)
    after
      timeout ->
        stop(worker, worker_ref)
        send(owner, {token, {:error, :timeout}})
    end
  end

  defp stop(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp boundary(work) do
    work.()
  rescue
    _error -> {:error, :source_failed}
  catch
    _kind, _reason -> {:error, :source_failed}
  end
end
