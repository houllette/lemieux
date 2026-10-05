defmodule Lemieux.Session.Window do
  @moduledoc false

  # The window a session plans compaction against, and what it tells the
  # person about it.
  #
  # Three things can say how big a model's window is, trusted in a known
  # order. A host's `:context_window` is an instruction. A provider's catalog,
  # or a refusal that states the window, is knowledge about the model. What
  # the serving endpoint reports giving the model (`{:context_window, tokens}`
  # after an answer — a local Ollama daemon, today) is knowledge about this
  # server, and the only one of the three a local model has: such a server
  # sizes the window when it loads the model and drops what does not fit
  # instead of refusing it. So a served window replaces anything discovered
  # and bounds even a configured one. Planning against 32,768 tokens while
  # the server keeps 4,096 is how a session loses the task it was given with
  # nobody saying so: measured, the person's request and the file the model
  # had just read were gone from the third request, and the run ended with an
  # empty answer and exit 0.
  #
  # The notices are said when a request is about to be planned rather than
  # when the session starts. Said at start they reached nobody: the TUI
  # starts its session before it knows the session's id and drops what
  # arrives before then, and `lmx run` subscribes when it sends the prompt.
  # A recorded TUI run showed the accurate "planning as if it held 128k
  # tokens" note zero times. Before the first request every host that will
  # ever listen is listening, and the request is what the notice is about.

  alias Lemieux.Context.Forecast
  alias Lemieux.Request
  alias Lemieux.Session.Core
  alias Lemieux.Session.Setup

  # What a session needs beyond its own instructions and tools to do any
  # work: the prompt, a file or two and the answers. lmx's instructions and
  # nine tools come to about 3,500 tokens, so Ollama's smallest default
  # window (4,096) leaves under 600 for all of that.
  @working_room 8_192

  # Before a request is planned: the unknown-window note once per model, and
  # whether the known window leaves room to work, once per model and window.
  def notice(state), do: state |> Setup.notice_unknown_window() |> notice_small()

  # The provider said what window the server gave the model. Unchanged news is
  # no news; a new window is a new chance for compaction, so a backoff earned
  # against the old one is forgotten, as it is when the model changes.
  def learn_served(%{served_window: window} = state, window), do: state

  def learn_served(state, window) do
    state
    |> served(window)
    |> Core.forget_compaction_failures()
    |> notice_small()
  end

  defp served(%{context_window_source: :configured} = state, window),
    do: %{state | served_window: window}

  defp served(state, window),
    do: %{state | served_window: window, context_window: window, context_window_source: :served}

  # The model's real window as far as anything has said: the smaller of what
  # the session was told and what the server reported serving, or nil.
  def known(%{context_window: nil, served_window: served}), do: served
  def known(%{context_window: window, served_window: nil}), do: window
  def known(%{context_window: window, served_window: served}), do: min(window, served)

  # The window the trigger and the retained tail are sized against: the known
  # one, or the fallback when nothing is known, and never more than the cap.
  def planning(state) do
    case known(state) || state.context_window_fallback do
      nil -> nil
      window -> capped(window, state.compaction.window_cap)
    end
  end

  defp capped(window, cap) when is_integer(cap), do: min(window, cap)
  defp capped(window, _uncapped), do: window

  # What every request of this session costs before any conversation: its
  # own instructions and its tools, the part no compaction can cut, at the
  # estimate the threshold forecasts with. Not a prepared request's: a
  # `prepare_next_turn` hook may add to the system prompt in proportion to
  # the conversation, and a summary that cut the conversation also cuts that.
  def overhead(state) do
    %Request{model: state.model, system: state.system, tools: state.tools}
    |> Forecast.input([], counter: state.compaction.input_token_counter)
    |> Map.fetch!(:input_tokens)
  end

  defp notice_small(state) do
    case known(state) do
      nil -> state
      window -> weigh(state, window)
    end
  end

  defp weigh(%{window_checked: {model, window}, model: model} = state, window), do: state

  defp weigh(state, window) do
    state = %{state | window_checked: {state.model, window}}
    overhead = overhead(state)

    if window < overhead + @working_room do
      Core.emit(
        state,
        {:context_window_small,
         %{model: state.model, window: window, overhead: overhead, source: source(state, window)}}
      )
    else
      state
    end
  end

  defp source(%{served_window: window}, window), do: :served
  defp source(state, _window), do: state.context_window_source
end
