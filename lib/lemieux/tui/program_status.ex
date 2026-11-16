if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.ProgramStatus do
    @moduledoc """
    Reports the screen's authoritative state, outside rendering, through OSC 7501.

    A whole conversation is one root record. Deriving waits from all pending
    approvals and the question prevents one resolved parallel call from claiming
    work resumed while another still needs the user. Completion survives ticks
    until input acknowledges it; retries and queued turns become working again.
    Deduplication is independent of rendering and desktop notification settings.
    """

    alias Lemieux.TUI

    @doc false
    @spec mounted(result :: {:ok, TUI.t()} | term()) :: term()
    def mounted({:ok, state}), do: {:ok, report(state, current(state, :idle))}
    def mounted(other), do: other

    @doc false
    @spec transition(reply :: tuple(), previous :: TUI.t(), event :: term()) :: tuple()
    def transition({kind, state}, previous, event),
      do: {kind, reconcile(kind, state, previous, event)}

    def transition({kind, state, opts}, previous, event),
      do: {kind, reconcile(kind, state, previous, event), opts}

    defp reconcile(:stop, state, _previous, _event), do: report(state, :clear)

    defp reconcile(_kind, state, previous, event) do
      fallback = settled(state, previous, event)
      report(state, current(state, fallback))
    end

    defp current(%{modal: %{kind: :first_run}}, _fallback), do: {:blocked, :auth}
    defp current(%{resume: %{startup_status: :failed}}, _fallback), do: :error
    defp current(%{resume: %{down: reason}}, _fallback) when not is_nil(reason), do: :error

    defp current(%{conversation: %{approvals: [_ | _]}}, _fallback),
      do: {:blocked, :permission}

    defp current(%{conversation: %{question: question}}, _fallback) when not is_nil(question),
      do: {:blocked, :question}

    defp current(%{conversation: %{busy?: true}}, _fallback), do: :working
    defp current(%{resume: %{startup_status: :loading}}, _fallback), do: :working
    defp current(_state, fallback), do: fallback

    defp settled(%{id: id}, _previous, {:lemieux, id, {:finished, :cancelled}}), do: :idle

    defp settled(%{id: id}, _previous, {:lemieux, id, {:finished, reason}})
         when reason in [:stop, :ok, :end_turn], do: :done

    defp settled(%{id: id}, _previous, {:lemieux, id, {:finished, _reason}}), do: :error

    defp settled(state, previous, event) do
      last = state.terminal.last_program_status

      cond do
        state.id != previous.id -> :idle
        acknowledged?(event) -> :idle
        last in [:done, :error] -> last
        true -> if is_nil(last), do: nil, else: :idle
      end
    end

    defp acknowledged?(%ExRatatui.Event.Key{kind: kind}) when kind in ["press", "repeat"],
      do: true

    defp acknowledged?(%ExRatatui.Event.Paste{}), do: true
    defp acknowledged?(%ExRatatui.Event.Mouse{kind: "down"}), do: true
    defp acknowledged?(_event), do: false

    defp report(state, nil), do: state
    defp report(%{terminal: %{last_program_status: status}} = state, status), do: state

    defp report(state, status) do
      _ignored = state.terminal.program_status.(status)
      put_in(state.terminal.last_program_status, status)
    end

    @doc false
    @spec terminate(reason :: term(), state :: TUI.t()) :: :ok
    def terminate(reason, state) do
      status =
        if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
          do: :clear,
          else: :error

      report(state, status)
      :ok
    end
  end
end
