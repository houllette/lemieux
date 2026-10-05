defmodule Lemieux.Tool.ReceiptTest do
  @moduledoc """
  What the model is told when a tool's outcome was lost.

  The distinction under test is the one that matters to a model deciding
  whether to call again: a crashed `read` is a crashed `read`, while a
  crashed `send_email` may have sent the email.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Receipt

  defmodule Local do
    @moduledoc false
    @behaviour Lemieux.Tool
    @impl Lemieux.Tool
    def name, do: "local"
    @impl Lemieux.Tool
    def description, do: "Touches the workspace."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object"}
    @impl Lemieux.Tool
    def run(_arguments, _context), do: {:ok, "done"}
  end

  defmodule Remote do
    @moduledoc false
    @behaviour Lemieux.Tool
    @impl Lemieux.Tool
    def name, do: "remote"
    @impl Lemieux.Tool
    def description, do: "Sends something that cannot be unsent."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object"}
    @impl Lemieux.Tool
    def metadata, do: %{"effects" => %{"class" => "external"}}
    @impl Lemieux.Tool
    def run(_arguments, _context), do: {:ok, "sent"}
  end

  @call %{id: "t1", name: "remote", arguments: %{"to" => "ops"}}

  describe "record/2" do
    test "sends the receipt to the session, keyed by the call" do
      assert Receipt.record(%{session: self(), call_id: "t1"}, %{"id" => "msg_1"}) == :ok
      assert_receive {:tool_receipt, "t1", %{"id" => "msg_1"}}
    end

    test "refuses a receipt the transcript could not hold" do
      assert Receipt.record(%{session: self(), call_id: "t1"}, %{"pid" => self()}) ==
               {:error, :not_json}

      assert Receipt.record(%{session: self(), call_id: "t1"}, %{atom: "key"}) ==
               {:error, :not_json}

      refute_receive {:tool_receipt, _id, _receipt}
    end
  end

  describe "lost/5" do
    test "a local tool's crash is still a crash the model can look into" do
      result = Receipt.lost(@call, Descriptor.new(Local), nil, :crashed, "the tool crashed: boom")

      assert result.outcome == :crashed
      assert result.error?
      assert result.output == "the tool crashed: boom"
      refute Map.has_key?(result, :receipt)
    end

    test "an external tool's crash is an unknown outcome the model must check" do
      result =
        Receipt.lost(@call, Descriptor.new(Remote), nil, :crashed, "the tool crashed: boom")

      assert result.outcome == :unknown
      assert result.error?
      assert result.output =~ "the tool crashed: boom"
      assert result.output =~ "may have happened"
      assert result.output =~ "check before repeating"
      assert result.receipt == %{"lost" => "crashed"}
      assert result.tool_identity["name"] == "remote"
    end

    test "a recorded receipt makes any loss unknown, and travels with it" do
      result =
        Receipt.lost(@call, Descriptor.new(Local), %{"id" => "msg_1"}, :timeout, "stopped.")

      assert result.outcome == :unknown
      assert result.output =~ ~s(reported this receipt before it was lost: {"id":"msg_1"})
      assert result.receipt == %{"reported" => %{"id" => "msg_1"}, "lost" => "timeout"}
    end

    test "a session that ended knows nothing about any tool" do
      result =
        Receipt.lost(@call, Descriptor.new(Local), nil, :session_ended, "the session ended.")

      assert result.outcome == :unknown
      assert result.output =~ "may or may not have run"
      assert result.receipt == %{"lost" => "session_ended"}
      assert result.duration_ms == 0
    end

    test "a tool nobody can describe is treated as local" do
      result = Receipt.lost(%{id: "t1", name: "gone"}, nil, nil, :cancelled, "cancelled.")

      assert result.outcome == :cancelled
      assert result.descriptor_digest == nil
      refute Map.has_key?(result, :receipt)
    end
  end

  describe "reported/2" do
    test "attaches a receipt to a completed result and leaves an unreceipted one alone" do
      result = %{call_id: "t1", outcome: :success}

      assert Receipt.reported(result, nil) == result

      assert Receipt.reported(result, %{"id" => "msg_1"}) ==
               Map.put(result, :receipt, %{"reported" => %{"id" => "msg_1"}})
    end
  end
end
