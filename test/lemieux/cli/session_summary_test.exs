defmodule Lemieux.CLI.SessionSummaryTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.SessionIndex
  alias Lemieux.CLI.SessionSummary
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir
  @usage %{"input_tokens" => 20, "output_tokens" => 5, "cost_usd" => 0.001}

  defp start(dir, script, opts \\ []) do
    runtime = :"summary_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new(script, estimated_cost_usd: 0.001)
    {:ok, harness} = Harness.assemble(Harness.new(), [SessionSummary])

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: runtime,
            provider: provider,
            store: JSONL.new(dir),
            model: "test:model",
            tools: [],
            subscriber: self(),
            hooks: harness.hooks
          ],
          opts
        )
      )

    {session, provider, runtime}
  end

  defp prompt(session, text) do
    id = Session.id(session)
    assert :ok = Session.prompt(session, text)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
  end

  test "one bounded request after two exchanges persists the gist without altering conversation",
       %{tmp_dir: dir} do
    {session, provider, runtime} =
      start(dir, [
        Scripted.complete("Which UI?", usage: @usage),
        Scripted.complete("I will polish the picker.", usage: @usage),
        Scripted.complete("Improve completion colors and session summaries", usage: @usage),
        Scripted.complete("Done.", usage: @usage)
      ])

    prompt(session, "Help me with the UI")
    assert length(Scripted.requests(provider)) == 1
    assert {:ok, [%{preview: "Help me with the UI"}]} = SessionIndex.recent(JSONL.new(dir))
    prompt(session, "Focus on completion menus")
    assert [_, _, summary] = Scripted.requests(provider)
    assert summary.model == "test:model"
    assert summary.tools == []
    assert summary.params[:max_tokens] == 1024
    assert summary.system =~ "untrusted historical conversation"
    assert summary.entries |> hd() |> Map.fetch!(:payload) |> Map.fetch!("text") =~ "Which UI?"
    snapshot = Session.snapshot(session)
    assert Enum.count(snapshot.entries, &(&1.type == :user)) == 2
    assert Enum.count(snapshot.entries, &(&1.type == :assistant)) == 2
    assert Session.budget(session).requests == 3

    for entry <- snapshot.entries, entry.type == :request do
      assert :ok = Lemieux.RequestSnapshot.verify(entry.payload)
    end

    label_request =
      Enum.find(snapshot.entries, &(&1.type == :request and &1.payload["auxiliary"] == true))

    assert hd(label_request.payload["auxiliary_entries"])["payload"]["text"] ==
             hd(summary.entries).payload["text"]

    assert snapshot.run_evidence.usage["state"] == "complete"
    assert_in_delta Session.budget(session).spent_usd, 0.003, 0.000001

    assert {:ok, [%{preview: "Improve completion colors and session summaries"}]} =
             SessionIndex.recent(JSONL.new(dir))

    prompt(session, "Finish")
    assert length(Scripted.requests(provider)) == 4

    assert List.last(Scripted.requests(provider)).entries
           |> Enum.filter(&(&1.type in [:user, :assistant]))
           |> length() == 5

    id = Session.id(session)
    GenServer.stop(session)

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(dir),
        resume: id
      )

    assert {:ok, %{value: %{"status" => "ready"}}} =
             Session.document(resumed, "lmx.session_summary")

    assert_in_delta Session.budget(resumed).spent_usd, 0.004, 0.000001
  end

  test "offline failure keeps the first prompt and does not retry", %{tmp_dir: dir} do
    {session, provider, _runtime} =
      start(dir, [
        Scripted.complete("First", usage: @usage),
        Scripted.complete("Second", usage: @usage),
        [{:error, :offline}],
        Scripted.complete("Third", usage: @usage)
      ])

    prompt(session, "Original task")
    prompt(session, "Clarification")

    assert {:ok, %{value: %{"status" => "failed"}}} =
             Session.document(session, "lmx.session_summary")

    assert Session.snapshot(session).run_evidence.usage["state"] == "partial"

    assert {:ok, [%{preview: "Original task"}]} = SessionIndex.recent(JSONL.new(dir))
    prompt(session, "Continue")
    assert length(Scripted.requests(provider)) == 4
    assert Session.budget(session).spent_usd == nil
  end

  test "the extra request respects the parent request ceiling", %{tmp_dir: dir} do
    {session, provider, _runtime} =
      start(
        dir,
        [Scripted.complete("First", usage: @usage), Scripted.complete("Second", usage: @usage)],
        max_requests: 2
      )

    prompt(session, "Original")
    prompt(session, "Followup")
    assert length(Scripted.requests(provider)) == 2

    assert {:ok, %{value: %{"status" => "attempted"}}} =
             Session.document(session, "lmx.session_summary")

    assert {:ok, [%{preview: "Original"}]} = SessionIndex.recent(JSONL.new(dir))
  end
end
