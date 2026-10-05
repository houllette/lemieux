defmodule Lemieux.DelegatedUsageTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @tag :tmp_dir
  test "snapshot separates direct and delegated usage and reports the inclusive total", context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    direct = %{
      "input_tokens" => 10,
      "output_tokens" => 2,
      "cache_read_tokens" => 3,
      "cache_write_tokens" => 1,
      "cost_usd" => 0.01
    }

    provider = Scripted.new([Scripted.complete("done", usage: direct)])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    :ok = Session.prompt(session, "measure this")
    assert_receive {:lemieux, _id, {:finished, :stop}}
    receive_last_context()

    delegated = %{
      "input_tokens" => 20,
      "output_tokens" => 4,
      "cache_read_tokens" => 5,
      "cache_write_tokens" => 0,
      "cost_usd" => 0.02
    }

    assert {:ok, _entry} =
             Session.append_subagent_entry(session, :subagent_result, %{
               "child_id" => "child-1",
               "usage" => delegated
             })

    snapshot = Session.snapshot(session)

    assert snapshot.usage.direct["input_tokens"] == 10
    assert snapshot.usage.delegated == delegated
    assert snapshot.usage.total["input_tokens"] == 30
    assert_in_delta snapshot.usage.total["cost_usd"], 0.03, 0.000_001
    assert_in_delta snapshot.inclusive_spent_usd, 0.03, 0.000_001
    assert_in_delta snapshot.spent_usd, 0.01, 0.000_001

    # The same tokens reach the context's own accounting, kept apart from the
    # position: a child's transcript is never in the parent's next request.
    assert snapshot.context.delegated == %{input: 20, output: 4, cached: 5, cache_write: 0}
    assert snapshot.context.tokens == 16

    # A child's envelope is the durable record of what it was billed, so a
    # front end has to be told the position changed when one lands. It was
    # not, which is how a delegation's tokens ended up on the transcript and
    # on nobody's screen.
    assert_receive {:lemieux, _id, {:context, published}}
    assert published.delegated == snapshot.context.delegated
  end

  @tag :tmp_dir
  test "cancelling a turn publishes the position it stopped at", context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([Scripted.complete("done", usage: %{"input_tokens" => 7})]),
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    :ok = Session.prompt(session, "measure this")
    assert_receive {:lemieux, _id, {:finished, :stop}}

    # A delegation that was cancelled still writes its envelope, and the
    # cancel itself has to publish the position like every other ending does
    # — otherwise a status line keeps whatever the live stream left it with,
    # which after a cancellation is nothing at all.
    assert {:ok, _entry} =
             Session.append_subagent_entry(session, :subagent_result, %{
               "child_id" => "child-1",
               "status" => "cancelled",
               "usage" => %{"input_tokens" => 9_000, "output_tokens" => 20}
             })

    :ok = Session.prompt(session, "and this")
    :ok = Session.cancel(session)
    assert_receive {:lemieux, _id, {:finished, :cancelled}}

    assert published = receive_last_context()
    assert Lemieux.Context.delegated_tokens(published) == 9_020
  end

  # Several positions are published while a turn runs; the one that matters is
  # the last, which is the one a status line is showing. Draining also puts
  # the mailbox in a state where the *next* publication can be asserted on.
  defp receive_last_context(seen \\ nil) do
    receive do
      {:lemieux, _id, {:context, context}} -> receive_last_context(context)
    after
      10 -> seen
    end
  end

  @tag :tmp_dir
  test "unknown delegated pricing keeps inclusive cost unknown", context do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider:
          Scripted.new([
            Scripted.complete("done",
              usage: %{"input_tokens" => 1, "output_tokens" => 1, "cost_usd" => 0.01}
            )
          ]),
        store: JSONL.new(context.tmp_dir),
        model: "test:parent",
        tools: [],
        cwd: context.tmp_dir,
        subscriber: self()
      )

    :ok = Session.prompt(session, "measure this")
    assert_receive {:lemieux, _id, {:finished, :stop}}

    assert {:ok, _entry} =
             Session.append_subagent_entry(session, :subagent_result, %{
               "child_id" => "child-1",
               "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "cost_usd" => nil}
             })

    assert Session.snapshot(session).inclusive_spent_usd == nil
  end
end
