# One sentence in the status row that clears itself: a copy receipt, a refused
# command, a hint about the queue. Not a transcript row, because it is about
# the keys just pressed rather than about the conversation.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Flash do
    @moduledoc "Shows transient feedback in a `Lemieux.TUI` status row and expires it."

    alias Lemieux.TUI

    @feedback_ms 2_000

    @doc false
    @spec show(TUI.t(), String.t()) :: TUI.t()
    def show(state, text) do
      token = make_ref()
      Process.send_after(self(), {:feedback_expired, token}, @feedback_ms)
      put_in(state.terminal.feedback, %{text: text, token: token})
    end

    # Only the newest feedback's timer clears it; an older one expiring must
    # not take down the sentence that replaced it.
    @doc false
    @spec expire(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def expire(%TUI{terminal: %{feedback: %{token: token}}} = state, token),
      do: {:noreply, put_in(state.terminal.feedback, nil)}

    def expire(state, _token), do: {:noreply, state}
  end
end
