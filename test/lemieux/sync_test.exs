defmodule LemieuxTest.SyncTest do
  use ExUnit.Case, async: true
  alias LemieuxTest.Sync

  test "observes the transition from a trigger run after registration and initial snapshot" do
    server = start_supervised!({Agent, fn -> :before end})

    assert :ok =
             Sync.state(server, &(&1 == :after), fn ->
               Agent.update(server, fn _ -> :after end)
             end)

    assert Agent.get(server, & &1) == :after
  end
end
