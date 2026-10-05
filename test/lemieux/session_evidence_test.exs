defmodule Lemieux.SessionEvidenceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_session_evidence_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  test "every successful accepted prompt persists and emits exactly one reconstructable manifest",
       context do
    {session, _provider} = start_session(context, [[{:text_delta, "done"}, {:done, :stop}]])
    id = Session.id(session)

    assert :ok = Session.prompt(session, "secret prompt")
    assert_receive {:lemieux, ^id, {:harness_snapshot, %Snapshot{} = snapshot}}
    assert_receive {:lemieux, ^id, {:run_evidence, %Run{} = evidence}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert evidence.outcome == "succeeded"
    assert evidence.harness_snapshot["id"] == snapshot.id
    refute Run.encode!(evidence) =~ "secret prompt"

    assert {:ok, entries} = Store.read(context.store, id)
    assert [harness] = Enum.filter(entries, &(&1.type == :harness_snapshot))
    assert [request] = Enum.filter(entries, &(&1.type == :request))
    assert [terminal] = Enum.filter(entries, &(&1.type == :run_evidence))
    assert request.payload["harness_snapshot_id"] == harness.payload["id"]
    assert request.payload["harness_snapshot_sha256"] == harness.payload["semantic_sha256"]
    assert {:ok, reconstructed} = Run.new(terminal.payload)
    assert reconstructed.sha256 == evidence.sha256
  end

  # The default is the local machine, and the snapshot says so rather than
  # leaving an audit to infer it from an empty map; a host's own description
  # of its sandbox goes over the module name, not instead of it.
  test "the snapshot names the environment in force, under the host's own context", context do
    {session, _provider} =
      start_session(context, [[{:text_delta, "done"}, {:done, :stop}]],
        harness_context: %{"environment_context" => %{"id" => "sandbox-7"}}
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "where am I?")
    assert_receive {:lemieux, ^id, {:harness_snapshot, %Snapshot{} = snapshot}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert snapshot.environment_context == %{
             "module" => "Lemieux.Environment.Local",
             "id" => "sandbox-7"
           }
  end

  test "provider failure and cancellation remain terminal observations", context do
    # A dropped connection is retried by default; this is about the record of
    # the failure that ends a turn, so retries are off.
    {failed, _provider} = start_session(context, [[{:error, :closed}]], provider_retry: false)
    assert :ok = Session.prompt(failed, "fail")
    assert_receive {:lemieux, _, {:run_evidence, %Run{outcome: "failed"}}}
    assert_receive {:lemieux, _, {:finished, :error}}

    parent = self()

    {canceled, _provider} =
      start_session(context, [
        fn _request ->
          send(parent, :provider_started)
          receive do: (:stop -> :ok)
        end
      ])

    assert :ok = Session.prompt(canceled, "cancel")
    assert_receive :provider_started
    assert :ok = Session.cancel(canceled)
    assert_receive {:lemieux, _, {:run_evidence, %Run{outcome: "canceled"} = evidence}}
    assert_receive {:lemieux, _, {:finished, :cancelled}}
    assert evidence.usage["state"] == "unknown"
    assert evidence.cost["usd"] == nil

    canceled_entries = Session.snapshot(canceled).entries
    assert Enum.count(canceled_entries, &(&1.type == :run_evidence)) == 1
  end

  test "a pre-request budget stop still records its harness and unknown evidence", context do
    {session, _provider} = start_session(context, [], max_cost_usd: 0.0)

    assert :ok = Session.prompt(session, "cannot start")
    assert_receive {:lemieux, _, {:run_evidence, %Run{} = evidence}}
    assert_receive {:lemieux, _, {:finished, {:budget, _payload}}}

    assert evidence.outcome == "budget_stopped"
    assert evidence.requests == []
    assert evidence.usage["state"] == "unknown"
    assert evidence.harness_snapshot["semantic_sha256"]
  end

  test "a request-hook denial still gets a fresh reconstructable harness and run", context do
    hook = fn _request, _context -> {:deny, "policy"} end
    {session, _provider} = start_session(context, [], hooks: [prepare_next_turn: hook])
    id = Session.id(session)

    assert :ok = Session.prompt(session, "denied")
    assert_receive {:lemieux, ^id, {:harness_snapshot, %Snapshot{} = snapshot}}
    assert_receive {:lemieux, ^id, {:run_evidence, %Run{} = evidence}}
    assert_receive {:lemieux, ^id, {:finished, :hook_failed}}

    assert evidence.outcome == "failed"
    assert evidence.requests == []
    assert evidence.harness_snapshot["id"] == snapshot.id

    assert evidence.observations["hook_outcomes"] == [
             %{
               "stage" => "prepare_next_turn",
               "request_ordinal" => 1,
               "outcome" => "denied",
               "changed_fields" => []
             }
           ]

    assert evidence.transcript["entry_count"] == 3
    assert evidence.transcript["first_seq"] == 1
    assert evidence.transcript["last_seq"] == 3
  end

  test "invalid host artifact evidence is rejected before a session starts", context do
    assert {:error, {:invalid_evidence_artifact, :missing_schema_version}} =
             Lemieux.start_session(
               supervisor: context.runtime,
               provider: Scripted.new([]),
               store: context.store,
               model: "test:model",
               evidence_artifacts: [%{"id" => "not-versioned"}]
             )
  end

  test "request hooks and resume record the effective current harness instead of a stale parent",
       context do
    hook = fn request, _hook_context ->
      {:ok, %{request | system: request.system <> "\nhost-v1"}}
    end

    {session, _provider} =
      start_session(context, [[{:done, :stop}]],
        hooks: [prepare_next_turn: hook],
        harness_context: %{"hooks" => %{"id" => "hooks-v1"}},
        correlation_ids: %{
          "tenant_id" => "tenant-a",
          "project_id" => "project-a",
          "run_id" => "host-first-run"
        }
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "one")
    assert_receive {:lemieux, ^id, {:harness_snapshot, %Snapshot{} = first}}
    assert_receive {:lemieux, ^id, {:run_evidence, %Run{} = first_run}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert first_run.id == "host-first-run"

    assert first_run.observations["hook_outcomes"] == [
             %{
               "stage" => "prepare_next_turn",
               "request_ordinal" => 1,
               "outcome" => "rewritten",
               "changed_fields" => ["system"]
             }
           ]

    assert first.system_prompt_sha256 == Contract.sha256(Lemieux.Prompt.default() <> "\nhost-v1")

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(context.runtime),
        session
      )

    LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

    next_hook = fn request, _hook_context ->
      {:ok, %{request | system: request.system <> "\nhost-v2"}}
    end

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: context.runtime,
               provider: Scripted.new([[{:done, :stop}]]),
               store: context.store,
               subscriber: self(),
               resume: id,
               hooks: [prepare_next_turn: next_hook],
               harness_context: %{"hooks" => %{"id" => "hooks-v2"}},
               correlation_ids: %{
                 "tenant_id" => "tenant-a",
                 "project_id" => "project-a",
                 "run_id" => "host-first-run"
               }
             )

    assert :ok = Session.prompt(resumed, "two")
    assert_receive {:lemieux, ^id, {:harness_snapshot, %Snapshot{} = second}}
    assert_receive {:lemieux, ^id, {:run_evidence, %Run{} = second_run}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    refute first.semantic_sha256 == second.semantic_sha256
    refute first_run.id == second_run.id
    assert second.hooks["id"] == "hooks-v2"
  end

  defp start_session(context, script, opts \\ []) do
    provider = Scripted.new(script)

    options =
      Keyword.merge(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          tools: [],
          subscriber: self(),
          correlation_ids: %{
            "tenant_id" => "tenant-a",
            "project_id" => "project-a",
            "attempt_id" => "attempt-a"
          }
        ],
        opts
      )

    {:ok, session} =
      Lemieux.start_session(options)

    {session, provider}
  end
end
