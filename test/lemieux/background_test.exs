defmodule Lemieux.BackgroundTest do
  use ExUnit.Case, async: true

  alias Lemieux.Background
  alias Lemieux.Clock.Manual
  alias Lemieux.Environment
  alias LemieuxTest.CommandGate

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_background_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, tmp_dir: tmp_dir}
  end

  # The option used to default to `Environment.local/0`, which made forgetting
  # it the same as choosing unconfined execution on the host's machine.
  test "refuses to start without an environment rather than assuming the local one", context do
    error =
      assert_raise ArgumentError, fn ->
        Background.start(
          supervisor: context.runtime,
          session_id: "session-1",
          owner: self(),
          command: "echo hello",
          cwd: context.tmp_dir
        )
      end

    assert error.message =~ ":environment"
    assert error.message =~ "Lemieux.Environment.local()"
  end

  test "starts a command, exposes live status, and awaits its completion", context do
    gate = CommandGate.new("first", "second")

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: gate.command,
               cwd: context.tmp_dir,
               timeout_ms: 2_000
             )

    socket = CommandGate.ready(gate)
    assert {:ok, running} = Background.poll(context.runtime, "session-1", task_id)
    assert running.id == task_id
    assert running.status == :running
    :ok = CommandGate.release(socket)

    assert {:ok, finished} =
             Background.await(context.runtime, "session-1", task_id, 2_000)

    assert finished.status == :exited
    assert finished.exit_status == 0
    assert finished.output == "firstsecond"
    assert finished.finished_at
    assert finished.duration_ms >= 0
  end

  test "await returns a current snapshot when its wait expires", context do
    clock = Manual.new()
    gate = CommandGate.new()

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: gate.command,
               cwd: context.tmp_dir,
               clock: clock
             )

    socket = CommandGate.ready(gate)
    task = task_pid(context, task_id)

    waiter = Task.async(fn -> Background.await(context.runtime, "session-1", task_id, 20) end)
    LemieuxTest.Sync.state(task, fn state -> map_size(state.waiters) == 1 end)

    # One millisecond short of the wait, it is still waiting; at the wait, it
    # answers with the running command's snapshot rather than an error.
    Manual.advance(clock, 19, settle: task)
    assert Task.yield(waiter, 0) == nil

    Manual.advance(clock, 1, settle: task)
    assert {:error, {:timeout, snapshot}} = Task.await(waiter)

    assert snapshot.status == :running
    :ok = CommandGate.release(socket)

    assert {:ok, finished} =
             Background.await(context.runtime, "session-1", task_id, 2_000)

    assert finished.status == :exited
    assert finished.output =~ "ready"
  end

  test "kills a command at the task's own deadline, measured on its clock", context do
    clock = Manual.new()
    gate = CommandGate.new()

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: gate.command,
               cwd: context.tmp_dir,
               timeout_ms: 600_000,
               clock: clock
             )

    socket = CommandGate.ready(gate)
    task = task_pid(context, task_id)

    Manual.advance(clock, 599_999, settle: task)
    assert {:ok, %{status: :running}} = Background.poll(context.runtime, "session-1", task_id)

    Manual.advance(clock, 1, settle: task)
    assert {:ok, snapshot} = Background.poll(context.runtime, "session-1", task_id)
    assert snapshot.status == :timed_out
    assert snapshot.error =~ "600000ms"
    assert snapshot.duration_ms == 600_000
    assert :ok = CommandGate.closed(socket)
  end

  test "a finished task stays queryable for its retention period, then expires", context do
    clock = Manual.new()

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "echo done",
               cwd: context.tmp_dir,
               retention_ms: 60_000,
               clock: clock
             )

    assert {:ok, %{status: :exited}} =
             Background.await(context.runtime, "session-1", task_id, :infinity)

    task = task_pid(context, task_id)
    monitor = Process.monitor(task)

    Manual.advance(clock, 59_999, settle: task)
    assert {:ok, %{status: :exited}} = Background.poll(context.runtime, "session-1", task_id)

    Manual.advance(clock, 1, settle: task)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}

    LemieuxTest.Sync.unregistered(
      Lemieux.Supervisor.background_registry(context.runtime),
      {"session-1", task_id}
    )

    assert Background.poll(context.runtime, "session-1", task_id) == {:error, :not_found}
  end

  test "reports non-zero exits as completed command state", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "echo nope; exit 7",
               cwd: context.tmp_dir
             )

    assert {:ok, snapshot} =
             Background.await(context.runtime, "session-1", task_id, 2_000)

    assert snapshot.status == :exited
    assert snapshot.exit_status == 7
    assert snapshot.output =~ "nope"
  end

  # The real-time check of the same deadline: the only one here that waits
  # on the wall clock, with a generous budget, asserting the outcome and not
  # how soon it came.
  test "kills commands at their background deadline", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "printf before; sleep 30",
               cwd: context.tmp_dir,
               # Large enough to cover starting the command, which the deadline
               # also pays for. At 50ms this raced process startup and lost
               # about as often as the suite was busy.
               timeout_ms: 2_000
             )

    assert {:ok, snapshot} =
             Background.await(context.runtime, "session-1", task_id, 10_000)

    assert snapshot.status == :timed_out
    assert snapshot.output =~ "before"
    assert snapshot.error =~ "2000ms"
  end

  test "bounds retained output while preserving its head and tail", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "printf 1234567890",
               cwd: context.tmp_dir,
               max_output_bytes: 6
             )

    assert {:ok, snapshot} =
             Background.await(context.runtime, "session-1", task_id, 2_000)

    assert snapshot.output_bytes == 10
    assert snapshot.output =~ "123"
    assert snapshot.output =~ "890"
    assert snapshot.output =~ "4 bytes cut from the middle"
  end

  test "task ids cannot be inspected by another session", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "sleep 1",
               cwd: context.tmp_dir
             )

    assert Background.poll(context.runtime, "session-2", task_id) == {:error, :not_found}
    assert :ok = Background.cancel(context.runtime, "session-1", task_id)
  end

  test "cancelling also stops the operating-system command", context do
    gate = CommandGate.new()
    marker = Path.join(context.tmp_dir, "late-marker")

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: gate.command,
               cwd: context.tmp_dir
             )

    socket = CommandGate.ready(gate)
    assert :ok = Background.cancel(context.runtime, "session-1", task_id)
    assert :ok = CommandGate.closed(socket)
    refute File.exists?(marker)
  end

  test "a task is stopped when its owning session exits", context do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: owner,
               environment: Environment.local(),
               command: "sleep 30",
               cwd: context.tmp_dir
             )

    registry = Lemieux.Supervisor.background_registry(context.runtime)
    [{task, _}] = Registry.lookup(registry, {"session-1", task_id})
    monitor = Process.monitor(task)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}
    assert Background.poll(context.runtime, "session-1", task_id) == {:error, :not_found}
  end

  # A background command is polled rather than read, so a broken transport has
  # nowhere else to surface: without its own status the task would report
  # `exited (1)` and the poller would believe the command ran.
  test "a broken output stream fails the task by name", context do
    events = [{:data, "partial"}, {:failed, :epipe}]

    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: {LemieuxTest.ScriptedEnvironment, events},
               command: "echo hello",
               cwd: context.tmp_dir,
               timeout_ms: 2_000
             )

    assert {:ok, finished} = Background.await(context.runtime, "session-1", task_id, 2_000)

    assert finished.status == :failed
    assert finished.exit_status == nil
    assert finished.error =~ "output stream failed"
    assert finished.error =~ "epipe"
    # Not the catch-all: an unrecognised event and a transport that broke are
    # different diagnoses, and only one of them is about lemieux.
    refute finished.error =~ "invalid command event"
    assert finished.output == "partial"
  end

  test "subscriptions deliver once and late subscribers receive the same terminal receipt",
       context do
    gate = CommandGate.new("before", "after")

    {:ok, id} =
      Background.start(
        supervisor: context.runtime,
        session_id: "subscriber",
        owner: self(),
        environment: Environment.local(),
        command: gate.command,
        cwd: context.tmp_dir
      )

    socket = CommandGate.ready(gate)
    assert :ok = Background.subscribe(context.runtime, "subscriber", id, self())
    assert :ok = Background.subscribe(context.runtime, "subscriber", id, self())
    assert {:error, :not_found} = Background.subscribe(context.runtime, "other", id, self())
    CommandGate.release(socket)

    assert_receive {:lemieux_background,
                    %{event_id: event_id, task: %{status: :exited, output: "beforeafter"}}},
                   5_000

    assert {:ok, _} = Background.await(context.runtime, "subscriber", id)
    refute_received {:lemieux_background, _}
    assert :ok = Background.subscribe(context.runtime, "subscriber", id, self())
    assert_receive {:lemieux_background, %{event_id: ^event_id, task: %{id: ^id}}}
  end

  test "unsubscribing and a dead subscriber do not change command completion", context do
    gate = CommandGate.new()

    {:ok, id} =
      Background.start(
        supervisor: context.runtime,
        session_id: "subscriber",
        owner: self(),
        environment: Environment.local(),
        command: gate.command,
        cwd: context.tmp_dir
      )

    socket = CommandGate.ready(gate)

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(subscriber)
    assert :ok = Background.subscribe(context.runtime, "subscriber", id, subscriber)
    assert :ok = Background.subscribe(context.runtime, "subscriber", id, self())
    assert :ok = Background.unsubscribe(context.runtime, "subscriber", id, self())
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :normal}
    CommandGate.release(socket)
    assert {:ok, %{status: :exited}} = Background.await(context.runtime, "subscriber", id)
    refute_received {:lemieux_background, _}
  end

  # A dev server's log is not a runaway command. With the environment's
  # foreground cap applied here too, one that passed eight megabytes was stopped
  # and reported as failed; the task keeps a bounded head and tail instead.
  test "a command whose output passes the foreground cap keeps running to its exit", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: "head -c 9000000 /dev/zero | tr '\\0' x; echo; echo done",
               cwd: context.tmp_dir,
               timeout_ms: 60_000
             )

    assert {:ok, finished} = Background.await(context.runtime, "session-1", task_id, 60_000)
    assert finished.status == :exited
    assert finished.exit_status == 0
    assert finished.output_bytes > 9_000_000
    assert finished.output =~ ~r/done\n?\z/
    assert byte_size(finished.output) < 1_100_000
  end

  test "the command runs with the variables it was given", context do
    assert {:ok, task_id} =
             Background.start(
               supervisor: context.runtime,
               session_id: "session-1",
               owner: self(),
               environment: Environment.local(),
               command: ~s(printf %s "$LEMIEUX_BACKGROUND_GIVEN"),
               cwd: context.tmp_dir,
               env: [{"LEMIEUX_BACKGROUND_GIVEN", "yes"}],
               timeout_ms: 10_000
             )

    assert {:ok, %{output: "yes"}} =
             Background.await(context.runtime, "session-1", task_id, 10_000)
  end

  defp task_pid(context, task_id) do
    registry = Lemieux.Supervisor.background_registry(context.runtime)
    [{task, _value}] = Registry.lookup(registry, {"session-1", task_id})
    task
  end
end
