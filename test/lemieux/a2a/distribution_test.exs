defmodule Lemieux.A2A.DistributionTest do
  @moduledoc """
  One agent asking another, across two real BEAM nodes.

  The serving node is a peer with this project's code path, running its own
  `Lemieux.A2A.Server` — so the calls under test really do cross a node
  boundary, and the read-only rule is enforced by the agent being asked rather
  than by the test's idea of it.

  `async: false`: distribution names the whole VM.
  """

  use ExUnit.Case, async: false

  alias Lemieux.A2A.Card
  alias Lemieux.A2A.Task, as: A2ATask
  alias Lemieux.A2A.Transport.Distribution

  @moduletag :distributed
  @moduletag :tmp_dir

  setup_all do
    unless Node.alive?(),
      do:
        {:ok, _pid} =
          Node.start(:"lmx-a2a-test@127.0.0.1", name_domain: :longnames)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    {:ok, _peer, agent} =
      :peer.start_link(%{
        name: :"agent#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-pa" | Enum.filter(:code.get_path(), &File.dir?/1)]
      })

    {:ok, _apps} = :erpc.call(agent, :application, :ensure_all_started, [:elixir])

    %{agent: agent, tmp_dir: tmp_dir}
  end

  # Every call to the far node names a module it can resolve. Anonymous
  # functions cannot cross: one closed over this test module arrives as
  # `:undef`, because a `.exs` has no object code for the other side to load.
  defp serving(agent, tmp_dir, script, opts \\ []) do
    :erpc.call(agent, LemieuxTest.A2AAgent, :start, [tmp_dir, script, opts], 30_000)
  end

  defp asking(text), do: %{"parts" => [%{"text" => text}]}

  describe "asking another agent something" do
    test "the answer comes back as a completed task", %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "the orders table has 12 rows"})

      assert {:ok, task} = Distribution.send_message(agent, asking("how many orders?"))

      assert task.state == :completed
      assert A2ATask.terminal?(task)
      assert [%{"text" => answer}] = task.artifacts
      assert answer =~ "12 rows"
    end

    test "and the task can be looked up again afterwards", %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "done"})

      {:ok, task} = Distribution.send_message(agent, asking("anything"))

      assert {:ok, ^task} = Distribution.get_task(agent, task.id)
    end

    test "a plain string is accepted as well as parts", %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "fine"})

      assert {:ok, task} = Distribution.send_message(agent, "just a string")
      assert task.state == :completed
    end

    test "a part it cannot read is rejected without spending a provider turn",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, :echo_prompt)

      message = %{"parts" => [%{"text" => "look at"}, %{"url" => "https://example.com/x"}]}

      assert {:error, message} = Distribution.send_message(agent, message)
      assert message =~ "ContentTypeNotSupported"
    end

    test "a remote task gets the read-only tools and nothing else",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, :report_tools)

      assert {:ok, task} = Distribution.send_message(agent, asking("what can you do?"))
      assert [%{"text" => offered}] = task.artifacts

      assert offered == "read"
      refute offered =~ "bash"
      refute offered =~ "write"
      refute offered =~ "edit"
    end

    test "even when the operator's own session has more", %{agent: agent, tmp_dir: tmp_dir} do
      # Serving with every tool there is, including the one that runs code.
      :ok =
        serving(agent, tmp_dir, :report_tools,
          tools: Lemieux.Tools.default() ++ [Lemieux.Tools.Eval]
        )

      assert {:ok, task} = Distribution.send_message(agent, asking("what can you do?"))
      assert [%{"text" => offered}] = task.artifacts

      assert offered == "read"
      refute offered =~ "elixir"
    end
  end

  describe "a question the answering agent needs help with" do
    test "comes back as input_required, which is not an ending",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, :asks_then_answers)

      assert {:ok, asking} = Distribution.send_message(agent, asking("is it deployed?"))

      assert asking.state == :input_required
      assert A2ATask.interrupted?(asking)
      refute A2ATask.terminal?(asking)
      assert asking.message =~ "which environment?"
    end

    test "and answering it continues the same task rather than starting another",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, :asks_then_answers)

      {:ok, asking} = Distribution.send_message(agent, asking("is it deployed?"))

      answer = %{"taskId" => asking.id, "parts" => [%{"text" => "production"}]}

      assert {:ok, done} = Distribution.send_message(agent, answer)

      # The same task, finished — not a second one.
      assert done.id == asking.id
      assert done.state == :completed
      assert [%{"text" => text}] = done.artifacts
      assert text =~ "in production"
    end
  end

  describe "watching a task as it happens" do
    test "a caller that asks to stream gets deltas and the ending",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "the answer"})

      assert {:ok, task} =
               Distribution.send_message(agent, asking("anything"), stream: self())

      id = task.id

      assert_received {:a2a, ^id, {:delta, "the answer"}}
      assert_received {:a2a, ^id, {:status, %A2ATask{state: :completed}}}
    end

    test "and a caller that does not ask is not sent anything",
         %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "quietly"})

      assert {:ok, _task} = Distribution.send_message(agent, asking("anything"))

      refute_received {:a2a, _id, _event}
    end
  end

  describe "the card" do
    test "says who the agent is and how to reach it", %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "hi"})

      assert {:ok, %Card{} = card} = Distribution.card(agent)

      assert card.name == "the backend"
      assert {:ok, ^agent} = Card.reachable(card, :distribution)
      assert Card.reachable(card, :jsonrpc) == :error
    end

    test "and promises only what it will actually do", %{agent: agent, tmp_dir: tmp_dir} do
      :ok = serving(agent, tmp_dir, {:says, "hi"})

      assert {:ok, card} = Distribution.card(agent)
      assert [skill] = card.skills

      assert skill.description =~ "will not change anything"
      assert "read-only" in skill.tags
    end
  end

  describe "when the other end is not what was hoped" do
    test "a node that is not an lmx agent says so", %{tmp_dir: _tmp_dir} do
      {:ok, _peer, bare} =
        :peer.start_link(%{
          name: :"bare#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true
        })

      assert {:error, message} = Distribution.card(bare)
      assert message =~ "not an lmx agent"
    end

    test "an lmx node that is not answering says something different", %{
      agent: agent,
      tmp_dir: _tmp
    } do
      # A runtime, but no server started on it.
      :ok = :erpc.call(agent, LemieuxTest.A2AAgent, :start_silent, [], 30_000)

      assert {:error, message} = Distribution.card(agent)
      assert message =~ "not answering to other agents"
    end

    test "a node that has gone away says that", %{tmp_dir: _tmp_dir} do
      {:ok, peer, gone} =
        :peer.start_link(%{
          name: :"gone#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true
        })

      :peer.stop(peer)

      assert {:error, message} = Distribution.card(gone)
      assert message =~ "cannot reach"
    end
  end
end
