# The panels that take the whole keyboard until they are closed. Guarded as
# `Lemieux.TUI` is: every one of them draws widgets.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Modal do
    @moduledoc """
    Routes keys, pastes and drawing to whichever panel holds the keyboard.

    `Lemieux.TUI`'s `:modal` field names at most one: the pager, reverse
    history search, the repository-trust question or the first-run provider
    picker. Each lives in its own module and answers the same three
    questions — what a key does, what a paste does, what to draw — so adding
    one is a clause here and a module there, not another field and another
    branch through the screen.

    Closing goes through `close/1` whichever panel it is, and that is also
    where the notice box gets its time back (`Lemieux.TUI.Notices.resume/1`):
    the box does not close behind a panel, so a notice said while one was
    open is still read once it is gone.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.FirstRun
    alias Lemieux.TUI.HistorySearch
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Pager
    alias Lemieux.TUI.Trust

    @typep reply :: {:noreply, TUI.t()} | {:stop, TUI.t()}

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: reply()
    def key(event, %TUI{modal: %{kind: kind}} = state), do: module(kind).key(event, state)

    @doc false
    @spec paste(ExRatatui.Event.Paste.t(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(event, %TUI{modal: %{kind: kind}} = state), do: module(kind).paste(event, state)

    @doc false
    @spec render(TUI.t(), map()) :: [{term(), ExRatatui.Layout.Rect.t()}]
    def render(%TUI{modal: %{kind: kind}} = state, panes), do: module(kind).render(state, panes)
    def render(_state, _panes), do: []

    @doc false
    @spec close(TUI.t()) :: TUI.t()
    def close(state), do: Notices.resume(%{state | modal: nil})

    defp module(:pager), do: Pager
    defp module(:history_search), do: HistorySearch
    defp module(:trust), do: Trust
    defp module(:first_run), do: FirstRun
  end
end
