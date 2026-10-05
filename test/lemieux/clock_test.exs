defmodule Lemieux.ClockTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock
  alias Lemieux.Clock.Manual

  # A process that re-arms a periodic timer each time it fires and records the
  # clock reading at every tick — the shape of a progress check, which is what
  # the `:settle` option exists for.
  defmodule Ticker do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def ticks(pid), do: GenServer.call(pid, :ticks)

    @impl GenServer
    def init(opts) do
      clock = Keyword.fetch!(opts, :clock)
      interval = Keyword.fetch!(opts, :interval)
      Clock.send_after(clock, self(), :tick, interval)
      {:ok, %{clock: clock, interval: interval, ticks: []}}
    end

    @impl GenServer
    def handle_call(:ticks, _from, state), do: {:reply, Enum.reverse(state.ticks), state}

    @impl GenServer
    def handle_info(:tick, state) do
      Clock.send_after(state.clock, self(), :tick, state.interval)
      {:noreply, %{state | ticks: [Clock.now_ms(state.clock) | state.ticks]}}
    end
  end

  # A process the delivered message stops, for the settle-after-exit case.
  defmodule Stopper do
    use GenServer

    @impl GenServer
    def init(:ok), do: {:ok, nil}

    @impl GenServer
    def handle_info(:stop, state), do: {:stop, :normal, state}
  end

  describe "the real clock" do
    test "nil and Lemieux.Clock.System read the VM's monotonic time" do
      before = System.monotonic_time(:millisecond)
      read = Clock.now_ms(nil)
      explicit = Clock.now_ms(Lemieux.Clock.System)

      assert read >= before
      assert explicit >= read
    end

    test "a timer delivers its message, and a cancelled one does not" do
      Clock.send_after(nil, self(), :soon, 0)
      assert_receive :soon

      timer = Clock.send_after(Lemieux.Clock.System, self(), :never, 60_000)
      assert Clock.cancel(Lemieux.Clock.System, timer) == :ok
      assert Clock.cancel(nil, timer) == :ok
      refute_received :never
    end
  end

  describe "the manual clock" do
    test "starts where it is told and stands still until advanced" do
      clock = Manual.new(now: 1_000)

      assert Clock.now_ms(clock) == 1_000
      Clock.send_after(clock, self(), :later, 50)
      refute_received :later
      assert Clock.now_ms(clock) == 1_000
    end

    test "advance delivers due timers in due order and returns them" do
      clock = Manual.new()

      Clock.send_after(clock, self(), :third, 300)
      Clock.send_after(clock, self(), :first, 100)
      Clock.send_after(clock, self(), :second, 200)
      Clock.send_after(clock, self(), :not_yet, 301)

      delivered = Manual.advance(clock, 300)

      assert Enum.map(delivered, & &1.message) == [:first, :second, :third]
      assert Clock.now_ms(clock) == 300

      assert_received :first
      assert_received :second
      assert_received :third
      refute_received :not_yet

      assert [%{message: :not_yet, due_in: 1, due_at: 301}] = Manual.pending(clock)
    end

    test "timers due at the same instant fire in the order they were armed" do
      clock = Manual.new()

      for n <- 1..5, do: Clock.send_after(clock, self(), {:n, n}, 10)
      Manual.advance(clock, 10)

      received = for _n <- 1..5, do: assert_received({:n, _})
      assert received == Enum.map(1..5, &{:n, &1})
    end

    test "a cancelled timer never fires, and cancelling twice is fine" do
      clock = Manual.new()
      timer = Clock.send_after(clock, self(), :cancelled, 10)

      assert Clock.cancel(clock, timer) == :ok
      assert Clock.cancel(clock, timer) == :ok
      assert Manual.pending(clock) == []

      assert Manual.advance(clock, 1_000) == []
      refute_received :cancelled
    end

    test "a zero-delay timer is delivered at once, as Process.send_after/3 would" do
      clock = Manual.new()
      Clock.send_after(clock, self(), :immediately, 0)

      assert_received :immediately
      assert Manual.pending(clock) == []
    end

    test "a registered name is resolved when the timer fires, and dropped if nobody holds it" do
      clock = Manual.new()
      name = :"clock_test_#{System.unique_integer([:positive])}"

      Clock.send_after(clock, name, :to_nobody, 10)
      Manual.advance(clock, 10)
      refute_received :to_nobody

      Process.register(self(), name)
      Clock.send_after(clock, name, :to_me, 10)
      Manual.advance(clock, 10)
      assert_received :to_me
    end

    test "with settle, a periodic timer fires at each of its own due instants" do
      clock = Manual.new()
      {:ok, ticker} = Ticker.start_link(clock: clock, interval: 100)

      Manual.advance(clock, 250, settle: ticker)

      assert Ticker.ticks(ticker) == [100, 200]
      assert [%{due_at: 300}] = Manual.pending(clock)
    end

    test "settle tolerates a process that the delivered message stopped" do
      clock = Manual.new()
      {:ok, stopper} = GenServer.start(Stopper, :ok)
      ref = Process.monitor(stopper)

      Clock.send_after(clock, stopper, :stop, 10)
      Clock.send_after(clock, self(), :after_stop, 20)

      delivered = Manual.advance(clock, 20, settle: stopper)

      assert Enum.map(delivered, & &1.message) == [:stop, :after_stop]
      assert_receive {:DOWN, ^ref, :process, ^stopper, :normal}
      assert_received :after_stop
    end

    test "a settle function runs after every delivery" do
      clock = Manual.new()
      test = self()

      Clock.send_after(clock, self(), :one, 10)
      Clock.send_after(clock, self(), :two, 20)

      Manual.advance(clock, 20, settle: fn -> send(test, {:settled, Clock.now_ms(clock)}) end)

      assert_received {:settled, 10}
      assert_received {:settled, 20}
    end

    test "await_timer answers with a timer already pending" do
      clock = Manual.new()
      Clock.send_after(clock, self(), :armed, 30)

      assert %{message: :armed, due_in: 30} = Manual.await_timer(clock)
    end

    test "await_timer waits for another process to arm a matching timer" do
      clock = Manual.new()
      Clock.send_after(clock, self(), :unrelated, 10)

      waiter = Task.async(fn -> Manual.await_timer(clock, &match?({:wanted, _}, &1.message)) end)
      assert Task.yield(waiter, 0) == nil

      Clock.send_after(clock, self(), {:wanted, 1}, 50)
      assert %{message: {:wanted, 1}, due_in: 50} = Task.await(waiter)
    end

    test "works under start_supervised!/1, which answers the pid" do
      clock = start_supervised!({Manual, now: 5})
      assert Clock.now_ms(clock) == 5
    end
  end
end
