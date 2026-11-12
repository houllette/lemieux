defmodule Lemieux.DiagnosticTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport

  alias Lemieux.Diagnostic
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI.Events
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.TranscriptPresentation

  defmodule Broken do
    @behaviour Lemieux.Tool
    def name, do: "broken"
    def description, do: "A programming failure"
    def schema, do: %{"type" => "object", "properties" => %{}}
    def run(_, _), do: raise("private exception with credentials")
  end

  @tag :tmp_dir
  @tag :capture_log
  test "recovered internal faults are durable, counted once, and reset on a new turn", ctx do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    provider =
      Scripted.new([
        [{:tool_call, %{id: "bad", name: "broken", arguments: %{}}}, {:done, :tool_calls}],
        Scripted.complete("Recovered"),
        Scripted.complete("Clean")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(ctx.tmp_dir),
        model: "test:model",
        tools: [Broken],
        subscriber: self()
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "work")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    snapshot = Session.snapshot(session)
    result = Enum.find(snapshot.entries, &(&1.type == :tool_result))
    assert result.payload["diagnostic"]["category"] == "internal"
    assert result.payload["diagnostic"]["original"] =~ "private exception"
    summaries = Enum.filter(snapshot.entries, &(&1.payload["namespace"] == "lemieux.errors"))
    assert [summary] = summaries
    assert summary.payload["value"]["count"] == 1
    :ok = Session.prompt(session, "clean turn")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert Enum.count(
             Session.snapshot(session).entries,
             &(&1.payload["namespace"] == "lemieux.errors")
           ) == 1
  end

  test "only explicitly marked faults count; expected failures and killed tasks are excluded" do
    refute Diagnostic.internal_crash?(:killed)
    refute Diagnostic.internal_crash?({:shutdown, :timeout})

    refute Diagnostic.internal_crash?(
             {RuntimeError.exception("external"), [{External, :run, 1, []}]}
           )

    for payload <- [
          %{"error" => true, "output" => "error"},
          %{"source" => "provider"},
          %{"source" => "harness", "stop_reason" => "budget"}
        ] do
      assert Diagnostic.from_payload(payload) == nil
    end
  end

  @tag :tmp_dir
  test "a child's duplicated fault is counted once, including on cancellation", ctx do
    runtime = Module.concat(__MODULE__, "ChildRuntime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    parent = self()

    provider =
      Scripted.new([
        fn _request ->
          send(parent, :working)

          receive do
            :finish -> Scripted.complete("done")
          end
        end
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(ctx.tmp_dir),
        model: "test:model",
        tools: [],
        subscriber: self()
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "work")
    assert_receive :working
    diagnostic = Diagnostic.new("tool", "Child fault", %{})
    entry = Entry.new(:error, %{"diagnostic" => diagnostic, "reason" => "Child fault"})

    for _ <- 1..2,
        do:
          GenServer.cast(
            session,
            {:publish_subagent_event, {:subagent, [id, "child"], {:entry, entry}}}
          )

    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}

    summaries =
      Enum.filter(
        Session.snapshot(session).entries,
        &(&1.payload["namespace"] == "lemieux.errors")
      )

    assert [summary] = summaries
    assert summary.payload["value"]["count"] == 1
  end

  test "live and restored transcripts show immediate muted italic hints and a red summary" do
    diagnostic = Diagnostic.new("runtime", "Unexpected internal failure", %{})
    error = Entry.new(:error, %{"reason" => diagnostic["message"], "diagnostic" => diagnostic})

    summary =
      Entry.new(:extension_state, %{"namespace" => "lemieux.errors", "value" => %{"count" => 1}})

    state = tui()
    {:noreply, state} = Events.handle(state, {:entry, error})
    {:noreply, state} = Events.handle(state, {:entry, summary})
    assert {:bug_hint, Diagnostic.hint()} in state.lines
    assert {:bug_summary, Diagnostic.summary(1)} in state.lines

    replay =
      TranscriptPresentation.lines([error, summary], %{
        renderers: Renderer.builtin(),
        theme: Theme.default(),
        width: 80
      })

    assert Enum.filter(replay, &(elem(&1, 0) in [:bug_hint, :bug_summary])) ==
             Enum.filter(Enum.reverse(state.lines), &(elem(&1, 0) in [:bug_hint, :bug_summary]))

    for theme <- [Theme.default(), Theme.light(), Theme.mono()] do
      [hint] = RichText.lines([{:bug_hint, "report"}], 80, theme)
      assert hd(hint.spans).style.fg == theme.text.muted
      assert :italic in hd(hint.spans).style.modifiers
      [summary] = RichText.lines([{:bug_summary, "one error"}], 80, theme)
      assert hd(summary.spans).style.fg == theme.text.error
    end
  end
end
