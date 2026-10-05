defmodule Lemieux.Clock.Manual do
  @moduledoc """
  A clock that only moves when a test says so.

  Start one, hand its pid to the process under test as its `:clock` option,
  and move time with `advance/3`:

      {:ok, clock} = Lemieux.Clock.Manual.start_link()
      {:ok, limiter} = Lemieux.ProviderLimiter.start_link(clock: clock, ...)

      Lemieux.Clock.Manual.advance(clock, 60_000, settle: limiter)

  Nothing fires on its own: a timer armed for 50 ms stays pending until the
  test advances past it, however long the machine takes to get there. That is
  the point — see `Lemieux.Clock` for the failures real-time waits caused.

  ## Delivery order and `:settle`

  `advance/3` steps through the pending timers in due order, setting the time
  to each timer's due instant before delivering it, and ends at the target
  time. Delivery is a `send/2` from the *calling* process, not from the
  clock's own process. Erlang orders messages between one pair of processes,
  so a `GenServer.call/2` the test makes after `advance/3` returns is queued
  behind every timer message it delivered — asserting on the process's state
  straight after is safe.

  A process that reacts to a timer by arming the next one (a periodic check)
  arms it relative to the time it reads when it handles the message. For that
  reading to be the timer's own due instant rather than the end of the
  advance, the test waits for the process between deliveries: `settle:`
  takes a pid or registered name (or a list of them) to synchronise with
  through `:sys.get_state/1`, or a zero-arity function to call. With a settle, advancing by 250 ms over a
  100 ms periodic check delivers exactly two checks, at 100 and 200.

  A timer armed with zero delay is delivered at once, as
  `Process.send_after/3` would.

  Ships in `lib`, beside `Lemieux.Testing`, so hosts can drive lemieux's
  deadlines from their own tests.
  """

  use GenServer

  @typedoc "A manual clock is its process."
  @type t :: pid()

  @typedoc "A pending timer, as `pending/1` reports it."
  @type timer :: %{
          ref: reference(),
          due_at: integer(),
          due_in: non_neg_integer(),
          destination: Lemieux.Clock.destination(),
          message: term()
        }

  @typedoc "What `advance/3` waits for between deliveries."
  @type settle :: nil | GenServer.server() | [GenServer.server()] | (-> term())

  @doc """
  Starts a manual clock linked to the caller.

  Options:

    * `:now` — the starting time in milliseconds (default `0`).

  Returns `{:ok, clock}`; the pid is the clock term every
  `Lemieux.Clock` function takes. Works with `start_supervised!/1` too, which
  returns the pid directly.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Starts a manual clock linked to the caller and returns it."
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    {:ok, clock} = start_link(opts)
    clock
  end

  @doc "The clock's current time in milliseconds."
  @spec now_ms(clock :: t()) :: integer()
  def now_ms(clock) when is_pid(clock), do: GenServer.call(clock, :now)

  @doc """
  Arms a timer that `advance/3` delivers once the clock reaches it.

  A zero-delay timer is delivered immediately.
  """
  @spec send_after(
          clock :: t(),
          destination :: Lemieux.Clock.destination(),
          message :: term(),
          ms :: non_neg_integer()
        ) :: reference()
  def send_after(clock, destination, message, ms)
      when is_pid(clock) and (is_pid(destination) or is_atom(destination)) and is_integer(ms) and
             ms >= 0 do
    case GenServer.call(clock, {:send_after, destination, message, ms}) do
      {:now, ref} ->
        deliver(destination, message)
        ref

      {:later, ref} ->
        ref
    end
  end

  @doc "Cancels a pending timer. `:ok` whether or not it was still pending."
  @spec cancel(clock :: t(), timer :: reference()) :: :ok
  def cancel(clock, timer) when is_pid(clock) and is_reference(timer),
    do: GenServer.call(clock, {:cancel, timer})

  @doc "The pending timers, soonest first."
  @spec pending(clock :: t()) :: [timer()]
  def pending(clock) when is_pid(clock), do: GenServer.call(clock, :pending)

  @doc """
  Waits until a pending timer satisfies `match` and returns it.

  For a test that must know the process under test has armed its timer
  before it moves time — otherwise the advance can land before the timer
  exists, and nothing fires. It answers at once when such a timer is already
  pending, and otherwise as soon as one is armed; the alternative is polling
  `pending/1` in a loop, which is a sleep by another name. `match` is a
  one-argument predicate over the timer (any timer by default), run in the
  clock's process. Gives up after `timeout` real milliseconds with an exit,
  as `GenServer.call/3` does.
  """
  @spec await_timer(
          clock :: t(),
          match :: (timer() -> as_boolean(term())),
          timeout :: timeout()
        ) :: timer()
  def await_timer(clock, match \\ fn _timer -> true end, timeout \\ 5_000)
      when is_pid(clock) and is_function(match, 1),
      do: GenServer.call(clock, {:await_timer, match}, timeout)

  @doc """
  Moves the clock forward by `ms`, delivering every timer that falls due on the
  way, in due order, and returns the timers it delivered.

  Timers armed during the advance (by a process reacting to an earlier
  delivery) are delivered too if they fall due before the target. See the
  moduledoc for `:settle`, which makes that exact.
  """
  @spec advance(clock :: t(), ms :: non_neg_integer(), opts :: [settle: settle()]) :: [timer()]
  def advance(clock, ms, opts \\ []) when is_pid(clock) and is_integer(ms) and ms >= 0 do
    settle = Keyword.get(opts, :settle)
    target = GenServer.call(clock, {:target, ms})
    deliver_until(clock, target, settle, [])
  end

  defp deliver_until(clock, target, settle, delivered) do
    case GenServer.call(clock, {:next_due, target}) do
      {:ok, timer} ->
        deliver(timer.destination, timer.message)
        wait_for(settle)
        deliver_until(clock, target, settle, [timer | delivered])

      :none ->
        Enum.reverse(delivered)
    end
  end

  # A registered name is resolved when the timer fires, and a name nobody
  # holds drops the message — `Process.send_after/3`'s own behaviour, which
  # code under test may rely on after a process restarts.
  defp deliver(destination, message) when is_pid(destination), do: send(destination, message)

  defp deliver(destination, message) when is_atom(destination) do
    case Process.whereis(destination) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp wait_for(nil), do: :ok
  defp wait_for(fun) when is_function(fun, 0), do: fun.()
  defp wait_for(servers) when is_list(servers), do: Enum.each(servers, &sync/1)
  defp wait_for(server), do: sync(server)

  # The delivered message may be what stops the process — a deadline that
  # ends a group, say. A process that is gone has nothing left to settle, so
  # its exit is the answer rather than a failure of the advance.
  defp sync(server) do
    :sys.get_state(server)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts),
    do: {:ok, %{now: Keyword.get(opts, :now, 0), timers: [], seq: 0, waiters: []}}

  @impl GenServer
  def handle_call(:now, _from, state), do: {:reply, state.now, state}

  def handle_call({:send_after, _destination, _message, 0}, _from, state),
    do: {:reply, {:now, make_ref()}, state}

  def handle_call({:send_after, destination, message, ms}, _from, state) do
    ref = make_ref()

    timer = %{
      ref: ref,
      due_at: state.now + ms,
      seq: state.seq,
      destination: destination,
      message: message
    }

    state = %{state | timers: [timer | state.timers], seq: state.seq + 1}
    {:reply, {:later, ref}, answer_waiters(state, public(timer, state.now))}
  end

  def handle_call({:cancel, ref}, _from, state),
    do: {:reply, :ok, %{state | timers: Enum.reject(state.timers, &(&1.ref == ref))}}

  def handle_call(:pending, _from, state),
    do: {:reply, state.timers |> sorted() |> Enum.map(&public(&1, state.now)), state}

  def handle_call({:target, ms}, _from, state), do: {:reply, state.now + ms, state}

  def handle_call({:await_timer, match}, from, state) do
    case state.timers |> sorted() |> Enum.map(&public(&1, state.now)) |> Enum.find(match) do
      nil -> {:noreply, %{state | waiters: [{from, match} | state.waiters]}}
      timer -> {:reply, timer, state}
    end
  end

  def handle_call({:next_due, target}, _from, state) do
    case sorted(state.timers) do
      [%{due_at: due_at} = timer | _rest] when due_at <= target ->
        now = max(state.now, due_at)
        timers = Enum.reject(state.timers, &(&1.ref == timer.ref))
        {:reply, {:ok, public(timer, now)}, %{state | now: now, timers: timers}}

      _none_due ->
        {:reply, :none, %{state | now: max(state.now, target)}}
    end
  end

  defp sorted(timers), do: Enum.sort_by(timers, &{&1.due_at, &1.seq})

  defp answer_waiters(state, timer) do
    {matched, waiting} = Enum.split_with(state.waiters, fn {_from, match} -> match.(timer) end)
    Enum.each(matched, fn {from, _match} -> GenServer.reply(from, timer) end)
    %{state | waiters: waiting}
  end

  defp public(timer, now) do
    %{
      ref: timer.ref,
      due_at: timer.due_at,
      due_in: max(timer.due_at - now, 0),
      destination: timer.destination,
      message: timer.message
    }
  end
end
