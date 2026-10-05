defmodule Lemieux.Clock.System do
  @moduledoc """
  The real clock: the VM's monotonic time and its timers.

  This is what a `:clock` option means when it is omitted or `nil`; passing
  the module name says the same thing explicitly. It exists as a module so
  that a host can write `clock: Lemieux.Clock.System` in configuration and
  have it read as a choice rather than an absence. See `Lemieux.Clock`.
  """

  @doc "The VM's monotonic time in milliseconds."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  @doc "`Process.send_after/3`."
  @spec send_after(
          destination :: Lemieux.Clock.destination(),
          message :: term(),
          ms :: non_neg_integer()
        ) :: reference()
  def send_after(destination, message, ms), do: Process.send_after(destination, message, ms)

  @doc "`Process.cancel_timer/1`, answering `:ok` whatever the timer's state."
  @spec cancel(timer :: reference()) :: :ok
  def cancel(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end
end
