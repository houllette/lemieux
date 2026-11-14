defmodule Lemieux.TUI.ContextReportingTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias Lemieux.Conversation
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI

  @moduletag :tmp_dir

  test "an omitted provider input counter stays unknown through the session and UI", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new([Scripted.complete("done", usage: %{output_tokens: 5})])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(dir),
        model: "test:model",
        context_window: 200_000,
        subscriber: self()
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "inspect")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    refute Session.snapshot(session).context.measured?
    assert Session.snapshot(session).context.fraction == nil
    {:ok, state} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert status_row(state) =~ "context ?/200.0k"
    refute status_row(state) =~ "(0%)"
  end

  test "cached main usage reaches streaming, completed and resumed UI with its planning cap", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(dir)

    provider =
      Scripted.new([
        Scripted.complete("done",
          usage: %{
            input_tokens: 100_000,
            output_tokens: 1_000,
            cache_read_tokens: 90_000,
            input_includes_cached: true
          }
        )
      ])

    opts = [
      supervisor: runtime,
      provider: provider,
      store: store,
      model: "test:model",
      context_window: 1_000_000,
      compaction_window_cap: 200_000,
      subscriber: self()
    ]

    {:ok, session} = Lemieux.start_session(opts)
    id = Session.id(session)
    :ok = Session.prompt(session, "inspect")
    live = follow(tui(session: session, id: id), id)
    assert live.conversation.context.tokens == 101_000
    assert status_row(live) =~ "101.0k/1.0m tokens (10%)"
    assert Conversation.context_report(live.conversation) =~ "160.0k input tokens"

    assert Session.snapshot(session).context.tokens == 101_000
    :ok = GenServer.stop(session)
    {:ok, resumed} = Lemieux.resume_session(Keyword.put(opts, :resume, id))
    {:ok, restored} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, resumed} end)
    assert restored.conversation.context.tokens == 101_000
    assert Conversation.context_report(restored.conversation) =~ "200.0k planning window"
    assert status_row(restored) =~ "101.0k/1.0m tokens (10%)"
  end

  defp follow(state, id) do
    assert_receive {:lemieux, ^id, event}
    state = info(state, event)

    case event do
      {:usage, _usage} ->
        assert state.conversation.context.tokens == 101_000
        follow(state, id)

      {:finished, :stop} ->
        state

      _other ->
        follow(state, id)
    end
  end
end
