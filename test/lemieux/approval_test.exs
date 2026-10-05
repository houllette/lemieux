defmodule Lemieux.ApprovalTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_approval_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defmodule Echo do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "echo"
    @impl Lemieux.Tool
    def description, do: "Echoes what it is given."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl Lemieux.Tool
    def run(%{"say" => say}, _context), do: {:ok, "echo: #{say}"}

    @impl Lemieux.Tool
    def parallel_safe?, do: true
  end

  defp call(id \\ "t1", say \\ "hello"),
    do: %{id: id, name: "echo", arguments: %{"say" => say}}

  # A session whose one tool call is waiting on somebody to approve it.
  defp start_pending(context, opts \\ []) do
    provider =
      Scripted.new([
        [{:tool_call, call()}, {:done, :tool_calls}],
        [{:text_delta, "done"}, {:done, :stop}]
      ])

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          tools: [Echo],
          hooks: [before_tool_call: fn _call, _context -> :pending end]
        ]
        |> Keyword.merge(opts)
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "use the tool")

    assert_receive {:lemieux, ^id, {:tool_approval, parked}}

    {session, provider, parked}
  end

  describe "a hook that answers :pending" do
    test "parks the call and announces it, rather than running it", context do
      {session, provider, parked} = start_pending(context)

      assert parked.id == "t1"
      assert parked.name == "echo"

      # Still one request: the second only happens once the call resolves.
      assert length(Scripted.requests(provider)) == 1
      assert Session.snapshot(session).status == :busy
    end

    test "the parked call is visible in a snapshot", context do
      {session, _provider, _parked} = start_pending(context)

      assert [pending] = Session.snapshot(session).pending
      assert pending.call_id == "t1"
      assert pending.kind == :approval
    end

    test "the request and resolution are durably auditable", context do
      {session, _provider, _parked} = start_pending(context)

      assert {:ok, pending_entries} = Store.read(context.store, Session.id(session))

      assert %{"call_id" => "t1", "status" => "pending"} =
               pending_entries |> Enum.find(&(&1.type == :approval)) |> Map.fetch!(:payload)

      assert :ok = Session.resolve_tool(session, "t1", :allow)
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))

      assert entries
             |> Enum.filter(&(&1.type == :approval))
             |> Enum.map(& &1.payload["status"]) == ["pending", "allowed"]
    end

    test "the session still answers while a call is parked", context do
      {session, _provider, _parked} = start_pending(context)

      # The point of parking in the session rather than blocking it.
      assert Session.snapshot(session).id == Session.id(session)
      assert Session.steer(session, "while you wait") == :ok
    end
  end

  describe "resolve_tool/3" do
    test "an allow runs the call and the loop carries on", context do
      {session, provider, _parked} = start_pending(context)
      id = Session.id(session)

      assert :ok = Session.resolve_tool(session, "t1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: hello"
      refute payload["error"]
    end

    test "a denial becomes the result the model reads, with the reason", context do
      {session, provider, _parked} = start_pending(context)
      id = Session.id(session)

      assert :ok = Session.resolve_tool(session, "t1", {:deny, "not on my watch"})
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] =~ "not on my watch"
      assert payload["error"]
    end

    test "a rewrite runs the call with the arguments it was given", context do
      {session, provider, _parked} = start_pending(context)
      id = Session.id(session)

      assert :ok = Session.resolve_tool(session, "t1", {:rewrite, %{"say" => "something else"}})
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: something else"
      assert payload["arguments"] == %{"say" => "something else"}
    end

    test "resolving a call nobody parked says so rather than pretending", context do
      {session, _provider, _parked} = start_pending(context)

      assert {:error, :unknown_call} = Session.resolve_tool(session, "nope", :allow)
    end

    test "the same call cannot be resolved twice", context do
      {session, _provider, _parked} = start_pending(context)
      id = Session.id(session)

      assert :ok = Session.resolve_tool(session, "t1", :allow)
      assert {:error, :unknown_call} = Session.resolve_tool(session, "t1", :allow)

      # The allowed call carries the turn on to another request. Ending the
      # test under it took the scripted provider away mid-call, and the crash
      # that followed was logged after the test, where nothing captured it.
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "attention observes a park and the final release without controlling either", context do
      parent = self()

      hooks = [
        before_tool_call: fn _call, _context -> :pending end,
        attention: fn attention, hook_context ->
          if attention.state == :waiting do
            send(parent, {:observer_waiting, self()})
            receive do: (:release -> :ok)
          end

          send(parent, {:attention, attention.state, attention, hook_context.session_id})
          :ignored
        end
      ]

      {session, _provider, _parked} = start_pending(context, hooks: hooks)
      id = Session.id(session)

      assert_receive {:observer_waiting, observer}
      assert :ok = Session.resolve_tool(session, "t1", :allow)

      send(observer, :release)

      assert_receive {:attention, :waiting, %{state: :waiting, call_id: "t1", kind: :approval},
                      ^id}

      assert_receive {:attention, :working, %{state: :working}, ^id}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "a failing attention observer cannot break the parked call", context do
      hooks = [
        before_tool_call: fn _call, _context -> :pending end,
        attention: fn _attention, _context -> raise "observer exploded" end
      ]

      {session, _provider, _parked} = start_pending(context, hooks: hooks)
      id = Session.id(session)

      assert :ok = Session.resolve_tool(session, "t1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end

    test "working waits until the final parked call releases", context do
      parent = self()

      provider =
        Scripted.new([
          [
            {:tool_call, call("t1", "one")},
            {:tool_call, call("t2", "two")},
            {:done, :tool_calls}
          ],
          [{:done, :stop}]
        ])

      hooks = [
        before_tool_call: fn _call, _context -> :pending end,
        attention: fn attention, _context -> send(parent, {:attention_state, attention.state}) end
      ]

      assert {:ok, session} =
               Lemieux.start_session(
                 supervisor: context.runtime,
                 provider: provider,
                 store: context.store,
                 model: "test:model",
                 subscriber: self(),
                 tools: [Echo],
                 hooks: hooks
               )

      id = Session.id(session)
      assert :ok = Session.prompt(session, "use both tools")
      assert_receive {:attention_state, :waiting}
      assert_receive {:attention_state, :waiting}

      assert :ok = Session.resolve_tool(session, "t1", :allow)
      refute_receive {:attention_state, :working}, 50

      assert :ok = Session.resolve_tool(session, "t2", :allow)
      assert_receive {:attention_state, :working}
      assert_receive {:lemieux, ^id, {:finished, :stop}}
    end
  end

  describe "when nobody answers" do
    # An unattended session that waits forever is the failure this exists to
    # prevent: it looks like a working agent and is a stuck process.
    test "the call times out into a denial the model can read", context do
      parent = self()

      hooks = [
        before_tool_call: fn _call, _context -> :pending end,
        attention: fn attention, _context -> send(parent, {:attention_state, attention.state}) end
      ]

      {session, provider, _parked} =
        start_pending(context, approval_timeout: 30, hooks: hooks)

      id = Session.id(session)

      assert_receive {:attention_state, :waiting}
      assert_receive {:attention_state, :working}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] =~ "nobody"
      assert payload["error"]
    end

    test "a resolution that arrives first wins, and no timeout fires", context do
      {session, provider, _parked} = start_pending(context, approval_timeout: 10_000)
      id = Session.id(session)

      :ok = Session.resolve_tool(session, "t1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: hello"
    end
  end

  describe "cancelling" do
    test "drops the parked call and leaves the session idle and usable", context do
      {session, _provider, _parked} = start_pending(context)
      id = Session.id(session)

      :ok = Session.cancel(session)
      assert_receive {:lemieux, ^id, {:finished, :cancelled}}

      assert Session.snapshot(session).status == :idle
      assert Session.snapshot(session).pending == []
      assert {:error, :unknown_call} = Session.resolve_tool(session, "t1", :allow)
    end

    test "notifies attention that work resumed after dropping a parked call", context do
      parent = self()

      hooks = [
        before_tool_call: fn _call, _context -> :pending end,
        attention: fn attention, _context -> send(parent, {:attention_state, attention.state}) end
      ]

      {session, _provider, _parked} = start_pending(context, hooks: hooks)

      assert_receive {:attention_state, :waiting}
      :ok = Session.cancel(session)
      assert_receive {:attention_state, :working}
    end
  end
end
