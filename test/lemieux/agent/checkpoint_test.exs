defmodule Lemieux.Agent.CheckpointTest do
  use ExUnit.Case, async: true
  alias Lemieux.Agent.Checkpoint
  alias Lemieux.Agent.Composition
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: Scripted.new([]),
        model: "test:journal",
        tools: []
      )

    identity = %{
      "workflow_digest" => "code-v1",
      "configuration_digest" => "config-v1",
      "policy_digest" => "policy-v1"
    }

    {:ok, handle} = Checkpoint.open(session, "run", identity)
    %{handle: handle, runtime: runtime, dir: dir, identity: identity, session: session}
  end

  defp inputs,
    do: %{
      "workspace_snapshot" => %{"sha256" => "snapshot-v1"},
      "upstream_artifacts" => %{"brief" => "digest-v1"}
    }

  test "cached output needs current validation and changed inputs never reuse it", ctx do
    assert {:ok, %{"answer" => "done"}} =
             Checkpoint.step(ctx.handle, "one", inputs(), fn -> {:ok, %{"answer" => "done"}} end)

    never = fn -> flunk("cached step executed twice") end

    assert {:error, :cached_output_requires_validation} =
             Checkpoint.step(ctx.handle, "one", inputs(), never)

    assert {:ok, %{"answer" => "done"}} =
             Checkpoint.step(ctx.handle, "one", inputs(), never,
               validate: fn %{"answer" => "done"} -> :ok end
             )

    assert {:error, :cached_output_invalid} =
             Checkpoint.step(ctx.handle, "one", inputs(), never,
               validate: fn _ -> {:error, :missing_artifact} end
             )

    changed = put_in(inputs(), ["upstream_artifacts", "brief"], "new")
    assert {:error, :step_identity_changed} = Checkpoint.step(ctx.handle, "one", changed, never)

    assert {:error, :run_identity_changed} =
             Checkpoint.open(
               ctx.session,
               "run",
               Map.put(ctx.identity, "policy_digest", "changed")
             )
  end

  test "approval suspends and stale approval cannot authorize an operation", ctx do
    parent = self()

    operation = fn ->
      send(parent, :executed)
      {:ok, %{"receipt" => "external:1"}}
    end

    assert {:suspended, %{revision: revision}} =
             Checkpoint.step(ctx.handle, "publish", inputs(), operation, approval: true)

    refute_received :executed

    assert {:error, {:conflict, ^revision}} =
             Checkpoint.approve(ctx.handle, "publish", revision - 1, "approved")

    assert {:ok, _} =
             Checkpoint.approve(ctx.handle, "publish", revision, "User reviewed artifact digest")

    assert {:ok, %{"receipt" => "external:1"}} =
             Checkpoint.step(ctx.handle, "publish", inputs(), operation, approval: true)

    assert_received :executed
  end

  test "interruption persists uncertainty and reconciliation prevents duplicate effects", ctx do
    assert {:error, {:requires_recovery, "external"}} =
             Checkpoint.step(ctx.handle, "external", inputs(), fn -> raise "interrupted" end)

    never = fn -> flunk("uncertain side effect repeated") end

    assert {:error, {:requires_recovery, "external"}} =
             Checkpoint.step(ctx.handle, "external", inputs(), never)

    assert {:ok, doc} = Checkpoint.status(ctx.handle, "external")

    assert {:ok, _} =
             Checkpoint.resolve(
               ctx.handle,
               "external",
               doc.revision,
               %{"receipt" => "external:2"},
               ["verified-receipt:2"]
             )

    assert {:ok, %{"receipt" => "external:2"}} =
             Checkpoint.step(ctx.handle, "external", inputs(), never, validate: fn _ -> :ok end)
  end

  test "parallel steps keep failures and retried work remains accounted", ctx do
    run = fn key ->
      Checkpoint.step(ctx.handle, key, inputs(), fn ->
        if key == "fail",
          do: {:error, :test_failure, %{"usage" => %{"input_tokens" => 3, "cost_usd" => 0.02}}},
          else: {:ok, %{"usage" => %{"input_tokens" => 4, "cost_usd" => 0.03}}}
      end)
    end

    assert [{:ok, {:ok, _}}, {:ok, {:error, {:step_failed, "fail", "test_failure"}}}] =
             Composition.parallel(ctx.runtime, ["pass", "fail"], run,
               max_concurrency: 2,
               timeout: 1_000
             )

    assert {:ok, doc} = Checkpoint.status(ctx.handle, "fail")
    assert {:ok, _} = Checkpoint.retry(ctx.handle, "fail", doc.revision, "failure corrected")

    assert {:ok, _} =
             Checkpoint.step(ctx.handle, "fail", inputs(), fn ->
               {:ok, %{"usage" => %{"input_tokens" => 5, "cost_usd" => 0.04}}}
             end)

    usage = Composition.usage(ctx.handle, ["pass", "fail"])
    assert usage["input_tokens"] == 12
    assert_in_delta usage["cost_usd"], 0.09, 0.00001
    assert Composition.usage(ctx.handle, ["missing"])["cost_usd"] == nil
  end

  test "resume reopens a run but a fork cannot inherit execution authority", ctx do
    assert {:ok, _} =
             Checkpoint.step(ctx.handle, "one", inputs(), fn -> {:ok, %{"receipt" => "r1"}} end)

    id = Session.id(ctx.session)
    store = JSONL.new(ctx.dir)
    assert {:ok, fork_id} = Lemieux.Transcript.fork(store, id, nil, unsafe: true)

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(ctx.runtime),
      ctx.session
    )

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: store,
               resume: id,
               provider: Scripted.new([])
             )

    assert {:ok, handle} = Checkpoint.open(resumed, "run", ctx.identity)
    assert {:ok, %{value: %{"status" => "completed"}}} = Checkpoint.status(handle, "one")

    assert {:ok, forked} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: store,
               resume: fork_id,
               provider: Scripted.new([])
             )

    assert {:error, :run_identity_changed} = Checkpoint.open(forked, "run", ctx.identity)
  end

  test "timed-out parallel workers leave an intent, not permission to repeat", ctx do
    parent = self()

    run = fn _ ->
      Checkpoint.step(ctx.handle, "slow", inputs(), fn ->
        send(parent, :checkpoint_entered)

        receive do
          :never -> {:ok, %{}}
        end
      end)
    end

    task =
      Task.async(fn ->
        Composition.parallel(ctx.runtime, [1], run, max_concurrency: 1, timeout: 1_000)
      end)

    assert_receive :checkpoint_entered
    assert [{:exit, :timeout}] = Task.await(task)
    assert {:ok, %{value: %{"status" => "in_doubt"}}} = Checkpoint.status(ctx.handle, "slow")
  end

  test "composes an ordinary bounded session with its transcript pointer", ctx do
    provider = Scripted.new([Scripted.complete("stage answer")])

    result =
      Checkpoint.step(ctx.handle, "model", inputs(), fn ->
        Composition.session(%{prompt: "respond", cwd: ctx.dir, timeout_ms: 2_000},
          provider: provider,
          model: "test:stage",
          supervisor: ctx.runtime,
          store: JSONL.new(Path.join(ctx.dir, "stages")),
          session_options: [tools: [], max_requests: 1]
        )
      end)

    assert {:ok, %{"answer" => "stage answer", "session_id" => id} = observation} = result
    assert is_binary(id)
    refute Map.has_key?(observation, "transcript")
    assert {:error, :stage_request_limit_required} = Composition.session(%{}, [])
  end
end
