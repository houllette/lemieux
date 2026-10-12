defmodule Lemieux.JobsTest do
  use ExUnit.Case, async: true
  alias Lemieux.Entry
  alias Lemieux.Jobs
  alias Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Jobs.Recovery
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent.Definition
  @moduletag :tmp_dir

  defmodule HeldTool do
    alias Lemieux.Tool.Result
    @behaviour Lemieux.Tool.Configured
    defstruct [:owner, :path, class: "external", hold?: true]
    @impl true
    def name(_tool), do: "held"
    @impl true
    def description(_tool), do: "A controlled effect fixture"
    @impl true
    def schema(_tool), do: %{"type" => "object", "properties" => %{}}
    @impl true
    def metadata(tool),
      do: %{
        effects: %{
          class: tool.class,
          external_cost: %{maximum_usd: if(tool.class == "read", do: 0, else: 0.2)}
        }
      }

    @impl true
    def run(tool, _args, _context) do
      if tool.class != "read", do: File.write!(tool.path, "effect\n", [:append])
      send(tool.owner, {:entered, self()})

      if tool.hold? do
        receive do
          :finish -> :ok
        end
      end

      {:ok,
       Result.new("effect finished",
         cost: %{"usd" => if(tool.class == "read", do: 0, else: 0.2)}
       )}
    end
  end

  defmodule PausedStore do
    @behaviour Lemieux.Store
    @impl true
    def append(state, id, entries) do
      if Enum.any?(entries, &(&1.type == Map.get(state, :pause_type, :tool_result))) do
        send(state.owner, {:before_result_append, self()})

        receive do
          :persist -> :ok
        end
      end

      Lemieux.Store.append(state.store, id, entries)
    end

    @impl true
    def read(state, id), do: Lemieux.Store.read(state.store, id)
    @impl true
    def list_sessions(state), do: Lemieux.Store.list_sessions(state.store)
    @impl true
    def lock(state, id), do: Lemieux.Store.lock(state.store, id)
    @impl true
    def unlock(state, id, lock), do: Lemieux.Store.unlock(state.store, id, lock)
  end

  setup %{tmp_dir: dir} do
    runtime = :"jobs_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    journal = Files.new(Path.join(dir, "jobs"))
    store = JSONL.new(Path.join(dir, "sessions"))
    %{runtime: runtime, journal: journal, store: store, dir: dir}
  end

  defp host(context, provider, extra \\ []) do
    {session_options, extra} = Keyword.pop(extra, :session_options, [])

    factory = fn _job ->
      {:ok,
       Keyword.merge(
         [
           provider: provider,
           model: "test:model",
           tools: [],
           provider_retry: false,
           compact_at: nil,
           store: context.store
         ],
         session_options
       )}
    end

    authorize = fn _action, _job, authority ->
      if authority == :owner, do: :ok, else: {:error, :unauthorized}
    end

    Jobs.start_link(
      [
        supervisor: context.runtime,
        journal: context.journal,
        store: context.store,
        factory: factory,
        authorize: authorize,
        poll_ms: 10
      ]
      |> Keyword.merge(extra)
    )
  end

  defp interrupt(context, manager, job) do
    {:ok, session} = Lemieux.session(context.runtime, job["session_id"])
    root = Process.monitor(session)
    monitor = Process.monitor(manager)
    Process.unlink(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}
    assert_receive {:DOWN, ^root, :process, ^session, _reason}
  end

  test "pending approvals survive host loss and require the new attempt's authority", context do
    args = %{"path" => "approved.txt", "content" => "once"}
    original = Scripted.new([Scripted.tool_call("write-1", "write", args)])

    options = [
      tools: [Lemieux.Tools.Write],
      hooks: [before_tool_call: fn _, _ -> :pending end],
      approval_timeout: :infinity
    ]

    {:ok, manager} = host(context, original, session_options: options)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    id = job["id"]
    session_id = job["session_id"]
    {:ok, _job} = Jobs.attach(manager, id, self(), :owner)

    assert_receive {:lemieux_job, ^id,
                    {:session, ^session_id, {:tool_approval, %{id: "write-1"}}}}

    {:ok, waiting} = Jobs.get(manager, id, :owner)
    interrupt(context, manager, job)

    fresh = Scripted.new([Scripted.complete("done")])
    {:ok, rebuilt} = host(context, fresh, session_options: options)
    {:ok, restored} = Jobs.get(rebuilt, id, :owner)
    assert restored["status"] == "interrupted"
    assert [%{"call_id" => "write-1"}] = restored["pending"]
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)

    assert_receive {:lemieux_job, ^id,
                    {:session, ^session_id, {:tool_approval, %{id: "write-1"}}}}

    {:ok, current} = Jobs.get(rebuilt, id, :owner)
    assert current["epoch"] != waiting["epoch"]

    assert {:error, :stale_attempt} =
             Jobs.resolve(rebuilt, id, waiting["epoch"], session_id, "write-1", :allow, :owner)

    assert {:error, :unauthorized} =
             Jobs.resolve(rebuilt, id, current["epoch"], session_id, "write-1", :allow, :stranger)

    refute File.exists?(Path.join(context.dir, "approved.txt"))

    assert :ok =
             Jobs.resolve(rebuilt, id, current["epoch"], session_id, "write-1", :allow, :owner)

    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    assert File.read!(Path.join(context.dir, "approved.txt")) == "once"
    assert length(Scripted.requests(original)) == 1
    assert length(Scripted.requests(fresh)) == 1
    GenServer.stop(rebuilt)
  end

  test "unknown external effects block recovery; proven completion is consumed without repetition",
       context do
    tool = %HeldTool{owner: self(), path: Path.join(context.dir, "effects")}
    usage = %{"cost_usd" => 0.1}

    provider =
      Scripted.new([Scripted.tool_call("effect-1", "held", %{}, usage: usage)],
        estimated_cost_usd: 0.1
      )

    {:ok, manager} = host(context, provider, session_options: [tools: [tool]])

    {:ok, job} =
      Jobs.submit(
        manager,
        intent(context, [{"limits", %{"max_requests" => 3, "max_cost_usd" => 1}}]),
        :owner
      )

    assert_receive {:entered, _task}
    interrupt(context, manager, job)
    # A live owner loss can reach the ordinary unknown-result path before
    # the manager drains the session. Reconciliation must correct that view
    # without replacing event history or adding a second tool response.
    {:ok, entries} = Store.read(context.store, job["session_id"])
    parent = List.last(entries)

    unknown =
      Entry.new(
        :tool_result,
        %{
          "call_id" => "effect-1",
          "name" => "held",
          "output" => "external outcome unknown",
          "outcome" => "unknown",
          "error" => true
        },
        parent: parent,
        seq: parent.seq + 1
      )

    assert :ok = Store.append(context.store, job["session_id"], [unknown])
    fresh = Scripted.new([Scripted.complete("checked", usage: usage)], estimated_cost_usd: 0.1)
    {:ok, rebuilt} = host(context, fresh, session_options: [tools: [tool]])
    id = job["id"]
    assert {:error, {:unresolved_effects, [key]}} = Jobs.recover(rebuilt, id, :owner)
    assert Scripted.requests(fresh) == []
    assert File.read!(tool.path) == "effect\n"

    assert {:error, :invalid_reconciliation} =
             Jobs.reconcile(rebuilt, id, key, %{"status" => "not_run"}, :owner)

    result = %{
      "call_id" => "effect-1",
      "name" => "held",
      "arguments" => %{},
      "output" => "effect finished",
      "error" => false,
      "outcome" => "success",
      "cost" => %{"usd" => 0.2}
    }

    assert {:error, :invalid_effect_reconciliation} =
             Jobs.reconcile(
               rebuilt,
               id,
               key,
               %{
                 "status" => "completed",
                 "result" => Map.put(result, "call_id", "another-call"),
                 "evidence" => "wrong receipt"
               },
               :owner
             )

    assert :ok =
             Jobs.reconcile(
               rebuilt,
               id,
               key,
               %{
                 "status" => "completed",
                 "result" => result,
                 "evidence" => "fixture filesystem receipt"
               },
               :owner
             )

    assert :ok =
             Jobs.reconcile(
               rebuilt,
               id,
               "budget",
               %{"spent_usd" => 0.3, "evidence" => "provider and tool receipts"},
               :owner
             )

    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    assert File.read!(tool.path) == "effect\n"
    refute_receive {:entered, _task}, 50
    {:ok, completed} = Jobs.get(rebuilt, id, :owner)
    assert completed["budget"]["requests"] == 2
    assert_in_delta completed["budget"]["spent_usd"], 0.4, 0.000001
    [request] = Scripted.requests(fresh)

    assert Enum.any?(
             request.entries,
             &(&1.type == :system and
                 String.contains?(inspect(&1), "fixture filesystem receipt"))
           )

    {:ok, entries} = Store.read(context.store, job["session_id"])
    assert Enum.count(entries, &(&1.type == :tool_result)) == 1
    GenServer.stop(rebuilt)
  end

  test "safe interrupted readers retry through the current policy", context do
    tool = %HeldTool{owner: self(), class: "read"}
    provider = Scripted.new([Scripted.tool_call("read-1", "held", %{})])
    {:ok, manager} = host(context, provider, session_options: [tools: [tool]])
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive {:entered, _task}
    interrupt(context, manager, job)
    fresh = Scripted.new([Scripted.complete("safe")])
    {:ok, rebuilt} = host(context, fresh, session_options: [tools: [tool]])
    id = job["id"]
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:entered, task}
    send(task, :finish)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    assert length(Scripted.requests(fresh)) == 1
    GenServer.stop(rebuilt)
  end

  test "recovered questions require current authority and return to running", context do
    args = %{"question" => "Which file?", "options" => [%{"label" => "A"}, %{"label" => "B"}]}
    provider = Scripted.new([Scripted.tool_call("question-1", "ask_user", args)])
    options = [tools: [Lemieux.Tools.AskUser], approval_timeout: :infinity]
    {:ok, manager} = host(context, provider, session_options: options)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    id = job["id"]
    session = job["session_id"]
    {:ok, _job} = Jobs.attach(manager, id, self(), :owner)
    assert_receive {:lemieux_job, ^id, {:session, ^session, {:question, _question}}}
    {:ok, old} = Jobs.get(manager, id, :owner)
    assert old["status"] == "waiting_approval"
    interrupt(context, manager, job)
    owner = self()

    fresh =
      Scripted.new([
        fn request ->
          send(owner, {:answered_request, request})
          Scripted.delayed(60_000, Scripted.complete("held"))
        end
      ])

    {:ok, rebuilt} = host(context, fresh, session_options: options)
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:lemieux_job, ^id, {:session, ^session, {:question, _question}}}
    {:ok, current} = Jobs.get(rebuilt, id, :owner)

    assert {:error, :stale_attempt} =
             Jobs.answer(rebuilt, id, old["epoch"], session, "question-1", "A", :owner)

    assert {:error, :unauthorized} =
             Jobs.answer(rebuilt, id, current["epoch"], session, "question-1", "A", :stranger)

    assert :ok = Jobs.answer(rebuilt, id, current["epoch"], session, "question-1", "A", :owner)
    assert_receive {:answered_request, request}
    assert Enum.any?(request.entries, &(&1.type == :tool_result and &1.payload["output"] == "A"))
    assert {:ok, %{"status" => "running", "pending" => []}} = Jobs.get(rebuilt, id, :owner)
    assert :ok = Jobs.cancel(rebuilt, id, :owner)
    GenServer.stop(rebuilt)
  end

  test "queue bounds, scheduling and admission persist without dispatch", context do
    provider = Scripted.new([])
    {:ok, manager} = host(context, provider, max_pending: 1)
    later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    {:ok, job} = Jobs.submit(manager, intent(context, [{"run_at", later}]), :owner)
    assert {:error, :queue_full} = Jobs.submit(manager, intent(context), :owner)

    assert {:error, :invalid_job_intent} =
             Jobs.submit(manager, %{"prompt" => "unbounded"}, :owner)

    assert Scripted.requests(provider) == []
    assert :ok = Jobs.cancel(manager, job["id"], :owner)
    {:ok, cancelled} = Jobs.get(manager, job["id"], :owner)
    assert cancelled["status"] == "cancelled"
    GenServer.stop(manager)
  end

  @tag capture_log: true
  test "a receipt committed before a lost transcript append is repaired without another effect",
       context do
    paused = Map.put(context, :store, {PausedStore, %{store: context.store, owner: self()}})
    tool = %HeldTool{owner: self(), path: Path.join(context.dir, "effects"), hold?: false}
    provider = Scripted.new([Scripted.tool_call("effect-1", "held", %{})])
    {:ok, manager} = host(paused, provider, session_options: [tools: [tool]])
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    id = job["id"]
    {:ok, _job} = Jobs.attach(manager, id, self(), :owner)
    assert_receive {:entered, _task}
    assert_receive {:before_result_append, session}
    {:ok, effects} = Jobs.effects(manager, id, nil, :owner)

    assert Enum.any?(
             effects,
             &(&1.value["effect"]["kind"] == "tool" and &1.value["status"] == "completed")
           )

    Process.exit(session, :kill)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "interrupted"}}}
    GenServer.stop(manager)
    fresh = Scripted.new([Scripted.complete("recovered")])
    {:ok, rebuilt} = host(context, fresh, session_options: [tools: [tool]])
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    assert File.read!(tool.path) == "effect\n"
    refute_receive {:entered, _task}, 50
    [request] = Scripted.requests(fresh)

    assert Enum.any?(
             request.entries,
             &(&1.type == :tool_result and &1.payload["output"] == "effect finished")
           )

    GenServer.stop(rebuilt)
  end

  test "recovery respects the same pending queue bound as submission", context do
    authorize = fn
      :run, _job, :owner -> {:error, :fresh_authority_required}
      _action, _job, :owner -> :ok
      _action, _job, _authority -> {:error, :unauthorized}
    end

    provider = Scripted.new([])
    {:ok, manager} = host(context, provider, max_pending: 1, authorize: authorize)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    id = job["id"]
    {:ok, attached} = Jobs.attach(manager, id, self(), :owner)

    if attached["status"] != "blocked" do
      assert_receive {:lemieux_job, ^id, {:status, %{"status" => "blocked"}}}
    end

    later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    assert {:ok, _queued} = Jobs.submit(manager, intent(context, [{"run_at", later}]), :owner)
    assert {:error, :queue_full} = Jobs.recover(manager, id, :owner)
    assert Scripted.requests(provider) == []
    GenServer.stop(manager)
  end

  test "slow preparation can be cancelled without blocking control or starting inference",
       context do
    owner = self()

    factory = fn _job ->
      send(owner, :preparing)

      receive do
        :finish -> {:error, :unused}
      end
    end

    provider = Scripted.new([])
    {:ok, manager} = host(context, provider, factory: factory)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive :preparing
    assert {:ok, %{"status" => "starting"}} = Jobs.get(manager, job["id"], :owner)
    assert :ok = Jobs.cancel(manager, job["id"], :owner)
    assert {:ok, %{"status" => "cancelled"}} = Jobs.get(manager, job["id"], :owner)
    assert Scripted.requests(provider) == []
    GenServer.stop(manager)
  end

  test "loss of a provider attempt retains admission and cannot silently retry", context do
    owner = self()

    provider =
      Scripted.new(
        [
          fn _ ->
            send(owner, :inference)
            Scripted.delayed(60_000, Scripted.complete("held"))
          end
        ],
        estimated_cost_usd: 0.3
      )

    {:ok, manager} = host(context, provider)

    {:ok, job} =
      Jobs.submit(
        manager,
        intent(context, [{"limits", %{"max_requests" => 2, "max_cost_usd" => 1}}]),
        :owner
      )

    assert_receive :inference
    interrupt(context, manager, job)
    fresh = Scripted.new([Scripted.complete("must not spend")], estimated_cost_usd: 0.3)
    {:ok, rebuilt} = host(context, fresh)
    {:ok, restored} = Jobs.get(rebuilt, job["id"], :owner)
    assert restored["budget"]["requests"] == 1
    assert restored["budget"]["reserved_usd"] == 0.3
    assert {:error, {:unresolved_effects, [_key]}} = Jobs.recover(rebuilt, job["id"], :owner)
    assert Scripted.requests(fresh) == []
    GenServer.stop(rebuilt)
  end

  test "the absolute job deadline stops work and survives recovery", context do
    owner = self()

    provider =
      Scripted.new([
        fn _ ->
          send(owner, :inference)
          Scripted.delayed(60_000, Scripted.complete("held"))
        end
      ])

    {:ok, manager} = host(context, provider)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive :inference
    id = job["id"]
    {:ok, _job} = Jobs.attach(manager, id, self(), :owner)
    past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601()

    {:ok, _record} =
      Journal.update(context.journal, "job-" <> id, &Map.put(&1, "deadline_at", past))

    send(manager, :poll)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "limited"}}}
    assert {:error, :not_interrupted} = Jobs.recover(manager, id, :owner)
    assert length(Scripted.requests(provider)) == 1
    GenServer.stop(manager)
  end

  defp intent(context, opts \\ []) do
    Map.merge(
      %{"prompt" => "fix the fixture", "cwd" => context.dir, "limits" => %{"max_requests" => 3}},
      Map.new(opts)
    )
  end

  test "intent is durable before dispatch; detach leaves the host owning execution", context do
    owner = self()

    provider =
      Scripted.new([
        fn _request ->
          send(owner, :dispatched)
          Scripted.delayed(60_000, Scripted.complete("done"))
        end
      ])

    {:ok, manager} = host(context, provider)
    assert {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert {:ok, record} = Journal.read(context.journal, "job-" <> job["id"])
    assert record.value["intent"]["prompt"] == "fix the fixture"
    assert_receive :dispatched
    assert {:ok, attached} = Jobs.attach(manager, job["id"], self(), :owner)
    assert attached["status"] == "running"
    assert :ok = Jobs.detach(manager, job["id"], self())
    assert {:error, :unauthorized} = Jobs.cancel(manager, job["id"], :stranger)
    assert :ok = Jobs.cancel(manager, job["id"], :owner)
    assert {:ok, cancelled} = Jobs.get(manager, job["id"], :owner)
    assert cancelled["status"] == "cancelled"
    GenServer.stop(manager)
  end

  @tag capture_log: true
  test "a completed provider receipt closes recovery without paying for another answer",
       context do
    paused =
      Map.put(
        context,
        :store,
        {PausedStore, %{store: context.store, owner: self(), pause_type: :assistant}}
      )

    provider =
      Scripted.new([Scripted.complete("already answered", usage: %{"cost_usd" => 0.1})],
        estimated_cost_usd: 0.1
      )

    {:ok, manager} = host(paused, provider)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    id = job["id"]
    {:ok, _job} = Jobs.attach(manager, id, self(), :owner)
    assert_receive {:before_result_append, session}
    Process.exit(session, :kill)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "interrupted"}}}
    GenServer.stop(manager)
    fresh = Scripted.new([])
    {:ok, rebuilt} = host(context, fresh)
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)

    assert_receive {:lemieux_job, ^id,
                    {:status,
                     %{"status" => "completed", "result" => %{"text" => "already answered"}}}}

    assert Scripted.requests(fresh) == []
    GenServer.stop(rebuilt)
  end

  test "interrupted preparation recovers the submitted intent without inventing a request",
       context do
    owner = self()

    factory = fn _job ->
      send(owner, {:preparing, self()})

      receive do
        :finish -> {:error, :unused}
      end
    end

    provider = Scripted.new([])
    {:ok, manager} = host(context, provider, factory: factory)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive {:preparing, preparation}
    monitor = Process.monitor(preparation)
    Process.unlink(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^preparation, _reason}
    fresh = Scripted.new([Scripted.complete("started from intent")])
    {:ok, rebuilt} = host(context, fresh)
    id = job["id"]
    {:ok, restored} = Jobs.attach(rebuilt, id, self(), :owner)
    assert restored["status"] == "interrupted"
    assert restored["budget"] == nil
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    [request] = Scripted.requests(fresh)

    assert Enum.any?(
             request.entries,
             &(&1.type == :user and &1.payload["text"] == "fix the fixture")
           )

    GenServer.stop(rebuilt)
  end

  test "a replacement child provider inherits the job journal and remaining allowance", context do
    owner = self()

    root_provider =
      Scripted.new(
        [
          fn _ ->
            send(owner, :root_running)
            Scripted.delayed(60_000, Scripted.complete("held"))
          end
        ],
        estimated_cost_usd: 0.1
      )

    {:ok, manager} = host(context, root_provider)

    {:ok, job} =
      Jobs.submit(manager, intent(context, [{"limits", %{"max_requests" => 2}}]), :owner)

    assert_receive :root_running
    {:ok, root} = Lemieux.session(context.runtime, job["session_id"])

    child_provider =
      Scripted.new(
        [
          Scripted.complete(
            JSON.encode!(%{
              "answer" => "child",
              "findings" => [],
              "artifacts" => [],
              "uncertainties" => [],
              "coverage" => %{"searched" => ["fixture"], "skipped" => []}
            }),
            usage: %{"cost_usd" => 0.01}
          )
        ],
        estimated_cost_usd: 0.01
      )

    definition =
      Definition.new(
        id: "scout",
        description: "Read only fixture",
        system_prompt: "Read only",
        model: "test:child",
        tools: [],
        max_cost_usd: 0.1
      )

    task = Lemieux.Subagent.Task.new(objective: "inspect", snapshot: %{"git_commit" => "fixture"})

    assert {:ok, child} =
             Lemieux.Subagent.spawn(root, definition, task,
               max_cost_usd: 0.1,
               providers: %{"scout" => child_provider},
               progress: [assess: false]
             )

    assert {:ok, _result} = Lemieux.Subagent.await(child)
    {:ok, snapshot} = Jobs.get(manager, job["id"], :owner)
    assert snapshot["budget"]["requests"] == 2
    assert child.id in snapshot["sessions"]
    {:ok, records} = Jobs.effects(manager, job["id"], nil, :owner)

    assert Enum.any?(
             records,
             &(&1.value["effect"]["session_id"] == child.id and &1.value["status"] == "completed")
           )

    assert :ok = Jobs.cancel(manager, job["id"], :owner)
    GenServer.stop(manager)
  end

  test "reused vendor call ids cannot consume another wave's completed receipt", context do
    tool = %HeldTool{owner: self(), class: "read"}

    provider =
      Scripted.new([
        Scripted.tool_call("same", "held", %{"wave" => 1}),
        Scripted.tool_call("same", "held", %{"wave" => 2})
      ])

    {:ok, manager} = host(context, provider, session_options: [tools: [tool]])
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive {:entered, first}
    send(first, :finish)
    assert_receive {:entered, _second}
    interrupt(context, manager, job)
    fresh = Scripted.new([Scripted.complete("done")])
    {:ok, rebuilt} = host(context, fresh, session_options: [tools: [tool]])
    id = job["id"]
    {:ok, _job} = Jobs.attach(rebuilt, id, self(), :owner)
    assert :ok = Jobs.recover(rebuilt, id, :owner)
    assert_receive {:entered, current}
    send(current, :finish)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    GenServer.stop(rebuilt)
  end

  test "auxiliary inference is charged and its receipt never becomes a conversation answer",
       context do
    owner = self()

    root_provider =
      Scripted.new(
        [
          fn _ ->
            send(owner, :root_running)
            Scripted.delayed(60_000, Scripted.complete("held"))
          end
        ],
        estimated_cost_usd: 0.1
      )

    {:ok, manager} = host(context, root_provider)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive :root_running
    {:ok, root} = Lemieux.session(context.runtime, job["session_id"])
    budget = Lemieux.Session.delegation_context(root).job_budget

    judge =
      Scripted.new([Scripted.complete("auxiliary-only", usage: %{"cost_usd" => 0.2})],
        estimated_cost_usd: 0.2
      )

    request = %Lemieux.Request{model: "test:judge", entries: [], tools: []}
    Lemieux.JobBudget.run(budget, judge, request, fn _event -> :ok end)
    {:ok, before_stop} = Jobs.get(manager, job["id"], :owner)
    assert before_stop["budget"]["requests"] == 2
    assert :ok = Jobs.cancel(manager, job["id"], :owner)
    {:ok, stored} = Journal.read(context.journal, "job-" <> job["id"])
    assert :ok = Recovery.repair(context.journal, stored.value, context.store)
    {:ok, entries} = Lemieux.Store.read(context.store, job["session_id"])

    refute Enum.any?(
             entries,
             &(&1.type == :assistant and
                 &1.payload["content"] == [%{"type" => "text", "text" => "auxiliary-only"}])
           )

    GenServer.stop(manager)
  end

  test "slow observers detach without acquiring ownership or cancelling the job", context do
    owner = self()

    provider =
      Scripted.new([
        fn _ ->
          send(owner, :running)
          Scripted.delayed(60_000, Scripted.complete("held"))
        end
      ])

    {:ok, manager} = host(context, provider, max_subscribers: 1)
    {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert_receive :running

    observer =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    id = job["id"]
    {:ok, _job} = Jobs.attach(manager, id, observer, :owner)
    assert {:error, :observer_limit} = Jobs.attach(manager, id, self(), :owner)
    Enum.each(1..300, &send(observer, {:queued, &1}))
    send(manager, {:lemieux, job["session_id"], {:text_delta, "fixture", "progress"}})
    assert {:ok, %{"status" => "running"}} = Jobs.get(manager, id, :owner)
    assert {:ok, _job} = Jobs.attach(manager, id, self(), :owner)
    monitor = Process.monitor(observer)
    send(observer, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}
    assert :ok = Jobs.cancel(manager, id, :owner)
    GenServer.stop(manager)
  end

  test "completed results survive a rebuilt host and never run again", context do
    provider = Scripted.new([Scripted.complete("reviewable", usage: %{"cost_usd" => 0.1})])
    {:ok, manager} = host(context, provider)
    assert {:ok, job} = Jobs.submit(manager, intent(context), :owner)
    assert {:ok, _job} = Jobs.attach(manager, job["id"], self(), :owner)
    id = job["id"]
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    GenServer.stop(manager)
    {:ok, rebuilt} = host(context, provider)
    assert {:ok, result} = Jobs.get(rebuilt, id, :owner)
    assert result["result"]["text"] == "reviewable"
    assert result["result"]["session_id"] == job["session_id"]
    assert length(Scripted.requests(provider)) == 1
    assert {:error, :not_interrupted} = Jobs.recover(rebuilt, id, :owner)
    GenServer.stop(rebuilt)
  end
end
