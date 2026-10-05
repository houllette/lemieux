defmodule Lemieux.A2A.JSONRPCTest do
  use ExUnit.Case, async: true

  alias Lemieux.A2A.Card
  alias Lemieux.A2A.JSONRPC
  alias Lemieux.A2A.Task, as: A2ATask

  describe "method names" do
    # The names changed in 1.0, and code written from memory of 0.3 talks to
    # nothing. Pinned here so a rename is a failing test rather than a
    # method-not-found from somebody else's agent.
    test "are the PascalCase ones 1.0 uses, not 0.3's paths" do
      assert JSONRPC.method(:send_message) == "SendMessage"
      assert JSONRPC.method(:get_task) == "GetTask"
      assert JSONRPC.method(:cancel_task) == "CancelTask"
    end

    test "round-trip" do
      for operation <- [:send_message, :get_task, :cancel_task, :list_tasks] do
        assert {:ok, ^operation} = operation |> JSONRPC.method() |> JSONRPC.from_method()
      end
    end

    test "and an unknown one is not guessed at" do
      assert JSONRPC.from_method("message/send") == :error
    end
  end

  describe "envelopes" do
    test "a request carries the version, the id and the method" do
      envelope = JSONRPC.request(:send_message, %{"message" => "hi"}, "req-1")

      assert envelope["jsonrpc"] == "2.0"
      assert envelope["id"] == "req-1"
      assert envelope["method"] == "SendMessage"
      assert envelope["params"] == %{"message" => "hi"}
    end

    test "encode and decode round-trip" do
      envelope = JSONRPC.request(:get_task, %{"id" => "t1"}, "req-2")

      assert {:ok, decoded} = envelope |> JSONRPC.encode() |> JSONRPC.decode()
      assert decoded == envelope
    end

    test "a body that is not JSON is a parse error rather than a raise" do
      assert {:error, failure} = JSONRPC.decode("not json at all")

      assert failure["error"]["code"] == -32_700
    end

    test "valid JSON that is not JSON-RPC is refused too" do
      assert {:error, failure} = JSONRPC.decode(~s({"hello": "world"}))

      assert failure["error"]["code"] == -32_600
    end
  end

  describe "results and failures" do
    test "a result comes back" do
      assert {:ok, %{"id" => "t1"}} = JSONRPC.result(JSONRPC.reply("req-1", %{"id" => "t1"}))
    end

    # Codes and ErrorInfo follow the pinned A2A 1.0 registry.
    test "a failure carries the registered code and ErrorInfo name" do
      envelope = JSONRPC.error("req-1", "TaskNotFound", "no task t9 here")

      assert envelope["error"]["code"] == -32_001
      assert hd(envelope["error"]["data"])["metadata"]["name"] == "TaskNotFound"
      assert {:error, message} = JSONRPC.result(envelope)
      assert message =~ "TaskNotFound"
      assert message =~ "no task t9 here"
    end

    test "and a response that is neither says so" do
      assert {:error, message} = JSONRPC.result(%{"jsonrpc" => "2.0", "id" => 1})
      assert message =~ "neither"
    end
  end

  describe "dispatch/2 — what a host wires into a plug" do
    defp handler do
      fn
        :get_task, %{"id" => "t1"} -> {:ok, %{"id" => "t1"}}
        :get_task, _params -> {:error, "TaskNotFound", "no such task"}
        _operation, _params -> {:error, "UnsupportedOperation", "not here"}
      end
    end

    test "runs the operation and replies with its result" do
      body = JSONRPC.encode(JSONRPC.request(:get_task, %{"id" => "t1"}, "req-1"))

      assert %{"result" => %{"id" => "t1"}, "id" => "req-1"} = JSONRPC.dispatch(body, handler())
    end

    test "turns a named failure into an error envelope" do
      body = JSONRPC.encode(JSONRPC.request(:get_task, %{"id" => "t9"}, "req-1"))

      assert %{"error" => error} = JSONRPC.dispatch(body, handler())
      assert hd(error["data"])["metadata"]["name"] == "TaskNotFound"
    end

    # A peer speaking a later version of the protocol will happen, and it is
    # not an error in this agent.
    test "an unknown method is a method-not-found rather than a crash" do
      body = ~s({"jsonrpc":"2.0","id":"req-1","method":"SomethingNewer","params":{}})

      assert %{"error" => error} = JSONRPC.dispatch(body, handler())
      assert error["code"] == -32_601
      assert hd(error["data"])["metadata"]["name"] == "MethodNotFound"
    end

    test "and a malformed body never reaches the handler" do
      never = fn _operation, _params -> flunk("the handler should not have been called") end

      assert %{"error" => error} = JSONRPC.dispatch("{", never)
      assert error["code"] == -32_700
    end
  end

  describe "the shapes that go on the wire" do
    test "a task round-trips through JSON" do
      task = %A2ATask{
        id: "t1",
        context_id: "c1",
        state: :input_required,
        message: "which environment?",
        artifacts: [%{"text" => "so far"}]
      }

      assert {:ok, back} = task |> A2ATask.to_json() |> A2ATask.from_json()
      assert back.state == task.state
      assert back.message == task.message
      assert A2ATask.text(back) == A2ATask.text(task)
    end

    test "a state this build does not know is refused rather than defaulted" do
      json = %{"id" => "t1", "status" => %{"state" => "TASK_STATE_NAPPING"}}

      assert {:error, message} = A2ATask.from_json(json)
      assert message =~ "invalid task"
    end

    test "a card round-trips, with its interfaces as objects" do
      card = %Card{
        id: "agent-1",
        name: "the backend",
        description: "answers questions",
        interfaces: [{:jsonrpc, "https://example.com/a2a"}]
      }

      json = Card.to_json(card)

      assert [
               %{
                 "protocolBinding" => "JSONRPC",
                 "protocolVersion" => "1.0",
                 "url" => "https://example.com/a2a"
               }
             ] =
               json["supportedInterfaces"]

      assert {:ok, back} = Card.from_json(json)
      assert %{back | id: card.id} == card
      assert Card.reachable(back, :jsonrpc) == {:ok, "https://example.com/a2a"}
    end

    test "an unknown binding does not create atoms or hide compatible interfaces" do
      transport = "unknown-#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(transport) end

      json =
        Card.to_json(%Card{
          name: "future peer",
          interfaces: [{:jsonrpc, "https://example.com/rpc"}]
        })

      json =
        Map.update!(
          json,
          "supportedInterfaces",
          &[
            %{
              "protocolBinding" => transport,
              "protocolVersion" => "1.1",
              "url" => "https://example.com/new"
            }
            | &1
          ]
        )

      assert {:ok, card} = Card.from_json(json)
      assert Card.reachable(card, :jsonrpc) == {:ok, "https://example.com/rpc"}
      assert_raise ArgumentError, fn -> String.to_existing_atom(transport) end
    end

    test "and JSON encoding actually works on both, which structs do not do for free" do
      card = %Card{id: "a", name: "n", skills: []}

      assert is_binary(card |> Card.to_json() |> JSON.encode!())
      assert is_binary(%A2ATask{id: "t"} |> A2ATask.to_json() |> JSON.encode!())
    end
  end
end
