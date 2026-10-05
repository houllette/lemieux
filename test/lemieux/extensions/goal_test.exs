defmodule Lemieux.Extensions.GoalTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.Goal
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent.Definition

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir), cwd: dir}
  end

  defp start(ctx, opts, count \\ 3) do
    defaults = [
      policy_id: "checks-v1",
      checks: %{"tests" => fn _ -> {:pass, ["test-receipt:1"]} end},
      snapshot: fn _ -> {:ok, %{"sha256" => "fixed"}} end,
      max_requests: 4
    ]

    options = Keyword.merge(defaults, opts)
    config = struct!(Goal, options)
    provider = Scripted.new(List.duplicate(Scripted.complete("done"), count))
    harness = Goal.apply(%Harness{tools: []}, options)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        provider: provider,
        store: ctx.store,
        model: "test:goal",
        cwd: ctx.cwd,
        harness: harness,
        subscriber: self()
      )

    {:ok, _} = Goal.create(session, 0, "Deliver the feature", ["tests"])
    {session, provider, config, %{session: session, supervisor: ctx.runtime, cwd: ctx.cwd}}
  end

  test "completion binds revision, policy and stable checked snapshot", ctx do
    {session, _, _, _} = start(ctx, [])
    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert {:ok, %{value: %{"status" => "completed", "assessment" => evidence}}} =
             Goal.read(session)

    assert evidence["goal_revision"] == 1
    assert evidence["policy_id"] == "checks-v1"
    assert evidence["snapshot_stable"]
    assert [%{"status" => "passed", "evidence" => ["test-receipt:1"]}] = evidence["checks"]
  end

  test "failed checks consume only the explicit continuation allowance", ctx do
    {session, provider, _, _} =
      start(ctx, checks: %{"tests" => fn _ -> {:fail, "test failure"} end}, max_continuations: 1)

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{value: %{"status" => "unverified", "continuations" => 1}}} = Goal.read(session)
  end

  test "snapshot drift and verification timeout stay unverified", ctx do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    snapshot = fn _ -> {:ok, %{"revision" => Agent.get_and_update(counter, &{&1, &1 + 1})}} end
    {session, _, config, context} = start(ctx, snapshot: snapshot)

    assert {:ok,
            %{value: %{"status" => "unverified", "assessment" => %{"snapshot_stable" => false}}}} =
             Goal.verify(config, session, 1, context)

    assert {:ok, current} = Goal.read(session)

    timeout = %{
      config
      | verify_timeout_ms: 10,
        checks: %{
          "tests" => fn _ ->
            receive do
              :never -> {:pass, ["no"]}
            end
          end
        }
    }

    assert {:ok, %{value: %{"status" => "unverified"}}} =
             Goal.verify(timeout, session, current.revision, context)
  end

  test "stale revisions cannot spend verification work or overwrite evidence", ctx do
    {session, _, config, context} = start(ctx, [])
    assert {:error, {:conflict, 1}} = Goal.verify(config, session, 0, context)
    assert {:ok, %{revision: 1, value: %{"status" => "active"}}} = Goal.read(session)
    assert :allow = Goal.stop(config, :cancelled, context)
  end

  test "independent review is an accounted bounded child", ctx do
    definition =
      Definition.new(
        id: "reviewer",
        description: "Review",
        system_prompt: "Inspect evidence",
        model: "test:review",
        tools: [],
        max_requests: 1,
        max_cost_usd: 0.1
      )

    provider =
      Scripted.new(
        [
          [
            {:text_delta, "{\"answer\":\"verified\"}"},
            {:usage, %{"input_tokens" => 5, "output_tokens" => 2, "cost_usd" => 0.01}},
            {:done, :stop}
          ]
        ],
        estimated_cost_usd: 0.01
      )

    reviewer = %{
      definition: definition,
      options: [max_cost_usd: 0.1, providers: %{"reviewer" => provider}],
      timeout_ms: 2_000,
      accept: fn result ->
        if result.answer == "verified",
          do: {:pass, [result.transcript_id]},
          else: {:fail, "not verified"}
      end
    }

    {session, _, config, context} = start(ctx, reviewer: reviewer)

    assert {:ok, %{value: %{"status" => "completed", "assessment" => assessment}}} =
             Goal.verify(config, session, 1, context)

    assert List.last(assessment["checks"])["child_session_id"]
    assert Session.snapshot(session).inclusive_spent_usd == 0.01
  end
end
