defmodule Lemieux.BackgroundCompletionTest do
  use ExUnit.Case, async: true
  alias Lemieux.A2A.Server, as: PeerServer
  alias Lemieux.Background
  alias Lemieux.Background.Completion
  alias Lemieux.CLI.Tasks
  alias Lemieux.Jobs
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.{Definition, Request, Task}
  alias Lemieux.Tool.Result
  @moduletag :tmp_dir

  defmodule Analysis do
    @behaviour Lemieux.Tool.Configured
    defstruct [:owner]
    @impl true
    def name(_), do: "analyze"
    @impl true
    def description(_), do: "A gated read-only analysis fixture"
    @impl true
    def schema(_), do: %{"type" => "object", "properties" => %{}}
    @impl true
    def read_only?(_), do: true
    @impl true
    def run(tool, _args, context) do
      {:ok, id} =
        Background.start(
          supervisor: context.supervisor,
          session_id: context.session_id,
          root_session_id: context.root_session_id,
          owner: context.session,
          command: "read-only analysis",
          cwd: context.cwd,
          environment: context.environment,
          runner: fn _, _ ->
            send(tool.owner, {:analysis, self(), context.session_id})

            receive do
              :finish -> {:ok, "COUNT=3", 0}
            after
              60_000 -> {:error, :fixture_held_too_long}
            end
          end
        )

      {:ok,
       Result.new("Started; yield until completion.",
         structured_content: %{"task_id" => id, "status" => "running"}
       )}
    end
  end

  setup %{tmp_dir: dir} do
    runtime = :"completion_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: Scripted.new([]),
        model: "test:parent",
        cwd: dir,
        tools: [],
        subscriber: self()
      )

    %{runtime: runtime, parent: parent, dir: dir}
  end

  defp spawn_child(ctx, limit \\ 5, turns \\ 10) do
    provider =
      Map.get_lazy(ctx, :provider, fn ->
        Scripted.new([
          Scripted.tool_call("analysis", "analyze", %{}),
          Scripted.complete("Waiting for analysis."),
          Scripted.complete(JSON.encode!(%{"answer" => "COUNT=3"}))
        ])
      end)

    definition =
      Definition.new(
        id: "analyst",
        description: "Analyze",
        system_prompt: "Analyze",
        model: "test:child",
        tools: [%Analysis{owner: self()}],
        max_requests: limit,
        max_turns: turns
      )

    request = Request.new(definition, Task.new(objective: "Analyze", snapshot: %{"version" => 1}))

    {:ok, group} =
      Subagent.spawn_many(ctx.parent, [request],
        max_cost_usd: 1,
        max_requests: 10,
        providers: %{"analyst" => provider},
        progress: Map.get(ctx, :progress, assess: false)
      )

    {:ok, [child]} = Subagent.children(group)
    assert_receive {:analysis, worker, child_id}
    assert child_id == child.id
    parent_id = Session.id(ctx.parent)

    assert_receive {:lemieux, ^parent_id,
                    {:subagent, [^parent_id, ^child_id], {:finished, :stop}}}

    # This call is serialized after the coordinator handles that first stop.
    assert {:ok, %{status: :running}} = Subagent.inspect(child)
    {group, child, worker, provider}
  end

  test "delegates wait without polling and expose their commands in the parent's native view",
       ctx do
    {group, child, worker, provider} = spawn_child(ctx)
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    assert row.managed? and row.running?
    assert row.owner_id == child.id
    assert row.label =~ "Delegate"
    send(worker, :finish)
    assert {:ok, %{results: [result]}} = Subagent.await(group, 5000)
    assert result.status == :ok
    assert result.answer == "COUNT=3"
    assert length(Scripted.requests(provider)) == 3
    request = List.last(Scripted.requests(provider))
    assert Enum.any?(request.entries, &(&1.type == :user and &1.payload["text"] =~ "COUNT=3"))
    assert {:ok, child_session} = Lemieux.session(ctx.runtime, child.id)
    assert Completion.settle(child_session) == :done
    assert length(Scripted.requests(provider)) == 3
  end

  test "the bounded session adapter returns the result after background completion", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("analysis", "analyze", %{}),
        Scripted.complete("Waiting for analysis."),
        Scripted.complete("COUNT=3")
      ])

    owner = self()

    attempt =
      Elixir.Task.async(fn ->
        Lemieux.Agent.run(
          Lemieux.Agent.Session,
          %{prompt: "Analyze", cwd: ctx.dir, timeout_ms: 60_000},
          supervisor: ctx.runtime,
          sessions_dir: Path.join(ctx.dir, "adapter-sessions"),
          provider: provider,
          model: "test:analyst",
          session_options: [tools: [%Analysis{owner: owner}], max_requests: 5]
        )
      end)

    assert_receive {:analysis, worker, _id}
    send(worker, :finish)
    assert {:ok, observation} = Elixir.Task.await(attempt)
    assert observation["answer"] == "COUNT=3"
    assert observation["tool_metrics"]["requests"] == 3
    assert length(Scripted.requests(provider)) == 3
  end

  test "two commands settle as one completion with both results", ctx do
    provider =
      Scripted.new([
        Scripted.tool_calls([
          %{id: "first", name: "analyze", arguments: %{}},
          %{id: "second", name: "analyze", arguments: %{}}
        ]),
        Scripted.complete("Waiting for both analyses."),
        fn request ->
          receipts =
            Enum.filter(request.entries, &(&1.type == :user and &1.payload["text"] =~ "COUNT=3"))

          assert [receipt] = receipts
          assert length(Regex.scan(~r/COUNT=3/, receipt.payload["text"])) == 2
          Scripted.complete(JSON.encode!(%{"answer" => "Both analyses completed"}))
        end
      ])

    {group, child, first, ^provider} = spawn_child(Map.put(ctx, :provider, provider))
    assert_receive {:analysis, second, child_id}
    assert child_id == child.id
    assert length(Background.list(ctx.runtime, child.id)) == 2
    send(first, :finish)
    send(second, :finish)

    assert {:ok, %{results: [%{answer: "Both analyses completed", status: :ok}]}} =
             Subagent.await(group, 5000)

    assert length(Scripted.requests(provider)) == 3
  end

  defp start_peer(ctx, limit \\ 5) do
    provider =
      Scripted.new([
        Scripted.tool_call("analysis", "analyze", %{}),
        Scripted.complete("Waiting for analysis."),
        Scripted.complete("COUNT=3")
      ])

    server =
      start_supervised!(
        {PeerServer,
         server_name: nil,
         supervisor: ctx.runtime,
         provider: provider,
         model: "test:peer",
         store: JSONL.new(Path.join(ctx.dir, "peer-private")),
         cwd: ctx.dir,
         max_requests: limit,
         tools: [%Analysis{owner: self()}]}
      )

    {server, provider}
  end

  test "A2A peers keep their bounded task open until background results arrive", ctx do
    {server, provider} = start_peer(ctx)
    request = Elixir.Task.async(fn -> PeerServer.ask("Analyze", server: server) end)
    assert_receive {:analysis, worker, _id}
    assert Elixir.Task.yield(request, 20) == nil
    send(worker, :finish)
    assert {:ok, task} = Elixir.Task.await(request)
    assert task.state == :completed
    assert Lemieux.A2A.Task.text(task) =~ "COUNT=3"
    assert length(Scripted.requests(provider)) == 3
  end

  test "A2A cancellation stops background work and revokes its continuation", ctx do
    {server, provider} = start_peer(ctx)
    request = Elixir.Task.async(fn -> PeerServer.ask("Analyze", server: server) end)
    assert_receive {:analysis, worker, id}
    monitor = Process.monitor(worker)
    assert {:ok, %{state: :canceled}} = PeerServer.cancel_task(id, server: server)
    assert {:ok, %{state: :canceled}} = Elixir.Task.await(request)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert length(Scripted.requests(provider)) <= 2
    assert Background.list(ctx.runtime, id) |> Enum.all?(&(&1.status != :running))
  end

  test "A2A completion cannot grow the peer's reserved request allowance", ctx do
    {server, provider} = start_peer(ctx, 2)
    request = Elixir.Task.async(fn -> PeerServer.ask("Analyze", server: server) end)
    assert_receive {:analysis, worker, _id}
    send(worker, :finish)
    assert {:ok, %{state: :failed}} = Elixir.Task.await(request)
    assert length(Scripted.requests(provider)) == 2
  end

  test "durable jobs await background results before recording completion", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("analysis", "analyze", %{}),
        Scripted.complete("Waiting for analysis."),
        Scripted.complete("COUNT=3")
      ])

    owner = self()
    store = JSONL.new(Path.join(ctx.dir, "job-sessions"))

    factory = fn _job ->
      {:ok,
       [provider: provider, model: "test:job", store: store, tools: [%Analysis{owner: owner}]]}
    end

    manager =
      start_supervised!(
        {Jobs,
         supervisor: ctx.runtime,
         journal: Files.new(Path.join(ctx.dir, "journal")),
         store: store,
         factory: factory,
         authorize: fn _, _, _ -> :ok end}
      )

    assert {:ok, job} =
             Jobs.submit(manager, %{
               "prompt" => "Analyze",
               "cwd" => ctx.dir,
               "limits" => %{"max_requests" => 5}
             })

    id = job["id"]
    assert {:ok, _} = Jobs.attach(manager, id)
    assert_receive {:analysis, worker, session_id}
    assert_receive {:lemieux_job, ^id, {:session, ^session_id, {:finished, :stop}}}
    assert {:ok, %{"status" => "running"}} = Jobs.get(manager, id)
    send(worker, :finish)
    assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"} = completed}}
    assert inspect(completed["result"]) =~ "COUNT=3"
    assert length(Scripted.requests(provider)) == 3
  end

  test "native cancellation revokes the child's continuation and settles the delegate", ctx do
    {group, _child, _worker, provider} = spawn_child(ctx)
    {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    assert :ok = Tasks.action(ctx.parent, row.id, :cancel)
    assert {:ok, %{results: [result]}} = Subagent.await(group, 5000)
    assert result.status == :cancelled
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{rows: [%{status: "cancelled"}]}} = Tasks.snapshot(ctx.parent)
  end

  test "completion cannot extend a child's request allowance", ctx do
    {group, _child, worker, provider} = spawn_child(ctx, 2)
    send(worker, :finish)
    assert {:ok, %{results: [result]}} = Subagent.await(group, 5000)
    assert result.status == :budget_exhausted
    assert length(Scripted.requests(provider)) == 2
  end

  test "group cancellation stops the waiting process and cannot resume it later", ctx do
    {group, child, worker, provider} = spawn_child(ctx)
    ref = Process.monitor(worker)
    assert :ok = Subagent.cancel(group, :test_cancel)
    assert {:ok, %{results: [%{status: :cancelled}]}} = Subagent.await(group, 5000)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert Background.list(ctx.runtime, child.id) |> Enum.all?(&(&1.status != :running))
    assert length(Scripted.requests(provider)) == 2
  end

  test "completion preserves the bounded assignment's turn limit", ctx do
    {group, _child, worker, provider} = spawn_child(ctx, 5, 2)
    send(worker, :finish)
    assert {:ok, %{results: [%{status: :failed}]}} = Subagent.await(group, 5000)
    assert length(Scripted.requests(provider)) == 2
  end

  test "a running background command does not spend a progress-judge request", ctx do
    {group, child, worker, provider} = spawn_child(Map.put(ctx, :progress, assess: :model))
    {:ok, coordinator} = Subagent.group(group)
    send(coordinator, {:child_clock, child.id})
    parent_id = Session.id(ctx.parent)
    child_id = child.id
    assert_receive {:lemieux, ^parent_id, {:subagent, [^parent_id], {:child_assessed, payload}}}
    assert payload["child_id"] == child_id
    assert payload["by"] == "activity"
    assert payload["note"] =~ "background command"
    assert length(Scripted.requests(provider)) == 2
    send(worker, :finish)
    assert {:ok, %{results: [%{status: :ok}]}} = Subagent.await(group, 5000)
  end
end
