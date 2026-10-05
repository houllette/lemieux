defmodule Lemieux.ProviderLimiter do
  @moduledoc """
  Admission for provider requests that share a credential or rate domain.

  Sessions call this boundary from their already-supervised provider tasks, so
  waiting for admission never blocks the session process. Leases are monitored:
  a cancelled or crashed provider task releases its concurrency slot without a
  cleanup message. Queueing is round-robin by root session inside each key so a
  busy root cannot permanently stand in front of another tenant's work.

  Lemieux cannot infer credential tenancy from a provider tuple. A host may pass
  a shared limiter process and an explicit key to every relevant session. The
  mount-local limiter is the safe default for CLI and single-tenant runtimes;
  its default token rate is unlimited until the host supplies measured limits.

  This module intentionally owns admission, not retries. `penalize/3` honors a
  provider's retry-after observation for later requests, while the request that
  saw the limit remains an ordinary failed provider call in its transcript.

  It is the shipped `Lemieux.Provider.Admission`: the four functions the loop
  calls are that behaviour's callbacks, with the limiter's own `GenServer`
  name as the ref. A host that wants a different algorithm implements the
  behaviour and names its module in `Lemieux.Supervisor`'s `:provider_limiter`
  option; `snapshot/1` and the token bucket are this implementation's, not
  the contract's.
  """

  use GenServer

  alias Lemieux.Clock

  @behaviour Lemieux.Provider.Admission

  @type key :: term()
  @type root_id :: String.t()
  @type lease :: %{id: reference(), key: key(), server: GenServer.server()}

  @default_interval :timer.minutes(1)

  @doc """
  Starts a limiter. See `Lemieux.Supervisor` for mount-local configuration.

  Options: `:max_concurrency` (default 8), `:tokens_per_interval` (default
  `:infinity`), `:interval_ms` (default one minute), `:name`, and `:clock` — a
  `Lemieux.Clock` that every cooldown, refill window and wake-up is measured
  on (the real clock when omitted; a test passes a `Lemieux.Clock.Manual`).
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Checks out a monitored lease, waiting fairly until capacity exists."
  @spec checkout(
          server :: GenServer.server(),
          key :: key(),
          root_id :: root_id(),
          estimated_tokens :: non_neg_integer()
        ) :: {:ok, lease()} | {:error, {:request_exceeds_token_limit, pos_integer()}}
  @impl Lemieux.Provider.Admission
  def checkout(server, key, root_id, estimated_tokens)
      when is_binary(root_id) and is_integer(estimated_tokens) and estimated_tokens >= 0 do
    GenServer.call(server, {:checkout, key, root_id, estimated_tokens}, :infinity)
  end

  @doc "Reports actual token usage for a live lease before it is released."
  @spec reconcile(lease :: lease(), actual_tokens :: non_neg_integer()) :: :ok
  @impl Lemieux.Provider.Admission
  def reconcile(%{server: server} = lease, actual_tokens)
      when is_integer(actual_tokens) and actual_tokens >= 0 do
    GenServer.cast(server, {:reconcile, lease, actual_tokens})
  end

  @doc "Releases a provider lease. Duplicate releases are harmless."
  @spec release(lease :: lease()) :: :ok
  @impl Lemieux.Provider.Admission
  def release(%{server: server} = lease), do: GenServer.cast(server, {:release, lease})

  @doc "Prevents new grants for `key` until `retry_after_ms` elapses."
  @spec penalize(server :: GenServer.server(), key :: key(), retry_after_ms :: non_neg_integer()) ::
          :ok
  @impl Lemieux.Provider.Admission
  def penalize(server, key, retry_after_ms)
      when is_integer(retry_after_ms) and retry_after_ms >= 0 do
    GenServer.cast(server, {:penalize, key, retry_after_ms})
  end

  @doc "Returns bounded live admission state for operations and tests."
  @spec snapshot(server :: GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       max_concurrency: positive!(opts, :max_concurrency, 8),
       token_limit: token_limit(opts),
       interval_ms: positive!(opts, :interval_ms, @default_interval),
       clock: Keyword.get(opts, :clock),
       buckets: %{},
       monitors: %{}
     }}
  end

  @impl GenServer
  def handle_call({:checkout, _key, _root_id, tokens}, _from, %{token_limit: limit} = state)
      when is_integer(limit) and tokens > limit do
    {:reply, {:error, {:request_exceeds_token_limit, limit}}, state}
  end

  def handle_call({:checkout, key, root_id, tokens}, from, state) do
    {bucket, state} = bucket(state, key)

    request = %{
      id: make_ref(),
      from: from,
      owner: elem(from, 0),
      root_id: root_id,
      tokens: tokens
    }

    monitor = Process.monitor(request.owner)
    request = Map.put(request, :monitor, monitor)
    state = put_in(state.monitors[monitor], {:queued, key, request.id})

    cond do
      grantable?(state, bucket, tokens) and queued_count(bucket) == 0 ->
        {bucket, state, lease} = grant(state, bucket, key, request)
        {:reply, {:ok, lease}, put_bucket(state, key, bucket)}

      queued_count(bucket) == 0 ->
        # First in line: nothing queued ahead of it will arm a wake-up.
        bucket = bucket |> enqueue(request) |> then(&wake_for_tokens(state, &1, key, tokens))
        {:noreply, put_bucket(state, key, bucket)}

      true ->
        {:noreply, put_bucket(state, key, enqueue(bucket, request))}
    end
  end

  def handle_call(:snapshot, _from, state) do
    buckets =
      Map.new(state.buckets, fn {key, bucket} ->
        {key,
         %{
           active: map_size(bucket.active),
           queued: queued_count(bucket),
           available_tokens: bucket.available_tokens,
           blocked_until: bucket.blocked_until
         }}
      end)

    {:reply, %{max_concurrency: state.max_concurrency, buckets: buckets}, state}
  end

  @impl GenServer
  def handle_cast({:reconcile, %{id: id, key: key}, actual_tokens}, state) do
    state =
      update_bucket(state, key, fn bucket ->
        update_in(bucket.active[id], fn
          nil -> nil
          lease -> %{lease | actual_tokens: actual_tokens}
        end)
      end)

    {:noreply, state}
  end

  def handle_cast({:release, %{id: id, key: key}}, state) do
    {:noreply, state |> release(key, id) |> dispatch(key)}
  end

  def handle_cast({:penalize, key, retry_after_ms}, state) do
    {bucket, state} = bucket(state, key)
    blocked_until = now(state) + retry_after_ms
    bucket = %{bucket | blocked_until: max(bucket.blocked_until, blocked_until)}
    Clock.send_after(state.clock, self(), {:dispatch, key}, retry_after_ms)
    {:noreply, put_bucket(state, key, bucket)}
  end

  @impl GenServer
  def handle_info({:dispatch, key}, state) do
    {:noreply, state |> update_bucket(key, &woken(state, &1)) |> dispatch(key)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{:active, key, lease_id}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, state |> release(key, lease_id, false) |> dispatch(key)}

      {{:queued, key, request_id}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, state |> remove_queued(key, request_id) |> dispatch(key)}
    end
  end

  defp dispatch(state, key) do
    {bucket, state} = bucket(state, key)
    bucket = refill(state, bucket)
    do_dispatch(state, key, bucket)
  end

  defp do_dispatch(state, key, bucket) do
    case next(bucket) do
      {nil, bucket} ->
        put_bucket(state, key, bucket)

      {request, remaining} ->
        if grantable?(state, bucket, request.tokens) do
          {remaining, state, lease} = grant(state, remaining, key, request)
          GenServer.reply(request.from, {:ok, lease})
          do_dispatch(state, key, remaining)
        else
          bucket = wake_for_tokens(state, put_front(remaining, request), key, request.tokens)
          put_bucket(state, key, bucket)
        end
    end
  end

  defp grant(state, bucket, key, request) do
    lease = %{
      id: make_ref(),
      key: key,
      server: self(),
      owner: request.owner,
      monitor: request.monitor,
      estimated_tokens: request.tokens,
      actual_tokens: nil
    }

    bucket = %{
      bucket
      | active: Map.put(bucket.active, lease.id, lease),
        available_tokens: spend(bucket.available_tokens, request.tokens)
    }

    monitors = Map.put(state.monitors, request.monitor, {:active, key, lease.id})
    {bucket, %{state | monitors: monitors}, Map.take(lease, [:id, :key, :server])}
  end

  defp release(state, key, lease_id, demonitor? \\ true) do
    {bucket, state} = bucket(state, key)

    case Map.pop(bucket.active, lease_id) do
      {nil, _active} ->
        state

      {lease, active} ->
        if demonitor?, do: Process.demonitor(lease.monitor, [:flush])
        monitors = Map.delete(state.monitors, lease.monitor)
        actual = lease.actual_tokens || lease.estimated_tokens

        available =
          reconcile_tokens(bucket.available_tokens, lease.estimated_tokens, actual, state)

        put_bucket(%{state | monitors: monitors}, key, %{
          bucket
          | active: active,
            available_tokens: available
        })
    end
  end

  defp remove_queued(state, key, request_id) do
    update_bucket(state, key, fn bucket ->
      queues =
        Map.new(bucket.queues, fn {root, queue} ->
          kept =
            queue |> :queue.to_list() |> Enum.reject(&(&1.id == request_id)) |> :queue.from_list()

          {root, kept}
        end)

      %{bucket | queues: queues} |> clean_roots()
    end)
  end

  defp bucket(state, key) do
    case Map.fetch(state.buckets, key) do
      {:ok, bucket} ->
        {refill(state, bucket), state}

      :error ->
        bucket = %{
          active: %{},
          queues: %{},
          roots: :queue.new(),
          available_tokens: state.token_limit,
          last_refill: now(state),
          blocked_until: now(state),
          wake_at: nil
        }

        {bucket, put_bucket(state, key, bucket)}
    end
  end

  defp put_bucket(state, key, bucket), do: put_in(state.buckets[key], bucket)

  defp update_bucket(state, key, fun) do
    {bucket, state} = bucket(state, key)
    put_bucket(state, key, fun.(bucket))
  end

  # A request short only of tokens has nothing else coming to wake it. No
  # lease is active to release, no penalty timer is pending, and the bucket
  # refills by arithmetic on its next access rather than by a message — so on
  # a quiet key the request waited until some unrelated checkout or release
  # happened to touch it, which could be never. The bucket arms one timer for
  # the instant enough tokens will have accrued. A request that is waiting on
  # concurrency is woken by the next release, and one waiting on a penalty by
  # the penalty's own timer, so neither arms another.
  defp wake_for_tokens(state, bucket, key, tokens) do
    short_of_tokens? =
      map_size(bucket.active) < state.max_concurrency and now(state) >= bucket.blocked_until and
        not enough_tokens?(bucket.available_tokens, tokens)

    if short_of_tokens?, do: arm_wake(state, bucket, key, tokens), else: bucket
  end

  defp arm_wake(state, bucket, key, tokens) do
    missing = tokens - bucket.available_tokens
    delay = max(ceil(missing * state.interval_ms / state.token_limit), 1)
    wake_at = now(state) + delay

    # One pending wake-up per key is enough: an earlier one re-evaluates the
    # queue when it fires and arms again if the head still has to wait.
    if bucket.wake_at && bucket.wake_at <= wake_at do
      bucket
    else
      Clock.send_after(state.clock, self(), {:dispatch, key}, delay)
      %{bucket | wake_at: wake_at}
    end
  end

  defp woken(state, %{wake_at: wake_at} = bucket) when is_integer(wake_at) do
    if now(state) >= wake_at, do: %{bucket | wake_at: nil}, else: bucket
  end

  defp woken(_state, bucket), do: bucket

  defp grantable?(state, bucket, tokens) do
    map_size(bucket.active) < state.max_concurrency and now(state) >= bucket.blocked_until and
      enough_tokens?(bucket.available_tokens, tokens)
  end

  defp enqueue(bucket, request) do
    new_root? = not Map.has_key?(bucket.queues, request.root_id)
    queue = :queue.in(request, Map.get(bucket.queues, request.root_id, :queue.new()))
    roots = if new_root?, do: :queue.in(request.root_id, bucket.roots), else: bucket.roots
    %{bucket | queues: Map.put(bucket.queues, request.root_id, queue), roots: roots}
  end

  defp put_front(bucket, request) do
    new_root? = not Map.has_key?(bucket.queues, request.root_id)
    queue = :queue.in_r(request, Map.get(bucket.queues, request.root_id, :queue.new()))
    roots = if new_root?, do: :queue.in_r(request.root_id, bucket.roots), else: bucket.roots
    %{bucket | queues: Map.put(bucket.queues, request.root_id, queue), roots: roots}
  end

  defp next(bucket) do
    case :queue.out(bucket.roots) do
      {:empty, _roots} ->
        {nil, bucket}

      {{:value, root}, roots} ->
        queue = Map.fetch!(bucket.queues, root)
        {{:value, request}, queue} = :queue.out(queue)

        if :queue.is_empty(queue) do
          {request, %{bucket | roots: roots, queues: Map.delete(bucket.queues, root)}}
        else
          {request,
           %{bucket | roots: :queue.in(root, roots), queues: Map.put(bucket.queues, root, queue)}}
        end
    end
  end

  defp clean_roots(bucket) do
    queues = Map.reject(bucket.queues, fn {_root, queue} -> :queue.is_empty(queue) end)

    roots =
      bucket.roots
      |> :queue.to_list()
      |> Enum.filter(&Map.has_key?(queues, &1))
      |> :queue.from_list()

    %{bucket | queues: queues, roots: roots}
  end

  defp queued_count(bucket),
    do: Enum.reduce(bucket.queues, 0, fn {_root, queue}, total -> total + :queue.len(queue) end)

  defp refill(%{token_limit: :infinity}, bucket), do: bucket

  defp refill(state, bucket) do
    current = now(state)
    elapsed = max(current - bucket.last_refill, 0)
    restored = state.token_limit * elapsed / state.interval_ms
    available = min(bucket.available_tokens + restored, state.token_limit)
    %{bucket | available_tokens: available, last_refill: current}
  end

  defp enough_tokens?(:infinity, _tokens), do: true
  defp enough_tokens?(available, tokens), do: available >= tokens
  defp spend(:infinity, _tokens), do: :infinity
  defp spend(available, tokens), do: available - tokens

  defp reconcile_tokens(:infinity, _estimated, _actual, _state), do: :infinity

  defp reconcile_tokens(available, estimated, actual, state),
    do: min(available + estimated - actual, state.token_limit)

  defp token_limit(opts) do
    case Keyword.get(opts, :tokens_per_interval, :infinity) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              ":tokens_per_interval must be a positive integer or :infinity, got: #{inspect(value)}"
    end
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp now(state), do: Clock.now_ms(state.clock)
end
