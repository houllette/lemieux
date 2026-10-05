defmodule LemieuxTest.Sync do
  @moduledoc false
  import ExUnit.Assertions

  @doc "Waits for an OTP state transition; predicates must be pure and never call the server."
  @spec state(server :: GenServer.server(), predicate :: (term() -> boolean())) :: :ok
  def state(server, predicate) do
    owner = self()
    ref = make_ref()

    observer = fn
      _, {:noreply, state}, _ -> observed(state, predicate, owner, ref)
      _, {:out, _reply, _from, state}, _ -> observed(state, predicate, owner, ref)
      acc, _event, _ -> acc
    end

    :ok = :sys.install(server, {ref, observer, nil})

    try do
      # Install before reading: a transition between these two operations is
      # either in the snapshot or in our mailbox, so it cannot be missed. The
      # wait is the suite's default (test/test_helper.exs), like every wait for
      # an event: a shorter one of its own is what fails first under load.
      unless predicate.(:sys.get_state(server)) do
        assert_receive {:state_reached, ^ref}
      end

      :ok
    after
      :sys.remove(server, ref)
      flush(ref)
    end
  end

  @doc "Waits for the registry to process the terminated owner's exit signal."
  @spec unregistered(registry :: atom(), key :: term()) :: :ok
  def unregistered(registry, key) do
    for {_, partition, _, _} <- Supervisor.which_children(registry) do
      state(partition, fn _state -> Registry.lookup(registry, key) == [] end)
    end

    assert Registry.lookup(registry, key) == []
    :ok
  end

  defp observed(state, predicate, owner, ref) do
    if predicate.(state) do
      send(owner, {:state_reached, ref})
      :done
    end
  end

  defp flush(ref) do
    receive do
      {:state_reached, ^ref} -> :ok
    after
      0 -> :ok
    end
  end
end
