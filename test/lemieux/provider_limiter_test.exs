defmodule Lemieux.ProviderLimiterTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock
  alias Lemieux.Clock.Manual
  alias Lemieux.ProviderLimiter
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  test "bounds concurrency without blocking the caller's session process" do
    limiter = start_supervised!({ProviderLimiter, max_concurrency: 1})
    {:ok, first} = ProviderLimiter.checkout(limiter, :provider, "root-1", 10)
    parent = self()

    task =
      Task.async(fn ->
        result = ProviderLimiter.checkout(limiter, :provider, "root-2", 10)
        send(parent, {:granted, result})
      end)

    refute_receive {:granted, _result}

    assert %{active: 1, queued: 1, available_tokens: :infinity} =
             ProviderLimiter.snapshot(limiter).buckets.provider

    :ok = ProviderLimiter.release(first)
    assert_receive {:granted, {:ok, second}}
    :ok = ProviderLimiter.release(second)
    Task.await(task)
  end

  test "round-robins queued roots within one rate domain" do
    limiter = start_supervised!({ProviderLimiter, max_concurrency: 1})
    {:ok, first} = ProviderLimiter.checkout(limiter, :provider, "root-a", 1)
    parent = self()

    a = checkout_async(parent, limiter, "root-a", :a)
    b = checkout_async(parent, limiter, "root-b", :b)
    a2 = checkout_async(parent, limiter, "root-a", :a2)

    ProviderLimiter.release(first)
    assert_receive {:granted, :a, lease_a}
    ProviderLimiter.release(lease_a)
    assert_receive {:granted, :b, lease_b}
    ProviderLimiter.release(lease_b)
    assert_receive {:granted, :a2, lease_a2}
    ProviderLimiter.release(lease_a2)

    Enum.each([a, b, a2], &Task.await/1)
  end

  test "reconciles pessimistic token reservations with actual usage" do
    # On a manual clock no refill happens between the calls, so the balance
    # is exactly what reconciliation leaves: 100 - 80 reserved + 60 returned.
    clock = Manual.new()

    limiter =
      start_supervised!(
        {ProviderLimiter, max_concurrency: 1, tokens_per_interval: 100, clock: clock}
      )

    {:ok, lease} = ProviderLimiter.checkout(limiter, :provider, "root", 80)
    ProviderLimiter.reconcile(lease, 20)
    ProviderLimiter.release(lease)

    assert ProviderLimiter.snapshot(limiter).buckets.provider.available_tokens == 80

    assert {:ok, second} = ProviderLimiter.checkout(limiter, :provider, "root", 80)
    ProviderLimiter.release(second)
  end

  test "a dead owner releases its monitored lease" do
    limiter = start_supervised!({ProviderLimiter, max_concurrency: 1})
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, _lease} = ProviderLimiter.checkout(limiter, :provider, "root", 1)
        send(parent, :checked_out)
      end)

    assert_receive :checked_out
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    assert {:ok, lease} = ProviderLimiter.checkout(limiter, :provider, "other", 1)
    ProviderLimiter.release(lease)
  end

  test "rejects an estimate larger than a finite bucket instead of queueing forever" do
    limiter = start_supervised!({ProviderLimiter, tokens_per_interval: 100})

    assert {:error, {:request_exceeds_token_limit, 100}} =
             ProviderLimiter.checkout(limiter, :provider, "root", 101)

    refute Map.has_key?(ProviderLimiter.snapshot(limiter).buckets, :provider)
  end

  @tag :tmp_dir
  test "session provider tasks wait at the limiter and cancellation removes queued work",
       context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime, provider_limiter: [max_concurrency: 1]})
    limiter = Lemieux.Supervisor.provider_limiter(runtime)
    {:ok, held} = ProviderLimiter.checkout(limiter, :shared_credential, "holder", 1)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([[{:text_delta, "late"}, {:done, :stop}]]),
        provider_limit_key: :shared_credential,
        store: JSONL.new(context.tmp_dir),
        model: "test:model",
        tools: []
      )

    assert :ok = Session.prompt(session, "wait")
    LemieuxTest.Sync.state(limiter, fn state -> queued(state) == 1 end)
    assert Session.snapshot(session).status == :busy

    assert :ok = Session.cancel(session)
    LemieuxTest.Sync.state(limiter, fn state -> queued(state) == 0 end)
    ProviderLimiter.release(held)
  end

  @tag :tmp_dir
  test "a typed retry-after failure delays later requests in the same rate domain", context do
    clock = Manual.new()
    runtime = Module.concat(__MODULE__, "PenaltyRuntime#{System.unique_integer([:positive])}")

    start_supervised!(
      {Lemieux.Supervisor, name: runtime, provider_limiter: [max_concurrency: 1, clock: clock]}
    )

    limiter = Lemieux.Supervisor.provider_limiter(runtime)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([Scripted.http_error(429, headers: %{"retry-after" => "1"})]),
        provider_limit_key: :shared_credential,
        store: JSONL.new(context.tmp_dir),
        model: "test:model",
        tools: [],
        subscriber: self(),
        # The penalty is the subject, not the retry: with retries on, the
        # session would honour the same header itself and send the request
        # again, which is a different test.
        provider_retry: false
      )

    assert :ok = Session.prompt(session, "rate limit me")
    assert_receive {:lemieux, _, {:finished, :error}}

    # The clock stands still, so the one-second penalty is in force for as
    # long as the assertions need — no window to outrun under load.
    LemieuxTest.Sync.state(limiter, fn state ->
      state.buckets.shared_credential.blocked_until == Clock.now_ms(clock) + 1_000
    end)

    parent = self()

    waiter =
      Task.async(fn ->
        {:ok, lease} = ProviderLimiter.checkout(limiter, :shared_credential, "other", 1)
        send(parent, {:penalty_released, lease})
      end)

    LemieuxTest.Sync.state(limiter, fn state -> queued(state) == 1 end)

    Manual.advance(clock, 999, settle: limiter)
    refute_received {:penalty_released, _lease}
    assert queued(:sys.get_state(limiter)) == 1

    Manual.advance(clock, 1, settle: limiter)
    assert_receive {:penalty_released, lease}
    ProviderLimiter.release(lease)
    Task.await(waiter)
  end

  test "a penalty lifts on the real clock too" do
    # The one real-time check of the cooldown timer: a short penalty, and a
    # generous wait for the grant it releases. Only the eventual grant is
    # asserted, never how soon, so a slow machine cannot fail it.
    limiter = start_supervised!({ProviderLimiter, max_concurrency: 1})
    ProviderLimiter.penalize(limiter, :provider, 20)
    parent = self()

    waiter =
      Task.async(fn ->
        {:ok, lease} = ProviderLimiter.checkout(limiter, :provider, "root", 1)
        send(parent, {:granted, lease})
      end)

    assert_receive {:granted, lease}, 5_000
    ProviderLimiter.release(lease)
    Task.await(waiter)
  end

  test "a request short only of tokens is woken when the bucket has refilled" do
    # 100 tokens a second. The first request reserves and spends 80, so a
    # second asking for 50 waits for 30 more tokens: 300 ms. No lease is
    # active and no penalty is pending, so nothing but the refill itself can
    # wake it.
    clock = Manual.new()

    limiter =
      start_supervised!(
        {ProviderLimiter,
         max_concurrency: 1, tokens_per_interval: 100, interval_ms: 1_000, clock: clock}
      )

    {:ok, first} = ProviderLimiter.checkout(limiter, :provider, "root", 80)
    ProviderLimiter.release(first)
    parent = self()

    waiter =
      Task.async(fn ->
        {:ok, lease} = ProviderLimiter.checkout(limiter, :provider, "root", 50)
        send(parent, {:granted, lease})
      end)

    LemieuxTest.Sync.state(limiter, fn state ->
      match?(%{queued: 1}, snapshot_bucket(state, :provider))
    end)

    Manual.advance(clock, 299, settle: limiter)
    refute_received {:granted, _lease}

    Manual.advance(clock, 1, settle: limiter)
    assert_receive {:granted, lease}
    ProviderLimiter.release(lease)
    Task.await(waiter)
  end

  defp checkout_async(parent, limiter, root, label) do
    Task.async(fn ->
      {:ok, lease} = ProviderLimiter.checkout(limiter, :provider, root, 1)
      send(parent, {:granted, label, lease})
    end)
  end

  defp queued(state) do
    state.buckets.shared_credential.queues
    |> Map.values()
    |> Enum.map(&:queue.len/1)
    |> Enum.sum()
  end

  defp snapshot_bucket(state, key) do
    bucket = Map.fetch!(state.buckets, key)

    %{
      active: map_size(bucket.active),
      queued: bucket.queues |> Map.values() |> Enum.map(&:queue.len/1) |> Enum.sum()
    }
  end
end
