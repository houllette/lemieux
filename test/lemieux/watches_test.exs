defmodule Lemieux.WatchesTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Watches
  alias Lemieux.Extensions.Watches.Server
  alias Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Source do
    @behaviour Lemieux.Extensions.Watches.Source
    @impl true
    def validate(_state, %{"run_id" => id} = target) when is_binary(id), do: {:ok, target}
    def validate(_state, _target), do: {:error, :invalid_target}
    @impl true
    def observe(state, target) do
      send(state.owner, {:observing, self(), target})

      receive do
        {:answer, result} -> result
      after
        60_000 -> {:error, :unavailable, "fixture held too long"}
      end
    end
  end

  setup %{tmp_dir: dir} do
    runtime = :"watch_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new([Scripted.complete("follow-up")])

    opts = [
      supervisor: runtime,
      store: JSONL.new(Path.join(dir, "sessions")),
      provider: provider,
      model: "test:model",
      subscriber: self()
    ]

    {:ok, session} = Lemieux.start_session(opts)
    clock = start_supervised!({Agent, fn -> 1_000_000 end})

    server_opts = [
      journal: Files.new(Path.join(dir, "watches")),
      session: session,
      session_id: Session.id(session),
      sources: %{"fake" => {Source, %{owner: self()}}},
      task_supervisor: Lemieux.Supervisor.task_supervisor(runtime),
      now: fn -> Agent.get(clock, & &1) end,
      tick_ms: 60_000
    ]

    %{
      dir: dir,
      runtime: runtime,
      opts: opts,
      server_opts: server_opts,
      session: session,
      id: Session.id(session),
      provider: provider,
      clock: clock
    }
  end

  test "observation order survives same-millisecond registrations and host recovery", ctx do
    manager = start_supervised!({Server, ctx.server_opts})
    target = %{"run_id" => "42"}
    assert {:ok, first} = Watches.register(manager, "fake", target)
    assert_receive {:observing, _, ^target}
    assert {:ok, _} = Watches.stop(manager, first["id"])
    assert {:ok, second} = Watches.register(manager, "fake", target)
    assert_receive {:observing, _, ^target}
    assert second["created_at"] == first["created_at"]
    assert second["created_order"] > first["created_order"]
    stop_supervised!(Server)
    manager = start_supervised!({Server, ctx.server_opts})
    assert {:ok, third} = Watches.register(manager, "fake", target)
    assert third["created_order"] > second["created_order"]
  end

  test "nearby background completions produce one batch and recovery deduplicates its components",
       ctx do
    owner = self()

    tasks =
      for n <- 1..2 do
        assert {:ok, id} =
                 Lemieux.Background.start(
                   supervisor: ctx.runtime,
                   session_id: ctx.id,
                   owner: ctx.session,
                   command: "analysis #{n}",
                   description: "Observe progress #{n}",
                   cwd: ctx.dir,
                   environment: Lemieux.Environment.local(),
                   runner: fn _, _ ->
                     send(owner, {:batch_worker, self()})

                     receive do
                       :finish -> {:ok, "DONE", 0}
                     after
                       60_000 -> {:error, :held_too_long}
                     end
                   end
                 )

        assert_receive {:batch_worker, worker}
        {:ok, task} = Lemieux.Background.poll(ctx.runtime, ctx.id, id)
        {task, worker}
      end

    server =
      start(ctx,
        sources: %{
          "background" => {Watches.Background, %{supervisor: ctx.runtime, session_id: ctx.id}}
        },
        default_follow_up: true
      )

    watches =
      for {task, _} <- tasks do
        {:ok, watch} =
          Watches.register(server, "background", %{"task_id" => task.id},
            label: task.description,
            task_name: task.name
          )

        watch
      end

    for {_, worker} <- tasks, do: send(worker, :finish)
    id = ctx.id

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{
                       type: :extension_state,
                       payload: %{
                         "namespace" => "lemieux.notification",
                         "value" => %{"background_results" => cards, "receipt_ids" => receipts}
                       }
                     }}}

    assert length(cards) == 2
    assert Enum.sort(receipts) == Enum.sort(Enum.map(watches, & &1["id"]))
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(ctx.provider)) == 1
    stop_supervised!(Server)
    lost = List.last(watches)

    {:ok, _} =
      Journal.update(
        Files.new(Path.join(ctx.dir, "watches")),
        lost["id"],
        &Map.put(&1, "delivery", "pending")
      )

    server =
      start(ctx,
        sources: %{
          "background" => {Watches.Background, %{supervisor: ctx.runtime, session_id: ctx.id}}
        },
        default_follow_up: true
      )

    send(server, :deliver_results)

    assert {:ok, %{"delivery" => "delivered", "continuation" => "already_delivered"}} =
             Watches.get(server, lost["id"])

    assert length(Scripted.requests(ctx.provider)) == 1
  end

  test "background watch outcomes distinguish successful and failed command exits", ctx do
    for {exit_status, outcome} <- [{0, "success"}, {7, "failure"}] do
      {:ok, task_id} =
        Lemieux.Background.start(
          supervisor: ctx.runtime,
          session_id: ctx.id,
          owner: ctx.session,
          command: "exit #{exit_status}",
          cwd: ctx.dir,
          environment: Lemieux.Environment.local()
        )

      assert {:ok, %{status: :exited, exit_status: ^exit_status}} =
               Lemieux.Background.await(ctx.runtime, ctx.id, task_id, 5000)

      assert {:done, result} =
               Watches.Background.observe(%{supervisor: ctx.runtime, session_id: ctx.id}, %{
                 "task_id" => task_id
               })

      assert result["outcome"] == outcome
      assert result["summary"] == "Command exit status: #{exit_status}"
    end
  end

  defp start(ctx, extra \\ []),
    do: start_supervised!({Server, Keyword.merge(ctx.server_opts, extra)})

  defp register(server, opts \\ []),
    do: Watches.register(server, "fake", %{"run_id" => "42"}, opts)

  defp tick(server), do: send(server, :tick)

  defp completed(pid),
    do:
      send(
        pid,
        {:answer,
         {:done,
          %{"outcome" => "failure", "logs" => "failing test", "url" => "https://example.test/42"}}}
      )

  test "waiting spends zero requests; idle completion continues once", ctx do
    server = start(ctx)
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, %{"run_id" => "42"}}
    assert Scripted.requests(ctx.provider) == []
    completed(observer)
    id = ctx.id
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert {:ok, %{"delivery" => "delivered", "status" => "completed"}} =
             Watches.get(server, watch["id"])

    assert length(Scripted.requests(ctx.provider)) == 1
    tick(server)
    :ok = Watches.attach(server, ctx.session)
    assert length(Scripted.requests(ctx.provider)) == 1
  end

  test "notification-only and denied continuation do not infer", ctx do
    server = start(ctx, authorize: fn _watch -> false end)
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    completed(observer)
    id = ctx.id

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{type: :extension_state, payload: %{"namespace" => "lemieux.notification"}}}}

    assert {:ok, %{"delivery" => "delivered", "continuation" => "notification_only"}} =
             Watches.get(server, watch["id"])

    assert Scripted.requests(ctx.provider) == []

    assert {:ok, %{"result" => nil, "output_expired" => true}} =
             Watches.forget(server, watch["id"])
  end

  test "busy completion is durable and delivered at the next idle boundary", ctx do
    parent = self()

    provider =
      Scripted.new([
        fn _request ->
          send(parent, {:model_waiting, self()})

          receive do
            :finish -> Scripted.complete("first finished")
          end
        end,
        Scripted.complete("then inspected")
      ])

    {:ok, session} = Lemieux.start_session(Keyword.put(ctx.opts, :provider, provider))
    id = Session.id(session)
    server = start(ctx, session: session, session_id: id)
    :ok = Session.prompt(session, "work")
    assert_receive {:model_waiting, model}
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    completed(observer)
    # The observer's next message is synchronized by a call after its result
    # was processed, rather than relying on a short sleep.
    receive_result(server, watch["id"])
    assert length(Scripted.requests(provider)) == 1
    assert {:ok, %{"delivery" => "pending"}} = Watches.get(server, watch["id"])
    send(model, :finish)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 2
  end

  test "recovery observes the same target; recorded completion survives reconnect", ctx do
    server = start(ctx)
    {:ok, watch} = register(server)
    assert_receive {:observing, observer, target}
    monitor = Process.monitor(observer)
    :ok = stop_supervised(Server)
    assert_receive {:DOWN, ^monitor, :process, ^observer, _reason}

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(ctx.runtime),
      ctx.session
    )

    recovered = start(ctx, session: nil)
    assert_receive {:observing, second, ^target}
    completed(second)
    receive_result(recovered, watch["id"])

    assert {:ok, %{"status" => "completed", "delivery" => "pending"}} =
             Watches.get(recovered, watch["id"])

    :ok = stop_supervised(Server)
    restored = start(ctx, session: nil)
    {:ok, session} = Lemieux.resume_session([resume: ctx.id] ++ ctx.opts)
    assert :ok = Watches.attach(restored, session)
    assert {:ok, %{"delivery" => "delivered"}} = Watches.get(restored, watch["id"])
    assert Scripted.requests(ctx.provider) == []
  end

  test "deadline, unavailable and authentication errors are explicit", ctx do
    server = start(ctx, max_concurrency: 1)
    {:ok, expired} = register(server, timeout_ms: 10)
    assert_receive {:observing, _observer, _target}
    Agent.update(ctx.clock, &(&1 + 11))
    tick(server)
    assert {:ok, %{"status" => "timed_out"}} = Watches.get(server, expired["id"])
    {:ok, auth} = register(server)
    assert_receive {:observing, observer, _target}
    send(observer, {:answer, {:error, :authentication, "login expired"}})
    receive_result(server, auth["id"])

    assert {:ok, %{"status" => "authentication", "result" => %{"summary" => "login expired"}}} =
             Watches.get(server, auth["id"])

    assert Scripted.requests(ctx.provider) == []
  end

  test "stop kills observation, not external work; late completion is ignored", ctx do
    server = start(ctx)
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    ref = Process.monitor(observer)
    assert {:ok, %{"status" => "stopped"}} = Watches.stop(server, watch["id"])
    assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
    completed(observer)
    tick(server)
    assert {:ok, %{"status" => "stopped"}} = Watches.get(server, watch["id"])
    assert Scripted.requests(ctx.provider) == []
  end

  test "concurrency, retry-after, backoff and record count are bounded", ctx do
    server = start(ctx, max_concurrency: 1, max_records: 2, poll_ms: 100)
    {:ok, first} = register(server)
    {:ok, second_watch} = register(server)
    assert {:error, :record_limit} = register(server)
    assert_receive {:observing, observer, _target}
    refute_receive {:observing, _other, _target}, 30
    send(observer, {:answer, {:retry, 5000, "rate limited"}})
    assert_receive {:observing, second, _target}
    assert {:ok, %{"next_poll_at" => 1_005_000}} = Watches.get(server, first["id"])
    send(second, {:answer, {:pending, "still running"}})
    receive_record(server, second_watch["id"], &(&1["attempts"] == 1))
    Agent.update(ctx.clock, &(&1 + 100))
    tick(server)
    assert_receive {:observing, third, _target}
    send(third, {:answer, {:pending, "still running"}})
    receive_record(server, second_watch["id"], &(&1["attempts"] == 2))
    assert {:ok, %{"next_poll_at" => 1_000_300}} = Watches.get(server, second_watch["id"])
    assert Scripted.requests(ctx.provider) == []
  end

  test "a recovered unacknowledged delivery never repeats the admitted follow-up", ctx do
    server = start(ctx)
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    completed(observer)
    id = ctx.id
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(ctx.provider)) == 1
    :ok = stop_supervised(Server)
    # Simulate a crash after the session receipt, before the host ack write.
    journal = ctx.server_opts[:journal]
    {:ok, _record} = Journal.update(journal, watch["id"], &Map.put(&1, "delivery", "pending"))
    recovered = start(ctx)
    assert {:ok, %{"delivery" => "delivered"}} = Watches.get(recovered, watch["id"])
    assert length(Scripted.requests(ctx.provider)) == 1
  end

  test "observation deadlines and retained output expire independently", ctx do
    server = start(ctx, observation_timeout_ms: 10, retention_ms: 20)
    {:ok, watch} = register(server)
    assert_receive {:observing, observer, _target}
    ref = Process.monitor(observer)
    Agent.update(ctx.clock, &(&1 + 11))
    tick(server)

    assert {:ok, %{"status" => "unavailable", "delivery" => "delivered"}} =
             Watches.get(server, watch["id"])

    assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
    Agent.update(ctx.clock, &(&1 + 21))
    tick(server)
    assert {:ok, %{"result" => nil, "output_expired" => true}} = Watches.get(server, watch["id"])
    assert Scripted.requests(ctx.provider) == []
  end

  test "cancelling a busy agent revokes pending continuation while preserving the watch", ctx do
    parent = self()

    provider =
      Scripted.new([
        fn _request ->
          send(parent, :model_started)

          receive do
            :finish -> Scripted.complete("finished")
          end
        end
      ])

    {:ok, session} = Lemieux.start_session(Keyword.put(ctx.opts, :provider, provider))
    id = Session.id(session)
    server = start(ctx, session: session, session_id: id)
    :ok = Session.prompt(session, "work")
    assert_receive :model_started
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}

    assert {:ok, %{"status" => "watching", "follow_up" => false}} =
             Watches.get(server, watch["id"])

    completed(observer)
    receive_result(server, watch["id"])

    assert {:ok, %{"delivery" => "delivered", "continuation" => "notification_only"}} =
             Watches.get(server, watch["id"])

    assert length(Scripted.requests(provider)) == 1
  end

  test "bounded output and mismatched session attachment fail closed", ctx do
    server = start(ctx)
    {:ok, watch} = register(server)
    assert_receive {:observing, observer, _target}
    output = "e" <> String.duplicate("\u0301", 50_000) <> String.duplicate("\u0000🦀", 20_000)
    send(observer, {:answer, {:done, %{"logs" => output, "summary" => output}}})
    receive_result(server, watch["id"])
    {:ok, stored} = Watches.get(server, watch["id"])
    assert byte_size(JSON.encode!(stored["result"])) <= 16_000
    assert stored["result"]["logs_bytes"] == byte_size(output)
    assert stored["result"]["logs"] =~ "truncated"
    {:ok, other} = Lemieux.start_session(ctx.opts)
    assert {:error, :wrong_session} = Watches.attach(server, other)
    {dead, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}
    assert {:error, :disconnected} = Watches.attach(server, dead)
    assert Process.alive?(server)
  end

  test "stopping a recorded completion revokes a queued follow-up", ctx do
    parent = self()

    provider =
      Scripted.new([
        fn _request ->
          send(parent, {:model_waiting, self()})

          receive do
            :finish -> Scripted.complete("finished")
          end
        end
      ])

    {:ok, session} = Lemieux.start_session(Keyword.put(ctx.opts, :provider, provider))
    id = Session.id(session)
    server = start(ctx, session: session, session_id: id)
    :ok = Session.prompt(session, "work")
    assert_receive {:model_waiting, model}
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}
    completed(observer)
    receive_result(server, watch["id"])

    assert {:ok, %{"status" => "completed", "follow_up" => false}} =
             Watches.stop(server, watch["id"])

    send(model, :finish)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    receive_record(server, watch["id"], &(&1["delivery"] == "delivered"))
    assert length(Scripted.requests(provider)) == 1
  end

  test "reconnect uses current continuation authority", ctx do
    server = start(ctx)
    {:ok, watch} = register(server, follow_up: true)
    assert_receive {:observing, observer, _target}

    DynamicSupervisor.terminate_child(
      Lemieux.Supervisor.session_supervisor(ctx.runtime),
      ctx.session
    )

    completed(observer)
    receive_result(server, watch["id"])
    {:ok, session} = Lemieux.resume_session([resume: ctx.id] ++ ctx.opts)
    assert :ok = Watches.attach(server, session, authorize: fn _watch -> false end)

    assert {:ok, %{"delivery" => "delivered", "continuation" => "notification_only"}} =
             Watches.get(server, watch["id"])

    assert Scripted.requests(ctx.provider) == []
  end

  # Wait for the scheduler's own observable persisted transition. A held fake
  # source never completes on a timer, and the suite's 5s deadline is retained.
  defp receive_result(server, id) do
    receive_record(server, id, &(&1["status"] != "watching"))
  end

  defp receive_record(server, id, predicate) do
    owner = self()

    task =
      Task.async(fn ->
        _record =
          Stream.repeatedly(fn -> Watches.get(server, id) end)
          |> Enum.find(fn {:ok, record} -> predicate.(record) end)

        send(owner, {:recorded, id})
      end)

    assert_receive {:recorded, ^id}
    Task.await(task)
  end
end
