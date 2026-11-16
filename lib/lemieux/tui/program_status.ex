if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.ProgramStatus do
    @moduledoc """
    Reports the screen's authoritative state, outside rendering, through OSC 7501.

    A whole conversation is one root record. Deriving waits from all pending
    approvals and the question prevents one resolved parallel call from claiming
    work resumed while another still needs the user. Completion survives ticks
    until input acknowledges it; retries and queued turns become working again.
    Deduplication is independent of rendering and desktop notification settings.
    Optional title metadata follows the displayed session label. It is a host
    presentation detail: it changes neither session identity nor execution.
    """

    alias Lemieux.TUI
    alias Lemieux.TUI.Screen

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

    defp report(state, status) do
      previous = state.terminal
      title = report_title(state, status)

      if previous.last_program_status == status and previous.last_program_status_title == title do
        state
      else
        emit(previous.program_status, status, title, previous.last_program_status != status)

        put_in(state.terminal, %{
          previous
          | last_program_status: status,
            last_program_status_title: title
        })
      end
    end

    defp report_title(_state, :clear), do: nil

    defp report_title(%{terminal: %{program_status_title?: true}} = state, _status),
      do: Screen.name(state)

    defp report_title(_state, _status), do: nil

    defp emit(callback, status, title, _changed?) when is_function(callback, 2),
      do: callback.(status, if(is_nil(title), do: [], else: [title: title]))

    # Existing host callbacks keep their state-only contract and are not called
    # again for a metadata-only rename they cannot represent.
    defp emit(callback, status, _title, true), do: callback.(status)
    defp emit(_callback, _status, _title, false), do: :ok

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
