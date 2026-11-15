if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Chrome do
    @moduledoc """
    The screen's overflow clock, independent of cursor blinking and agent work.

    Terminal text moves in whole cells. One column every 250 ms gives a regular
    four-column-per-second ticker without pretending extra redraws can produce
    sub-cell motion. Only visible overflow requests a timer. Deadlines follow
    the screen's monotonic epoch, so transcript traffic cannot restart them or
    accumulate one timer per update; late callbacks coalesce into one frame.

    The shipped status line instead rotates whole groups every five seconds.
    Its anchor is a stat's identity rather than a page number, keeping that
    stat visible when changed values or a resize repack the groups. A delayed
    callback advances once and gives the next page a full reading interval.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Status

    @step_ms 250
    @page_ms 5_000

    @doc false
    @spec frame(state :: TUI.t()) :: non_neg_integer()
    def frame(state), do: div(max(state.clock.() - state.terminal.chrome_since, 0), @step_ms)

    @doc false
    @spec transition(reply :: tuple()) :: tuple()
    def transition({kind, state}), do: {kind, reconcile(kind, state)}
    def transition({kind, state, opts}), do: {kind, reconcile(kind, state), opts}

    defp reconcile(:stop, state), do: cancel(state)

    defp reconcile(_kind, state) do
      now = state.clock.()
      state = rotate_status(state, Screen.status_pages(state), now)

      deadlines =
        [header_deadline(state, now), state.terminal.status_rotation.next_at]
        |> Enum.reject(&is_nil/1)

      if deadlines == [], do: cancel(state), else: schedule(state, Enum.min(deadlines), now)
    end

    defp header_deadline(state, now) do
      if interval = Screen.chrome_interval(state),
        do: now + interval - rem(max(now - state.terminal.chrome_since, 0), interval)
    end

    defp rotate_status(state, pages, _now) when length(pages) <= 1,
      do: put_in(state.terminal.status_rotation, %{anchor: nil, next_at: nil})

    defp rotate_status(state, pages, now) do
      rotation = state.terminal.status_rotation
      index = Status.page_index(pages, rotation.anchor)

      # Keep the current stat anchored when values or page packing change.
      # A late callback advances once and gives the next group its full
      # reading interval instead of racing through missed pages.
      due? = not is_nil(rotation.next_at) and now >= rotation.next_at
      index = if due?, do: rem(index + 1, length(pages)), else: index
      {keys, _text} = Enum.at(pages, index)
      anchor = if not due? and rotation.anchor in keys, do: rotation.anchor, else: hd(keys)
      next_at = if due?, do: now + @page_ms, else: rotation.next_at || now + @page_ms
      put_in(state.terminal.status_rotation, %{anchor: anchor, next_at: next_at})
    end

    defp schedule(%{terminal: %{chrome_timer: %{deadline: deadline}}} = state, deadline, _now),
      do: state

    defp schedule(state, deadline, now) do
      state = cancel(state)
      token = make_ref()
      timer = Process.send_after(self(), {:chrome_tick, token}, max(deadline - now, 1))
      put_in(state.terminal.chrome_timer, %{timer: timer, token: token, deadline: deadline})
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
