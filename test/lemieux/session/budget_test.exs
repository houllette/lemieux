defmodule Lemieux.Session.BudgetTest do
  # What a session reports of the bounds a host set on it: spend, requests and
  # time. A model is never told about those bounds unless something reads them
  # (#35), and `Lemieux.Extensions.Budget` reads them here.
  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"session_budget_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir)}
  end

  defp start(ctx, provider, opts) do
    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: ctx.runtime,
          provider: provider,
          store: ctx.store,
          model: "test:model",
          subscriber: self()
        ] ++ opts
      )

    session
  end

  test "a session with no bounds reports none", ctx do
    session = start(ctx, Scripted.new([]), [])

    assert Session.budget(session) == %{
             spent_usd: 0.0,
             max_cost_usd: nil,
             requests: 0,
             max_requests: nil,
             deadline_ms: nil,
             time_left_ms: nil
           }
  end

  test "the time left is measured on the session's clock from its start", ctx do
    clock = Manual.new()
    session = start(ctx, Scripted.new([]), clock: clock, deadline_ms: 60_000)

    assert %{deadline_ms: 60_000, time_left_ms: 60_000} = Session.budget(session)

    Manual.advance(clock, 15_000)
    assert %{time_left_ms: 45_000} = Session.budget(session)

    # Past it, nothing is left; the session does not stop on its own, since
    # the host that set the deadline enforces it.
    Manual.advance(clock, 50_000)
    assert %{time_left_ms: 0} = Session.budget(session)
    assert Session.info(session).status == :idle
  end

  test "requests are counted against max_requests", ctx do
    session =
      start(ctx, Scripted.new([Scripted.complete("Done.")]), max_requests: 5)

    id = Session.id(session)
    :ok = Session.prompt(session, "work")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert %{requests: 1, max_requests: 5} = Session.budget(session)
  end

  test "the deadline is recorded with the run's other limits", ctx do
    session =
      start(ctx, Scripted.new([Scripted.complete("Done.")]),
        deadline_ms: 900_000,
        max_requests: 40
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "work")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert %Entry{payload: %{"context_limits" => limits}} =
             session |> Session.snapshot() |> Map.fetch!(:entries) |> Enum.find(&harness?/1)

    assert %{"deadline_ms" => 900_000, "max_requests" => 40} = limits
  end

  test "a deadline must be a positive number of milliseconds", ctx do
    Process.flag(:trap_exit, true)

    for invalid <- [0, -1, 1.5, "60000"] do
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Lemieux.start_session(
                 supervisor: ctx.runtime,
                 provider: Scripted.new([]),
                 store: ctx.store,
                 model: "test:model",
                 deadline_ms: invalid
               )

      assert message =~ "deadline_ms"
    end
  end

  defp harness?(%Entry{type: :harness_snapshot}), do: true
  defp harness?(_entry), do: false
end
