defmodule Lemieux.SteeringTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_steering_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  # A tool that stops the loop in a known place and waits to be let go. Mid-turn
  # is otherwise a race: the scripted provider answers instantly, so a steer
  # sent "while it works" would usually arrive after the work was over and the
  # test would pass without exercising anything.
  defmodule Gate do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "gate"
    @impl Lemieux.Tool
    def description, do: "Blocks until the test releases it."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl Lemieux.Tool
    def run(%{"test" => encoded}, _context) do
      # The pid travels as a string because the call is persisted as JSON on
      # its way through the transcript.
      pid = encoded |> String.to_charlist() |> :erlang.list_to_pid()
      send(pid, {:gate_entered, self()})

      receive do
        :release -> {:ok, "released"}
      after
        5_000 -> {:error, "the gate was never released"}
      end
    end
  end

  # Mirrors the ownership shape of ReqLLM's real streaming path without
  # making a network request: the provider task starts a linked StreamServer
  # and then blocks while the session remains able to cancel it.
  defmodule LinkedStream do
    @moduledoc false
    @behaviour Lemieux.Provider

    @impl Lemieux.Provider
    def run(test, _request, _emit) do
      # The server only needs the provider identity for this lifecycle test.
      # Looking it up through the full catalog made the synchronization event
      # wait behind cold catalog startup and intermittently miss its timeout
      # when the async suite was busy.
      model = LLMDB.Model.new!(%{id: "claude-haiku-4-5", provider: :anthropic})

      {:ok, server} =
        ReqLLM.StreamServer.start_link(
          provider_mod: ReqLLM.Providers.Anthropic,
          model: model
        )

      send(test, {:stream_server, server})
      receive do: (:stop -> :ok)
    end
  end

  defmodule PartialStream do
    @moduledoc false
    @behaviour Lemieux.Provider

    @impl Lemieux.Provider
    def run(test, _request, emit) do
      emit.({:text_delta, "work already shown"})
      send(test, {:partial_stream, self()})
      receive do: (:stop -> :ok)
    end
  end

  defp start_session(context, script, opts) do
    provider = Scripted.new(script)

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

  defp gate_call(id \\ "g1") do
    encoded = self() |> :erlang.pid_to_list() |> to_string()

    %{id: id, name: "gate", arguments: %{"test" => encoded}}
  end

  # A session held open at a tool call: the provider has answered, the tool is
  # running, and the next request has not been built yet.
  defp start_gated(context, later_turns \\ [[{:text_delta, "ok"}, {:done, :stop}]]) do
    {session, provider} =
      start_session(
        context,
        [[{:tool_call, gate_call()}, {:done, :tool_calls}] | later_turns],
        tools: [Gate]
      )

    :ok = Session.prompt(session, "go")
    assert_receive {:gate_entered, tool}

    {session, provider, tool}
  end

  describe "steer/2" do
    test "a steer can be revoked before the next request and never reaches the transcript",
         context do
      {session, provider, tool} = start_gated(context)

      :ok = Session.steer(session, "use tabs")
      assert :ok = Session.revoke_steer(session, "use tabs")
      assert {:error, :already_sent} = Session.revoke_steer(session, "use tabs")

      send(tool, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}
      assert [_first, %Request{entries: request_entries}] = Scripted.requests(provider)
      refute Enum.any?(request_entries, &(&1.type == :user and &1.payload["text"] == "use tabs"))
      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      refute Enum.any?(entries, &(&1.type == :user and &1.payload["text"] == "use tabs"))
    end

    test "a steer queued mid-turn appears as a user message in the next request", context do
      {session, provider, tool} = start_gated(context)

      :ok = Session.steer(session, "actually, use tabs")
      send(tool, :release)

      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)

      assert Enum.map(entries, & &1.type) == [
               :session,
               :user,
               :request,
               :assistant,
               :tool_result,
               :user
             ]

      assert List.last(entries).payload == %{"text" => "actually, use tabs"}
    end

    test "the steer is persisted, so a resumed session still has it", context do
      {session, _provider, tool} = start_gated(context)

      :ok = Session.steer(session, "use tabs")
      send(tool, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))

      # One harness snapshot per run: the steer changes no behaviour, so the
      # second request reuses the snapshot the first one recorded.
      assert Enum.map(entries, & &1.type) == [
               :session,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :tool_result,
               :user,
               :request,
               :assistant,
               :run_evidence
             ]
    end

    test "a steer is announced to the subscriber like any other entry", context do
      {session, _provider, tool} = start_gated(context)
      id = Session.id(session)

      :ok = Session.steer(session, "use tabs")
      send(tool, :release)

      assert_receive {:lemieux, ^id,
                      {:entry, %Entry{type: :user, payload: %{"text" => "use tabs"}}}}
    end

    test "several steers arrive in the order they were sent", context do
      {session, provider, tool} = start_gated(context)

      :ok = Session.steer(session, "first")
      :ok = Session.steer(session, "second")
      send(tool, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)

      assert entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.payload["text"]) ==
               ["go", "first", "second"]
    end

    # Without this the words sit in the queue until somebody prompts again,
    # which to the person who typed them is indistinguishable from being
    # ignored.
    test "a steer that arrives during a turn is answered when the model stops", context do
      test = self()

      {session, provider} =
        start_session(
          context,
          [
            fn _request ->
              send(test, {:answering, self()})

              receive do
                :release -> [{:text_delta, "first"}, {:done, :stop}]
              after
                5_000 -> [{:done, :stop}]
              end
            end,
            [{:text_delta, "and about those tabs"}, {:done, :stop}]
          ],
          []
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:answering, answering}

      :ok = Session.steer(session, "use tabs")
      send(answering, :release)

      assert_receive {:lemieux, _, {:finished, :stop}}

      # Two requests, not one: the second exists only because of the steer.
      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert List.last(entries).payload == %{"text" => "use tabs"}
    end

    test "a steer cannot buy more turns than the prompt was allowed", context do
      test = self()

      {session, provider} =
        start_session(
          context,
          [
            fn _request ->
              send(test, {:answering, self()})

              receive do
                :release -> [{:done, :stop}]
              after
                5_000 -> [{:done, :stop}]
              end
            end
          ],
          max_turns: 1
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:answering, answering}
      :ok = Session.steer(session, "and this")
      send(answering, :release)

      assert_receive {:lemieux, _, {:finished, _}}
      assert length(Scripted.requests(provider)) == 1
    end

    # The queue is drained where the next request is built, so a steer with no
    # turn to join must not start one — a session that answered a steer on its
    # own would spend tokens nobody asked it to spend.
    test "steering an idle session starts nothing on its own", context do
      {session, provider} = start_session(context, [[{:done, :stop}]], [])

      :ok = Session.steer(session, "nobody asked")

      assert Session.snapshot(session).status == :idle
      assert Scripted.requests(provider) == []
      refute_receive {:lemieux, _, {:finished, _}}, 50
    end

    test "a steer queued while idle is carried by the next prompt", context do
      {session, provider} = start_session(context, [[{:done, :stop}]], [])

      :ok = Session.steer(session, "and be terse")
      :ok = Session.prompt(session, "say hi")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{entries: entries}] = Scripted.requests(provider)

      assert Enum.map(entries, & &1.payload["text"]) == [nil, "say hi", "and be terse"]
    end

    test "a steer that cannot run at the turn limit does not leak into the next prompt",
         context do
      test = self()

      {session, provider} =
        start_session(
          context,
          [
            fn _request ->
              send(test, {:answering, self()})

              receive do
                :release -> [{:done, :stop}]
              end
            end,
            [{:done, :stop}]
          ],
          max_turns: 1
        )

      :ok = Session.prompt(session, "first")
      assert_receive {:answering, answering}
      :ok = Session.steer(session, "stale")
      send(answering, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}

      :ok = Session.prompt(session, "second")
      assert_receive {:lemieux, _, {:finished, :stop}}

      [_first, %Request{entries: entries}] = Scripted.requests(provider)
      user_texts = entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.payload["text"])
      assert user_texts == ["first", "second"]
    end
  end

  describe "follow_up/2" do
    test "queues a fresh prompt after current work finishes", context do
      {session, provider, tool} =
        start_gated(context, [
          [{:text_delta, "ok"}, {:done, :stop}],
          [{:text_delta, "followed up"}, {:done, :stop}]
        ])

      :ok = Session.follow_up(session, "check the tests too")
      assert Session.snapshot(session).queued_follow_ups == ["check the tests too"]
      send(tool, :release)

      assert_receive {:lemieux, _, {:finished, :stop}}
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_tool_call, _completion, %Request{entries: entries}] =
               Scripted.requests(provider)

      assert List.last(entries).payload == %{"text" => "check the tests too"}
      assert Session.snapshot(session).queued_follow_ups == []
    end

    test "starts immediately when the session is idle", context do
      {session, provider} = start_session(context, [[{:done, :stop}]], [])

      :ok = Session.follow_up(session, "run now")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{entries: entries}] = Scripted.requests(provider)
      assert List.last(entries).payload == %{"text" => "run now"}
    end
  end

  describe "cancel/2" do
    test "stops a provider's linked stream server as a normal shutdown", context do
      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: {LinkedStream, self()},
          store: context.store,
          model: "test:model",
          subscriber: self()
        )

      :ok = Session.prompt(session, "take your time")
      # A cold ReqLLM StreamServer startup can exceed the suite-wide one-second
      # mailbox timeout on a loaded CI runner. The server is the synchronization
      # point this test needs, so wait for that event rather than racing startup.
      assert_receive {:stream_server, server}, 15_000
      down = Process.monitor(server)

      :ok = Session.cancel(session)

      assert_receive {:DOWN, ^down, :process, ^server, :shutdown}
      assert_receive {:lemieux, _, {:finished, :cancelled}}
      assert Process.alive?(session)
      assert Session.snapshot(session).status == :idle
    end

    test "cancel kills running tool tasks and the session survives, resumable", context do
      {session, _provider, tool} = start_gated(context)
      down = Process.monitor(tool)

      :ok = Session.cancel(session)

      assert_receive {:DOWN, ^down, :process, ^tool, _reason}
      assert_receive {:lemieux, _, {:finished, :cancelled}}

      assert Process.alive?(session)
      assert Session.snapshot(session).status == :idle

      assert {:ok, entries} = Store.read(context.store, Session.id(session))

      assert %Entry{type: :tool_result, payload: payload} =
               Enum.find(entries, &(&1.type == :tool_result))

      assert payload["error"]
      assert payload["output"] =~ "cancelled"
      assert Transcript.validate(entries) == :ok
    end

    test "a cancelled session takes another prompt", context do
      {session, _provider, tool} =
        start_gated(context, [[{:text_delta, "second"}, {:done, :stop}]])

      :ok = Session.cancel(session)
      assert_receive {:lemieux, _, {:finished, :cancelled}}
      send(tool, :release)

      :ok = Session.prompt(session, "try again")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert Session.snapshot(session).status == :idle
    end

    # Without this the transcript reads as a turn that simply stopped talking,
    # which is the same shape as a provider that hung up.
    test "the cancellation is recorded in the transcript", context do
      {session, _provider, _tool} = start_gated(context)

      :ok = Session.cancel(session)
      assert_receive {:lemieux, _, {:finished, :cancelled}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert Enum.any?(entries, &(&1.type == :cancelled))

      assert %Entry{type: :run_evidence, payload: %{"outcome" => "canceled"}} =
               List.last(entries)
    end

    test "cancelling mid-stream ends the turn rather than waiting for the model", context do
      owner = self()

      {session, _provider} =
        start_session(
          context,
          [
            fn _request ->
              send(owner, :provider_waiting)
              receive do: (:release -> :ok)
              [{:done, :stop}]
            end
          ],
          []
        )

      :ok = Session.prompt(session, "take your time")
      assert_receive :provider_waiting
      :ok = Session.cancel(session)

      assert_receive {:lemieux, _, {:finished, :cancelled}}
      assert Session.snapshot(session).status == :idle
    end

    test "cancelling preserves partial assistant text as a durable checkpoint", context do
      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: {PartialStream, self()},
          store: context.store,
          model: "test:model",
          subscriber: self()
        )

      :ok = Session.prompt(session, "take your time")
      assert_receive {:partial_stream, _provider_task}
      assert_receive {:lemieux, _, {:text_delta, %{text: "work already shown"}}}
      :ok = Session.cancel(session)
      assert_receive {:lemieux, _, {:finished, :cancelled}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      partial = Enum.find(entries, &(&1.type == :assistant))
      assert partial.payload["content"] == [%{"type" => "text", "text" => "work already shown"}]
      assert Enum.any?(entries, &(&1.type == :cancelled))
      assert List.last(entries).type == :run_evidence
    end

    test "cancelling drops what was queued, rather than saving it for later", context do
      {session, provider, _tool} = start_gated(context)

      :ok = Session.steer(session, "never mind that")
      :ok = Session.cancel(session)
      assert_receive {:lemieux, _, {:finished, :cancelled}}

      :ok = Session.prompt(session, "something else")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)

      refute Enum.any?(entries, &(&1.payload["text"] == "never mind that"))
    end

    test "cancelling an idle session changes nothing", context do
      {session, _provider} = start_session(context, [[{:done, :stop}]], [])

      :ok = Session.cancel(session)

      assert Session.snapshot(session).status == :idle
      assert Enum.map(Session.snapshot(session).entries, & &1.type) == [:session]
      refute_receive {:lemieux, _, {:finished, _}}, 50
    end
  end
end
