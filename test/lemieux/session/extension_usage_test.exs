defmodule Lemieux.Session.ExtensionUsageTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "a paid extension checkpoint counts against the session budget after resume", %{
    tmp_dir: dir
  } do
    runtime = :"extension_usage_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(dir)
    provider = Scripted.new([Scripted.complete("done")], estimated_cost_usd: 0.006)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: store,
        model: "test:model",
        max_cost_usd: 0.01,
        subscriber: self()
      )

    id = Session.id(session)

    usage = %{
      "model" => "local-scorer-1",
      "input_tokens" => 100,
      "output_tokens" => 2,
      "cost_usd" => 0.005,
      "source" => "systemone_compaction"
    }

    assert {:ok, %{revision: 1}} =
             Session.put_document(session, "systemone_compaction", 0, %{"attempts" => 1},
               usage: usage
             )

    assert_receive {:lemieux, ^id, {:usage, ^usage}}
    assert %{spent_usd: 0.005, max_cost_usd: 0.01} = Session.budget(session)
    assert Session.snapshot(session).usage.direct["input_tokens"] == 100
    refute Session.snapshot(session).context.measured?

    :ok = Session.prompt(session, "work")
    assert_receive {:lemieux, ^id, {:finished, {:budget, %{spent: 0.005}}}}
    assert Scripted.requests(provider) == []

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(runtime),
      session
    )

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: store,
        resume: id,
        max_cost_usd: 0.01
      )

    assert %{spent_usd: 0.005, max_cost_usd: 0.01} = Session.budget(resumed)

    assert {:ok, %{revision: 1, value: %{"attempts" => 1}}} =
             Session.document(resumed, "systemone_compaction")
  end

  test "unknown external cost remains unknown, never zero", %{tmp_dir: dir} do
    runtime = :"extension_unknown_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(dir),
        model: "test:model",
        max_cost_usd: 1.0
      )

    usage = %{
      "model" => "local-scorer-1",
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cost_usd" => nil
    }

    assert {:ok, _} = Session.put_document(session, "systemone_compaction", 0, %{}, usage: usage)
    assert Session.budget(session).spent_usd == nil
  end

  test "a stale document writer still records its paid external usage", %{tmp_dir: dir} do
    runtime = :"extension_conflict_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([]),
        store: JSONL.new(dir),
        model: "test:model"
      )

    assert {:ok, %{revision: 1}} = Session.put_document(session, "judge", 0, %{"winner" => true})

    usage = %{
      "model" => "local-scorer-1",
      "input_tokens" => 12,
      "output_tokens" => 1,
      "cost_usd" => 0.001
    }

    assert {:error, {:conflict, 1}} =
             Session.put_document(session, "judge", 0, %{"winner" => false}, usage: usage)

    assert {:ok, %{revision: 1, value: %{"winner" => true}}} =
             Session.document(session, "judge")

    assert Session.budget(session).spent_usd == 0.001
    assert Session.snapshot(session).usage.direct["input_tokens"] == 12
  end
end
