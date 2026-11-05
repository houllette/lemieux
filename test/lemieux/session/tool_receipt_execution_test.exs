defmodule Lemieux.Session.ToolReceiptExecutionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Receipt

  @moduletag :tmp_dir

  defmodule Held do
    @behaviour Lemieux.Tool

    def name, do: "held"
    def description, do: "Waits for the test to finish the call."
    def schema, do: %{"type" => "object", "properties" => %{}}

    def run(_args, _context) do
      receive do
        :finish -> {:ok, "done"}
      end
    end
  end

  for ending <- [:completed, :cancelled] do
    @tag ending: ending
    test "a receipt from a #{ending} execution cannot attach to a reused call ID", context do
      parent = self()
      runtime = :"receipt_execution_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      call = Scripted.tool_call("reused", "held", %{})

      first =
        if context.ending == :completed, do: [call, Scripted.complete("first")], else: [call]

      provider = Scripted.new(first ++ [call, Scripted.complete("second")])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: provider,
          model: "test:model",
          store: JSONL.new(context.tmp_dir),
          subscriber: self(),
          tools: [Held],
          hooks: [
            before_tool_call: fn _call, tool_context ->
              send(parent, {:running, self(), tool_context})
              :allow
            end
          ]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "first")
      assert_receive {:running, first_worker, first_context}
      first_monitor = Process.monitor(first_worker)

      case context.ending do
        :completed -> send(first_worker, :finish)
        :cancelled -> assert :ok = Session.cancel(session)
      end

      assert_receive {:lemieux, ^id, {:finished, _reason}}
      assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, _reason}

      :ok = Session.prompt(session, "second")
      assert_receive {:running, second_worker, second_context}

      # A helper can retain the old context after its original task is gone.
      # The provider's call ID is deliberately identical in both executions.
      assert :ok = Receipt.record(first_context, %{"id" => "old"})
      assert Session.info(session).status == :busy
      refute_received {:lemieux, ^id, {:tool_receipt, %{receipt: %{"id" => "old"}}}}

      # Recording from another process with the current context still works.
      assert :ok = Receipt.record(second_context, %{"id" => "current"})

      assert_receive {:lemieux, ^id,
                      {:tool_receipt,
                       %{call_id: "reused", name: "held", receipt: %{"id" => "current"}}}}

      send(second_worker, :finish)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      results =
        for %Entry{type: :tool_result, payload: payload} <- Session.snapshot(session).entries,
            do: payload

      assert [first_result, second_result] = results
      refute Map.has_key?(first_result, "receipt")
      assert second_result["receipt"] == %{"reported" => %{"id" => "current"}}
    end
  end
end
