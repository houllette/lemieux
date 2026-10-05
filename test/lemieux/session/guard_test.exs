defmodule Lemieux.Session.GuardTest do
  @moduledoc """
  The `:guard` seam: a host's rule decides when a looping session stops,
  with its own reason and its own words, and the shipped rule is what a
  session gets when nobody said otherwise.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Messages
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Guard
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # Stops after a number of turns it is handed as its state.
  defmodule Enough do
    @moduledoc false
    @behaviour Lemieux.Session.Guard

    @impl true
    def decide(limit, %{turns_taken: taken}) when taken >= limit,
      do: {:stop, :enough, "#{limit} turns is plenty"}

    def decide(_limit, _view), do: :continue
  end

  # Never minds a repeat; only the budget stops it, in the host's words.
  defmodule Patient do
    @moduledoc false
    @behaviour Lemieux.Session.Guard

    @impl true
    def decide(_state, %{turns_taken: taken, max_turns: max, messages: messages})
        when taken >= max,
        do: {:stop, :max_turns, messages.turn_budget_spent(max)}

    def decide(_state, _view), do: :continue
  end

  defmodule Unbounded do
    @behaviour Lemieux.Session.Guard
    @impl true
    def decide(_state, _view), do: :continue
  end

  test "a replacement guard cannot waive the host's turn budget", context do
    {session, provider} =
      start_session(context, List.duplicate(calling(), 4), guard: Unbounded, max_turns: 1)

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    assert length(Scripted.requests(provider)) == 1
  end

  # Reports every view it is shown to the test, and defers to the default.
  defmodule Watching do
    @moduledoc false
    @behaviour Lemieux.Session.Guard

    @impl true
    def decide(test, view) do
      send(test, {:view, view})
      Guard.decide(nil, view)
    end
  end

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

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_guard_test_#{System.unique_integer([:positive])}"
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
          tools: [Stuck]
        ] ++ opts
      )

    {session, provider}
  end

  defp calling,
    do: [{:tool_call, %{id: "t", name: "stuck", arguments: %{}}}, {:done, :tool_calls}]

  test "a guard that stops after two turns ends the session with its own reason and message",
       context do
    {session, provider} =
      start_session(context, List.duplicate(calling(), 20), guard: {Enough, 2}, max_turns: 20)

    id = Session.id(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:lemieux, ^id, {:finished, :enough}}
    assert length(Scripted.requests(provider)) == 2

    {:ok, entries} = Store.read(context.store, id)

    assert Enum.any?(entries, fn entry ->
             entry.type == :error and entry.payload["reason"] == "2 turns is plenty"
           end)

    # The reason is recorded like any other stop, and the session is idle.
    assert %Entry{type: :run_evidence, payload: %{"stop_reason" => "enough"}} =
             Enum.find(entries, &(&1.type == :run_evidence))

    assert Session.snapshot(session).status == :idle
  end

  # The shipped rule would have stopped this at the third identical round.
  test "a guard that ignores repeats lets a repeating session run to its budget", context do
    {session, provider} =
      start_session(context, List.duplicate(calling(), 20), guard: Patient, max_turns: 5)

    id = Session.id(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    assert length(Scripted.requests(provider)) == 5
  end

  test "the view is the record the shipped rule reads", context do
    {session, _provider} =
      start_session(context, List.duplicate(calling(), 20),
        guard: {Watching, self()},
        max_turns: 20
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :no_progress}}

    assert_receive {:view, %{repeats: 1, turns_taken: 1} = first}
    assert_receive {:view, %{repeats: 2, turns_taken: 2}}
    assert_receive {:view, %{repeats: 3, turns_taken: 3} = third}
    refute_receive {:view, _later}

    assert first.max_turns == 20
    assert first.messages == Messages
    assert is_integer(first.last_wave)
    assert first.last_wave == third.last_wave

    assert [%{name: "stuck", error?: true}, %{name: "stuck"}, %{name: "stuck"}] =
             third.recent_calls
  end

  test "the default is the module that declares the behaviour", context do
    {session, _provider} = start_session(context, [[{:done, :stop}]], [])
    assert :sys.get_state(session).guard == {Guard, nil}

    behaviours = Guard.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    assert Guard in behaviours
  end

  test "nothing about the module reaches the transcript", context do
    {session, _provider} = start_session(context, [[{:done, :stop}]], guard: {Enough, 2})
    id = Session.id(session)

    {:ok, entries} = Store.read(context.store, id)
    assert %Entry{payload: config} = Enum.find(entries, &(&1.type == :session))
    refute Map.has_key?(config, "guard")
    refute inspect(config) =~ "Enough"
  end

  test "something that is neither a module nor a pair is refused at start", context do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             Lemieux.start_session(
               supervisor: context.runtime,
               provider: Scripted.new([]),
               store: context.store,
               model: "test:model",
               guard: "strict"
             )

    assert message =~ ":guard"
  end
end
