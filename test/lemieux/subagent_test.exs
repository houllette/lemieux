defmodule Lemieux.SubagentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Context, as: SubagentContext
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Replay
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task

  setup context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(context.tmp_dir)

    parent_provider =
      Scripted.new([[{:text_delta, "parent-only history"}, {:done, :stop}]],
        estimated_cost_usd: 0.01
      )

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: parent_provider,
        store: store,
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    %{runtime: runtime, store: store, parent: parent, parent_provider: parent_provider}
  end

  @tag :tmp_dir
  test "runs a fresh child session and persists complete parent-child lineage", context do
    :ok = Session.prompt(context.parent, "secret parent context")
    assert_receive {:lemieux, _parent_id, {:finished, :stop}}

    provider = successful_provider("The cancellation owner is Session.", 11, 4, 0.02)
    definition = definition("scout")
    entry = Lemieux.Entry.new(:user, %{"text" => "Host-selected compatibility constraint"})
    {:ok, packet} = SubagentContext.select("parent-evidence", [entry], [entry.id])
    task = %{task("Find cancellation ownership") | context: packet}

    assert {:ok, child_ref} =
             Subagent.spawn(context.parent, definition, task,
               max_cost_usd: 0.5,
               providers: %{"scout" => provider}
             )

    assert {:ok, result} = Subagent.await(child_ref, 5_000)
    assert result.status == :ok
    assert result.answer == "The cancellation owner is Session."
    assert result.usage["input_tokens"] == 11

    assert {:ok, snapshot} = Subagent.inspect(child_ref)
    assert snapshot.status == :ok
    assert snapshot.transcript_id == child_ref.id
    assert snapshot.input["task"]["objective"] == "Find cancellation ownership"
    assert snapshot.input["system_prompt"] =~ "depth-one delegated investigator"
    assert snapshot.input["user_prompt"] =~ "Objective:\nFind cancellation ownership"
    assert snapshot.input["user_prompt"] =~ "Host-selected compatibility constraint"
    assert snapshot.input["task"]["context"] == packet
    assert snapshot.input["request"]["system"] == snapshot.input["system_prompt"]

    [child_request] = Scripted.requests(provider)

    refute Enum.any?(
             child_request.entries,
             &(get_in(&1.payload, ["text"]) == "secret parent context")
           )

    assert child_request.system =~ "depth-one delegated investigator"
    assert child_request.system =~ "Definition digest:"
    assert Enum.map(child_request.tools, &Lemieux.Tool.name/1) == ["read"]
    assert child_request.output_schema == nil

    {:ok, parent_entries} = Store.read(context.store, child_ref.parent_id)

    assert [:subagent_spawn, :subagent_result, :subagent_group_result] =
             parent_entries
             |> Enum.map(& &1.type)
             |> Enum.filter(&(&1 in [:subagent_spawn, :subagent_result, :subagent_group_result]))

    spawn = Enum.find(parent_entries, &(&1.type == :subagent_spawn))
    assert spawn.payload["child_id"] == child_ref.id
    assert spawn.payload["authority"] == %{"read_only" => true, "tools" => ["read"]}
    assert spawn.payload["task"]["objective"] == "Find cancellation ownership"

    assert_receive {:lemieux, _parent_id, {:subagent, [_root_id, child_id], {:finished, :stop}}}

    assert child_id == child_ref.id

    assert {:ok, %{groups: [%{status: :ok, children: [%{status: :ok}]}]}} =
             Replay.tree(context.store, child_ref.parent_id)

    {:ok, group} = Subagent.group(child_ref)

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.subagent_group_supervisor(context.runtime),
        group
      )

    assert {:ok, durable_result} = Subagent.await(child_ref, 100)
    assert durable_result.answer == "The cancellation owner is Session."

    assert {:ok, durable_snapshot} = Subagent.inspect(child_ref)
    assert durable_snapshot.input["task"]["objective"] == "Find cancellation ownership"
    assert durable_snapshot.input["request"]["system"] =~ "depth-one delegated investigator"
  end

  @tag :tmp_dir
  test "max-turn and no-progress stops retain their real failure reason", context do
    File.write!(Path.join(context.tmp_dir, "a.txt"), "same")

    max_turn_provider =
      Scripted.new(
        [Scripted.tool_call("read-1", "read", %{"path" => "a.txt"})],
        estimated_cost_usd: 0.01
      )

    max_turn_definition = definition("max-turn", max_turns: 1)

    assert {:ok, max_turn_ref} =
             Subagent.spawn(context.parent, max_turn_definition, task("Keep reading"),
               max_cost_usd: 0.5,
               providers: %{"max-turn" => max_turn_provider}
             )

    assert {:ok, max_turn_result} = Subagent.await(max_turn_ref, 5_000)
    assert max_turn_result.status == :failed
    assert max_turn_result.uncertainties == ["stopped after 1 turns"]

    repeated =
      Enum.map(1..3, fn index ->
        Scripted.tool_call("read-#{index}", "read", %{"path" => "a.txt"},
          usage: %{"input_tokens" => 1, "output_tokens" => 1, "cost_usd" => 0.01}
        )
      end)

    no_progress_provider = Scripted.new(repeated, estimated_cost_usd: 0.01)
    no_progress_definition = definition("no-progress", max_turns: 4)

    assert {:ok, no_progress_ref} =
             Subagent.spawn(context.parent, no_progress_definition, task("Keep reading"),
               max_cost_usd: 0.5,
               providers: %{"no-progress" => no_progress_provider}
             )

    assert {:ok, no_progress_result} = Subagent.await(no_progress_ref, 5_000)
    assert no_progress_result.status == :failed

    assert no_progress_result.uncertainties == [
             "stopped after 3 rounds that asked for the same thing and got the same answer"
           ]
  end

  @tag :tmp_dir
  test "all-settled fan-out preserves input order and successful siblings", context do
    slow = successful_provider("first", 7, 2, 0.01, true)

    # A child that answered in prose did the work; the envelope keeps it and
    # labels it rather than reporting nothing to the parent.
    prose =
      Scripted.new([[{:text_delta, "not json"}, {:done, :stop}]], estimated_cost_usd: 0.01)

    requests = [
      Request.new(definition("first"), task("Inspect session cancellation")),
      Request.new(definition("second"), task("Inspect tool cancellation"))
    ]

    assert {:ok, group_ref} =
             Subagent.spawn_many(context.parent, requests,
               max_cost_usd: 0.5,
               providers: %{"first" => slow, "second" => prose}
             )

    assert_receive {:provider_waiting, slow_worker}
    assert {:ok, [_first, second]} = Subagent.children(group_ref)

    assert {:ok, %{status: :ok, format: :prose, answer: "not json"}} =
             Subagent.await(second, 5_000)

    send(slow_worker, :release)

    assert {:ok, result} = Subagent.await(group_ref, 5_000)
    assert result.status == :ok
    assert Enum.map(result.results, & &1.definition_id) == ["first", "second"]
    assert Enum.map(result.results, & &1.status) == [:ok, :ok]
    assert Enum.map(result.results, & &1.format) == [:structured, :prose]
    assert Enum.at(result.results, 0).answer == "first"
  end

  @tag :tmp_dir
  test "a sibling that genuinely failed is still reported beside the ones that did not",
       context do
    slow = successful_provider("first", 7, 2, 0.01, true)
    # No answer at all: the provider errored before the child said anything.
    silent = Scripted.new([Scripted.error(:closed)], estimated_cost_usd: 0.01)

    requests = [
      Request.new(definition("first"), task("Inspect session cancellation")),
      Request.new(definition("second"), task("Inspect tool cancellation"))
    ]

    assert {:ok, group_ref} =
             Subagent.spawn_many(context.parent, requests,
               max_cost_usd: 0.5,
               providers: %{"first" => slow, "second" => silent}
             )

    assert_receive {:provider_waiting, slow_worker}
    assert {:ok, [_first, second]} = Subagent.children(group_ref)
    assert {:ok, failed} = Subagent.await(second, 5_000)
    assert failed.status == :failed
    assert failed.answer == ""
    send(slow_worker, :release)

    assert {:ok, result} = Subagent.await(group_ref, 5_000)
    assert result.status == :partial
    assert Enum.map(result.results, & &1.status) == [:ok, :failed]
  end

  @tag :tmp_dir
  test "child timeout stops provider work and keeps an explicit timeout envelope", context do
    clock = Manual.new()
    provider = successful_provider("too late", 1, 1, 0.01, true)
    definition = definition("slow", timeout: 20)

    assert {:ok, child_ref} =
             Subagent.spawn(context.parent, definition, task("Wait forever"),
               max_cost_usd: 0.5,
               providers: %{"slow" => provider},
               clock: clock
             )

    # The child's clock is its 20 ms deadline, nearer than any check. On the
    # manual clock it fires when the test moves time to it, not when a busy
    # machine gets round to it.
    {:ok, group} = Subagent.group(child_ref)

    LemieuxTest.Sync.state(group, fn state ->
      Enum.any?(state.children, fn {_id, child} -> child.timer != nil end)
    end)

    Manual.advance(clock, 19, settle: group)
    assert {:ok, %{status: :running}} = Subagent.inspect(child_ref)

    Manual.advance(clock, 1, settle: group)
    assert {:ok, result} = Subagent.await(child_ref, 5_000)
    assert result.status == :timeout
    assert result.answer == ""
    assert result.findings == []

    {:ok, entries} = Store.read(context.store, child_ref.parent_id)

    assert Enum.count(entries, fn entry ->
             entry.type == :subagent_result and entry.payload["child_id"] == child_ref.id
           end) == 1
  end

  @tag :tmp_dir
  test "authorized steering is durable and group cancellation retains terminal results",
       context do
    provider = successful_provider("too late", 1, 1, 0.01, true)

    assert {:ok, child_ref} =
             Subagent.spawn(context.parent, definition("running"), task("Keep reading"),
               max_cost_usd: 0.5,
               providers: %{"running" => provider}
             )

    assert_receive {:provider_waiting, _worker}
    assert {:ok, %{status: :running}} = Subagent.inspect(child_ref)
    assert :ok = Subagent.steer(child_ref, "Also inspect tool shutdown.")
    assert :ok = Subagent.cancel(child_ref, :user_requested)
    assert {:ok, result} = Subagent.await(child_ref, 5_000)
    assert result.status == :cancelled

    {:ok, entries} = Store.read(context.store, child_ref.parent_id)
    steer = Enum.find(entries, &(&1.type == :subagent_steer))
    assert steer.payload["instruction"] == "Also inspect tool shutdown."
  end

  @tag :tmp_dir
  test "parent cancellation reaches a registered foreground group", context do
    provider = successful_provider("too late", 1, 1, 0.01, true)

    assert {:ok, child_ref} =
             Subagent.spawn(context.parent, definition("running"), task("Keep reading"),
               max_cost_usd: 0.5,
               providers: %{"running" => provider}
             )

    assert_receive {:provider_waiting, _worker}
    assert Session.snapshot(context.parent).status == :busy
    assert :ok = Session.cancel(context.parent, :parent_cancelled)
    assert {:ok, result} = Subagent.await(child_ref, 5_000)
    assert result.status == :cancelled
  end

  defp definition(id, overrides \\ []) do
    Definition.new(
      Keyword.merge(
        [
          id: id,
          description: "Investigates #{id}",
          system_prompt: "Return concise sourced findings.",
          model: "test:child",
          tools: [Lemieux.Tools.Read],
          max_cost_usd: 0.1
        ],
        overrides
      )
    )
  end

  defp task(objective) do
    Task.new(
      objective: objective,
      expected_evidence: ["file and line references"],
      acceptance_criteria: ["cover the named subsystem"],
      snapshot: %{"git_commit" => "abc123"}
    )
  end

  defp successful_provider(answer, input, output, cost, gated? \\ false) do
    owner = self()

    Scripted.new(
      [
        fn _request ->
          if gated? do
            send(owner, {:provider_waiting, self()})
            receive do: (:release -> :ok)
          end

          body = %{
            "answer" => answer,
            "findings" => [],
            "artifacts" => [],
            "uncertainties" => [],
            "coverage" => %{"searched" => ["lib"], "skipped" => []}
          }

          [
            {:text_delta, JSON.encode!(body)},
            {:usage,
             %{
               "input_tokens" => input,
               "output_tokens" => output,
               "cost_usd" => cost
             }},
            {:done, :stop}
          ]
        end
      ],
      estimated_cost_usd: 0.01
    )
  end
end
