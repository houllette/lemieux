defmodule Lemieux.Session.MessagesTest do
  @moduledoc """
  The `:messages` seam: a host's wording reaches the model where the
  session's own used to.

  Each test picks one sentence the loop writes, replaces it, and reads it
  back from the place the model (or the person) would — a tool result, a
  system entry, an error entry — rather than from the module directly, so
  what is proven is that the session asks, not that the module answers.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Messages
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # A replacement that changes three sentences and delegates the rest, which
  # is the shape the module documentation recommends.
  defmodule Curt do
    @moduledoc false
    @behaviour Lemieux.Messages

    @impl true
    def approval_timed_out(timeout_ms), do: "curt: unapproved after #{timeout_ms}ms"

    @impl true
    def tools_changed(names), do: "curt: tools are now #{Enum.join(names, "+")}"

    @impl true
    def turn_budget_spent(max_turns), do: "curt: #{max_turns} turns is all you get"

    @impl true
    defdelegate question_timed_out(timeout_ms), to: Messages
    @impl true
    defdelegate budget_stopped(payload), to: Messages
    @impl true
    defdelegate tool_budget_denied(payload), to: Messages
    @impl true
    defdelegate stuck(repeats), to: Messages
    @impl true
    defdelegate cycling(calls), to: Messages
    @impl true
    defdelegate aside_denied(call), to: Messages
    @impl true
    defdelegate lost_call(call), to: Messages
    @impl true
    defdelegate tool_crashed(call, reason), to: Messages
    @impl true
    defdelegate tool_timed_out(call, timeout_ms), to: Messages
    @impl true
    defdelegate tool_cancelled(call), to: Messages
    @impl true
    defdelegate attachments_refreshed(paths), to: Messages
    @impl true
    defdelegate summary_empty(), to: Messages
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
    def run(_arguments, _context), do: {:ok, "echo"}
  end

  defmodule Brief do
    @behaviour Lemieux.Messages
    @impl true
    def tools_changed(_names), do: "The catalog changed."
  end

  test "a one-sentence override inherits default stops", context do
    {session, _provider} =
      start_session(context, List.duplicate(calling(), 3), messages: Brief, max_turns: 1)

    id = Session.id(session)
    {:ok, _} = Session.disable_tools(session, [])
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    {:ok, entries} = Store.read(context.store, id)

    assert Enum.any?(
             entries,
             &(&1.type == :error and &1.payload["reason"] == "stopped after 1 turns")
           )

    {:ok, _} = Session.disable_tools(session, ["echo"])
    {:ok, entries} = Store.read(context.store, id)

    assert Enum.any?(
             entries,
             &(&1.type == :system and &1.payload["text"] == "The catalog changed.")
           )
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_messages_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
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
          subscriber: self(),
          tools: [Echo]
        ] ++ opts
      )

    {session, provider}
  end

  defp calling do
    [{:tool_call, %{id: "t1", name: "echo", arguments: %{}}}, {:done, :tool_calls}]
  end

  test "a custom denial is what the model reads when nobody approves a call", context do
    clock = start_supervised!(Manual)

    {session, provider} =
      start_session(context, [calling(), [{:done, :stop}]],
        messages: Curt,
        approval_timeout: 20,
        clock: clock,
        hooks: [before_tool_call: fn _call, _context -> :pending end]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")

    # The approval's timeout is armed on the manual clock; nobody answers, and
    # its twenty milliseconds pass when the test moves time, not before.
    Manual.await_timer(clock, &match?({:park_timeout, _call_id}, &1.message))
    Manual.advance(clock, 20, settle: session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
    assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
    assert payload["error"]
    assert payload["output"] =~ "curt: unapproved after 20ms"
    refute payload["output"] =~ "nobody approved"
  end

  test "the catalog notice a tool change writes is the host's", context do
    {session, _provider} = start_session(context, [[{:done, :stop}]], messages: Curt)
    id = Session.id(session)

    {:ok, _names} = Session.disable_tools(session, ["echo"])

    {:ok, entries} = Store.read(context.store, id)
    assert %Entry{payload: %{"text" => text}} = Enum.find(entries, &(&1.type == :system))
    assert text == "curt: tools are now "
  end

  test "the turn-budget stop says it the host's way", context do
    {session, _provider} =
      start_session(context, List.duplicate(calling(), 3), messages: Curt, max_turns: 2)

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}

    {:ok, entries} = Store.read(context.store, id)

    assert Enum.any?(entries, fn entry ->
             entry.type == :error and entry.payload["reason"] == "curt: 2 turns is all you get"
           end)
  end

  test "nothing about the module reaches the transcript", context do
    {session, _provider} = start_session(context, [[{:done, :stop}]], messages: Curt)
    id = Session.id(session)

    {:ok, entries} = Store.read(context.store, id)
    assert %Entry{payload: config} = Enum.find(entries, &(&1.type == :session))
    refute Map.has_key?(config, "messages")
    refute inspect(config) =~ "Curt"
  end

  test "the default is the module that declares the behaviour", context do
    {session, _provider} = start_session(context, [[{:done, :stop}]], [])
    assert :sys.get_state(session).messages == Messages

    behaviours = Keyword.get_values(Messages.__info__(:attributes), :behaviour)
    assert Messages in List.flatten(behaviours)
  end

  test "something that is not a module is refused at start", context do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             Lemieux.start_session(
               supervisor: context.runtime,
               provider: Scripted.new([]),
               store: context.store,
               model: "test:model",
               messages: "curt"
             )

    assert message =~ ":messages"
  end

  test "an unrelated or missing module is refused before its first message", context do
    for module <- [String, MissingMessages] do
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Lemieux.start_session(
                 supervisor: context.runtime,
                 provider: Scripted.new([]),
                 store: context.store,
                 model: "test:model",
                 messages: module
               )

      assert message =~ "at least one"
    end
  end
end
