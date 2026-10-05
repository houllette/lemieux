defmodule Lemieux.Tools.EvalTest do
  @moduledoc """
  Every test here starts a real second BEAM node, which is the point: the
  claims this tool makes are claims about node boundaries, and a mock of a
  node would only be able to confirm what it was written to confirm.

  That costs a few hundred milliseconds per runtime, so the sandbox is shared
  across the tests in a describe block wherever what they assert allows it.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Tools.Eval

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_elixir_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    context = %{
      cwd: tmp_dir,
      session_id: "01SESSION#{System.unique_integer([:positive])}",
      call_id: "call-1",
      session: self(),
      supervisor: runtime
    }

    %{context: context, tmp_dir: tmp_dir}
  end

  defp eval(context, code), do: Eval.run(%{"code" => code}, context)

  # Starts the node up front with a short timeout, under the same registered
  # name the tool would use, so the tool finds this one instead of starting
  # its own. Two minutes is the right bound for real work and the wrong one
  # for a test that exists to watch the bound fire.
  defp impatient(context, timeout) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Lemieux.Supervisor.sandbox_supervisor(context.supervisor),
        {Lemieux.Eval.Sandbox,
         name:
           {:via, Registry,
            {Lemieux.Supervisor.registry(context.supervisor),
             {:elixir_sandbox, context.session_id}}},
         session_id: context.session_id,
         timeout: timeout}
      )

    context
  end

  describe "evaluating" do
    test "returns the value of the last expression", %{context: context} do
      assert {:ok, output} = eval(context, "1 + 1")
      assert output =~ "2"
    end

    test "returns what was written to standard output as well as the value",
         %{context: context} do
      assert {:ok, output} = eval(context, ~s|IO.puts("hello"); :done|)

      assert output =~ "hello"
      assert output =~ ":done"
    end

    test "runs in the session's working directory", %{context: context, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "there.txt"), "found me")

      assert {:ok, output} = eval(context, ~s|File.read!("there.txt")|)
      assert output =~ "found me"
    end

    test "the standard library is there, which is the whole point of the tool",
         %{context: context, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.ex"), "defmodule A, do: use GenServer")
      File.write!(Path.join(tmp_dir, "b.ex"), "defmodule B, do: :ok")

      code = ~S"""
      Path.wildcard("*.ex") |> Enum.filter(&(File.read!(&1) =~ "GenServer"))
      """

      assert {:ok, output} = eval(context, code)
      assert output =~ "a.ex"
      refute output =~ "b.ex"
    end

    test "modules defined on the node stay defined for the session",
         %{context: context} do
      # Parenthesised, so the snippet is unambiguous: the bare nested `do:`
      # parses to the same module and makes the suite print a compiler warning
      # about somebody else's code on every run.
      assert {:ok, _} = eval(context, "defmodule Remembered, do: (def hello, do: :hi)")
      assert {:ok, output} = eval(context, "Remembered.hello()")

      assert output =~ ":hi"
    end
  end

  describe "failing" do
    test "a raise comes back as an error the model can read", %{context: context} do
      assert {:error, message} = eval(context, ~s|raise "deliberate"|)

      assert message =~ "deliberate"
      assert message =~ "RuntimeError"
    end

    test "a syntax error is a result, not a crash", %{context: context} do
      assert {:error, message} = eval(context, "do do do")

      assert message =~ "Error"
    end

    test "output written before a raise is not lost", %{context: context} do
      assert {:error, message} = eval(context, ~s|IO.puts("got this far"); raise "then this"|)

      assert message =~ "got this far"
      assert message =~ "then this"
    end

    test "empty code is refused without starting anything", %{context: context} do
      assert {:error, message} = Eval.run(%{"code" => ""}, context)
      assert message =~ "needs code"
    end
  end

  describe "the node boundary" do
    # These are the tests that justify the design. Each one would pass
    # trivially — and mean nothing — if evaluation happened in this VM, so
    # each asserts on something that is *different* over there.

    test "it is a different VM from the one holding the session", %{context: context} do
      assert {:ok, output} = eval(context, "{node(), System.pid()}")

      refute output =~ System.pid()
    end

    test "it cannot see this VM's processes", %{context: context} do
      Process.register(self(), :a_name_only_the_test_vm_has)
      on_exit(fn -> :ok end)

      assert {:ok, output} = eval(context, "Process.whereis(:a_name_only_the_test_vm_has)")
      assert output =~ "nil"
    end

    test "it cannot read this VM's application environment", %{context: context} do
      Application.put_env(:lemieux, :a_secret_only_the_test_vm_has, "swordfish")
      on_exit(fn -> Application.delete_env(:lemieux, :a_secret_only_the_test_vm_has) end)

      assert {:ok, output} =
               eval(context, "Application.get_env(:lemieux, :a_secret_only_the_test_vm_has)")

      assert output =~ "nil"
    end

    test "it cannot read this VM's ETS tables", %{context: context} do
      :ets.new(:a_table_only_the_test_vm_has, [:named_table, :public])

      assert {:ok, output} =
               eval(context, ~s|:ets.whereis(:a_table_only_the_test_vm_has)|)

      assert output =~ ":undefined"
    end
  end

  describe "surviving what it is given" do
    test "an evaluation that never returns is stopped, and the session is told",
         %{context: context} do
      context = impatient(context, 500)

      assert {:error, message} = eval(context, "receive do: (:stop -> :ok)")

      assert message =~ "longer than"
    end

    test "and the node is still usable afterwards", %{context: context} do
      # Usable is the claim, not fast. The node's one budget covers both calls,
      # so it is loose enough that a loaded CI runner recovering the node after
      # the stop is not what decides the second one (500ms did, once).
      context = impatient(context, 2_000)

      assert {:error, _stopped} = eval(context, "receive do: (:stop -> :ok)")
      assert {:ok, output} = eval(context, "1 + 1")

      assert output =~ "2"
    end

    test "a runaway allocation kills the evaluation, not the node",
         %{context: context} do
      context = impatient(context, :timer.seconds(20))

      assert {:error, message} = eval(context, "Enum.to_list(1..500_000_000)")

      # Either the heap cap or the timeout gets there first; both are the node
      # surviving something that would otherwise have taken a VM down.
      assert message =~ "died" or message =~ "longer than"
      assert {:ok, still_working} = eval(context, "1 + 1")
      assert still_working =~ "2"
    end

    test "very long output is cut, and says so", %{context: context} do
      assert {:ok, output} = eval(context, ~s|String.duplicate("x", 200_000)|)

      assert output =~ "not shown"
      assert byte_size(output) < 100_000
    end
  end

  describe "how it is scheduled" do
    test "is never run alongside its siblings, because it can write anything" do
      refute Lemieux.Tool.parallel_safe?(Eval)
    end

    test "is not one of the tools a session gets by default" do
      refute Eval in Lemieux.Tools.default()
    end
  end

  describe "what the node inherits" do
    setup do
      name = "LEMIEUX_EVAL_TEST_#{System.unique_integer([:positive])}_TOKEN"
      System.put_env(name, "secret-value")
      on_exit(fn -> System.delete_env(name) end)
      %{name: name}
    end

    test "a scrubbing environment's credentials do not reach the node", %{
      context: context,
      name: name
    } do
      context =
        Map.put(context, :environment, Local.new(credentials: {:scrub, []}))

      assert {:ok, output} = eval(context, ~s{System.get_env("#{name}") in [nil, ""]})
      assert output =~ "true"
    end

    test "without a policy the node inherits, as before", %{context: context, name: name} do
      assert {:ok, output} = eval(context, ~s{System.get_env("#{name}")})
      assert output =~ "secret-value"
    end
  end
end
