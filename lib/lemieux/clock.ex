defmodule Lemieux.Clock do
  @moduledoc """
  Where a long-lived process reads the time and arms its timers.

  A clock is a value passed in, not a module a process calls by name:
  `nil` (or `Lemieux.Clock.System`) is the real one, and a
  `Lemieux.Clock.Manual` pid is one a test moves by hand. Every process that
  enforces a deadline, a cooldown or a periodic check takes one through a
  `:clock` option and reads the time, arms timers and cancels them only through
  this module.

      deadline = Lemieux.Clock.now_ms(clock) + budget_ms
      timer = Lemieux.Clock.send_after(clock, self(), :deadline, budget_ms)
      Lemieux.Clock.cancel(clock, timer)

  ## Why a clock value rather than sleeps

  The tests this replaces gave a subagent a 50 ms progress interval, or an
  agent a 10 ms deadline, and then waited in real time for the process to
  notice. Under a busy CI runner the process under test is descheduled for
  longer than the whole budget, the assertion times out, and the fix was
  another "robust under CI load" commit that widened the window — five of
  them in six weeks, two more while this module was being written. Widening
  a window makes a test slower and moves the race; it doesn't remove it.
  With a manual clock nothing happens until the test says time has passed,
  so a deadline test asserts the same thing on an idle laptop and a
  saturated runner, and runs in microseconds.

  ## Why not Mox, or a global switch

  A timer is a message the VM delivers later. A mocked `send_after` still has
  to deliver it, so every test would reimplement a small timer wheel; this
  module is that wheel, written once and tested once. A process-global switch
  (an application environment key, `:meck`) would make every async test in
  the suite share one notion of time. A value threaded through options is
  local to the process that received it, costs production one function-head
  match, and keeps `async: true` honest.

  ## What it does not cover

  Time spent by operating-system processes (a `bash` command's timeout, an
  ExCmd teardown) is measured by the OS, not by this clock, and stays real.
  Wall-clock timestamps written into transcripts (`DateTime.utc_now/0`) are a
  different question from monotonic deadlines and are not routed here.
  """

  alias Lemieux.Clock.Manual

  @typedoc """
  The real clock (`nil` or `Lemieux.Clock.System`) or a `Lemieux.Clock.Manual`
  pid.
  """
  @type t :: nil | Lemieux.Clock.System | pid()

  @typedoc "Where a timer's message goes: a pid, or a locally registered name."
  @type destination :: pid() | atom()

  @doc """
  The current monotonic time in milliseconds.

  Only differences between two readings of the same clock mean anything; the
  value itself is not wall-clock time and may be negative.
  """
  @spec now_ms(clock :: t()) :: integer()
  def now_ms(nil), do: System.monotonic_time(:millisecond)
  def now_ms(Lemieux.Clock.System), do: System.monotonic_time(:millisecond)
  def now_ms(clock) when is_pid(clock), do: Manual.now_ms(clock)

  @doc """
  Sends `message` to `destination` after `ms` milliseconds of this clock's time.

  Returns a reference for `cancel/2`. As with `Process.send_after/3`, a
  registered name is resolved when the timer fires, and a message to a name
  nobody holds is dropped.
  """
  @spec send_after(
          clock :: t(),
          destination :: destination(),
          message :: term(),
          ms :: non_neg_integer()
        ) :: reference()
  def send_after(nil, destination, message, ms),
    do: Process.send_after(destination, message, ms)

  def send_after(Lemieux.Clock.System, destination, message, ms),
    do: Process.send_after(destination, message, ms)

  def send_after(clock, destination, message, ms) when is_pid(clock),
    do: Manual.send_after(clock, destination, message, ms)

  @doc """
  Cancels a timer armed by `send_after/4` on the same clock.

  Always `:ok`: cancelling a timer that already fired, or was already
  cancelled, is not an error. As with `Process.cancel_timer/1`, a message that
  was delivered before the cancel stays in the mailbox, so a process that can
  receive a stale timer message matches it against the reference it keeps.
  """
  @spec cancel(clock :: t(), timer :: reference()) :: :ok
  def cancel(nil, timer) when is_reference(timer), do: real_cancel(timer)
  def cancel(Lemieux.Clock.System, timer) when is_reference(timer), do: real_cancel(timer)

  def cancel(clock, timer) when is_pid(clock) and is_reference(timer),
    do: Manual.cancel(clock, timer)

  defp real_cancel(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
