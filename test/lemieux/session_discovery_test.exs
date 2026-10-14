defmodule Lemieux.SessionDiscoveryTest do
  use ExUnit.Case, async: true
  alias Lemieux.Supervisor, as: Sup

  test "discovery excludes a terminated process before Registry consumes its DOWN" do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Sup, name: runtime})
    registry = Sup.registry(runtime)
    [{_id, partition, :worker, [Registry.Partition]}] = Supervisor.which_children(registry)
    owner = self()
    id = "temporary-session"

    session =
      spawn(fn ->
        {:ok, _owner} = Registry.register(registry, id, nil)
        send(owner, {:registered, self()})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(session, :kill) end)
    assert_receive {:registered, ^session}
    assert Lemieux.session(runtime, id) == {:ok, session}
    assert Lemieux.sessions(runtime) == [{id, session}]
    :ok = :sys.suspend(partition)

    try do
      monitor = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :killed}
      # Deterministically hold the stale entry; no scheduler race or polling.
      assert Registry.lookup(registry, id) == [{session, nil}]
      assert Lemieux.session(runtime, id) == :error
      assert Lemieux.sessions(runtime) == []
    after
      :sys.resume(partition)
    end
  end
end
