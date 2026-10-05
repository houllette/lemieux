defmodule Lemieux.AgentSessionLifecycleTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "one default-runtime caller finishing does not terminate another caller's session", %{
    tmp_dir: root
  } do
    check_callers(root, :agent)
  end

  test "native benchmark convenience runtime outlives its first worker", %{tmp_dir: root} do
    check_callers(root, :native)
  end

  defp check_callers(root, adapter) do
    {invocation, supervisor} =
      case adapter do
        :agent ->
          {"Lemieux.Agent.run(Lemieux.Agent.Session, input, options)",
           Lemieux.Agent.SessionSupervisor}

        :native ->
          {"Lemieux.Benchmark.Runtime.Native.run(struct!(Lemieux.Benchmark.Task, Map.merge(input, %{id: \"task\", grader: nil})), options)",
           Lemieux.Benchmark.NativeSupervisor}
      end

    script = """
    defmodule GateProvider do
      def validate_model(_, _, _), do: :ok
      def run({owner, label}, _request, emit) do
        send(owner, {:entered, label, self()})
        receive do
          :finish -> Enum.each(Lemieux.Providers.Scripted.complete(Atom.to_string(label)), emit)
        after
          3000 -> raise "provider was not released"
        end
        :ok
      end
    end
    owner = self()
    input = %{prompt: "work", cwd: #{inspect(root)}, timeout_ms: 5000}
    launch = fn label ->
      spawn_monitor(fn ->
        options = [provider: {GateProvider, {owner, label}}, model: "test:model",
          sessions_dir: #{inspect(Path.join(root, "sessions"))}]
        result = #{invocation}
        send(owner, {label, result})
      end)
    end
    {fast, monitor} = launch.(:fast)
    fast_provider = receive do {:entered, :fast, pid} -> pid after 3000 -> raise "fast missing" end
    launch.(:slow)
    slow_provider = receive do {:entered, :slow, pid} -> pid after 3000 -> raise "slow missing" end
    send(fast_provider, :finish)
    receive do {:fast, {:ok, %{"answer" => "fast"}}} -> :ok after 3000 -> raise "fast failed" end
    receive do {:DOWN, ^monitor, :process, ^fast, :normal} -> :ok after 3000 -> raise "fast did not exit" end
    # Force the shared supervisor to process the former owner's exit signal.
    :sys.get_state(#{inspect(supervisor)})
    send(slow_provider, :finish)
    receive do {:slow, {:ok, %{"answer" => "slow"}}} -> :ok after 3000 -> raise "peer session was lost" end
    IO.puts("concurrent-callers-ok")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd("elixir", ["--erl", "+S 2:2"] ++ paths ++ ["-e", script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "concurrent-callers-ok"
  end
end
