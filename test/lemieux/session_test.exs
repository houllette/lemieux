defmodule Lemieux.SessionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Receipt
  alias Lemieux.Tool.Result, as: ToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_session_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts \\ []) do
    {estimated_cost_usd, opts} = Keyword.pop(opts, :estimated_cost_usd)
    provider = Scripted.new(script, estimated_cost_usd: estimated_cost_usd)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self()
        ] ++ opts
      )

    {session, provider}
  end

  defp forward_events(parent) do
    receive do
      message ->
        send(parent, {:forwarded, message})
        forward_events(parent)
    end
  end

  test "a request allowance spans prompts and restored sessions", context do
    {session, provider} = start_session(context, [Scripted.complete("done")], max_requests: 1)
    id = Session.id(session)
    :ok = Session.prompt(session, "first")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = Session.prompt(session, "second")

    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests, spent: 1, cap: 1}}}}

    assert length(Scripted.requests(provider)) == 1

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(context.runtime),
      session
    )

    fresh = Scripted.new([Scripted.complete("must not dispatch")])

    {:ok, restored} =
      Lemieux.resume_session(
        supervisor: context.runtime,
        provider: fresh,
        store: context.store,
        resume: id,
        subscriber: self(),
        max_requests: 1
      )

    :ok = Session.prompt(restored, "third")

    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests, spent: 1, cap: 1}}}}

    assert Scripted.requests(fresh) == []
  end

  describe "prompt/2" do
    test "streams deltas to the subscriber and persists user and assistant entries", context do
      {session, _provider} =
        start_session(context, [[{:text_delta, "he"}, {:text_delta, "llo"}, {:done, :stop}]])

      id = Session.id(session)

      :ok = Session.prompt(session, "say hi")

      assert_receive {:lemieux, ^id,
                      {:entry, %Entry{type: :user, payload: %{"text" => "say hi"}}}}

      assert_receive {:lemieux, ^id, {:text_delta, %{id: entry_id, text: "he"}}}
      assert_receive {:lemieux, ^id, {:text_delta, %{id: ^entry_id, text: "llo"}}}
      assert_receive {:lemieux, ^id, {:entry, %Entry{id: ^entry_id, type: :assistant}}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert {:ok, [_config, user, harness, request, assistant, evidence]} =
               Store.read(context.store, id)

      assert user.type == :user
      assert harness.type == :harness_snapshot
      assert request.type == :request
      assert assistant.type == :assistant
      assert evidence.type == :run_evidence
      assert harness.parent_id == user.id
      assert request.parent_id == harness.id
      assert assistant.parent_id == request.id
      assert evidence.parent_id == assistant.id
      assert assistant.payload["content"] == [%{"type" => "text", "text" => "hello"}]
      assert assistant.payload["request_id"] == request.payload["id"]
    end

    test "sends the transcript so far as the request", context do
      {session, provider} = start_session(context, [[{:done, :stop}]])
      :ok = Session.prompt(session, "say hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{model: "test:model", entries: [_config, entry]}] =
               Scripted.requests(provider)

      assert entry.type == :user
      assert entry.payload == %{"text" => "say hi"}
    end

    test "carries the system prompt on every request", context do
      {session, provider} = start_session(context, [[{:done, :stop}]], system: "be terse")
      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{system: "be terse"}] = Scripted.requests(provider)
    end

    test "a prepare_next_turn hook can customize the request before dispatch", context do
      hook = fn request, hook_context ->
        assert hook_context.session_id

        {:ok,
         %{
           request
           | system: request.system <> "\nFresh host context.",
             params: Keyword.put(request.params, :temperature, 0.2)
         }}
      end

      {session, provider} =
        start_session(context, [[{:done, :stop}]], hooks: [prepare_next_turn: hook])

      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{system: system, params: params}] = Scripted.requests(provider)
      assert String.ends_with?(system, "Fresh host context.")
      assert params[:temperature] == 0.2
    end

    test "a second prompt carries the first exchange", context do
      {session, provider} =
        start_session(context, [
          [{:text_delta, "one"}, {:done, :stop}],
          [{:text_delta, "two"}, {:done, :stop}]
        ])

      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, :stop}}
      :ok = Session.prompt(session, "second")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert Enum.map(entries, & &1.type) == [:session, :user, :request, :assistant, :user]
    end

    test "is refused while a turn is running", context do
      # A scripted turn that blocks until it is told to finish: whether a
      # normal turn is still open by the time the second prompt lands is a
      # race, and a test that races is a test that flakes.
      parent = self()

      {session, _provider} =
        start_session(context, [
          fn _request ->
            send(parent, {:streaming, self()})

            receive do
              :release -> [{:done, :stop}]
            end
          end
        ])

      :ok = Session.prompt(session, "first")
      assert_receive {:streaming, provider_task}

      assert Session.prompt(session, "second") == {:error, :busy}

      send(provider_task, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}
    end

    test "records usage on the assistant entry", context do
      usage = %{"input_tokens" => 11, "output_tokens" => 2}

      {session, _provider} =
        start_session(context, [[{:text_delta, "hi"}, {:usage, usage}, {:done, :stop}]])

      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{} = assistant = Enum.find(entries, &(&1.type == :assistant))

      assert assistant.usage["input_tokens"] == 11
      assert assistant.usage["output_tokens"] == 2
      assert assistant.usage["cache_read_tokens"] == 0
      assert assistant.usage["cache_write_tokens"] == 0
      assert assistant.usage["cost_usd"] == nil
      assert assistant.usage["model"] == "test:model"
    end
  end

  describe "subscribers" do
    test "a host may attach and detach another watcher without restarting the session", context do
      parent = self()
      watcher = spawn(fn -> forward_events(parent) end)

      {session, _provider} =
        start_session(context, [
          [{:text_delta, "first"}, {:done, :stop}],
          [{:text_delta, "second"}, {:done, :stop}]
        ])

      id = Session.id(session)
      assert :ok = Session.subscribe(session, watcher)
      assert :ok = Session.subscribe(session, watcher)

      assert :ok = Session.prompt(session, "one")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert_receive {:forwarded, {:lemieux, ^id, {:finished, :stop}}}

      assert :ok = Session.unsubscribe(session, watcher)
      assert :ok = Session.unsubscribe(session, watcher)

      assert :ok = Session.prompt(session, "two")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      refute_receive {:forwarded, {:lemieux, ^id, {:text_delta, %{text: "second"}}}}
      refute_receive {:forwarded, {:lemieux, ^id, {:finished, :stop}}}
    end

    test "subscriber accepts several initial watcher pids", context do
      parent = self()
      watcher = spawn(fn -> forward_events(parent) end)
      provider = Scripted.new([[{:done, :stop}]])

      assert {:ok, session} =
               Lemieux.start_session(
                 supervisor: context.runtime,
                 provider: provider,
                 store: context.store,
                 model: "test:model",
                 subscriber: [self(), watcher]
               )

      id = Session.id(session)
      assert :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, ^id, {:finished, :stop}}
      assert_receive {:forwarded, {:lemieux, ^id, {:finished, :stop}}}
    end

    test "a dead watcher is discarded without stopping the session", context do
      watcher = spawn(fn -> receive do: (:stop -> :ok) end)
      {session, _provider} = start_session(context, [])

      assert :ok = Session.subscribe(session, watcher)
      assert Map.has_key?(:sys.get_state(session).subscribers.refs, watcher)

      Process.exit(watcher, :kill)

      LemieuxTest.Sync.state(session, fn state ->
        not MapSet.member?(state.subscribers.pids, watcher)
      end)

      state = :sys.get_state(session)
      refute Map.has_key?(state.subscribers.refs, watcher)
      assert Process.alive?(session)
    end
  end

  describe "tool receipts" do
    defmodule Remote do
      @moduledoc false
      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "remote"
      @impl Lemieux.Tool
      def description, do: "Sends something that cannot be unsent."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{"do" => %{"type" => "string"}}}
      @impl Lemieux.Tool
      def metadata, do: %{"effects" => %{"class" => "external"}}

      @impl Lemieux.Tool
      def run(%{"do" => "crash"}, _context), do: raise("the wire dropped")

      def run(%{"do" => "receipt then crash"}, context) do
        :ok = Receipt.record(context, %{"id" => "msg_123"})
        raise("lost after sending")
      end

      def run(%{"do" => "receipt"}, context) do
        :ok = Receipt.record(context, %{"id" => "msg_123"})
        {:ok, "sent"}
      end

      def run(%{"do" => "hang"}, _context), do: receive(do: (:stop -> :ok))
    end

    defp remote(id, action), do: %{id: id, name: "remote", arguments: %{"do" => action}}

    defp remote_result(context, session) do
      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      payload
    end

    @tag :capture_log
    test "a crash after an external effect is an unknown outcome, not a failure to repeat",
         context do
      {session, provider} =
        start_session(
          context,
          [[{:tool_call, remote("t1", "crash")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Remote]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      payload = remote_result(context, session)
      assert payload["outcome"] == "unknown"
      assert payload["error"] == true
      assert payload["output"] =~ "the wire dropped"
      assert payload["output"] =~ "may have happened"
      assert payload["receipt"] == %{"lost" => "crashed"}

      # And that is what the model reads on the next request.
      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert Enum.any?(entries, &(&1.type == :tool_result and &1.payload["outcome"] == "unknown"))
    end

    test "a receipt the tool recorded is announced and travels with its result", context do
      {session, _provider} =
        start_session(
          context,
          [[{:tool_call, remote("t1", "receipt")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Remote]
        )

      :ok = Session.prompt(session, "go")

      assert_receive {:lemieux, _,
                      {:tool_receipt,
                       %{call_id: "t1", name: "remote", receipt: %{"id" => "msg_123"}}}}

      assert_receive {:lemieux, _, {:finished, :stop}}

      payload = remote_result(context, session)
      assert payload["outcome"] == "success"
      assert payload["output"] == "sent"
      assert payload["receipt"] == %{"reported" => %{"id" => "msg_123"}}
    end

    @tag :capture_log
    test "a receipt survives the crash that followed it", context do
      {session, _provider} =
        start_session(
          context,
          [
            [{:tool_call, remote("t1", "receipt then crash")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          tools: [Remote]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      payload = remote_result(context, session)
      assert payload["outcome"] == "unknown"
      assert payload["output"] =~ "lost after sending"
      assert payload["output"] =~ ~s({"id":"msg_123"})
      assert payload["receipt"] == %{"reported" => %{"id" => "msg_123"}, "lost" => "crashed"}
    end

    test "cancelling an external tool leaves its outcome unknown", context do
      {session, _provider} =
        start_session(
          context,
          [[{:tool_call, remote("t1", "hang")}, {:done, :tool_calls}]],
          tools: [Remote]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:tool_call, %{id: "t1"}}}
      :ok = Session.cancel(session)
      assert_receive {:lemieux, _, {:finished, :cancelled}}

      payload = remote_result(context, session)
      assert payload["outcome"] == "unknown"
      assert payload["output"] =~ "cancelled before the tool completed"
      assert payload["output"] =~ "may have happened"
      assert payload["receipt"] == %{"lost" => "cancelled"}
    end

    # The transcript a dead process leaves behind: the model asked for a
    # tool and nothing answered. Before this, resuming it produced a request
    # every provider refuses.
    test "a call the session died before answering is answered as unknown on resume",
         context do
      id = Lemieux.ID.generate()

      :ok =
        Store.append(context.store, id, [
          Entry.new(:user, %{"text" => "send it"}),
          Entry.new(:assistant, %{
            "content" => [],
            "tool_calls" => [%{"id" => "t1", "name" => "remote", "arguments" => %{"do" => "x"}}]
          })
        ])

      provider = Scripted.new([[{:done, :stop}]])

      {:ok, resumed} =
        Lemieux.resume_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          resume: id,
          subscriber: self(),
          tools: [Remote],
          model: "test:model"
        )

      :ok = Session.prompt(resumed, "again")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [%Request{entries: sent}] = Scripted.requests(provider)
      types = Enum.map(sent, & &1.type)
      assert [:user, :assistant, :tool_result | _rest] = types
      assert %Entry{payload: payload} = Enum.find(sent, &(&1.type == :tool_result))
      assert payload["call_id"] == "t1"
      assert payload["outcome"] == "unknown"
      assert payload["output"] =~ "the session ended before this tool reported a result"
      assert payload["output"] =~ "may have happened"
      assert payload["receipt"] == %{"lost" => "session_ended"}

      # Answered once: a second resume finds nothing left to answer.
      assert {:ok, stored} = Store.read(context.store, id)
      assert Lemieux.Transcript.unanswered_calls(stored) == []
      assert Enum.count(stored, &(&1.type == :tool_result)) == 1
    end
  end

  describe "the tool loop" do
    defmodule Echo do
      @moduledoc false
      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "echo"
      @impl Lemieux.Tool
      def description, do: "Echoes what it is given."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{"say" => %{"type" => "string"}}}

      @impl Lemieux.Tool
      def run(%{"say" => "boom"}, _context), do: raise("the tool exploded")
      def run(%{"say" => "no"}, _context), do: {:error, "refused to say no"}
      def run(%{"say" => say}, _context), do: {:ok, "echo: #{say}"}
    end

    defmodule Rich do
      @moduledoc false
      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "rich"
      @impl Lemieux.Tool
      def description, do: "Returns a structured result."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object"}

      @impl Lemieux.Tool
      def run(_arguments, _context) do
        {:ok,
         ToolResult.new("two records",
           structured_content: %{"records" => [%{"id" => 1}, %{"id" => 2}]},
           content: [%{"type" => "resource_link", "uri" => "record://1"}],
           artifacts: [%{"uri" => "artifact://records.json"}],
           cost: %{"usd" => 0.02}
         )}
      end
    end

    defmodule Slow do
      @moduledoc false
      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "slow"
      @impl Lemieux.Tool
      def description, do: "Never finishes on its own."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object"}
      @impl Lemieux.Tool
      def run(_arguments, _context), do: receive(do: (:stop -> :ok))
    end

    defmodule ResourceTool do
      @moduledoc false
      defstruct [:name, :owner]

      def name(%__MODULE__{name: name}), do: name
      def description(%__MODULE__{name: name}), do: "Runs #{name}."
      def schema(%__MODULE__{}), do: %{"type" => "object"}

      def run(%__MODULE__{name: name, owner: owner}, _arguments, _context) do
        send(owner, {:resource_started, name, self()})

        receive do
          :release -> {:ok, "finished #{name}"}
        end
      end
    end

    defp call(id, say), do: %{id: id, name: "echo", arguments: %{"say" => say}}

    test "a tool_call is executed and the next request carries its result", context do
      {session, provider} =
        start_session(
          context,
          [
            [{:tool_call, call("t1", "hello")}, {:done, :tool_calls}],
            [{:text_delta, "it said hello"}, {:done, :stop}]
          ],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)

      assert Enum.map(entries, & &1.type) == [
               :session,
               :user,
               :request,
               :assistant,
               :tool_result
             ]

      assert %Entry{type: :tool_result, payload: payload} = List.last(entries)
      assert payload["call_id"] == "t1"
      assert payload["name"] == "echo"
      assert payload["output"] == "echo: hello"
      assert payload["error"] == false
      assert is_integer(payload["duration_ms"])
      assert payload["duration_ms"] >= 0
    end

    test "the assistant entry records the calls it made", context do
      {session, _provider} =
        start_session(
          context,
          [[{:tool_call, call("t1", "hi")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{} = assistant = Enum.find(entries, &(&1.type == :assistant))

      assert assistant.payload["tool_calls"] == [
               %{"id" => "t1", "name" => "echo", "arguments" => %{"say" => "hi"}}
             ]
    end

    test "every call in a wave is answered before the next request", context do
      {session, provider} =
        start_session(
          context,
          [
            [
              {:tool_call, call("t1", "one")},
              {:tool_call, call("t2", "two")},
              {:tool_call, call("t3", "three")},
              {:done, :tool_calls}
            ],
            [{:done, :stop}]
          ],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      results = Enum.filter(entries, &(&1.type == :tool_result))

      # In call order, not completion order: a transcript that reorders them
      # stops matching the assistant turn that asked for them.
      assert Enum.map(results, & &1.payload["call_id"]) == ["t1", "t2", "t3"]

      assert Enum.map(results, & &1.payload["output"]) == [
               "echo: one",
               "echo: two",
               "echo: three"
             ]
    end

    test "a tool that returns an error is a result the model reads", context do
      {session, provider} =
        start_session(
          context,
          [[{:tool_call, call("t1", "no")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "refused to say no"
      assert payload["error"] == true
    end

    test "a structured result is audited without changing the provider-facing text", context do
      {session, provider} =
        start_session(
          context,
          [
            [{:tool_call, %{id: "t1", name: "rich", arguments: %{}}}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          tools: [Rich],
          hooks: [
            before_tool_call: fn _call, hook_context ->
              assert hook_context.tool_descriptor["identity"]["canonical_name"] == "host/rich"
              :allow
            end
          ]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "two records"
      assert payload["structured_content"]["records"] == [%{"id" => 1}, %{"id" => 2}]
      assert payload["content"] == [%{"type" => "resource_link", "uri" => "record://1"}]
      assert payload["artifacts"] == [%{"uri" => "artifact://records.json"}]
      assert payload["cost"] == %{"usd" => 0.02}
      assert payload["outcome"] == "success"
      assert byte_size(payload["descriptor_digest"]) == 64
    end

    test "the execution envelope stops a tool at its declared deadline", context do
      slow = Descriptor.new(Slow, runtime: %{"timeout_ms" => 20})

      {session, provider} =
        start_session(
          context,
          [
            [{:tool_call, %{id: "t1", name: "slow", arguments: %{}}}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          tools: [slow]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["error"] == true
      assert payload["outcome"] == "timeout"
      assert payload["output"] =~ "20ms deadline"
    end

    test "resource-keyed calls overlap across resources but serialize within one", context do
      resource = fn name, key ->
        Descriptor.new(%ResourceTool{name: name, owner: self()},
          identity: %{"namespace" => "test"},
          runtime: %{
            "timeout_ms" => 1_000,
            "concurrency" => %{"class" => "resource", "resource_key" => key}
          }
        )
      end

      calls = [
        {:tool_call, %{id: "t1", name: "alpha_one", arguments: %{}}},
        {:tool_call, %{id: "t2", name: "beta", arguments: %{}}},
        {:tool_call, %{id: "t3", name: "alpha_two", arguments: %{}}},
        {:done, :tool_calls}
      ]

      {session, _provider} =
        start_session(context, [calls, [{:done, :stop}]],
          tools: [
            resource.("alpha_one", "alpha"),
            resource.("beta", "beta"),
            resource.("alpha_two", "alpha")
          ]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:resource_started, "alpha_one", alpha_one}
      assert_receive {:resource_started, "beta", beta}
      refute_receive {:resource_started, "alpha_two", _pid}, 30

      send(alpha_one, :release)
      send(beta, :release)
      assert_receive {:resource_started, "alpha_two", alpha_two}
      send(alpha_two, :release)

      assert_receive {:lemieux, _, {:finished, :stop}}
    end

    @tag :capture_log
    test "a crashing tool becomes an error result and the session survives", context do
      {session, provider} =
        start_session(
          context,
          [[{:tool_call, call("t1", "boom")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert Process.alive?(session)

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["error"] == true
      assert payload["output"] =~ "the tool exploded"
    end

    test "an unknown tool name is an error naming what is available", context do
      {session, provider} =
        start_session(
          context,
          [
            [{:tool_call, %{id: "t1", name: "nope", arguments: %{}}}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] =~ "tool \"nope\" is not available in the current tool profile"
      assert payload["output"] =~ "Available tools: echo"
    end

    test "the session stays busy across the whole loop, then finishes once", context do
      {session, _provider} =
        start_session(
          context,
          [[{:tool_call, call("t1", "hi")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}
      refute_received {:lemieux, _, {:finished, _}}

      assert Session.snapshot(session).status == :idle
    end

    test "tools are offered to the provider on every request", context do
      {session, provider} = start_session(context, [[{:done, :stop}]], tools: [Echo])

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{tools: [Echo]}] = Scripted.requests(provider)
    end

    @tag :capture_log
    test "an ordinary tool's crash is still a crash, with nothing to reconcile", context do
      {session, _provider} =
        start_session(
          context,
          [[{:tool_call, call("t1", "boom")}, {:done, :tool_calls}], [{:done, :stop}]],
          tools: [Echo]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["outcome"] == "crashed"
      refute Map.has_key?(payload, "receipt")
    end

    test "a runaway loop stops at max_turns rather than at the credit limit", context do
      # Asking for something *different* every turn, so this reaches the turn
      # bound rather than tripping the no-progress guard three rounds in. A
      # loop that keeps making new requests is the one max_turns is for; the
      # one that keeps making the same request is caught earlier and cheaper.
      forever = fn request ->
        [{:tool_call, call("t1", "again #{length(request.entries)}")}, {:done, :tool_calls}]
      end

      {session, provider} =
        start_session(context, List.duplicate(forever, 10), tools: [Echo], max_turns: 3)

      :ok = Session.prompt(session, "go")
      # Three requests and transcript writes can exceed ExUnit's one-second
      # mailbox default on a busy CI runner; the terminal reason is the gate.
      assert_receive {:lemieux, _, {:finished, :max_turns}}, 5_000

      assert length(Scripted.requests(provider)) == 3
      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{payload: %{"reason" => reason}} = Enum.find(entries, &(&1.type == :error))
      assert reason =~ "3 turns"

      assert %Entry{type: :run_evidence, payload: %{"stop_reason" => "max_turns"}} =
               List.last(entries)
    end

    test "a new prompt gets a fresh turn budget", context do
      {session, _provider} =
        start_session(
          context,
          [
            [{:tool_call, call("t1", "hi")}, {:done, :tool_calls}],
            [{:done, :stop}],
            [{:tool_call, call("t2", "hi")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          tools: [Echo],
          max_turns: 2
        )

      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, :stop}}
      :ok = Session.prompt(session, "second")
      assert_receive {:lemieux, _, {:finished, :stop}}
    end

    test "stops before a request whose estimate exceeds the remaining cost budget", context do
      {session, provider} =
        start_session(context, [[{:done, :stop}]],
          max_cost_usd: 1.0,
          estimated_cost_usd: 1.01
        )

      :ok = Session.prompt(session, "expensive")

      assert_receive {:lemieux, _, {:finished, {:budget, payload}}}
      assert payload == %{spent: 0.0, estimate: 1.01, cap: 1.0}

      assert Scripted.requests(provider) == []
      assert {:ok, entries} = Store.read(context.store, Session.id(session))

      assert %Entry{type: :error, payload: %{"reason" => reason}} =
               Enum.find(entries, &(&1.type == :error))

      assert reason =~ "before"

      assert %Entry{type: :run_evidence, payload: %{"outcome" => "budget_stopped"}} =
               List.last(entries)
    end

    test "includes measured earlier turns in the pre-request cost gate", context do
      first = [
        {:tool_call, call("t1", "hi")},
        {:usage, %{"input_tokens" => 10, "output_tokens" => 2, "total_cost" => 0.5}},
        {:done, :tool_calls}
      ]

      {session, provider} =
        start_session(context, [first, [{:done, :stop}]],
          tools: [Echo],
          max_cost_usd: 1.0,
          estimated_cost_usd: 0.6
        )

      :ok = Session.prompt(session, "work")

      assert_receive {:lemieux, _, {:finished, {:budget, %{spent: 0.5, estimate: 0.6, cap: 1.0}}}}

      assert length(Scripted.requests(provider)) == 1
    end

    test "unknown pricing stops instead of being treated as free", context do
      {session, provider} =
        start_session(context, [[{:done, :stop}]], max_cost_usd: 1.0)

      :ok = Session.prompt(session, "unpriced")

      assert_receive {:lemieux, _, {:finished, {:budget, payload}}}
      assert payload == %{spent: 0.0, estimate: nil, cap: 1.0}

      assert Scripted.requests(provider) == []
    end

    test "missing usage makes later spend unknown", context do
      first = [{:tool_call, call("t1", "hi")}, {:done, :tool_calls}]

      {session, provider} =
        start_session(context, [first, [{:done, :stop}]],
          tools: [Echo],
          max_cost_usd: 1.0,
          estimated_cost_usd: 0.1
        )

      :ok = Session.prompt(session, "work")

      assert_receive {:lemieux, _, {:finished, {:budget, payload}}}
      assert payload == %{spent: nil, estimate: 0.1, cap: 1.0}
      assert length(Scripted.requests(provider)) == 1
    end
  end

  describe "how a wave of tool calls is scheduled" do
    # Both tools do the same thing — count how many copies of themselves were
    # ever running at once — and differ only in what they say about being
    # parallel-safe. That is the whole point: the two tests below would both
    # pass if `run_tools/2` serialised everything, and the second one is what
    # stops that being the fix.
    defmodule Witness do
      @moduledoc false

      use Agent

      def start_link({runtime, owner}) do
        Agent.start_link(fn -> {0, 0, owner} end, name: name(runtime))
      end

      def enter(runtime, tool) do
        owner =
          Agent.get_and_update(name(runtime), fn {now, peak, owner} ->
            {owner, {now + 1, max(peak, now + 1), owner}}
          end)

        send(owner, {:tool_entered, tool, self()})
        receive do: (:release -> :ok)
      end

      def leave(runtime),
        do: Agent.update(name(runtime), fn {now, peak, owner} -> {now - 1, peak, owner} end)

      def peak(runtime), do: Agent.get(name(runtime), fn {_now, peak, _owner} -> peak end)

      defp name(runtime),
        do: {:via, Registry, {Lemieux.Supervisor.registry(runtime), :test_witness}}
    end

    defmodule Mutating do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "mutating"
      @impl Lemieux.Tool
      def description, do: "Says nothing about itself, so it must be assumed to write."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}

      @impl Lemieux.Tool
      def run(_args, context) do
        Witness.enter(context.supervisor, "mutating")
        Witness.leave(context.supervisor)

        {:ok, "done"}
      end
    end

    defmodule Reading do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "reading"
      @impl Lemieux.Tool
      def description, do: "Touches nothing, and says so."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}

      @impl Lemieux.Tool
      def parallel_safe?, do: true

      @impl Lemieux.Tool
      def run(_args, context) do
        Witness.enter(context.supervisor, "reading")
        Witness.leave(context.supervisor)

        {:ok, "done"}
      end
    end

    defp wave(name) do
      [
        [
          {:tool_call, %{id: "t1", name: name, arguments: %{}}},
          {:tool_call, %{id: "t2", name: name, arguments: %{}}},
          {:tool_call, %{id: "t3", name: name, arguments: %{}}},
          {:done, :tool_calls}
        ],
        [{:done, :stop}]
      ]
    end

    test "a tool that has not promised otherwise runs alone", context do
      start_supervised!({Witness, {context.runtime, self()}})

      {session, _provider} = start_session(context, wave("mutating"), tools: [Mutating])

      :ok = Session.prompt(session, "go")

      for _ <- 1..3 do
        assert_receive {:tool_entered, "mutating", worker}
        # Reading state is a barrier after the scheduler dispatched the batch.
        # If writers were dispatched together, this fails even when one worker
        # happens to run before its siblings get CPU time.
        assert map_size(:sys.get_state(session).wave.tool_tasks) == 1
        send(worker, :release)
      end

      assert_receive {:lemieux, _, {:finished, :stop}}

      # Three calls to a tool that might write to the same file the last one
      # wrote to. Running them together loses an edit, silently.
      assert Witness.peak(context.runtime) == 1
    end

    test "a tool that declares itself parallel-safe still runs with its siblings", context do
      start_supervised!({Witness, {context.runtime, self()}})

      {session, _provider} = start_session(context, wave("reading"), tools: [Reading])

      :ok = Session.prompt(session, "go")

      workers =
        for _ <- 1..3 do
          assert_receive {:tool_entered, "reading", worker}
          worker
        end

      Enum.each(workers, &send(&1, :release))

      assert_receive {:lemieux, _, {:finished, :stop}}

      assert Witness.peak(context.runtime) > 1
    end

    test "readers wait for the writers, whatever order the model asked in", context do
      start_supervised!({Witness, {context.runtime, self()}})

      mixed = [
        [
          {:tool_call, %{id: "t1", name: "reading", arguments: %{}}},
          {:tool_call, %{id: "t2", name: "mutating", arguments: %{}}},
          {:tool_call, %{id: "t3", name: "reading", arguments: %{}}},
          {:done, :tool_calls}
        ],
        [{:done, :stop}]
      ]

      {session, _provider} = start_session(context, mixed, tools: [Mutating, Reading])

      :ok = Session.prompt(session, "go")

      # The writer runs first and alone, even though the model asked for a read
      # before it. A read that overlapped a write of the same file would return
      # a file that never existed, and the model has no way to tell.
      assert_receive {:tool_entered, "mutating", writer}
      assert map_size(:sys.get_state(session).wave.tool_tasks) == 1
      send(writer, :release)

      # And the readers still go together once the writer is done, rather than
      # the whole wave being serialised to buy the guarantee above.
      assert_receive {:tool_entered, "reading", first}
      assert_receive {:tool_entered, "reading", second}
      assert map_size(:sys.get_state(session).wave.tool_tasks) == 2
      send(first, :release)
      send(second, :release)

      assert_receive {:lemieux, _, {:finished, :stop}}
    end
  end

  describe "a loop that is not getting anywhere" do
    defmodule Stuck do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "stuck"
      @impl Lemieux.Tool
      def description, do: "Refuses, identically, forever."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}

      @impl Lemieux.Tool
      def run(_args, _context), do: {:error, "permission denied"}
    end

    defmodule Counting do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "counting"
      @impl Lemieux.Tool
      def description, do: "Answers differently every time it is asked."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}

      @impl Lemieux.Tool
      def run(_args, _context) do
        {:ok, "run #{Agent.get_and_update(Lemieux.SessionTest.Counter, &{&1, &1 + 1})}"}
      end
    end

    defp calling(name),
      do: [{:tool_call, %{id: "t", name: name, arguments: %{}}}, {:done, :tool_calls}]

    test "stops when the same call keeps coming back with the same answer", context do
      {session, provider} =
        start_session(context, List.duplicate(calling("stuck"), 20),
          tools: [Stuck],
          max_turns: 20
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :no_progress}}

      # Three model calls, not twenty. `max_turns` would have caught this
      # eventually and charged for seventeen more rounds of the same refusal
      # to find out what the third one already said.
      assert length(Scripted.requests(provider)) == 3
    end

    test "the same call answered differently is progress, and runs on", context do
      start_supervised!(%{
        id: Lemieux.SessionTest.Counter,
        start: {Agent, :start_link, [fn -> 1 end, [name: Lemieux.SessionTest.Counter]]}
      })

      script = List.duplicate(calling("counting"), 4) ++ [[{:done, :stop}]]

      {session, provider} =
        start_session(context, script, tools: [Counting], max_turns: 20)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert length(Scripted.requests(provider)) == 5
    end

    defmodule Pair do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "pair"
      @impl Lemieux.Tool
      def description, do: "Answers each of two questions the same way every time."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}

      @impl Lemieux.Tool
      def run(%{"n" => n}, _context), do: {:ok, "answer #{n}"}
    end

    # `a, b, a, b, a, b` is never the same round twice, so the rule above
    # never fires on it — and it is the loop a weaker model actually falls
    # into. Half of the last eight calls repeating an earlier one, answer and
    # all, is the rule that does.
    test "stops when it alternates between the same two calls", context do
      script =
        Enum.map(1..20, fn i ->
          [
            {:tool_call, %{id: "t", name: "pair", arguments: %{"n" => rem(i, 2)}}},
            {:done, :tool_calls}
          ]
        end)

      {session, provider} = start_session(context, script, tools: [Pair], max_turns: 20)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :no_progress}}

      # Six calls: three of each, which is the window's floor.
      assert length(Scripted.requests(provider)) == 6

      {:ok, entries} = Store.read(context.store, Session.id(session))

      assert Enum.any?(entries, fn entry ->
               entry.type == :error and
                 entry.payload["reason"] =~ "most of the last 6 calls repeated"
             end)
    end

    test "a new prompt forgets the calls the last one kept making", context do
      script =
        Enum.map(1..4, fn i ->
          [
            {:tool_call, %{id: "t", name: "pair", arguments: %{"n" => rem(i, 2)}}},
            {:done, :tool_calls}
          ]
        end) ++
          [[{:done, :stop}]] ++
          Enum.map(1..4, fn i ->
            [
              {:tool_call, %{id: "t", name: "pair", arguments: %{"n" => rem(i, 2)}}},
              {:done, :tool_calls}
            ]
          end) ++ [[{:done, :stop}]]

      {session, _provider} = start_session(context, script, tools: [Pair], max_turns: 20)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}
      :ok = Session.prompt(session, "again")
      assert_receive {:lemieux, _, {:finished, :stop}}
    end
  end

  describe "the clocks a session sets" do
    defmodule Deadline do
      @moduledoc false

      @behaviour Lemieux.Tool

      @impl Lemieux.Tool
      def name, do: "deadline"
      @impl Lemieux.Tool
      def description, do: "Reports the clock it was given."
      @impl Lemieux.Tool
      def schema, do: %{"type" => "object", "properties" => %{}}

      @impl Lemieux.Tool
      def run(_args, context), do: {:ok, "deadline=#{context.deadline_ms}"}
    end

    # A tool that waits on something it started can hand that something a
    # shorter clock only if it knows its own; `delegate` does exactly that.
    test "a tool is told the deadline it actually got", context do
      {session, _provider} =
        start_session(context, [calling("deadline"), [{:done, :stop}]],
          tools: [Deadline],
          tool_timeout_ms: 1_234
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      {:ok, entries} = Store.read(context.store, Session.id(session))

      assert Enum.any?(entries, fn entry ->
               entry.type == :tool_result and entry.payload["output"] == "deadline=1234"
             end)
    end

    # Neither is a guard: the repeat rules and the budgets are. Both are set
    # where a session working well on a long task never meets them.
    test "the defaults leave room for a long task", context do
      {session, _provider} = start_session(context, [[{:done, :stop}]])
      state = :sys.get_state(session)

      assert state.tool_timeout_ms == :timer.hours(1)
      assert state.max_turns == 400
    end
  end

  describe "failure" do
    test "a provider error is persisted and the session survives, idle", context do
      {session, _provider} = start_session(context, [[{:error, :boom}]])
      id = Session.id(session)

      :ok = Session.prompt(session, "hi")

      assert_receive {:lemieux, ^id, {:error, :boom}}
      assert_receive {:lemieux, ^id, {:finished, :error}}

      assert Process.alive?(session)
      assert Session.snapshot(session).status == :idle

      assert {:ok, entries} = Store.read(context.store, id)
      assert Enum.any?(entries, &(&1.type == :error))

      assert %Entry{type: :run_evidence, payload: %{"outcome" => "failed"}} =
               List.last(entries)
    end

    @tag :capture_log
    test "a crashing provider becomes an error entry rather than a dead session", context do
      {session, _provider} =
        start_session(context, [fn _request -> raise "provider exploded" end])

      id = Session.id(session)

      :ok = Session.prompt(session, "hi")

      assert_receive {:lemieux, ^id, {:error, _reason}}
      assert_receive {:lemieux, ^id, {:finished, :error}}
      assert Process.alive?(session)

      assert {:ok, entries} = Store.read(context.store, id)
      assert Enum.any?(entries, &(&1.type == :error))

      assert %Entry{type: :run_evidence, payload: %{"outcome" => "failed"}} =
               List.last(entries)
    end

    test "a stream that ends without a terminal event still finishes the turn", context do
      # A provider that returns without saying :done or :error would otherwise
      # leave the session busy forever.
      {session, _provider} = start_session(context, [[{:text_delta, "cut off"}]])

      :ok = Session.prompt(session, "hi")

      assert_receive {:lemieux, _, {:finished, :error}}
      assert Session.snapshot(session).status == :idle
    end
  end

  describe "snapshot/1" do
    test "reports the id, status and transcript without touching the store", context do
      {session, _provider} = start_session(context, [[{:text_delta, "hi"}, {:done, :stop}]])

      assert %{status: :idle, entries: [%Entry{type: :session}]} = Session.snapshot(session)

      :ok = Session.prompt(session, "hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      snapshot = Session.snapshot(session)
      assert snapshot.id == Session.id(session)

      assert Enum.map(snapshot.entries, & &1.type) == [
               :session,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :run_evidence
             ]
    end
  end

  describe "registration" do
    test "a session can be found by its id", context do
      {session, _provider} = start_session(context, [])

      assert Lemieux.session(context.runtime, Session.id(session)) == {:ok, session}
      assert Lemieux.session(context.runtime, "nope") == :error
    end

    test "the caller can name the session, so a host controls its own ids", context do
      {session, _provider} = start_session(context, [], id: "host-42")

      assert Session.id(session) == "host-42"
      assert Lemieux.session(context.runtime, "host-42") == {:ok, session}
    end
  end
end
