defmodule Lemieux.Extensions.BudgetTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Extensions
  alias Lemieux.Extensions.Budget
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Ping do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "ping"

    @impl true
    def description, do: "Answers pong."

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}}

    # Each answer its own, or the session's no-progress guard would end a run
    # of identical calls before the budget is used.
    @impl true
    def run(%{"n" => n}, _context), do: {:ok, "pong #{n}"}
    def run(_args, _context), do: {:ok, "pong"}

    @impl true
    def read_only?, do: true

    @impl true
    def parallel_safe?, do: true
  end

  describe "init/1" do
    test "rejects options it would silently ignore, and thresholds that cannot be reached" do
      assert {:error, message} = Budget.init(threshold: [0.5])
      assert message =~ "threshold"

      for invalid <- [[], [1.0], [-0.1], [0.5, 0.5], ["half"], 0.5] do
        assert {:error, message} = Budget.init(thresholds: invalid), inspect(invalid)
        assert message =~ "thresholds"
      end

      assert {:error, _} = Budget.init(enabled: "yes")

      assert {:ok, %Budget{thresholds: [0.0, 0.5, 0.75, 0.9], enabled: true}} = Budget.init([])
      assert {:ok, %Budget{thresholds: [0.25, 0.8]}} = Budget.init(thresholds: [0.8, 0.25])
    end

    test "the coding recipe offers it by name, off unless asked" do
      refute Keyword.has_key?(Extensions.coding("test:model", Scripted.new([])), :budget)

      recipe =
        Extensions.coding("test:model", Scripted.new([]), budget: true, delegate: false)

      assert recipe[:budget] == Budget
    end
  end

  describe "in a session" do
    setup %{tmp_dir: tmp_dir} do
      runtime = :"budget_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      %{runtime: runtime, store: JSONL.new(tmp_dir), cwd: tmp_dir}
    end

    defp start(ctx, script, session_opts, budget_opts \\ []) do
      provider = Scripted.new(script)
      {:ok, harness} = Harness.assemble(Harness.new(), [{Budget, budget_opts}])

      {:ok, session} =
        Lemieux.start_session(
          [
            supervisor: ctx.runtime,
            store: ctx.store,
            provider: provider,
            model: "test:budget",
            cwd: ctx.cwd,
            subscriber: self(),
            tools: [Ping],
            harness: harness
          ] ++ session_opts
        )

      {session, provider}
    end

    defp run(session) do
      id = Session.id(session)
      :ok = Session.prompt(session, "work")
      assert_receive {:lemieux, ^id, {:finished, reason}}
      reason
    end

    defp ping(id), do: Scripted.tool_call(id, "ping", %{"n" => System.unique_integer()})

    # What each tool result told the model, oldest first.
    defp outputs(session) do
      for %Entry{type: :tool_result, payload: payload} <- Session.snapshot(session).entries,
          do: payload["output"]
    end

    defp notices(session), do: session |> outputs() |> Enum.filter(&(&1 =~ Budget.marker()))

    test "the first tool result says what the session has, in all", ctx do
      {session, _provider} =
        start(ctx, [ping("p1"), Scripted.complete("Done.")],
          max_requests: 10,
          deadline_ms: 600_000,
          clock: Manual.new()
        )

      assert run(session) == :stop
      assert [first] = outputs(session)

      assert first =~ "pong"
      assert first =~ Budget.marker()
      assert first =~ "This session has about 10 minutes and 9 requests left"
      # The advice the issue asked for, given where a limit is known to exist
      # rather than paid for on every request of every session.
      assert first =~ "put a valid result where the task requires it as soon as you have one"
      assert first =~ "improve it in place"
    end

    test "each threshold is told once, as the requests are used", ctx do
      script = for(n <- 1..9, do: ping("p#{n}")) ++ [Scripted.complete("Done.")]
      {session, provider} = start(ctx, script, max_requests: 10)

      assert run(session) == :stop
      assert length(Scripted.requests(provider)) == 10

      told =
        session
        |> outputs()
        |> Enum.with_index(1)
        |> Enum.filter(fn {output, _n} -> output =~ Budget.marker() end)
        |> Enum.map(fn {_output, n} -> n end)

      # 10%, 50%, 80% (past 75%) and 90% of ten requests.
      assert told == [1, 5, 8, 9]

      assert [_first, half, three_quarters, last] = notices(session)
      assert half =~ "5 requests are left (50% used)"
      assert three_quarters =~ "2 requests are left (80% used)"
      assert last =~ "1 request is left (90% used)"
    end

    test "time is read on the session's clock", ctx do
      clock = Manual.new()

      later = fn _request ->
        Manual.advance(clock, 300_000)
        ping("p2")
      end

      {session, _provider} =
        start(ctx, [ping("p1"), later, Scripted.complete("Done.")],
          deadline_ms: 600_000,
          clock: clock
        )

      assert run(session) == :stop
      assert [first, second] = notices(session)
      assert first =~ "This session has about 10 minutes left"
      assert second =~ "About 5 minutes are left (50% used)"
      refute second =~ "request"
    end

    test "calls made together get one notice between them", ctx do
      calls = for n <- 1..3, do: %{id: "p#{n}", name: "ping", arguments: %{"n" => n}}

      {session, _provider} =
        start(ctx, [Scripted.tool_calls(calls), Scripted.complete("Done.")], max_requests: 10)

      assert run(session) == :stop
      assert length(outputs(session)) == 3
      assert [_one] = notices(session)
    end

    test "a session without a limit is told nothing", ctx do
      {session, _provider} = start(ctx, [ping("p1"), Scripted.complete("Done.")], [])

      assert run(session) == :stop
      assert [output] = outputs(session)
      assert output =~ "pong"
      refute output =~ Budget.marker()
    end

    test "turned off, it says nothing", ctx do
      {session, _provider} =
        start(ctx, [ping("p1"), Scripted.complete("Done.")], [max_requests: 10], enabled: false)

      assert run(session) == :stop
      assert notices(session) == []
    end
  end
end
