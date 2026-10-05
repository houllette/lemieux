defmodule Lemieux.A2A.HTTPTest do
  @moduledoc """
  The HTTP binding, over a real socket.

  `LemieuxTest.HTTPAgent` says why it is a socket rather than an in-process
  double: the two things most worth getting wrong here — that a JSON-RPC error
  arrives with HTTP 200, and that the card is not at the RPC endpoint — are
  both properties of the wire, and a double would agree with whatever the
  client did.
  """

  use ExUnit.Case, async: true

  alias Lemieux.A2A
  alias Lemieux.A2A.Card
  alias Lemieux.A2A.JSONRPC
  alias Lemieux.A2A.Task, as: A2ATask
  alias Lemieux.A2A.Transport.HTTP

  # A stand-in agent answering through the same `dispatch/2` a host would wire
  # into its own plug, which is the half of the codec the client never sees.
  defp agent do
    LemieuxTest.HTTPAgent.start(fn
      "/.well-known/agent-card.json", _body ->
        {200,
         Card.to_json(%Card{
           id: "stub-1",
           name: "the stub",
           interfaces: [{:jsonrpc, "http://elsewhere/a2a"}]
         })}

      _rpc, body ->
        {200, JSONRPC.dispatch(body, &answer/2)}
    end)
  end

  defp answer(:send_message, _params) do
    {:ok,
     %{
       "task" =>
         A2ATask.to_json(%A2ATask{
           id: "t1",
           state: :completed,
           artifacts: [%{"text" => "from the other side"}]
         })
     }}
  end

  defp answer(:get_task, %{"id" => "t1"}),
    do: {:ok, A2ATask.to_json(%A2ATask{id: "t1", state: :working})}

  defp answer(:get_task, _params), do: {:error, "TaskNotFound", "no such task"}
  defp answer(_operation, _params), do: {:error, "UnsupportedOperation", "not here"}

  describe "asking an agent over HTTP" do
    setup do: %{url: agent() <> "/a2a"}

    test "the answer comes back as a task", %{url: url} do
      assert {:ok, task} = HTTP.send_message(url, %{"parts" => [%{"text" => "hello"}]})

      assert task.state == :completed
      assert A2ATask.text(task) == "from the other side"
    end

    test "a task can be looked up", %{url: url} do
      assert {:ok, task} = HTTP.get_task(url, "t1")

      assert task.state == :working
    end

    # The one that a stub cannot catch: this is an HTTP 200 whose body says
    # the call failed, so a client reading the status is wrong and looks right.
    test "a named failure arrives as a readable error, despite the 200", %{url: url} do
      assert {:error, message} = HTTP.get_task(url, "t9")

      assert message =~ "TaskNotFound"
      assert message =~ "no such task"
    end

    test "and it goes through the front door too", %{url: url} do
      assert {:ok, task} = A2A.ask(url, %{"parts" => [%{"text" => "hello"}]})

      assert task.state == :completed
    end
  end

  describe "the card" do
    test "is fetched from the well-known path, not from under the endpoint" do
      assert {:ok, card} = HTTP.card(agent() <> "/a2a/rpc")

      assert card.name == "the stub"
      assert {:ok, "http://elsewhere/a2a"} = Card.reachable(card, :jsonrpc)
    end
  end

  describe "when the other end misbehaves" do
    test "a non-2xx is a transport failure rather than an agent's answer" do
      url = LemieuxTest.HTTPAgent.start(fn _path, _body -> {503, %{"nope" => true}} end)

      assert {:error, message} = HTTP.get_task(url <> "/a2a", "t1")
      assert message =~ "503"
    end

    test "a result that is not a task is refused rather than half-read" do
      url =
        LemieuxTest.HTTPAgent.start(fn _path, _body ->
          {200, JSONRPC.reply("req-1", %{"something" => "else"})}
        end)

      assert {:error, message} = HTTP.get_task(url <> "/a2a", "t1")
      assert message =~ "id does not match"
    end

    test "and a host that is not listening says so" do
      # Port 1 on loopback: nothing is there, and nothing is going to be.
      assert {:error, message} = HTTP.get_task("http://127.0.0.1:1/a2a", "t1")

      assert message =~ "could not reach"
    end
  end

  describe "which binding an address picks" do
    test "an address that is neither a node nor a URL is refused, not guessed at" do
      assert {:error, message} = A2A.ask(123, "hello")

      assert message =~ "not an agent address"
    end
  end
end
