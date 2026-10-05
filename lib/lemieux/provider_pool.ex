defmodule Lemieux.ProviderPool do
  @moduledoc """
  Sizes the HTTP connection pool every model stream shares, from what this
  runtime is configured to run at once.

  `req_llm` streams through a single Finch instance whose default pools are
  one connection each, eight pools per host. That is right for a session
  talking to a model on its own and wrong the moment a parent delegates: a
  parent plus three children is four concurrent streams to the same provider,
  and Finch picks a pool per checkout without balancing, so collisions start
  well below eight. The 2026-09-17 investigator evaluation lost four of nine
  children to exactly that — each one queued behind a busy connection for the
  whole pool timeout and died at its deadline having read one file.

  The experiment fixed it in its own script. That is the wrong place: the
  number that decides how many streams can be in flight is
  `Lemieux.Subagent.Admission`'s, it lives in the supervisor a host mounts,
  and a host that raises it should not have to know that a dependency's pool
  needs raising too. So the sizing happens where the concurrency is declared.

  ## What it will and will not do

  Pool configuration is global to the VM and applying it means restarting
  `:req_llm`, which drops idle connections. Both facts bound what is safe:

    * a host that configured `:req_llm`'s `:finch` pools itself is never
      touched — it has already made this decision;
    * a pool that is already big enough is left alone;
    * the resize happens **at most once per VM**, recorded in `:persistent_term`,
      so a second mounted runtime cannot restart the dependency underneath the
      first one's in-flight requests. A second mount that needs more says so in
      the result rather than acting;
    * `provider_pool: :off` skips it entirely, for a host that would rather
      own the decision and accept the default;
    * a restart keeps the start type `:req_llm` had, so a release's
      `:permanent` dependency stays permanent.

  A host that sets `config :req_llm, stream_pool_size: N` (at least the
  concurrency it runs) before mounting gets `:sufficient` and no restart at
  all, which is the quieter choice for anything long-running.

  Connections are established lazily, so a larger `size` is a ceiling rather
  than an allocation: sizing each pool to hold the whole concurrency costs
  nothing when the concurrency is not used.
  """

  require Logger

  @marker {__MODULE__, :sized}
  @default_pool_count 8

  @typedoc "What `ensure/1` did, and why."
  @type outcome ::
          :host_configured | :sufficient | :resized | :already_sized | :disabled | :unavailable

  @doc """
  Ensures the shared stream pool can hold `:streams` concurrent connections.

  Options:

    * `:streams` — the concurrency to size for. Normally derived by
      `required/1` from the subagent admission limits.
    * `:mode` — `:size` (default) or `:off`.

  Returns `{:ok, outcome}`; a pool that could not be resized is reported, not
  raised, because a runtime with an undersized pool still works and a host
  should not fail to mount over a connection count.
  """
  @spec ensure(opts :: keyword()) :: {:ok, outcome()}
  def ensure(opts \\ []) when is_list(opts) do
    streams = Keyword.get_lazy(opts, :streams, fn -> required(opts) end)

    cond do
      Keyword.get(opts, :mode, :size) == :off -> {:ok, :disabled}
      not Code.ensure_loaded?(ReqLLM.Application) -> {:ok, :unavailable}
      host_configured?() -> {:ok, :host_configured}
      pool_size() >= streams -> {:ok, :sufficient}
      :persistent_term.get(@marker, false) -> already_sized(streams)
      true -> resize(streams)
    end
  end

  @doc """
  How many concurrent streams a runtime with these options can produce.

  One per admitted child, plus one parent for each of them: a parent is
  streaming its own turn while its children stream theirs, and the parent's
  connection is the one whose loss is least recoverable. `:max_concurrent_streams`
  overrides the derivation for a host that knows better — one running many
  parents per runtime, say, or one that shares a VM with other traffic.
  """
  @spec required(opts :: keyword()) :: pos_integer()
  def required(opts \\ []) when is_list(opts) do
    subagents = Keyword.get(opts, :subagents, [])
    children = Keyword.get(subagents, :max_active_runtime, 8)

    Keyword.get(opts, :max_concurrent_streams, children * 2)
  end

  @doc "How many concurrent streams the configured pool can hold."
  @spec capacity() :: non_neg_integer()
  def capacity do
    size = pool_size()
    count = Application.get_env(:req_llm, :stream_pool_count, @default_pool_count)

    if is_integer(count) and count > 0,
      do: size * count,
      else: 0
  end

  defp pool_size do
    case Application.get_env(:req_llm, :stream_pool_size, 1) do
      size when is_integer(size) and size > 0 -> size
      _invalid -> 0
    end
  end

  # Each pool is sized to hold the whole concurrency rather than its share of
  # it. Finch picks a pool per checkout without balancing, so a per-pool share
  # leaves the unlucky request queued behind a busy connection — which is the
  # failure this exists to prevent, at a per-pool depth instead of a global one.
  defp resize(streams) do
    count = Application.get_env(:req_llm, :stream_pool_count, @default_pool_count)
    count = if is_integer(count) and count > 0, do: count, else: @default_pool_count

    Application.put_env(:req_llm, :stream_pool_size, streams)
    Application.put_env(:req_llm, :stream_pool_count, count)
    :persistent_term.put(@marker, true)

    case restart(:req_llm) do
      :ok ->
        Logger.debug(fn ->
          "lemieux: sized the provider stream pool for #{streams} concurrent streams " <>
            "(#{count} pools of #{streams})"
        end)

        {:ok, :resized}

      {:error, reason} ->
        Logger.warning(
          "lemieux: could not resize the provider stream pool (#{inspect(reason)}); " <>
            "concurrent children may queue behind one another"
        )

        {:ok, :unavailable}
    end
  end

  @doc false
  # Public for its test, which restarts an application of its own: making
  # `:req_llm` itself `:permanent` in a test VM would let any crash in it end
  # the suite.
  #
  # Not started yet is the easy case: the env is read when it starts, so there
  # is nothing to restart and nothing in flight to disturb.
  #
  # Restarted with the start type it had. `Application.ensure_all_started/1`
  # alone starts it `:temporary`, which in a release demotes a `:permanent`
  # dependency: a host that called `ensure/1` before mounting, as the guides
  # say to, found that a later crash of ReqLLM's supervisor left it running
  # with no provider pool — every model call failing — instead of taking the
  # node down for its supervisor to restart.
  @spec restart(app :: atom()) :: :ok | {:error, term()}
  def restart(app) when is_atom(app) do
    case started_type(app) do
      nil ->
        :ok

      type ->
        with :ok <- Application.stop(app),
             {:ok, _started} <- Application.ensure_all_started(app, type: type) do
          :ok
        end
    end
  end

  # Only `:application.info/0` says how a running application was started.
  defp started_type(app) do
    case :application.info() |> Keyword.get(:started, []) |> List.keyfind(app, 0) do
      {^app, type} -> type
      nil -> nil
    end
  end

  defp already_sized(streams) do
    if pool_size() < streams do
      Logger.warning(
        "lemieux: this runtime wants #{streams} concurrent provider streams but the pool " <>
          "holds #{pool_size()} per pool, and another runtime already sized it. Configure " <>
          ":req_llm, :stream_pool_size before mounting, or expect children to queue."
      )
    end

    {:ok, :already_sized}
  end

  defp host_configured? do
    :req_llm |> Application.get_env(:finch, []) |> Keyword.has_key?(:pools)
  end

  @doc false
  @spec forget() :: :ok
  def forget, do: :persistent_term.erase(@marker) && :ok
end
