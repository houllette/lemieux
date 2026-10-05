defmodule Lemieux.A2A.WireTest do
  use ExUnit.Case, async: true
  alias Lemieux.A2A.{Card, JSONRPC, Message, SSE, Task}
  alias Lemieux.A2A.Transport.HTTP

  defp fixture(name),
    do: File.read!(Path.join(["test", "fixtures", "a2a", name <> ".json"])) |> JSON.decode!()

  defp reply(body, result) do
    request = JSON.decode!(body)
    %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
  end

  test "independent cards select JSONRPC 1.0 despite unsupported preferred bindings" do
    assert {:ok, card} = Card.from_json(fixture("agent-card"))
    assert Card.reachable(card, :jsonrpc) == {:ok, "https://example.org/rpc"}

    json =
      put_in(
        fixture("agent-card"),
        ["supportedInterfaces", Access.at(1), "protocolVersion"],
        "9.0"
      )

    assert {:ok, future} = Card.from_json(json)
    assert Card.reachable(future, :jsonrpc) == :error
  end

  test "canonical outbound messages and SendMessage task/message unions" do
    parent = self()

    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        request = JSON.decode!(body)
        send(parent, {:request, request})
        {200, reply(body, %{"task" => fixture("task")})}
      end)

    assert {:ok, task} = HTTP.send_message(url, "hello")
    assert Task.text(task) == "Independent response"
    assert_receive {:request, request}
    assert request["method"] == "SendMessage"

    assert %{"role" => "ROLE_USER", "parts" => [%{"text" => "hello"}], "messageId" => id} =
             request["params"]["message"]

    assert is_binary(id) and id != ""

    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        {200,
         reply(body, %{
           "message" => %{
             "messageId" => "reply",
             "role" => "ROLE_AGENT",
             "parts" => [%{"text" => "direct"}]
           }
         })}
      end)

    assert {:ok, %{"messageId" => "reply"}} = HTTP.send_message(url, "hello")
  end

  test "credentials and limits reach every operation through the public facade" do
    parent = self()

    url =
      LemieuxTest.HTTPAgent.start(fn path, body, headers ->
        send(parent, {:headers, headers})

        if path == "/.well-known/agent-card.json",
          do: {200, fixture("agent-card")},
          else: {200, reply(body, fixture("task"))}
      end)

    for operation <- [:card, :task, :cancel] do
      result =
        if operation == :card,
          do: Lemieux.A2A.card(url, auth: {:bearer, "fixture-token"}),
          else: apply(Lemieux.A2A, operation, [url, "id", [auth: {:bearer, "fixture-token"}]])

      assert {:ok, _} = result
      assert_receive {:headers, headers}
      assert headers["authorization"] == "Bearer fixture-token"
      assert headers["a2a-version"] == "1.0"
    end

    assert {:error, error} = HTTP.get_task(url, "id", max_response_bytes: 10)
    assert error =~ "limit"
  end

  test "response correlation and malformed unions fail before returning data" do
    url =
      LemieuxTest.HTTPAgent.start(fn _path, _body ->
        {200, %{"jsonrpc" => "2.0", "id" => "wrong", "result" => fixture("task")}}
      end)

    assert {:error, error} = HTTP.get_task(url, "id")
    assert error =~ "id does not match"

    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        {200, reply(body, %{"task" => fixture("task"), "message" => Message.agent("ambiguous")})}
      end)

    assert {:error, error} = HTTP.send_message(url, "hello")
    assert error =~ "union"
  end

  test "streaming delivers deltas incrementally and reconstructs a canonical task" do
    parent = self()

    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        request = JSON.decode!(body)
        send(parent, {:method, request["method"]})
        id = request["id"]

        task = %{
          "id" => "stream-task",
          "contextId" => "context",
          "status" => %{"state" => "TASK_STATE_WORKING"}
        }

        envelopes =
          [
            %{"task" => task},
            %{
              "artifactUpdate" => %{
                "taskId" => "stream-task",
                "contextId" => "context",
                "append" => false,
                "artifact" => %{"artifactId" => "answer", "parts" => [%{"text" => "first "}]}
              }
            },
            %{
              "artifactUpdate" => %{
                "taskId" => "stream-task",
                "contextId" => "context",
                "append" => true,
                "artifact" => %{"artifactId" => "answer", "parts" => [%{"text" => "second"}]}
              }
            },
            %{
              "statusUpdate" => %{
                "taskId" => "stream-task",
                "contextId" => "context",
                "status" => %{"state" => "TASK_STATE_COMPLETED"}
              }
            }
          ]
          |> Enum.map(fn result ->
            "data: " <>
              JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\r\n\r\n"
          end)

        {200, "text/event-stream", envelopes, 20}
      end)

    work = Elixir.Task.async(fn -> HTTP.send_message(url, "hello", stream: parent) end)
    assert_receive {:method, "SendStreamingMessage"}
    assert_receive {:a2a, "stream-task", {:delta, "first "}}
    assert_receive {:a2a, "stream-task", {:delta, "second"}}
    assert {:ok, task} = Elixir.Task.await(work)
    assert task.state == :completed
    assert Task.text(task) == "first second"
    assert {:ok, task} = HTTP.subscribe(url, "stream-task", stream: self())
    assert task.state == :completed
    assert_receive {:method, "SubscribeToTask"}
  end

  test "premature EOF and malformed streaming parts are failures" do
    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        id = JSON.decode!(body)["id"]

        frame =
          "data: " <>
            JSON.encode!(%{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "task" => %{"id" => "t", "status" => %{"state" => "TASK_STATE_WORKING"}}
              }
            }) <> "\n\n"

        {200, "text/event-stream", [frame], 0}
      end)

    assert {:error, error} = HTTP.subscribe(url, "t")
    assert error =~ "ended before"
    assert {:error, _} = SSE.feed("", "data: " <> String.duplicate("x", 40), 10)
    assert {:error, _} = SSE.feed("", "data: invalid\n\n", 100)
  end

  test "SSE framing tolerates comments, split CRLF and multiline JSON" do
    assert {:ok, buffer, []} = SSE.feed("", ": keepalive\r\n\r", 1000)
    assert {:ok, "", []} = SSE.feed(buffer, "\n", 1000)

    assert {:ok, buffer, []} =
             SSE.feed(
               "",
               "data: {\r\ndata: \"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}\r\ndata: }\r",
               1000
             )

    assert {:ok, "", [frame]} = SSE.feed(buffer, "\n\r\n", 1000)
    assert frame["id"] == 1
  end

  test "malformed peer data and requests return errors instead of raising" do
    for bad <- [
          nil,
          [],
          9,
          %{"id" => "t", "status" => nil},
          %{"id" => "t", "status" => %{"state" => 9}},
          put_in(fixture("task"), ["artifacts"], [nil])
        ] do
      assert {:error, _} = Task.from_json(bad)
    end

    for bad <- [
          nil,
          [],
          %{"name" => "x", "skills" => nil},
          Map.put(fixture("agent-card"), "capabilities", nil)
        ] do
      assert {:error, _} = Card.from_json(bad)
    end

    never = fn _, _ -> flunk("malformed input reached handler") end

    for request <- [
          %{"method" => 9, "id" => 1},
          %{"method" => "GetTask", "id" => %{}},
          %{"method" => "GetTask", "id" => 1, "params" => []}
        ] do
      assert %{"error" => _} =
               JSONRPC.dispatch(JSON.encode!(Map.put(request, "jsonrpc", "2.0")), never)
    end

    assert %{"error" => %{"code" => -32_001}} = JSONRPC.error(1, "TaskNotFound", "missing")
    assert %{"error" => %{"code" => -32_002}} = JSONRPC.error(1, "TaskNotCancelable", "ended")
  end

  test "a direct streaming Message is accepted and a slow stream has an absolute deadline" do
    message = %{
      "messageId" => "direct",
      "role" => "ROLE_AGENT",
      "parts" => [%{"text" => "hello"}]
    }

    url =
      LemieuxTest.HTTPAgent.start(fn _path, body ->
        id = JSON.decode!(body)["id"]

        frame =
          "data: " <>
            JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"message" => message}}) <>
            "\n\n"

        {200, "text/event-stream", [frame], 0}
      end)

    assert {:ok, ^message} = HTTP.send_message(url, "hello", stream: self())
    assert_receive {:a2a, "direct", {:message, ^message}}

    slow =
      LemieuxTest.HTTPAgent.start(fn _path, _body ->
        {200, "text/event-stream", List.duplicate(": keepalive\n\n", 20), 10}
      end)

    assert {:error, _} = HTTP.subscribe(slow, "task", timeout: 30)
  end
end
