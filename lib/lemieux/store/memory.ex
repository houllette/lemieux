defmodule Lemieux.Store.Memory do
  @moduledoc """
  A bounded, process-owned transcript store for short-lived embeddings.

  `new/1` starts a private store for the calling process. Pass the returned
  store to Lemieux sessions. After a session stops, the owner can still read
  or resume its transcript until the owner exits or calls `close/1`.
  Closing the store releases every transcript, so stop any sessions using it
  first.

  `:max_bytes` defaults to 8 MiB across all transcripts. The limit counts each
  session identifier once and each entry by its external term size, a
  measure of retained data independent of BEAM heap overhead. A batch that
  would exceed the limit returns `{:error, :limit_exceeded}` without appending
  any of its entries. A session that hits a store error stops to avoid
  working from an incomplete transcript.
  """
  use GenServer

  @behaviour Lemieux.Store

  alias Lemieux.Entry
  alias Lemieux.Store

  @default_max_bytes 8 * 1024 * 1024

  @doc "Starts an in-memory store owned by the calling process."
  @spec new(opts :: keyword()) :: {:ok, Store.t()} | {:error, term()}
  def new(opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, ":max_bytes must be a positive integer"
    end

    with {:ok, pid} <- GenServer.start(__MODULE__, {self(), max_bytes}),
         do: {:ok, {__MODULE__, pid}}
  end

  @doc "Releases the store and its entries. Only the owner may close it."
  @spec close(store :: Store.t()) :: :ok | {:error, :not_owner | :closed}
  def close({__MODULE__, pid}), do: request(pid, :close)

  @impl Store
  @spec append(pid :: pid(), id :: Store.session_id(), entries :: [Entry.t()]) ::
          :ok | {:error, :closed | :limit_exceeded}
  def append(pid, id, entries), do: request(pid, {:append, id, entries})

  @impl Store
  @spec read(pid :: pid(), id :: Store.session_id()) ::
          {:ok, [Entry.t()]} | {:error, :closed | :not_found}
  def read(pid, id), do: request(pid, {:read, id})

  @impl Store
  @spec list_sessions(pid :: pid()) :: {:ok, [Store.session_id()]} | {:error, :closed}
  def list_sessions(pid), do: request(pid, :list)

  @impl Store
  @spec lock(pid :: pid(), id :: Store.session_id()) ::
          {:ok, reference()} | {:error, :closed | {:locked, map()}}
  def lock(pid, id), do: request(pid, {:lock, id})

  @impl Store
  @spec unlock(pid :: pid(), id :: Store.session_id(), lock :: reference()) :: :ok
  def unlock(pid, id, lock) do
    _ = request(pid, {:unlock, id, lock})
    :ok
  end

  defp request(pid, call) do
    GenServer.call(pid, call, :infinity)
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal] ->
      {:error, :closed}
  end

  @impl true
  def init({owner, max_bytes}) do
    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       max_bytes: max_bytes,
       bytes: 0,
       sessions: %{},
       newest_first: [],
       locks: %{}
     }}
  end

  @impl true
  def handle_call(:close, {owner, _tag}, %{owner: owner} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(:close, _from, state), do: {:reply, {:error, :not_owner}, state}

  def handle_call({:append, _id, []}, _from, state), do: {:reply, :ok, state}

  def handle_call({:append, id, entries}, _from, state) do
    old_entries = Map.get(state.sessions, id, [])
    id_bytes = if old_entries == [], do: byte_size(id), else: 0
    bytes = Enum.reduce(entries, state.bytes + id_bytes, &(:erlang.external_size(&1) + &2))

    if bytes <= state.max_bytes do
      order = if old_entries == [], do: [id | state.newest_first], else: state.newest_first
      sessions = Map.put(state.sessions, id, Enum.reverse(entries, old_entries))
      {:reply, :ok, %{state | bytes: bytes, sessions: sessions, newest_first: order}}
    else
      {:reply, {:error, :limit_exceeded}, state}
    end
  end

  def handle_call({:read, id}, _from, state) do
    result =
      case Map.fetch(state.sessions, id) do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        :error -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state),
    do: {:reply, {:ok, Enum.reverse(state.newest_first)}, state}

  def handle_call({:lock, id}, {writer, _tag}, state) do
    case Map.fetch(state.locks, id) do
      {:ok, {holder, ref}} ->
        if Process.alive?(holder) do
          {:reply, {:error, {:locked, %{"process" => inspect(holder)}}}, state}
        else
          Process.demonitor(ref, [:flush])
          claim(state, id, writer)
        end

      :error ->
        claim(state, id, writer)
    end
  end

  def handle_call({:unlock, id, ref}, _from, state) do
    case Map.get(state.locks, id) do
      {_writer, ^ref} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | locks: Map.delete(state.locks, id)}}

      _other ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | locks: Map.reject(state.locks, fn {_id, {_, lock}} -> ref == lock end)}}
  end

  defp claim(state, id, writer) do
    ref = Process.monitor(writer)
    {:reply, {:ok, ref}, put_in(state.locks[id], {writer, ref})}
  end
end
