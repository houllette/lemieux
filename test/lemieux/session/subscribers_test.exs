defmodule Lemieux.Session.SubscribersTest do
  use ExUnit.Case, async: true

  alias Lemieux.Session.Subscribers

  test "adding and removing a watcher is idempotent" do
    watcher = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(watcher), do: Process.exit(watcher, :kill) end)

    subscribers = Subscribers.new(watcher)
    ref = Map.fetch!(subscribers.refs, watcher)

    subscribers = Subscribers.add(subscribers, watcher)
    assert subscribers.refs == %{watcher => ref}

    subscribers = subscribers |> Subscribers.remove(watcher) |> Subscribers.remove(watcher)
    assert subscribers.pids == MapSet.new()
    assert subscribers.refs == %{}
  end

  test "slow watchers lose reconstructible deltas but not durable events" do
    watcher =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(watcher), do: Process.exit(watcher, :kill) end)

    Enum.each(1..1_000, &send(watcher, {:noise, &1}))
    assert {:message_queue_len, 1_000} = Process.info(watcher, :message_queue_len)

    subscribers = Subscribers.new(watcher)
    assert :ok = Subscribers.broadcast(subscribers, "session", {:text_delta, %{text: "late"}})
    assert :ok = Subscribers.broadcast(subscribers, "session", {:entry, :durable})

    {:messages, messages} = Process.info(watcher, :messages)
    refute {:lemieux, "session", {:text_delta, %{text: "late"}}} in messages
    assert {:lemieux, "session", {:entry, :durable}} in messages
  end
end
