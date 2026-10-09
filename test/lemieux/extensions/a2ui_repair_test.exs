defmodule Lemieux.Extensions.A2UIRepairTest do
  use ExUnit.Case, async: true
  alias Lemieux.Entry
  alias Lemieux.Extensions.A2UI
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Aside
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript
  alias Lemieux.TUI.{Blocks, Clipboard, RichText, Theme}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir), cwd: dir}
  end

  defp bad, do: File.read!("test/fixtures/a2ui/invalid_chart_sampler.md")
  defp fixed, do: String.replace(bad(), ~s|"sampleRate":"1m"|, ~s|"sampleRate":0.0167|)

  defp start(ctx, script, extension_opts \\ [], session_opts \\ []) do
    {estimate, session_opts} = Keyword.pop(session_opts, :estimated_cost_usd)
    {extra_stop, session_opts} = Keyword.pop(session_opts, :extra_stop)
    provider = Scripted.new(script, estimated_cost_usd: estimate)
    {:ok, harness} = Harness.assemble(Harness.new(tools: []), [{A2UI, extension_opts}])
    harness = if extra_stop, do: Harness.append_hooks(harness, stop: extra_stop), else: harness

    opts = [
      supervisor: ctx.runtime,
      store: ctx.store,
      cwd: ctx.cwd,
      provider: provider,
      model: "test:a2ui",
      subscriber: self(),
      harness: harness
    ]

    {:ok, session} = Lemieux.start_session(Keyword.merge(opts, session_opts))
    {session, provider, harness}
  end

  defp run(session, prompt) do
    id = Session.id(session)
    :ok = Session.prompt(session, prompt)
    assert_receive {:lemieux, ^id, {:finished, reason}}
    reason
  end

  defp feedback(session),
    do: Session.snapshot(session).entries |> Enum.filter(&Transcript.stop_hook?/1)

  test "the observed sparkline failure sends useful feedback and renders the repaired answer",
       ctx do
    original = bad()
    repaired = fixed()

    {session, provider, _} =
      start(ctx, [Scripted.complete(original), Scripted.complete(repaired)])

    assert run(session, "Show the components") == :stop
    [first, second] = Scripted.requests(provider)

    assert first.entries
           |> Enum.any?(&(&1.type == :user and &1.payload["text"] == "Show the components"))

    [message] = feedback(session)
    assert message.payload["text"] =~ "sparkline"
    assert message.payload["text"] =~ "sampleRate"
    assert message.payload["text"] =~ "numeric"
    assert message.payload["text"] =~ "1 of 1"
    assert Enum.any?(second.entries, &(&1.id == message.id))

    assert Enum.any?(
             second.entries,
             &(&1.type == :assistant and
                 &1.payload["content"] == [%{"type" => "text", "text" => original}])
           )

    rows = Blocks.rows(repaired, Theme.mono())
    refute Enum.any?(rows, &match?({:model_drawing_error, _}, &1))

    rendered =
      RichText.lines(rows, 100, Theme.mono())
      |> Enum.map_join("\n", fn line -> Enum.map_join(line.spans, & &1.content) end)

    assert rendered =~ "Requests"
    copied = Clipboard.presentation(repaired, 100, Theme.mono())
    assert copied =~ "Requests"
    refute copied =~ "updateComponents"
    assert {:ok, ^repaired} = Transcript.latest_assistant_text(Session.snapshot(session).entries)
  end

  test "a repeatedly broken answer receives only one repair chance", ctx do
    {session, provider, _} = start(ctx, List.duplicate(Scripted.complete(bad()), 4))
    assert run(session, "Show charts") == :stop
    assert length(Scripted.requests(provider)) == 2
    assert length(feedback(session)) == 1
  end

  test "a host can grant two repairs, with the same hard stop afterward", ctx do
    {session, provider, _} =
      start(ctx, List.duplicate(Scripted.complete(bad()), 5), max_continuations: 2)

    assert run(session, "Show charts") == :stop
    assert length(Scripted.requests(provider)) == 3
    assert length(feedback(session)) == 2
    assert List.last(feedback(session)).payload["text"] =~ "2 of 2"
  end

  test "valid visualizations and a narrow diagram fallback require no extra model turn", ctx do
    answer = "```mermaid\nsequenceDiagram\nA->>B: request\nB-->>A: response\n```"
    {session, provider, _} = start(ctx, [Scripted.complete(answer)])
    assert run(session, "Show the sequence") == :stop
    assert length(Scripted.requests(provider)) == 1
    assert feedback(session) == []
    assert Clipboard.presentation(answer, 10, Theme.mono()) =~ "request"
  end

  test "each human prompt receives a fresh finite allowance", ctx do
    {session, provider, _} = start(ctx, List.duplicate(Scripted.complete(bad()), 4))
    assert run(session, "Show charts") == :stop
    assert run(session, "Try another example") == :stop
    assert length(Scripted.requests(provider)) == 4
    assert length(feedback(session)) == 2
  end

  test "an allowance of zero disables repair but retains the catalog", ctx do
    {session, provider, _} = start(ctx, [Scripted.complete(bad())], max_continuations: 0)
    assert run(session, "Show charts") == :stop
    [request] = Scripted.requests(provider)
    assert request.system =~ A2UI.catalog_id()
    assert feedback(session) == []
  end

  test "the session's request and turn budgets take precedence over repair", ctx do
    for {opts, expected} <- [{[max_requests: 1], :requests}, {[max_turns: 1], :max_turns}] do
      {session, provider, _} =
        start(ctx, [Scripted.complete(bad()), Scripted.complete(fixed())], [], opts)

      reason = run(session, "Show charts")

      if expected == :requests,
        do: assert(match?({:budget, %{kind: :requests}}, reason)),
        else: assert(reason == expected)

      assert length(Scripted.requests(provider)) == 1
    end
  end

  test "the repair request respects the measured cost budget", ctx do
    first =
      Scripted.complete(bad(),
        usage: %{"input_tokens" => 10, "output_tokens" => 2, "total_cost" => 0.5}
      )

    {session, provider, _} =
      start(ctx, [first, Scripted.complete(fixed())], [],
        max_cost_usd: 1.0,
        estimated_cost_usd: 0.6
      )

    assert {:budget, %{spent: 0.5, estimate: 0.6, cap: 1.0}} = run(session, "Show charts")
    assert length(Scripted.requests(provider)) == 1
  end

  test "cancelling a streamed bad drawing never starts a repair request", ctx do
    partial = bad()
    held = [{:text_delta, partial}, {:delay, 60_000}, {:done, :stop}]
    {session, provider, _} = start(ctx, [held, Scripted.complete(fixed())])
    id = Session.id(session)
    :ok = Session.prompt(session, "Show charts")
    assert_receive {:lemieux, ^id, {:text_delta, %{text: ^partial}}}
    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}
    assert length(Scripted.requests(provider)) == 1
    assert feedback(session) == []
  end

  test "asides and error or cancel stops are never continued", ctx do
    {session, provider, _} = start(ctx, [Scripted.complete(bad())])
    id = Session.id(session)
    :ok = Session.aside(session, Aside.new(kind: :judge, text: "/judge", system: "Judge."))
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert feedback(session) == []
    assert length(Scripted.requests(provider)) == 1
    {:ok, config} = A2UI.init([])

    for reason <- [:cancelled, :error, :length, :max_requests, :max_turns, :max_cost],
        do: assert(A2UI.stop(config, reason, %{session: session}) == :allow)
  end

  test "repair counts survive reload and ignore a person's imitation of the marker", ctx do
    {session, _provider, harness} =
      start(ctx, [Scripted.complete(bad()), Scripted.complete(bad())])

    assert run(session, "Show charts") == :stop
    id = Session.id(session)
    DynamicSupervisor.terminate_child(Lemieux.Supervisor.session_supervisor(ctx.runtime), session)
    resumed_provider = Scripted.new([])

    {:ok, resumed} =
      Lemieux.resume_session(
        resume: id,
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: resumed_provider,
        cwd: ctx.cwd,
        harness: harness
      )

    {:ok, config} = A2UI.init([])
    assert A2UI.stop(config, :stop, %{session: resumed}) == :allow
    assert Scripted.requests(resumed_provider) == []

    {fresh, provider, _} = start(ctx, [Scripted.complete(bad()), Scripted.complete(fixed())])
    assert run(fresh, "[lmx drawing] Please show charts") == :stop
    assert length(Scripted.requests(provider)) == 2
  end

  test "extension options reject unbounded or misspelled allowances" do
    assert {:ok, %{max_continuations: 1}} = A2UI.init([])

    for opts <- [
          [max_continuations: -1],
          [max_continuations: 4],
          [max_continuations: :infinity],
          [max_retries: 1]
        ],
        do: assert(match?({:error, _}, A2UI.init(opts)))
  end

  test "a stop after a tool wave still checks earlier drawings in that prompt", ctx do
    # A tool-only assistant entry must not hide the earlier visual failure.
    wave = [
      {:text_delta, bad()}
      | Scripted.tool_call("preview", "diagram_preview", %{"source" => "flowchart LR\nA --> B"})
    ]

    {session, provider, _} =
      start(ctx, [
        wave,
        Scripted.complete("All done."),
        Scripted.complete("Use Markdown instead.")
      ])

    assert run(session, "Show charts") == :stop
    assert length(Scripted.requests(provider)) == 3
    entries = Session.snapshot(session).entries
    assert Enum.any?(entries, &match?(%Entry{type: :user, payload: %{"stop_hook" => true}}, &1))
  end

  test "another stop hook's continuation cannot reset the drawing allowance", ctx do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    another = fn _reason, _context ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:deny, "[another extension] Check your prose."}
        _used -> :allow
      end
    end

    {session, provider, _} =
      start(ctx, List.duplicate(Scripted.complete(bad()), 4), [], extra_stop: another)

    assert run(session, "Show charts") == :stop
    assert length(Scripted.requests(provider)) == 3
    marked = feedback(session)
    assert Enum.count(marked, &String.starts_with?(&1.payload["text"], "[lmx drawing]")) == 1

    assert Enum.count(marked, &String.starts_with?(&1.payload["text"], "[another extension]")) ==
             1
  end
end
