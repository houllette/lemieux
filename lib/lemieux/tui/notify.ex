if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Notify do
    @moduledoc """
    Telling a person who looked away that the screen wants them.

    Two moments earn it: a turn that ran long enough for somebody to switch
    windows has finished, and a turn is waiting on them — an approval or a
    question. `Lemieux.Terminal.notify/2` does the telling (OSC 9 and the
    bell); this decides when, so a quick answer does not buzz the desktop
    and a notification never fires for a turn somebody watched finish.

    On by default; the host's `:notifications` turns it off for good, and
    `alt-n` for the sitting.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Flash

    # Long enough that the person has plausibly gone somewhere else.
    @finished_after_seconds 15

    @doc false
    @spec toggle(TUI.t()) :: TUI.t()
    def toggle(state) do
      enabled? = not state.terminal.notifications?
      state = put_in(state.terminal.notifications?, enabled?)

      Flash.show(
        state,
        if(enabled?, do: "notifications on", else: "notifications off for this sitting")
      )
    end

    @doc "A turn ended after `seconds`; worth a notification only if it was a long one."
    @spec finished(TUI.t(), non_neg_integer()) :: TUI.t()
    def finished(state, seconds) when seconds >= @finished_after_seconds,
      do: send_notification(state, "lmx: finished (#{seconds}s)")

    def finished(state, _seconds), do: state

    @doc "The turn is waiting on the person — an approval or a question."
    @spec waiting(TUI.t(), String.t()) :: TUI.t()
    def waiting(state, what), do: send_notification(state, "lmx: waiting for #{what}")

    defp send_notification(%TUI{terminal: %{notifications?: false}} = state, _text), do: state

    defp send_notification(state, text) do
      _ignored = state.terminal.notify.(text)
      state
    end
  end
end
