defmodule Lemieux.Jobs.Journal do
  @moduledoc """
  Storage chosen by a durable-job host.

  Records have inert JSON values and monotonically increasing revisions.
  Compare-and-swap writes must be atomic and durable before returning. A
  process owns the host lock until it releases it or is provably dead. Locks
  are fencing, not expiring leases: an unreachable owner is refused. The
  shipped filesystem implementation is for one machine; database hosts can
  implement indexed scans and transactions without a dependency in Lemieux.

  `scan` returns a bounded, key-ordered page strictly after the cursor.
  Prefixes separate jobs, budgets and per-effect receipts, so admission never
  rewrites the whole transcript or all effects in a growing job.
  """
  @type t :: {module(), term()}
  @type stored_record :: %{key: String.t(), revision: pos_integer(), value: map()}
  @callback read(state :: term(), key :: String.t()) :: {:ok, stored_record()} | {:error, term()}
  @callback write(
              state :: term(),
              key :: String.t(),
              revision :: non_neg_integer(),
              value :: map()
            ) ::
              {:ok, stored_record()} | {:error, term()}
  @callback scan(
              state :: term(),
              prefix :: String.t(),
              cursor :: String.t() | nil,
              limit :: pos_integer()
            ) ::
              {:ok, [stored_record()]} | {:error, term()}
  @callback lock(state :: term(), key :: String.t()) :: {:ok, term()} | {:error, term()}
  @callback unlock(state :: term(), key :: String.t(), lock :: term()) :: :ok

  @doc "Optional indexed scan of nonterminal jobs for startup; include every nonterminal record."
  @callback pending(state :: term(), cursor :: String.t() | nil, limit :: pos_integer()) ::
              {:ok, [stored_record()]} | {:error, term()}
  @optional_callbacks pending: 3

  @doc "Reads a versioned record."
  @spec read(journal :: t(), key :: String.t()) :: {:ok, stored_record()} | {:error, term()}
  def read({module, state}, key), do: module.read(state, key)
  @doc "Writes only if the expected revision still holds; zero creates."
  @spec write(journal :: t(), key :: String.t(), revision :: non_neg_integer(), value :: map()) ::
          {:ok, stored_record()} | {:error, term()}
  def write({module, state}, key, revision, value), do: module.write(state, key, revision, value)
  @doc "Reads a bounded ordered page."
  @spec scan(
          journal :: t(),
          prefix :: String.t(),
          cursor :: String.t() | nil,
          limit :: pos_integer()
        ) ::
          {:ok, [stored_record()]} | {:error, term()}
  def scan({module, state}, prefix, cursor, limit), do: module.scan(state, prefix, cursor, limit)
  @doc "Claims one host or transaction lock."
  @spec lock(journal :: t(), key :: String.t()) :: {:ok, term()} | {:error, term()}
  def lock({module, state}, key), do: module.lock(state, key)
  @doc "Releases only the calling holder's claim."
  @spec unlock(journal :: t(), key :: String.t(), lock :: term()) :: :ok
  def unlock({module, state}, key, lock), do: module.unlock(state, key, lock)

  @doc "Scans startup candidates, using a host index when supplied; otherwise scans job pages."
  @spec pending(journal :: t(), cursor :: String.t() | nil, limit :: pos_integer()) ::
          {:ok, [stored_record()]} | {:error, term()}
  def pending({module, state} = journal, cursor, limit) do
    if Code.ensure_loaded?(module) and function_exported?(module, :pending, 3),
      do: module.pending(state, cursor, limit),
      else: scan(journal, "job-", cursor, limit)
  end

  @doc "Applies a bounded CAS retry to one record, retaining unrelated fields."
  @spec update(journal :: t(), key :: String.t(), change :: (map() -> map())) ::
          {:ok, stored_record()} | {:error, term()}
  def update(journal, key, change), do: update(journal, key, change, 5)
  defp update(_journal, _key, _change, 0), do: {:error, :conflict}

  defp update(journal, key, change, attempts) do
    with {:ok, record} <- read(journal, key) do
      case write(journal, key, record.revision, change.(record.value)) do
        {:error, :conflict} -> update(journal, key, change, attempts - 1)
        result -> result
      end
    end
  end
end
