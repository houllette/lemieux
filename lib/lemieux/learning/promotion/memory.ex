defmodule Lemieux.Learning.Promotion.Memory do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Explicitly mounted reference promotion host for an in-memory harness owner.
  The registry and harness swap in one GenServer state transition. `:prepare`
  is a bounded, side-effect-free assembly/restart-preparation check receiving
  the old harness, proposed harness and receipt. Failure keeps both old values
  and quarantines an attempted activation. Current authority is checked again
  after preparation, before commit. Clients use `Promotion.current/2` to obtain
  a harness for each invocation, including resumed sessions.

  This adapter is volatile. It does not install an external runtime or provide
  crash-durable history. Durable hosts implement `Promotion.Host` and its
  intent/rollback contract. Nothing starts until the host mounts this process.
  """
  use GenServer
  @behaviour Lemieux.Learning.Promotion.Host
  alias Lemieux.Learning.Promotion
  alias Lemieux.RepositoryContext.Worker

  @doc "Mounts a reference host with a fresh `:base`, `:scope` and optional `:prepare` check."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the host's owned in-memory state for inspection, never an authority grant."
  @spec snapshot(server :: GenServer.server()) :: Promotion.state()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def transact(server, transition), do: GenServer.call(server, {:transact, transition}, 20_000)

  @impl true
  def init(opts) do
    case Promotion.new(Keyword.fetch!(opts, :base), Keyword.fetch!(opts, :scope)) do
      {:ok, state} ->
        {:ok, %{owned: state, prepare: Keyword.get(opts, :prepare, fn _, _, _ -> :ok end)}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.owned, state}

  def handle_call({:transact, transition}, _from, state) do
    outcome = Worker.run(fn -> transition.(state.owned) end, 5000)
    finish(outcome, state)
  end

  defp finish({:ok, {:ok, next, harness, receipt, check}}, state) do
    with {:ok, :ok} <-
           Worker.run(fn -> state.prepare.(state.owned.harness, harness, receipt) end, 5000),
         {:ok, :ok} <- Worker.run(check, 5000) do
      {:reply, {:ok, harness, receipt}, %{state | owned: next}}
    else
      _failure -> preparation_failed(state, next, receipt)
    end
  end

  defp finish({:ok, {:error, reason}}, state), do: {:reply, {:error, reason}, state}
  defp finish(_incomplete, state), do: {:reply, {:error, :promotion_transition_failed}, state}

  defp preparation_failed(state, next, %{"action" => "activated"} = receipt) do
    {owned, failure} = Promotion.failed(state.owned, next, receipt)
    {:reply, {:error, {:runtime_preparation_failed, failure}}, %{state | owned: owned}}
  end

  defp preparation_failed(state, _next, _receipt),
    do: {:reply, {:error, :runtime_preparation_failed}, state}
end
