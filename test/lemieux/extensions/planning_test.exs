defmodule Lemieux.Extensions.PlanningTest do
  use ExUnit.Case, async: true
  alias Lemieux.Entry
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Planning.Reducer
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Document
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Result

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new([Scripted.complete("done")])
    harness = Planning.apply(%Lemieux.Harness{}, [])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: provider,
        model: "test:plan",
        subscriber: self(),
        harness: harness
      )

    %{
      session: session,
      runtime: runtime,
      store: JSONL.new(dir),
      provider: provider,
      harness: harness
    }
  end

  test "CAS, request projection and resume retain plans independently of tool output", ctx do
    assert {:ok, %{revision: 1}} =
             Planning.update(ctx.session, 0, %{"action" => "create", "title" => "Verify"})

    assert {:error, {:conflict, 1}} =
             Planning.update(ctx.session, 0, %{"action" => "create", "title" => "Stale"})

    assert {:ok, %{revision: 1}} =
             Planning.update(ctx.session, 1, %{
               "action" => "update",
               "id" => "t1",
               "title" => "Verify"
             })

    id = Session.id(ctx.session)
    :ok = Session.prompt(ctx.session, "continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [request] = Scripted.requests(ctx.provider)

    assert Enum.any?(
             request.entries,
             &(&1.type == :user and String.contains?(&1.payload["text"] || "", "Plan revision 1"))
           )

    assert {:ok, entries} = Lemieux.Store.read(ctx.store, id)
    checkpoint = Enum.find(entries, &(&1.type == :extension_state))
    assert checkpoint.v == 4
    assert checkpoint == Entry.decode!(Entry.encode!(checkpoint))
    assert_raise ArgumentError, fn -> Entry.decode!(Entry.encode!(%{checkpoint | v: 2})) end

    assert {:ok, forked} = Lemieux.Transcript.fork(ctx.store, id)
    assert {:ok, fork_entries} = Lemieux.Store.read(ctx.store, forked)

    assert {:ok, %{revision: 1}} =
             Document.read(Enum.reverse(fork_entries), "lemieux.plan")

    assert {:ok, %{revision: 2}} =
             Planning.update(ctx.session, 1, %{"action" => "create", "title" => "Parent only"})

    assert {:ok, unchanged} = Lemieux.Store.read(ctx.store, forked)
    assert unchanged == fork_entries

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(ctx.runtime),
      ctx.session
    )

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: ctx.store,
               provider: ctx.provider,
               resume: id,
               harness: ctx.harness
             )

    assert {:ok,
            %{
              revision: 2,
              value: %{"tasks" => [%{"title" => "Verify"}, %{"title" => "Parent only"}]}
            }} =
             Planning.read(resumed)
  end

  test "dependencies reject cycles, early completion and deleting prerequisites" do
    initial = %{"version" => 1, "tasks" => [], "next_id" => 1}
    assert {:ok, plan} = Reducer.apply(initial, %{"action" => "create", "title" => "First"})

    assert {:ok, plan} =
             Reducer.apply(plan, %{
               "action" => "create",
               "title" => "Second",
               "depends_on" => ["t1"]
             })

    assert {:error, _} =
             Reducer.apply(plan, %{"action" => "update", "id" => "t1", "depends_on" => ["t2"]})

    assert {:error, _} =
             Reducer.apply(plan, %{"action" => "update", "id" => "t2", "status" => "completed"})

    assert {:error, _} = Reducer.apply(plan, %{"action" => "delete", "id" => "t1"})

    assert {:ok, plan} =
             Reducer.apply(plan, %{"action" => "update", "id" => "t1", "status" => "completed"})

    assert {:error, :reopen_required} =
             Reducer.apply(plan, %{"action" => "update", "id" => "t1", "status" => "pending"})

    assert {:ok, plan} =
             Reducer.apply(plan, %{"action" => "reopen", "id" => "t1", "reason" => "New evidence"})

    assert hd(plan["tasks"])["reopened_reason"] == "New evidence"
  end

  @empty %{"version" => 1, "tasks" => [], "next_id" => 1}

  defp set(plan, tasks), do: Reducer.apply(plan, %{"action" => "set", "tasks" => tasks})

  describe "set" do
    test "replaces the plan, keeping ids for restated titles and removing what it omits" do
      assert {:ok, plan} =
               set(@empty, [
                 %{"title" => "Read the failing test", "status" => "completed"},
                 %{"title" => "Fix the parser", "status" => "in_progress"},
                 %{"title" => "Run the suite", "status" => "pending"}
               ])

      assert Enum.map(plan["tasks"], &{&1["id"], &1["status"]}) == [
               {"t1", "completed"},
               {"t2", "in_progress"},
               {"t3", "pending"}
             ]

      assert {:ok, plan} =
               set(plan, [
                 %{"title" => "Fix the parser", "status" => "completed"},
                 %{"title" => "Run the suite", "status" => "in_progress"},
                 %{"title" => "Update the changelog", "status" => "pending"}
               ])

      assert Enum.map(plan["tasks"], &{&1["id"], &1["title"], &1["status"]}) == [
               {"t2", "Fix the parser", "completed"},
               {"t3", "Run the suite", "in_progress"},
               {"t4", "Update the changelog", "pending"}
             ]

      assert Reducer.valid?(plan)
    end

    test "an explicit id renames a task in place; an unknown one is refused" do
      assert {:ok, plan} = set(@empty, [%{"title" => "Draft", "status" => "pending"}])

      assert {:ok, renamed} =
               set(plan, [%{"id" => "t1", "title" => "Draft the fix", "status" => "in_progress"}])

      assert [%{"id" => "t1", "title" => "Draft the fix"}] = renamed["tasks"]

      assert {:error, :unknown_task} =
               set(plan, [%{"id" => "t9", "title" => "Ghost", "status" => "pending"}])
    end

    test "invalid statuses and items are refused rather than guessed at" do
      assert {:error, :invalid_plan_command} =
               set(@empty, [%{"title" => "Deleted", "status" => "deleted"}])

      assert {:error, :invalid_plan_command} = set(@empty, [%{"status" => "pending"}])
      assert {:error, _invalid} = set(@empty, [%{"title" => "", "status" => "pending"}])
    end

    test "restating a completed task as pending drops the evidence of that completion" do
      plan = %{
        "version" => 1,
        "next_id" => 2,
        "tasks" => [
          %{
            "id" => "t1",
            "title" => "Ship",
            "status" => "completed",
            "depends_on" => [],
            "evidence" => ["ci run 7"],
            "owner" => nil
          }
        ]
      }

      assert {:ok, %{"tasks" => [%{"status" => "pending", "evidence" => []}]}} =
               set(plan, [%{"title" => "Ship", "status" => "pending"}])

      assert {:ok, %{"tasks" => [%{"status" => "completed", "evidence" => ["ci run 7"]}]}} =
               set(plan, [%{"title" => "Ship", "status" => "completed"}])
    end

    test "recorded dependencies survive while they still hold and are released when reported past" do
      assert {:ok, plan} = Reducer.apply(@empty, %{"action" => "create", "title" => "First"})

      assert {:ok, plan} =
               Reducer.apply(plan, %{
                 "action" => "create",
                 "title" => "Second",
                 "depends_on" => ["t1"]
               })

      assert {:ok, kept} =
               set(plan, [
                 %{"title" => "First", "status" => "in_progress"},
                 %{"title" => "Second", "status" => "pending"}
               ])

      assert Enum.at(kept["tasks"], 1)["depends_on"] == ["t1"]

      assert {:ok, released} =
               set(plan, [
                 %{"title" => "First", "status" => "pending"},
                 %{"title" => "Second", "status" => "in_progress"}
               ])

      assert Enum.at(released["tasks"], 1)["depends_on"] == []

      assert {:ok, dropped} = set(plan, [%{"title" => "Second", "status" => "pending"}])
      assert [%{"id" => "t2", "depends_on" => []}] = dropped["tasks"]
    end

    test "commits without a revision, broadcasts the plan and is what the tool's set does", ctx do
      id = Session.id(ctx.session)
      namespace = Planning.namespace()

      assert {:ok, %{revision: 1}} =
               Planning.set(ctx.session, [%{"title" => "Verify", "status" => "in_progress"}])

      assert_receive {:lemieux, ^id,
                      {:entry,
                       %Entry{
                         type: :extension_state,
                         payload: %{"namespace" => ^namespace, "revision" => 1, "value" => plan}
                       }}}

      assert Planning.tasks(plan) == [
               %{"id" => "t1", "title" => "Verify", "status" => "in_progress"}
             ]

      context = %{session: ctx.session}

      assert {:ok, %Result{structured_content: %{"revision" => 2, "plan" => plan}}} =
               Planning.Tool.run(
                 %{
                   "action" => "set",
                   "tasks" => [
                     %{"title" => "Verify", "status" => "completed"},
                     %{"title" => "Report", "status" => "pending"}
                   ]
                 },
                 context
               )

      assert Enum.map(Planning.tasks(plan), & &1["status"]) == ["completed", "pending"]

      # Restating the same plan writes nothing.
      assert {:ok, %{revision: 2}} =
               Planning.set(ctx.session, [
                 %{"title" => "Verify", "status" => "completed"},
                 %{"title" => "Report", "status" => "pending"}
               ])
    end

    test "tasks/1 hides deleted tasks and tolerates an absent plan" do
      plan = %{
        "tasks" => [
          %{"id" => "t1", "title" => "Kept", "status" => "pending"},
          %{"id" => "t2", "title" => "Gone", "status" => "deleted"}
        ]
      }

      assert Planning.tasks(plan) == [%{"id" => "t1", "title" => "Kept", "status" => "pending"}]
      assert Planning.tasks(nil) == []
    end
  end

  # A resource-scoped call overlaps the other calls of its wave and is ordered
  # only against calls for the same resource — no longer the barrier every
  # plan update used to be, and never two plan writes racing each other.
  test "the todo tool shares a wave with other tools but serializes against itself" do
    descriptor = Lemieux.Tool.descriptor(Planning.Tool)

    assert Descriptor.concurrency(descriptor) == {:resource, "lemieux.plan"}
    assert descriptor.policy["approval"] == "never"
  end

  test "document validation rejects oversized and non JSON state without killing session", ctx do
    assert {:error, :document_too_large} =
             Session.put_document(ctx.session, "test", 0, %{"x" => String.duplicate("x", 70_000)})

    assert {:error, :invalid_document} =
             Session.put_document(ctx.session, "test", 0, %{"x" => self()})

    assert {:ok, %{revision: 0}} = Session.document(ctx.session, "test")
  end
end
