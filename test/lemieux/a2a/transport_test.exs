defmodule Lemieux.A2A.TransportTest do
  @moduledoc """
  Which binding an address picks, and how a host adds one.

  The two built-in bindings each claim the shape they own, and a third — a
  made-up one, addressed by `{:tube, name}` — is chosen the same way once it
  is in the list. Nothing here crosses a socket or a node: what is under test
  is the choosing.
  """

  use ExUnit.Case, async: true

  alias Lemieux.A2A
  alias Lemieux.A2A.Card
  alias Lemieux.A2A.Task, as: A2ATask
  alias Lemieux.A2A.Transport.Distribution
  alias Lemieux.A2A.Transport.HTTP

  defmodule Pneumatic do
    @moduledoc false
    @behaviour Lemieux.A2A.Transport

    @impl Lemieux.A2A.Transport
    def handles?({:tube, _name}), do: true
    def handles?(_address), do: false

    @impl Lemieux.A2A.Transport
    def send_message({:tube, name}, message, opts) do
      send(self(), {:tube, name, message, opts})

      {:ok, %A2ATask{id: "tube-1", state: :completed, artifacts: [%{"text" => "#{name} heard"}]}}
    end

    @impl Lemieux.A2A.Transport
    def get_task({:tube, _name}, task_id), do: {:ok, %A2ATask{id: task_id, state: :working}}

    @impl Lemieux.A2A.Transport
    def cancel_task({:tube, _name}, task_id), do: {:ok, %A2ATask{id: task_id, state: :canceled}}

    @impl Lemieux.A2A.Transport
    def card({:tube, name}), do: {:ok, %Card{id: name, name: "tube #{name}", interfaces: []}}
  end

  # A binding that never says which addresses are its own. It can still be
  # named outright; it is never picked by shape.
  defmodule Nameless do
    @moduledoc false
    @behaviour Lemieux.A2A.Transport

    @impl Lemieux.A2A.Transport
    def send_message(address, _message, _opts),
      do: {:ok, %A2ATask{id: "nameless-1", state: :completed, artifacts: [%{"to" => address}]}}

    @impl Lemieux.A2A.Transport
    def get_task(_address, task_id), do: {:ok, %A2ATask{id: task_id, state: :working}}

    @impl Lemieux.A2A.Transport
    def cancel_task(_address, task_id), do: {:ok, %A2ATask{id: task_id, state: :canceled}}

    @impl Lemieux.A2A.Transport
    def card(_address), do: {:ok, %Card{id: "nameless", name: "nameless", interfaces: []}}
  end

  describe "the built-in bindings" do
    test "are distribution and then HTTP" do
      assert A2A.transports() == [Distribution, HTTP]
    end

    test "each claims the shape it owns and no other" do
      assert Distribution.handles?(:agent@host)
      refute Distribution.handles?("http://agent.example/a2a")

      assert HTTP.handles?("http://agent.example/a2a")
      assert HTTP.handles?("https://agent.example/a2a")
      refute HTTP.handles?(:agent@host)
      refute HTTP.handles?({:tube, "lab"})
    end

    test "do not claim a made-up shape, so it is refused rather than guessed at" do
      assert {:error, message} = A2A.ask({:tube, "lab"}, "hello")

      assert message =~ "not an agent address"
      assert message =~ "a node like"
    end
  end

  describe "a host binding in the list" do
    test "is chosen by the shape it claims, and carries every operation" do
      transports = [Pneumatic | A2A.transports()]
      address = {:tube, "lab"}

      assert {:ok, %A2ATask{state: :completed, artifacts: [%{"text" => "lab heard"}]}} =
               A2A.ask(address, "hello", transports: transports)

      assert {:ok, %Card{name: "tube lab"}} = A2A.card(address, transports: transports)

      assert {:ok, %A2ATask{id: "t1", state: :working}} =
               A2A.task(address, "t1", transports: transports)

      assert {:ok, %A2ATask{id: "t1", state: :canceled}} =
               A2A.cancel(address, "t1", transports: transports)
    end

    test "the first binding to claim the address wins, and one that never claims is passed over" do
      assert {:ok, %A2ATask{id: "tube-1"}} =
               A2A.ask({:tube, "lab"}, "hello", transports: [Nameless, Pneumatic])
    end

    test "the routing options stay with the router; the binding sees the rest" do
      assert {:ok, _task} =
               A2A.ask({:tube, "lab"}, "hello", transports: [Pneumatic], timeout: 5)

      assert_received {:tube, "lab", "hello", opts}
      assert opts == [timeout: 5]
    end

    test "a list without a claimant refuses the address and names what was tried" do
      assert {:error, message} = A2A.ask({:tube, "lab"}, "hello", transports: [Nameless])

      assert message =~ "not an agent address"
      assert message =~ "Nameless"
      refute message =~ "a node like"
    end
  end

  describe "naming the binding outright" do
    test "uses it whatever the address looks like" do
      assert {:ok, %A2ATask{artifacts: [%{"to" => "anything at all"}]}} =
               A2A.ask("anything at all", "hello", transport: Nameless)

      assert {:ok, %Card{name: "nameless"}} = A2A.card(123, transport: Nameless)
    end

    test "wins over a list that would have chosen differently" do
      assert {:ok, %A2ATask{id: "nameless-1"}} =
               A2A.ask({:tube, "lab"}, "hello", transport: Nameless, transports: [Pneumatic])
    end
  end
end
