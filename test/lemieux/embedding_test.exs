defmodule Lemieux.EmbeddingTest do
  @moduledoc """
  A host that is not `lmx`, doing what `docs/embedding.md` says to do.

  Every claim in that guide is a promise to somebody who will find out it is
  wrong long after the commit that broke it, so the guide is checked here
  rather than proofread: a store of its own, a tool of its own, hooks of its
  own, and nothing from `Lemieux.CLI`.

  That last part is the point of the file. `lmx` gets no privileged path into
  the library — if it did, this is the test that would stop compiling.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session

  # A host's own store: an Agent standing in for the database an embedder
  # would use, implementing the same three callbacks `Lemieux.Store.JSONL`
  # does.
  defmodule MemoryStore do
    @moduledoc false
    @behaviour Lemieux.Store

    def new do
      {:ok, agent} = Agent.start_link(fn -> %{} end)

      {__MODULE__, agent}
    end

    @impl Lemieux.Store
    def append(agent, session_id, entries) do
      Agent.update(agent, &Map.update(&1, session_id, entries, fn kept -> kept ++ entries end))
    end

    @impl Lemieux.Store
    def read(agent, session_id) do
      case Agent.get(agent, &Map.fetch(&1, session_id)) do
        {:ok, entries} -> {:ok, entries}
        :error -> {:error, :not_found}
      end
    end

    @impl Lemieux.Store
    def list_sessions(agent), do: {:ok, Agent.get(agent, &Map.keys/1)}
  end

  # A host's own tool, written from the guide.
  defmodule Deploy do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "deploy"

    @impl Lemieux.Tool
    def description, do: "Deploys the current branch to staging."

    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl Lemieux.Tool
    def run(_arguments, context), do: {:ok, "deployed from #{context.cwd}"}
  end

  setup do
    runtime = :"lemieux_embedding_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: MemoryStore.new()}
  end

  defp start(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        Keyword.merge(
          [
            supervisor: context.runtime,
            provider: provider,
            store: context.store,
            model: "test:model",
            subscriber: self(),
            tools: [Deploy]
          ],
          opts
        )
      )

    {session, provider}
  end

  defp call(name), do: %{id: "c1", name: name, arguments: %{}}

  describe "a host with its own everything" do
    test "runs a session: its store, its tool, its subscriber", context do
      {session, _provider} =
        start(context, [
          [{:tool_call, call("deploy")}, {:done, :tool_calls}],
          [{:text_delta, "done"}, {:done, :stop}]
        ])

      id = Session.id(session)

      :ok = Session.prompt(session, "ship it")

      assert_receive {:lemieux, ^id, {:tool_call, %{name: "deploy"}}}
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      # Written to the host's store, not to a file lemieux chose.
      assert {:ok, entries} = Lemieux.Store.read(context.store, id)

      assert %Entry{payload: %{"output" => output}} =
               Enum.find(entries, &(&1.type == :tool_result))

      assert output =~ "deployed from"
    end

    test "the store it supplied is the only one written to", context do
      {session, _provider} = start(context, [[{:done, :stop}]])
      id = Session.id(session)

      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      assert {:ok, [^id]} = Lemieux.Store.list_sessions(context.store)
    end
  end

  describe "policy, attached the way the guide says" do
    test "a hook denies a call and the model reads why", context do
      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("deploy")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          hooks: [before_tool_call: fn _call, _context -> {:deny, "not on a Friday"} end]
        )

      :ok = Session.prompt(session, "ship it")
      assert_receive {:lemieux, _id, {:finished, _reason}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))

      assert payload["output"] =~ "not on a Friday"
      assert payload["error"]
    end

    test "a hook parks a call, and the host answers it later", context do
      {session, _provider} =
        start(
          context,
          [
            [{:tool_call, call("deploy")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          hooks: [before_tool_call: fn _call, _context -> :pending end]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "ship it")

      assert_receive {:lemieux, ^id, {:tool_approval, parked}}
      assert parked.name == "deploy"

      :ok = Session.resolve_tool(session, "c1", :allow)
      assert_receive {:lemieux, ^id, {:finished, _reason}}
    end

    test "a hook rewrites the arguments a call runs with", context do
      {session, _provider} =
        start(
          context,
          [
            [{:tool_call, call("deploy")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          hooks: [
            before_tool_call: fn _call, _context -> {:rewrite, %{"target" => "staging"}} end
          ]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "ship it")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      assert {:ok, entries} = Lemieux.Store.read(context.store, id)

      assert %Entry{payload: %{"arguments" => %{"target" => "staging"}}} =
               Enum.find(entries, &(&1.type == :tool_result))
    end
  end

  describe "what a host gets back" do
    test "a resumed session reads the host's store and continues", context do
      {session, _provider} = start(context, [[{:text_delta, "first"}, {:done, :stop}]])
      id = Session.id(session)

      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      :ok =
        DynamicSupervisor.terminate_child(
          Lemieux.Supervisor.session_supervisor(context.runtime),
          session
        )

      LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

      resumed_provider = Scripted.new([[{:done, :stop}]])

      {:ok, resumed} =
        Lemieux.resume_session(
          supervisor: context.runtime,
          provider: resumed_provider,
          store: context.store,
          subscriber: self(),
          resume: id
        )

      :ok = Session.prompt(resumed, "again")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      # The conversation the host stored is the conversation the model is sent.
      assert [%Request{entries: entries}] = Scripted.requests(resumed_provider)
      texts = for %Entry{type: :user, payload: %{"text" => text}} <- entries, do: text

      assert texts == ["hello", "again"]
    end

    test "a fork of the host's transcript is a new session in the same store", context do
      {session, _provider} = start(context, [[{:text_delta, "first"}, {:done, :stop}]])
      id = Session.id(session)

      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      assert {:ok, forked} = Lemieux.Transcript.fork(context.store, id)
      assert forked != id

      assert {:ok, entries} = Lemieux.Store.read(context.store, forked)
      assert Enum.any?(entries, &(&1.type == :fork))
    end

    test "the snapshot reports where the session stands", context do
      {session, _provider} =
        start(context, [
          [
            {:text_delta, "hi"},
            {:usage, %{"input_tokens" => 120, "output_tokens" => 8}},
            {:done, :stop}
          ]
        ])

      id = Session.id(session)
      :ok = Session.prompt(session, "hello")
      assert_receive {:lemieux, ^id, {:finished, _reason}}

      snapshot = Session.snapshot(session)

      assert snapshot.status == :idle
      assert snapshot.context.tokens == 128
      assert snapshot.context.spent.requests == 1
    end
  end
end
