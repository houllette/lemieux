defmodule Lemieux.Store do
  @moduledoc """
  Where a session's entries are persisted.

  A store is a `{module, state}` pair. The module implements this behaviour;
  the state is whatever that implementation needs and lemieux never inspects —
  a directory for `Lemieux.Store.JSONL`, a repo and a scope for a host that
  keeps transcripts in Postgres.

  ## Why a behaviour rather than a table

  The core takes no database dependency, by design, and a store baked into the
  library would be that dependency by another name. Hosts differ in what they
  already have: `lmx` has a filesystem and wants files it can `grep`, and an
  embedder with a database wants transcripts inside its own transactions and
  its own retention policy. Neither can be talked into the other's storage,
  and a library that picks one makes the other host reimplement persistence
  around it.

  The pair shape rather than a bare module is what lets one VM hold several
  stores — two directories, two tenants — without a global.

  ## The contract

  Appends are ordered and durable: `read/2` returns exactly what `append/3`
  was given, in the order it was given, and a store rebuilt over the same
  backing data returns the same list. Nothing else is promised. In particular
  a store is not asked to be a queue, to notify anybody, or to serialise two
  writers on one session — a session has exactly one writer, its
  `Lemieux.Session` process, and that is where the ordering guarantee comes
  from.

  ## Keeping it one writer

  One writer per *process* is the session's promise; one writer per
  *transcript* is not something a process can promise alone. Two hosts — two
  terminals resuming the same id — each start a perfectly ordered session,
  and their appends interleave into a file with two parents for one entry.
  The optional `c:lock/2` and `c:unlock/3` callbacks are how a store stops
  that: a session claims its transcript before it writes and releases it
  when it stops, and a store that can tell a claim is held refuses the
  second session with `{:error, {:locked, holder}}` instead. A store that
  implements neither behaves as before. `Lemieux.Store.JSONL` uses a lock
  file; a database-backed store would use an advisory lock.
  """

  alias Lemieux.Entry

  @typedoc "An implementation module paired with its own state."
  @type t :: {module(), state :: term()}

  @typedoc "The identifier of one session's transcript."
  @type session_id :: String.t()

  @doc """
  Appends entries to a session, creating it if it does not exist.
  """
  @callback append(state :: term(), session_id :: session_id(), entries :: [Entry.t()]) ::
              :ok | {:error, term()}

  @doc """
  Reads a session's entries in append order.

  Returns `{:error, :not_found}` when the session has never been written.

  A transcript this build cannot understand — an entry schema version or an
  entry type from a different release — is an error and not an exception.
  Implementations must not raise out of this callback and must not skip the
  parts they could not read: a conversation returned with its middle missing
  is one the model answers confidently and wrong. Say so instead, and let the
  caller decide.
  """
  @callback read(state :: term(), session_id :: session_id()) ::
              {:ok, [Entry.t()]} | {:error, term()}

  @doc """
  Lists the sessions this store holds, oldest first.
  """
  @callback list_sessions(state :: term()) :: {:ok, [session_id()]} | {:error, term()}

  @doc """
  Claims a session's transcript for the calling process before it writes.

  Returns an opaque lock handed back to `c:unlock/3`, or
  `{:error, {:locked, holder}}` when another live writer holds it — `holder`
  is a JSON-shaped description of that writer for a person to read. A claim
  whose holder is provably gone should be taken over rather than refused:
  a crash must not strand a transcript. Optional.
  """
  @callback lock(state :: term(), session_id :: session_id()) ::
              {:ok, lock :: term()} | {:error, {:locked, map()} | term()}

  @doc """
  Releases a claim `c:lock/2` made. Must tolerate a claim already taken over.
  Optional.
  """
  @callback unlock(state :: term(), session_id :: session_id(), lock :: term()) :: :ok

  @optional_callbacks lock: 2, unlock: 3

  @doc """
  Appends entries to a session.
  """
  @spec append(store :: t(), session_id :: session_id(), entries :: [Entry.t()]) ::
          :ok | {:error, term()}
  def append({module, state}, session_id, entries) when is_list(entries) do
    module.append(state, session_id, entries)
  end

  @doc """
  Reads a session's entries in append order.
  """
  @spec read(store :: t(), session_id :: session_id()) :: {:ok, [Entry.t()]} | {:error, term()}
  def read({module, state}, session_id), do: module.read(state, session_id)

  @doc """
  Lists the sessions this store holds, oldest first.
  """
  @spec list_sessions(store :: t()) :: {:ok, [session_id()]} | {:error, term()}
  def list_sessions({module, state}), do: module.list_sessions(state)

  @doc """
  Claims a session's transcript for the calling process.

  `{:ok, nil}` from a store that does not implement `c:lock/2`: such a store
  never promised to notice a second writer, and refusing every session
  because it cannot would be worse than the risk it leaves.
  """
  @spec lock(store :: t(), session_id :: session_id()) ::
          {:ok, term()} | {:error, {:locked, map()} | term()}
  def lock({module, state}, session_id) do
    if Code.ensure_loaded?(module) and function_exported?(module, :lock, 2),
      do: module.lock(state, session_id),
      else: {:ok, nil}
  end

  @doc "Releases a claim `lock/2` returned. A `nil` claim is nothing to release."
  @spec unlock(store :: t(), session_id :: session_id(), lock :: term()) :: :ok
  def unlock(_store, _session_id, nil), do: :ok

  def unlock({module, state}, session_id, lock) do
    if Code.ensure_loaded?(module) and function_exported?(module, :unlock, 3),
      do: module.unlock(state, session_id, lock),
      else: :ok
  end
end
