defmodule Lemieux.A2A.ServerTest do
  use ExUnit.Case, async: true
  alias Lemieux.A2A.{Card, Handler, JSONRPC, Message, Server}
  alias Lemieux.A2A.Task, as: A2ATask
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    runtime = :"a2a_runtime_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, dir: dir}
  end

  defp server(context, script, extra \\ []) do
    provider = Scripted.new(script)

    opts = [
      server_name: nil,
      supervisor: context.runtime,
      provider: provider,
      model: "test:model",
      cwd: context.dir,
      store: JSONL.new(Path.join(context.dir, "private"))
    ]

    pid = start_supervised!({Server, Keyword.merge(opts, extra)})
    {pid, provider}
  end

  defp ask(pid, message, opts \\ []), do: Server.ask(message, Keyword.put(opts, :server, pid))

  defp immediate(pid, text, opts \\ []),
    do:
      Server.request(
        :send_message,
        %{"message" => Message.new(text), "configuration" => %{"returnImmediately" => true}},
        Keyword.put(opts, :server, pid)
      )

  defp question do
    [
      {:tool_call,
       %{
         id: "q1",
         name: "ask_user",
         arguments: %{
           "questions" => [
             %{"id" => "env", "question" => "Environment?", "type" => "text"},
             %{"id" => "release", "question" => "Release?", "type" => "text"}
           ]
         }
       }},
      {:done, :tool_calls}
    ]
  end

  defp waiting(context),
    do:
      server(context, [question(), Scripted.complete("continued")],
        tools: [Lemieux.Tools.Read, Lemieux.Tools.AskUser]
      )

  test "capabilities are filtered after resolving the harness; host tools, MCP and entries cannot widen them",
       context do
    {pid, provider} =
      server(context, [Scripted.complete("safe")],
        harness: %Lemieux.Harness{tools: []},
        host_tools: [Lemieux.Tools.Write],
        mcp_servers: [%{"invalid" => true}],
        entries: [Lemieux.Entry.new(:user, %{"text" => "private operator conversation"})],
        system: "private operator system"
      )

    assert {:ok, task} = ask(pid, "fresh peer question")
    assert task.state == :completed
    [request] = Scripted.requests(provider)
    assert request.tools == []
    refute inspect(request.entries) =~ "private operator"
    # The server stops the task's session before it answers, but the registry
    # drops the name only once it has seen the exit; on a slow runner the
    # lookup came first and found the pid (CI, Elixir floor, 2026-10-06).
    :ok = LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), task.id)
    assert :error = Lemieux.session(context.runtime, task.id)
  end

  test "write tools are removed even when supplied directly", context do
    {pid, provider} =
      server(context, [Scripted.complete("safe")],
        tools: [Lemieux.Tools.Read, Lemieux.Tools.Write, Lemieux.Tools.Bash]
      )

    assert {:ok, _} = ask(pid, "hello")
    assert Enum.map(hd(Scripted.requests(provider)).tools, &Lemieux.Tool.name/1) == ["read"]
  end

  test "unknown and finished task ids never create sessions", context do
    {pid, provider} = server(context, [Scripted.complete("done")])
    assert {:ok, task} = ask(pid, "hello")

    assert {:error, error} =
             ask(pid, %{"taskId" => "missing", "parts" => [%{"text" => "continue"}]})

    assert error =~ "TaskNotFound"

    assert {:error, error} =
             ask(pid, %{"taskId" => task.id, "parts" => [%{"text" => "continue"}]})

    assert error =~ "UnsupportedOperation"
    assert length(Scripted.requests(provider)) == 1
    assert Process.alive?(pid)
  end

  test "cancellation immediately closes a parked question and a late reply cannot crash the server",
       context do
    {pid, _provider} = waiting(context)
    assert {:ok, task} = ask(pid, "ask questions")
    assert task.state == :input_required
    assert {:ok, canceled} = Server.cancel_task(task.id, server: pid)
    assert canceled.state == :canceled
    assert {:error, _} = ask(pid, %{"taskId" => task.id, "parts" => [%{"text" => "late"}]})
    assert {:error, error} = Server.cancel_task(task.id, server: pid)
    assert error =~ "TaskNotCancelable"
    assert Process.alive?(pid)
    assert :sys.get_state(pid).tasks[task.id].awaiting == nil
  end

  test "full questionnaires survive transport and invalid replies leave the task awaiting",
       context do
    {pid, _provider} = waiting(context)
    assert {:ok, task} = ask(pid, "ask questions")

    [%{"text" => "Environment?"}, %{"data" => data}] =
      A2ATask.to_json(task)["status"]["message"]["parts"]

    assert length(data["questions"]) == 2
    assert {:error, _} = ask(pid, %{"taskId" => task.id, "parts" => [%{"text" => "production"}]})
    assert {:ok, still_waiting} = Server.get_task(task.id, server: pid)
    assert still_waiting.state == :input_required

    assert {:ok, done} =
             ask(pid, %{
               "taskId" => task.id,
               "parts" => [
                 %{"data" => %{"answers" => [%{"text" => "production"}, %{"text" => "v2"}]}}
               ]
             })

    assert done.state == :completed
    assert done.message == nil
    assert A2ATask.text(done) == "continued"
  end

  test "ownership covers get, cancel, continuation and listing", context do
    {pid, _} = waiting(context)
    assert {:ok, task} = ask(pid, "ask", principal: "alice")

    for operation <- [:get_task, :cancel_task, :subscribe_to_task] do
      assert {:error, "TaskNotFound", _} =
               Server.request(operation, %{"id" => task.id},
                 server: pid,
                 principal: "bob",
                 stream: self()
               )
    end

    assert {:error, _} =
             ask(pid, %{"taskId" => task.id, "parts" => [%{"text" => "steal"}]}, principal: "bob")

    assert {:ok, %{"tasks" => []}} = Server.list_tasks(%{}, server: pid, principal: "bob")
    assert {:ok, %{"tasks" => [json]}} = Server.list_tasks(%{}, server: pid, principal: "alice")
    assert json["id"] == task.id
  end

  test "execution deadlines finish tasks after the caller detaches", context do
    {pid, _} =
      server(context, [[{:delay, 200}, {:text_delta, "late"}, {:done, :stop}]],
        task_timeout_ms: 30
      )

    assert {:ok, task} = immediate(pid, "hello", stream: self())
    assert_receive {:a2a, id, {:status, %A2ATask{state: :working}}}
    assert id == task.id
    assert_receive {:a2a, ^id, {:status, %A2ATask{state: :failed, message: message}}}
    assert message =~ "deadline"
    assert {:ok, %A2ATask{state: :failed}} = Server.get_task(id, server: pid)
  end

  test "unexpected session death becomes failure", context do
    {pid, _} = server(context, [[{:delay, 500}, {:done, :stop}]])
    assert {:ok, task} = immediate(pid, "hello", stream: self())
    session = :sys.get_state(pid).tasks[task.id].session
    Process.exit(session, :kill)
    assert_receive {:a2a, id, {:status, %A2ATask{state: :failed}}}
    assert id == task.id
    assert Process.alive?(pid)
  end

  test "multiple subscribers receive updates and disconnect cleanly", context do
    {pid, _} = server(context, [[{:delay, 100}, {:text_delta, "hello"}, {:done, :stop}]])
    assert {:ok, task} = immediate(pid, "hello", stream: self())
    parent = self()

    watcher =
      spawn(fn ->
        receive do
          event -> send(parent, {:watcher, event})
        end
      end)

    assert {:ok, _} = Server.subscribe(task.id, watcher, server: pid)
    assert_receive {:watcher, {:a2a, _, {:status, _}}}
    assert {:ok, _} = Server.subscribe(task.id, self(), server: pid)
    assert_receive {:a2a, _, {:delta, "hello"}}
    assert_receive {:a2a, _, {:status, %A2ATask{state: :completed}}}
    assert :sys.get_state(pid).tasks[task.id].watchers == %{}
  end

  test "admission, output and request allowances are enforced", context do
    {pid, _} =
      server(context, [[{:delay, 50}, {:text_delta, "too much output"}, {:done, :stop}]],
        max_concurrency: 1,
        max_total_requests: 8,
        max_output_bytes: 5
      )

    assert {:ok, task} = immediate(pid, "hello", stream: self())
    assert {:error, "UnsupportedOperation", _} = immediate(pid, "second")
    assert_receive {:a2a, _, {:status, %A2ATask{state: :failed}}}
    assert {:error, "UnsupportedOperation", error} = immediate(pid, "third")
    assert error =~ "allowance"
    assert {:ok, %A2ATask{state: :failed}} = Server.get_task(task.id, server: pid)
  end

  test "journal recovery preserves ownership and fails lost executions without replay", context do
    directory = Path.join(context.dir, "journal")

    {pid, provider} =
      server(context, [[{:delay, 500}, {:done, :stop}]],
        task_directory: directory,
        max_total_requests: 8
      )

    assert {:ok, task} = immediate(pid, "hello", principal: "alice")
    GenServer.stop(pid)
    stop_supervised(Server)

    {recovered, _} =
      server(context, [Scripted.complete("must not replay")],
        task_directory: directory,
        max_total_requests: 8
      )

    assert {:ok, failed} = Server.get_task(task.id, server: recovered, principal: "alice")
    assert failed.state == :failed
    assert failed.message =~ "restart"
    assert {:error, _} = Server.get_task(task.id, server: recovered, principal: "bob")
    assert {:error, "UnsupportedOperation", _} = immediate(recovered, "new task")
    assert length(Scripted.requests(provider)) <= 1
    assert Bitwise.band(File.stat!(Path.join(directory, "tasks.json")).mode, 0o777) == 0o600
  end

  test "retention prunes results and frees task slots", context do
    {pid, _} =
      server(context, [Scripted.complete("one"), Scripted.complete("two")],
        max_tasks: 1,
        retention_ms: 1
      )

    assert {:ok, first} = ask(pid, "one")
    Process.sleep(5)
    assert {:error, _} = Server.get_task(first.id, server: pid)
    assert {:ok, second} = ask(pid, "two")
    refute second.id == first.id
  end

  test "private paths and symlink aliases are blocked while source can be read", context do
    File.write!(Path.join(context.dir, ".env"), "secret")
    File.ln_s!(".env", Path.join(context.dir, "alias"))
    File.write!(Path.join(context.dir, "public.ex"), "source")
    {pid, _} = server(context, [])
    env = :sys.get_state(pid).session_opts[:environment]
    assert {:error, :data_scope_denied} = Lemieux.Environment.read_file(env, context.dir, ".env")
    assert {:error, :data_scope_denied} = Lemieux.Environment.read_file(env, context.dir, "alias")
    assert {:ok, "source"} = Lemieux.Environment.read_file(env, context.dir, "public.ex")
    assert {:error, :read_only} = Lemieux.Environment.write_file(env, context.dir, "new", "bad")
    assert {:error, :read_only} = Lemieux.Environment.run(env, "touch bad", [])
  end

  test "host adapter requires authentication, handles versions and unsupported capabilities",
       context do
    {pid, _} = server(context, [Scripted.complete("done")])

    body =
      JSONRPC.request(:send_message, %{"message" => Message.new("hello")}, "1")
      |> JSONRPC.encode()

    assert Handler.dispatch(body, server: pid)["error"]["code"] == -32_600

    assert Handler.dispatch(body, server: pid, principal: "alice", version: "0.3")["error"][
             "code"
           ] == -32_009

    assert Handler.dispatch(body, server: pid, principal: "alice")["result"]["task"]["status"][
             "state"
           ] == "TASK_STATE_COMPLETED"

    body = JSONRPC.request(:get_extended_agent_card, %{}, "2") |> JSONRPC.encode()
    assert Handler.dispatch(body, server: pid, principal: "alice")["error"]["code"] == -32_007
  end

  test "cards omit operator route and absolute paths and have valid defaults", context do
    {pid, _} = server(context, [], harness: %Lemieux.Harness{tools: []})
    assert {:ok, card} = Server.card(server: pid)
    assert is_binary(card.name)
    assert card.skills == []
    encoded = Card.to_json(card) |> JSON.encode!()
    refute encoded =~ context.dir
    refute encoded =~ "test:model"
  end

  test "usage reports preserve unknown cost and disclose missing measurements", context do
    {pid, _} =
      server(context, [
        Scripted.complete("reported",
          usage: %{input_tokens: 10, output_tokens: 2, cost_usd: 0.1}
        ),
        Scripted.complete("unmeasured")
      ])

    assert {:ok, measured} = ask(pid, "one")
    assert measured.metadata["lemieux"]["usage"]["cost_usd"] == 0.1
    assert measured.metadata["lemieux"]["requests_started"] == 1
    assert measured.metadata["lemieux"]["usage_complete"] == true
    assert {:ok, unknown} = ask(pid, "two")
    assert unknown.metadata["lemieux"]["usage"]["cost_usd"] == nil
    assert unknown.metadata["lemieux"]["usage_complete"] == false
  end

  test "list pagination, history and artifact projection follow protocol defaults", context do
    {pid, _} = server(context, [Scripted.complete("one"), Scripted.complete("two")])
    assert {:ok, one} = ask(pid, "one")
    assert {:ok, two} = ask(pid, "two")
    assert {:ok, page} = Server.list_tasks(%{"pageSize" => 1, "historyLength" => 0}, server: pid)
    [first] = page["tasks"]
    assert first["artifacts"] == []
    assert first["history"] == []
    assert page["nextPageToken"] != ""

    assert {:ok, next} =
             Server.list_tasks(
               %{
                 "pageSize" => 1,
                 "pageToken" => page["nextPageToken"],
                 "includeArtifacts" => true
               },
               server: pid
             )

    [last] = next["tasks"]
    assert Enum.sort([first["id"], last["id"]]) == Enum.sort([one.id, two.id])
    assert last["artifacts"] != []
    assert next["nextPageToken"] == ""
    assert {:error, error} = Server.subscribe(two.id, self(), server: pid)
    assert error =~ "UnsupportedOperation"

    assert {:ok, %{"tasks" => []}} =
             Server.list_tasks(%{"statusTimestampAfter" => "2999-01-01T00:00:00Z"}, server: pid)
  end

  test "host streaming prepares a snapshot and removes subscriptions on disconnect", context do
    {pid, _} = server(context, [[{:delay, 100}, {:text_delta, "answer"}, {:done, :stop}]])

    body =
      JSONRPC.request(:send_streaming_message, %{"message" => Message.new("hello")}, "stream")
      |> JSONRPC.encode()

    envelope = Handler.open_stream(body, server: pid, principal: "host")
    id = envelope["result"]["task"]["id"]
    assert is_binary(id)
    assert map_size(:sys.get_state(pid).tasks[id].watchers) == 1
    assert {:ok, _} = Handler.close_stream(id, server: pid, principal: "host")
    assert :sys.get_state(pid).tasks[id].watchers == %{}
    assert {:ok, canceled} = Server.cancel_task(id, server: pid, principal: "host")
    assert canceled.state == :canceled
  end

  test "read allowlists are rooted and directory discovery cannot reveal excluded files",
       context do
    File.mkdir_p!(Path.join(context.dir, "lib"))
    File.mkdir_p!(Path.join(context.dir, "private/lib"))
    File.write!(Path.join(context.dir, "lib/public.ex"), "source")
    File.write!(Path.join(context.dir, "private/lib/private.ex"), "private")
    {pid, _} = server(context, [], read_paths: ["lib/**"])
    env = :sys.get_state(pid).session_opts[:environment]
    assert {:ok, "source"} = Lemieux.Environment.read_file(env, context.dir, "lib/public.ex")

    assert {:error, :data_scope_denied} =
             Lemieux.Environment.read_file(env, context.dir, "private/lib/private.ex")

    assert {:ok, entries} = Lemieux.Environment.list_dir(env, context.dir, ".")
    assert Enum.map(entries, & &1.name) == ["lib"]
    assert {:ok, entries} = Lemieux.Environment.list_dir(env, context.dir, "lib")
    assert Enum.map(entries, & &1.name) == ["public.ex"]
  end

  test "cards follow profile and disabled tool restrictions", context do
    {pid, provider} = server(context, [Scripted.complete("hello")], disabled_tools: ["read"])
    assert {:ok, card} = Server.card(server: pid)
    assert card.skills == []
    assert {:ok, _} = ask(pid, "hello")
    assert hd(Scripted.requests(provider)).tools == []
  end

  # `Lemieux.start_session/1` raises in its caller for these, and a server's
  # caller is its own handle_call: mounted without a model, it used to die on
  # every remote ask. A configuration mistake stops the child at mount instead.
  test "a server whose task sessions could not start refuses to mount", context do
    base = [
      server_name: nil,
      supervisor: context.runtime,
      provider: Scripted.new([]),
      model: "test:model",
      cwd: context.dir,
      store: JSONL.new(Path.join(context.dir, "private"))
    ]

    for {key, value} <- [model: nil, provider: nil, provider: Scripted, store: JSONL] do
      opts = Keyword.put(base, key, value)

      assert {:error, {{:invalid_session_options, ^key}, _child}} =
               start_supervised({Server, opts}, id: {key, value})
    end

    assert {:ok, _pid} = start_supervised({Server, base}, id: :valid)
  end
end
