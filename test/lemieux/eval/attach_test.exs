defmodule Lemieux.Eval.AttachTest do
  @moduledoc """
  Attaching, against a node that is genuinely somebody else's.

  The stand-in is a real second BEAM with Elixir on its code path and **no
  lemieux**, which is the whole point: a target that could already load
  `Runner` would prove nothing about injecting it, and the claim
  being tested is that an application needs no dependency on this library to
  be attached to.

  `async: false`, because starting distribution names the whole VM and epmd is
  shared. Nothing here can run beside another test that cares about either.
  """

  use ExUnit.Case, async: false

  alias Lemieux.Eval.Attach
  alias Lemieux.Eval.Runner
  alias Lemieux.Eval.Sandbox
  alias Lemieux.Tools.Eval

  @moduletag :distributed
  @moduletag :tmp_dir

  setup_all do
    # Distribution has to be up before a peer can be named, and it stays up:
    # stopping it would pull the rug from any other node in the same run.
    unless Node.alive?(),
      do: {:ok, _pid} = Node.start(:"lmx-test@127.0.0.1", name_domain: :longnames)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    # Elixir, and nothing else. Deliberately not this project's build path.
    elixir =
      :code.lib_dir(:elixir)
      |> Path.dirname()
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.map(&String.to_charlist/1)

    name = :"project#{System.unique_integer([:positive])}"

    {:ok, peer, target} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-pa" | elixir]
      })

    # No `on_exit` stopping it: `:peer.start_link/1` links the node to this
    # test process, so it dies with the test. Stopping it again from `on_exit`
    # — which runs after that process is gone — exits on a pid that is
    # already dead, and every test in the file fails for a reason that has
    # nothing to do with what it was testing.
    {:ok, _apps} = :erpc.call(target, :application, :ensure_all_started, [:elixir])

    runtime = :"lemieux_attach_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    context = %{
      cwd: tmp_dir,
      session_id: "01SESSION#{System.unique_integer([:positive])}",
      call_id: "call-1",
      session: self(),
      supervisor: runtime
    }

    %{context: context, target: target, peer: peer}
  end

  defp eval(context, code), do: Eval.run(%{"code" => code}, context)

  describe "the target owes us nothing" do
    test "it has never heard of lemieux before we attach", %{target: target} do
      assert {:error, :nofile} =
               :erpc.call(target, Code, :ensure_loaded, [Runner])
    end

    test "and one module is all that is added", %{context: context, target: target} do
      assert {:ok, ^target} = Sandbox.attach(context, Atom.to_string(target))

      assert {:module, Runner} =
               :erpc.call(target, Code, :ensure_loaded, [Runner])

      # Nothing else came with it. `Lemieux.Session` is the obvious thing to
      # have dragged along, and the runner is written so it cannot.
      assert {:error, :nofile} = :erpc.call(target, Code, :ensure_loaded, [Lemieux.Session])
    end
  end

  describe "evaluating over there" do
    setup %{context: context, target: target} do
      {:ok, ^target} = Sandbox.attach(context, Atom.to_string(target))

      :ok
    end

    test "runs on the attached node, not ours", %{context: context, target: target} do
      assert {:ok, output} = eval(context, "node()")

      assert output =~ Atom.to_string(target)
      refute output =~ Atom.to_string(node())
    end

    test "sees the attached application's live processes", %{context: context, target: target} do
      # Something running over there that we could not otherwise know about,
      # started unlinked so it outlives the call that made it.
      :erpc.call(target, Code, :eval_string, [
        """
        caller = self()
        spawn(fn ->
          Process.register(self(), :the_shop)
          send(caller, :ready)
          receive do: (:stop -> :ok)
        end)
        receive do: (:ready -> :ok)
        """
      ])

      assert {:ok, output} = eval(context, "Process.whereis(:the_shop) |> is_pid()")
      assert output =~ "true"

      # And it is genuinely not ours.
      assert Process.whereis(:the_shop) == nil
    end

    test "reads state we have no other way to see", %{context: context, target: target} do
      :erpc.call(target, Code, :eval_string, [
        """
        caller = self()
        spawn(fn ->
          :ets.new(:orders, [:named_table, :public])
          :ets.insert(:orders, {:today, 12})
          send(caller, :ready)
          receive do: (:stop -> :ok)
        end)
        receive do: (:ready -> :ok)
        """
      ])

      assert {:ok, output} = eval(context, ":ets.lookup(:orders, :today)")
      assert output =~ "12"
    end

    test "an exception raised over there arrives readable", %{context: context} do
      assert {:error, message} = eval(context, ~s|raise ArgumentError, "from the app"|)

      assert message =~ "from the app"
      assert message =~ "ArgumentError"
    end

    test "detaching goes back to our own node", %{context: context, target: target} do
      assert :ok = Sandbox.detach(context)
      assert {:ok, output} = eval(context, "node()")

      refute output =~ Atom.to_string(target)
    end

    test "and an application that goes away takes the session home", %{
      context: context,
      peer: peer,
      target: target
    } do
      assert Sandbox.target(context) == target

      :peer.stop(peer)

      # The monitor fires asynchronously, so this waits for it rather than
      # assuming it has already happened.
      server =
        {:via, Registry,
         {Lemieux.Supervisor.registry(context.supervisor), {:elixir_sandbox, context.session_id}}}

      assert :ok = LemieuxTest.Sync.state(server, fn state -> state.attached == nil end)
      assert Sandbox.target(context) == nil

      assert {:ok, output} = eval(context, "1 + 1")
      assert output =~ "2"
    end
  end

  describe "saying what went wrong" do
    test "a node that is not there says so, and how to fix it", %{context: context} do
      assert {:error, message} = Sandbox.attach(context, "definitely-not-running")

      assert message =~ "could not reach"
      assert message =~ "--sname"
      assert message =~ "cookie"
    end
  end

  describe "candidates/0" do
    test "lists named nodes on this machine, and not our own", %{target: target} do
      candidates = Attach.candidates()

      assert target in candidates
      refute node() in candidates
    end
  end
end
