if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Chrome do
    @moduledoc """
    The screen's overflow clock, independent of cursor blinking and agent work.

    Terminal text moves in whole cells. One column every 250 ms gives a regular
    four-column-per-second ticker without pretending extra redraws can produce
    sub-cell motion. Only visible overflow requests a timer. Deadlines follow
    the screen's monotonic epoch, so transcript traffic cannot restart them or
    accumulate one timer per update; late callbacks coalesce into one frame.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Screen

    @step_ms 250

    @doc false
    @spec frame(state :: TUI.t()) :: non_neg_integer()
    def frame(state), do: div(max(state.clock.() - state.terminal.chrome_since, 0), @step_ms)

    @doc false
    @spec transition(reply :: tuple()) :: tuple()
    def transition({kind, state}), do: {kind, reconcile(kind, state)}
    def transition({kind, state, opts}), do: {kind, reconcile(kind, state), opts}

    defp reconcile(:stop, state), do: cancel(state)

    defp reconcile(_kind, state) do
      case Screen.chrome_interval(state) do
        nil -> cancel(state)
        interval -> schedule(state, interval)
      end
    end

    defp schedule(%{terminal: %{chrome_timer: %{interval: interval}}} = state, interval),
      do: state

    defp schedule(state, interval) do
      state = cancel(state)
      token = make_ref()
      elapsed = max(state.clock.() - state.terminal.chrome_since, 0)
      timer = Process.send_after(self(), {:chrome_tick, token}, interval - rem(elapsed, interval))
      put_in(state.terminal.chrome_timer, %{timer: timer, token: token, interval: interval})
    end

    defp cancel(%{terminal: %{chrome_timer: nil}} = state), do: state

    defp cancel(state) do
      Process.cancel_timer(state.terminal.chrome_timer.timer)
      put_in(state.terminal.chrome_timer, nil)
    end

    @doc false
    @spec tick(state :: TUI.t(), token :: reference()) :: tuple()
    def tick(%{terminal: %{chrome_timer: %{token: token}}} = state, token),
      do: {:noreply, put_in(state.terminal.chrome_timer, nil)}

    def tick(state, _token), do: {:noreply, state, render?: false}
  end
end
