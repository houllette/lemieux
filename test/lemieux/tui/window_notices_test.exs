defmodule Lemieux.TUI.WindowNoticesTest do
  @moduledoc """
  What the screen shows about the window a session plans against.

  These notices never reached a screen before: the session said them when it
  started, before the TUI knew which session's events to read. They now
  come with the first request, so how they are drawn matters.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  defp drop_events(id) do
    receive do
      {:lemieux, ^id, _event} -> drop_events(id)
    after
      0 -> :ok
    end
  end

  defp rows(state, pattern) do
    Enum.filter(state.lines, fn
      {_who, text} when is_binary(text) -> text =~ pattern
      _other -> false
    end)
  end

  # The whole path, as the screen meets it. A recorded TUI run showed the
  # session's "planning as if it held 128k tokens" note zero times: it was
  # said while the session started, and the screen learns which session's
  # events are its own only once the start returns, dropping what came
  # before. Dropping them here is that screen.
  @tag :tmp_dir
  test "a real session's unknown window reaches the screen with the first prompt", context do
    runtime = :"lemieux_window_notices_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([[{:text_delta, "ok"}, {:done, :stop}]]),
        store: JSONL.new(context.tmp_dir),
        model: "test:model",
        subscriber: self(),
        tools: [],
        cwd: context.tmp_dir
      )

    id = Session.id(session)
    # A call is answered only after everything the session does as it starts.
    _started = Session.info(session)
    drop_events(id)

    state =
      [session: session, id: id]
      |> tui()
      |> type("hello")
      |> press("enter")
      |> settle()

    assert [{:notice, text}] = rows(state, "context window")
    assert text =~ "planning as if it held 128.0k tokens"
  end

  test "an unknown window is one notice, not a notice and a line saying the same" do
    state = info(tui(), {:context_window_unknown, %{model: "x:y", fallback: 128_000}})

    assert [{:notice, text}] = rows(state, "context window")
    assert text =~ "planning as if it held 128.0k tokens"
    assert text =~ "--context-window N"
  end

  # The flag describes a window to the session and cannot change the one
  # Ollama serves, which is what this screen's own sentence used to advise
  # (`set context_window`); the conversation's names the daemon instead.
  test "an unknown local window points at the daemon, not at a setting that cannot change it" do
    state =
      info(tui(), {:context_window_unknown, %{model: "ollama:gemma4:12b", fallback: 128_000}})

    assert [{:notice, text}] = rows(state, "Ollama has not said yet")
    assert text =~ "ollama ps"
    refute text =~ "context_window"
    refute text =~ "--context-window"
  end

  # A host may turn the fallback off, and this clause used to format the
  # missing number and crash the screen at the first prompt.
  test "an unknown window with no fallback says nothing compacts, and draws" do
    state = info(tui(), {:context_window_unknown, %{model: "local:thing", fallback: nil}})

    assert [{:notice, text}] = rows(state, "local:thing")
    assert text =~ "will not compact on its own"
    assert screen(state) =~ "nothing publishes local:thing's context window"
  end

  test "a window too small to work in is a notice that says what to change" do
    event =
      {:context_window_small,
       %{model: "ollama:gemma4:12b", window: 4_096, overhead: 3_490, source: :served}}

    state = info(tui(), event)

    assert [{:notice, text}] = rows(state, "4,096-token context window")
    assert text =~ "OLLAMA_CONTEXT_LENGTH=65536"
    assert screen(state) =~ "OLLAMA_CONTEXT_LENGTH"

    # Once per sitting, as the session sends it once per model and window.
    assert [_once] = state |> info(event) |> rows("4,096-token context window")
  end

  test "a summary that made no room is said" do
    event =
      {:compaction_ineffective,
       %{input_tokens: 9_750, threshold: 8_000, window: 10_000, retry_in: 32}}

    assert [_said] = rows(info(tui(), event), "summarising made no room")
  end
end
