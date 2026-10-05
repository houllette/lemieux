defmodule Lemieux.ReflectionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Reflection
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp entry(type, payload, seq) do
    Entry.new(type, payload, seq: seq)
  end

  test "gathers failures, human interruption, compaction and command exits without treating cancellation as failure" do
    entries = [
      entry(:user, %{"text" => "Implement an Elixir feature"}, 0),
      entry(
        :tool_result,
        %{"name" => "ask_user", "error" => true, "output" => "invalid options"},
        1
      ),
      entry(
        :tool_result,
        %{
          "name" => "bash",
          "error" => false,
          "structured_content" => %{"status" => "exited", "exit_status" => 1}
        },
        2
      ),
      entry(:cancelled, %{"reason" => "cancelled"}, 3),
      entry(:compaction, %{"summary" => "Earlier context", "entry_ids" => []}, 4),
      entry(
        :assistant,
        %{
          "content" => [
            %{"type" => "thinking", "text" => "private reasoning"},
            %{"type" => "text", "text" => "public answer"}
          ]
        },
        5
      )
    ]

    report = Reflection.gather(entries)
    assert report["entry_count"] == 6
    assert report["event_counts"]["cancelled"] == 1
    assert report["event_counts"]["compaction"] == 1

    assert report["tool_usage"]["bash"] == %{
             "calls" => 1,
             "invocation_errors" => 0,
             "unsuccessful_outcomes" => 1
           }

    assert Enum.find(report["events"], &(&1["seq"] == 1))["failure"]
    refute Enum.find(report["events"], &(&1["seq"] == 3))["failure"]
    refute JSON.encode!(report) =~ "private reasoning"
    assert JSON.encode!(report) =~ "public answer"
    assert report["scope"]["kind"] == "base"
  end

  test "bounded projection admits missing evidence and still counts every event" do
    entries = for seq <- 0..39, do: entry(:user, %{"text" => String.duplicate("x", 5000)}, seq)
    report = Reflection.gather(entries, max_evidence_bytes: 6000)
    assert report["event_counts"]["user"] == 40
    assert report["coverage"]["omitted_events"] > 0
    assert report["coverage"]["clipped_events"] > 0
    assert report["coverage"]["included_events"] + report["coverage"]["omitted_events"] == 40
  end

  test "restores extension designation from snapshots and keeps host evidence separate" do
    entries = [
      entry(
        :harness_snapshot,
        %{"extensions" => %{"session_profile" => %{"kind" => "builder"}}},
        0
      )
    ]

    report =
      Reflection.gather(entries,
        host_evidence: %{
          "source" => "test gateway",
          "scope" => %{"api_key" => "secret-value"}
        }
      )

    assert report["scope"]["kind"] == "extension"
    assert report["scope"]["identity"] =~ "builder"
    assert report["host_evidence"]["availability"] == "supplied"
    assert report["host_evidence"]["provenance"]["source"] == "test gateway"
    assert report["host_evidence"]["reconciliation"]["local"]["requests"] == 0
    refute JSON.encode!(report["host_evidence"]) =~ "secret-value"
    assert report["resources"]["requests"] == 0
  end

  test "a session with no gateway says so rather than leaving an empty section" do
    report = Reflection.gather([entry(:user, %{"text" => "hi"}, 0)])

    assert report["host_evidence"]["availability"] == "not supplied"
    assert report["host_evidence"]["note"] =~ "complete on its own terms"
  end

  test "legacy builder identity is an explicit inference and strings redact common credentials" do
    entries = [
      entry(:session, %{"system" => "You are Lemieux's extension builder. Help the user."}, 0),
      entry(:user, %{"text" => "api_key=private-value Bearer private-token"}, 1)
    ]

    report = Reflection.gather(entries)
    assert report["scope"]["kind"] == "extension"
    assert report["scope"]["designation"] =~ "inferred"
    refute JSON.encode!(report) =~ "private-value"
    refute JSON.encode!(report) =~ "private-token"
  end

  test "unanswered requests retain unknown usage rather than manufacturing zeros" do
    entries = [entry(:request, %{"id" => "unanswered", "kind" => "turn"}, 0)]
    report = Reflection.gather(entries)
    assert report["resources"]["requests"] == 1
    refute report["resources"]["usage_complete"]
    assert report["resources"]["output_tokens"] == nil
    assert report["resources"]["cost_usd"] == nil
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"reflection_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp session(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          system: "Original task instructions",
          tools: [Lemieux.Tools.Write],
          subscriber: self(),
          cwd: context.tmp_dir
        ] ++ opts
      )

    {session, provider, Session.id(session)}
  end

  test "reflection is a budgeted read-only request and the next task retains its original configuration",
       context do
    {session, provider, id} =
      session(context, [
        Scripted.complete("Initial answer"),
        Scripted.complete("Improve the scaffold diagnostic"),
        Scripted.complete("Continued")
      ])

    :ok = Session.prompt(session, "Build an extension")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Reflection.reflect(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Session.prompt(session, "Continue building")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [initial, reflection, continued] = Scripted.requests(provider)
    assert reflection.tools == []
    assert reflection.output_schema == nil
    assert reflection.system =~ "Build an extension"
    assert reflection.system =~ "NOT proof the agent"
    assert Enum.map(reflection.entries, & &1.payload["text"]) == ["/reflect"]
    assert continued.system == initial.system
    assert continued.tools == initial.tools
    refute continued.system =~ "Evidence (bounded"
    entries = Session.snapshot(session).entries
    assert Enum.any?(entries, &(&1.type == :request and &1.payload["kind"] == "reflection"))
    assert Session.snapshot(session).status == :idle
  end

  test "even a provider emitting an unoffered write cannot mutate files during reflection",
       context do
    {session, _provider, id} =
      session(context, [
        Scripted.tool_call("write", "write", %{"path" => "unwanted.txt", "content" => "oops"})
      ])

    assert :ok = Reflection.reflect(session)
    assert_receive {:lemieux, ^id, {:finished, :error}}
    refute File.exists?(Path.join(context.tmp_dir, "unwanted.txt"))

    assert Enum.any?(
             Session.snapshot(session).entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )
  end

  test "reflection refuses busy work and cancellation restores ordinary requests", context do
    parent = self()

    {session, provider, id} =
      session(context, [
        fn _request ->
          send(parent, :reflection_started)
          Scripted.delayed(10_000, Scripted.complete("late"))
        end,
        Scripted.complete("normal")
      ])

    assert :ok = Reflection.reflect(session)
    assert_receive :reflection_started
    assert {:error, :busy} = Reflection.reflect(session)
    assert :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}
    assert :ok = Session.prompt(session, "continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert List.last(Scripted.requests(provider)).system == "Original task instructions"
    assert List.last(Scripted.requests(provider)).tools == [Lemieux.Tools.Write]
  end

  test "the opportunities mode asks for records under the same request kind", context do
    {session, provider, id} = session(context, [Scripted.complete("[]")])

    assert :ok = Reflection.reflect(session, mode: :opportunities)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [request] = Scripted.requests(provider)
    assert request.tools == []
    assert request.system =~ "OUTPUT CONTRACT"
    assert request.system =~ ~s("mode":"opportunities")
    assert Enum.map(request.entries, & &1.payload["text"]) == ["/reflect"]

    entries = Session.snapshot(session).entries
    assert Enum.any?(entries, &(&1.type == :request and &1.payload["kind"] == "reflection"))
  end

  # The designation reaches the evidence from the host's harness context, not
  # from a snapshot entry: before the first turn there is no such entry yet.
  test "a reflection before any turn still names the host's extension", context do
    {session, provider, id} =
      session(context, [Scripted.complete("scoped")],
        harness_context: %{"extensions" => %{"agent" => %{"name" => "Scout"}}}
      )

    assert :ok = Reflection.reflect(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [request] = Scripted.requests(provider)
    assert request.system =~ ~s("kind":"extension")
    assert request.system =~ "Scout"
  end

  test "reflection cannot bypass a spent request allowance", context do
    {session, provider, id} = session(context, [Scripted.complete("done")], max_requests: 1)
    :ok = Session.prompt(session, "task")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Reflection.reflect(session)
    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests}}}}
    assert length(Scripted.requests(provider)) == 1
  end
end
