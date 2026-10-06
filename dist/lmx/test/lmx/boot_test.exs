defmodule Lmx.BootTest do
  # Not async: stopping records the signal's status in a persistent term.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  # What a hot upgrade does to Lmx.Boot, for a script run in a VM of its own:
  # a changed version loaded, and the version before it soft-purged, which
  # succeeds because no process is executing that version. Reloading the
  # same beam would prove nothing: a local function stays valid while code
  # identical to its own is loaded.
  @hot_upgrade """
  Code.compiler_options(ignore_module_conflict: true)
  source = File.read!(#{inspect(Path.expand("../../lib/lmx/boot.ex", __DIR__))})
  changed = String.replace_suffix(String.trim_trailing(source), "end", "def upgraded?, do: true\\nend")
  [{Lmx.Boot, _beam}] = Code.compile_string(changed)
  true = :code.soft_purge(Lmx.Boot)
  """

  setup do
    on_exit(fn ->
      :persistent_term.erase({Lmx.Boot, :signal_status})
      :persistent_term.erase({Lmx.Boot, :command})
      :persistent_term.erase({Lmx.Boot, :launcher_notice})
    end)
  end

  test "a command's status is the process status" do
    assert Lmx.Boot.run(["--version"], fn ["--version"] -> 0 end) == 0
    assert Lmx.Boot.run([], fn [] -> 3 end) == 3
  end

  test "a raised exception becomes a failure status and a message" do
    stderr =
      capture_io(:stderr, fn ->
        assert Lmx.Boot.run([], fn _argv -> raise "boom" end) == 1
      end)

    assert stderr =~ "lmx crashed: boom"
  end

  # An exit used to escape to the release's `--eval` printer, which could
  # itself fail while the runtime was still booting and leave a crash dump in
  # whatever directory lmx was started from instead of a status.
  test "an exit becomes a failure status and a message" do
    stderr =
      capture_io(:stderr, fn ->
        assert Lmx.Boot.run([], fn _argv -> exit(:terminal_init_failed) end) == 1
      end)

    assert stderr =~ "lmx stopped:"
    assert stderr =~ "terminal_init_failed"
  end

  test "reporting survives a missing standard error device" do
    assert Lmx.Boot.report("lmx: fallback path", :lmx_boot_test_no_such_device) == :ok
  end

  # SIGTERM used to stop the VM outright: the turn was never recorded as
  # cancelled, and the agent's running command outlived lmx.
  @tag :tmp_dir
  test "a stop cancels the turn in flight before the VM stops", %{tmp_dir: dir} do
    {runtime, session} = busy_session(dir)
    test = self()

    assert Lmx.Boot.stop(143, supervisor: runtime, grace: 0, stop: &send(test, {:stopped, &1})) ==
             :ok

    assert_received {:stopped, 143}
    assert eventually(fn -> Session.snapshot(session).status == :idle end)
    assert transcript(dir) =~ ~s("type":"cancelled")
    # Nothing is in flight any more, so a second stop would not wait.
    assert Lmx.Boot.cancel_sessions(runtime) == 0
  end

  # With the launcher gone, the watcher released the lease after the traps
  # had returned, racing the shutdown the last trap had asked for; a loaded
  # macOS runner stopped the VM first and left the lease behind (the 0.8.1
  # rehearsal, 2026-10-06). The trap itself now releases it, and says why the
  # VM is stopping, before it asks the VM to stop.
  @tag :tmp_dir
  test "with the launcher gone, the lease is released before the VM is asked to stop", %{
    tmp_dir: dir
  } do
    lease = Path.join(dir, "lease")
    File.write!(lease, System.pid())
    System.put_env("LMX_LEASE_FILE", lease)
    on_exit(fn -> System.delete_env("LMX_LEASE_FILE") end)
    :persistent_term.put({Lmx.Boot, :launcher_notice}, :pending)
    test = self()

    stderr =
      capture_io(:stderr, fn ->
        assert Lmx.Boot.stop(143,
                 supervisor: :lmx_boot_test_no_runtime,
                 stop: &send(test, {:stopped, &1, File.exists?(lease)})
               ) == :ok
      end)

    assert_received {:stopped, 143, false}
    assert stderr =~ "the launcher is gone; stopping"
    # Released once; the watcher's later call finds nothing to remove.
    assert Lmx.Boot.release_transferred_lease() == :ok
  end

  # The trap waits in the signal server, and the shutdown that a command
  # starts once it has reported the cancellation waits for that server: a
  # trap that slept out its whole grace held every Ctrl-C up by two seconds.
  @tag :tmp_dir
  test "the grace lasts until the VM is stopping, and no longer", %{tmp_dir: dir} do
    test = self()
    stop = &send(test, {:stopped, &1})

    {runtime, _session} = busy_session(Path.join(dir, "running"))
    running = fn -> {:started, :started} end

    # A command still running may yet report, so the grace runs on.
    {elapsed, :ok} =
      :timer.tc(
        Lmx.Boot,
        :stop,
        [143, [supervisor: runtime, grace: 300, stop: stop, status: running, command: self()]],
        :millisecond
      )

    assert elapsed >= 300
    assert_received {:stopped, 143}

    {runtime, _session} = busy_session(Path.join(dir, "stopping"))
    stopping = fn -> {:stopping, :started} end

    task =
      Task.async(fn ->
        Lmx.Boot.stop(143, supervisor: runtime, grace: 60_000, stop: stop, status: stopping)
      end)

    assert Task.await(task, 5_000) == :ok
    assert_receive {:stopped, 143}
  end

  # A command that is gone reports nothing. The terminal UI's trap stopped
  # its screen with :shutdown, which killed the command linked to it, and
  # the VM then waited out the whole grace with nobody left to end it.
  @tag :tmp_dir
  test "the grace ends once the command is gone", %{tmp_dir: dir} do
    test = self()
    {runtime, _session} = busy_session(dir)
    {command, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^command, :normal}
    running = fn -> {:started, :started} end

    task =
      Task.async(fn ->
        Lmx.Boot.stop(143,
          supervisor: runtime,
          grace: 60_000,
          stop: &send(test, {:stopped, &1}),
          status: running,
          command: command
        )
      end)

    assert Task.await(task, 5_000) == :ok
    assert_receive {:stopped, 143}
    # Cancelled before the grace began, and recorded before the cancel
    # returned: stopping at once loses nothing.
    assert transcript(dir) =~ ~s("type":"cancelled")
    assert Lmx.Boot.cancel_sessions(runtime) == 0
  end

  # The tests tagged :unix below send real signals (`kill`) or stand a shell
  # (/bin/sh) in for the launcher; Windows has neither.
  #
  # The trap path itself, in a VM of its own. Elixir runs a trap and then
  # OTP's default SIGTERM handler, init:stop/0 with status 0; a trap that only
  # spawned the stop let that default win, and the VM exited 0 at once, with
  # the cancellation racing the shutdown.
  @tag :unix
  @tag :tmp_dir
  test "SIGTERM cancels the turn and stops a real VM with 143", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "vm.pid")

    script = """
    alias Lemieux.Providers.Scripted
    Logger.configure(level: :error)
    {:ok, _apps} = Application.ensure_all_started(:lemieux)
    {:ok, runtime} = Lemieux.Supervisor.start_link(name: Lemieux.Supervisor)
    Process.unlink(runtime)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: Lemieux.Supervisor,
        provider: Scripted.new([Scripted.delayed(60_000, Scripted.complete("too late"))]),
        store: Lemieux.Store.JSONL.new(#{inspect(dir)}),
        model: "test:model",
        tools: []
      )

    :ok = Lemieux.Session.prompt(session, "take your time")
    :ok = Lmx.Boot.stop_on_sigterm()
    File.write!(#{inspect(pid_file)}, System.pid())
    Process.sleep(:infinity)
    """

    port = elixir(script)
    vm = await_file(pid_file, port, "")
    {_, 0} = System.cmd("kill", ["-TERM", vm])
    {status, output} = await_exit(port, "")

    assert status == 143, "the VM exited #{status}: #{output}"
    assert transcript(dir) =~ ~s("type":"cancelled")
  end

  # A trap registered after Lmx.Boot's runs before it, and the terminal UI's
  # ends the command by closing the screen. Here the stand-in trap lets the
  # command finish and is still running when the command stops the VM: the
  # command used to stop it with its own 0, before Lmx.Boot's trap had
  # recorded 143.
  @tag :unix
  @tag :tmp_dir
  test "a trap that ends the command first still leaves the VM exiting 143", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "vm.pid")

    script = """
    Logger.configure(level: :error)
    :ok = Lmx.Boot.stop_on_sigterm()
    command = self()

    {:ok, _id} =
      System.trap_signal(:sigterm, fn ->
        send(command, :screen_closed)
        Process.sleep(1_000)
        :ok
      end)

    File.write!(#{inspect(pid_file)}, System.pid())
    receive do: (:screen_closed -> Lmx.Boot.finish(0))
    """

    port = elixir(script)
    vm = await_file(pid_file, port, "")
    {_, 0} = System.cmd("kill", ["-TERM", vm])
    {status, output} = await_exit(port, "")

    assert status == 143, "the VM exited #{status}: #{output}"
  end

  # The terminal UI's trap stops its screen with :shutdown, and the screen is
  # linked to the command, which that kills. Elixir's script runner then
  # printed the exit and halted the VM with 1 at once, before Lmx.Boot's
  # trap had even run.
  @tag :unix
  @tag :tmp_dir
  test "a trap that kills the command still leaves the VM exiting 143", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "vm.pid")

    script = """
    Logger.configure(level: :error)
    :ok = Lmx.Boot.hold_exit_for_signals()
    :ok = Lmx.Boot.stop_on_sigterm()
    screen = spawn_link(fn -> Process.sleep(:infinity) end)

    {:ok, _id} =
      System.trap_signal(:sigterm, fn ->
        Process.exit(screen, :shutdown)
        Process.sleep(500)
        :ok
      end)

    File.write!(#{inspect(pid_file)}, System.pid())
    Process.sleep(:infinity)
    """

    port = elixir(script)
    vm = await_file(pid_file, port, "")
    {_, 0} = System.cmd("kill", ["-TERM", vm])
    {status, output} = await_exit(port, "")

    assert status == 143, "the VM exited #{status}: #{output}"
  end

  # A trap added or removed while a SIGTERM is being handled (the terminal
  # UI's command adds one as its screen opens and removes it once the screen
  # is closed) holds Elixir's configuration server until the signal server
  # is free, and System.stop/1 inside Lmx.Boot's trap waited for that
  # server: the VM hung, with every later signal (SIGUSR1 included) queued
  # behind it.
  @tag :unix
  @tag :tmp_dir
  test "a trap removed while SIGTERM is handled cannot hang the stop", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "vm.pid")

    script = """
    Logger.configure(level: :error)
    :ok = Lmx.Boot.stop_on_sigterm()

    {:ok, :screen} =
      System.trap_signal(:sigterm, :screen, fn ->
        spawn(fn -> System.untrap_signal(:sigterm, :screen) end)
        Process.sleep(500)
        :ok
      end)

    File.write!(#{inspect(pid_file)}, System.pid())
    Process.sleep(:infinity)
    """

    port = elixir(script)
    vm = await_file(pid_file, port, "")
    {_, 0} = System.cmd("kill", ["-TERM", vm])
    {status, output} = await_exit(port, "", 15_000)

    assert status == 143, "the VM exited #{status}: #{output}"
  end

  # The signal server and Elixir's configuration server hold the trap and the
  # exit hook as data for the life of the VM, and soft purge ignores data. A
  # hot upgrade that loads a new Lmx.Boot and purges the version that made
  # them left local functions pointing at nothing: the trap raised
  # BadFunctionError, the signal server dropped it, and OTP's default
  # stopped the VM with 0; the hook raised in the script runner, which then
  # halted with 1.
  describe "after a hot upgrade replaces Lmx.Boot" do
    @describetag :tmp_dir
    @describetag :unix

    test "SIGTERM still stops the VM with 143", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "vm.pid")

      script = """
      Logger.configure(level: :error)
      :ok = Lmx.Boot.stop_on_sigterm()
      #{@hot_upgrade}
      File.write!(#{inspect(pid_file)}, System.pid())
      Process.sleep(:infinity)
      """

      port = elixir(script)
      vm = await_file(pid_file, port, "")
      {_, 0} = System.cmd("kill", ["-TERM", vm])
      {status, output} = await_exit(port, "")

      assert status == 143, "the VM exited #{status}: #{output}"
    end

    test "a trap that kills the command still leaves the VM exiting 143", %{tmp_dir: dir} do
      pid_file = Path.join(dir, "vm.pid")

      script = """
      Logger.configure(level: :error)
      :ok = Lmx.Boot.hold_exit_for_signals()
      :ok = Lmx.Boot.stop_on_sigterm()
      #{@hot_upgrade}
      screen = spawn_link(fn -> Process.sleep(:infinity) end)

      {:ok, _id} =
        System.trap_signal(:sigterm, fn ->
          Process.exit(screen, :shutdown)
          Process.sleep(500)
          :ok
        end)

      File.write!(#{inspect(pid_file)}, System.pid())
      Process.sleep(:infinity)
      """

      port = elixir(script)
      vm = await_file(pid_file, port, "")
      {_, 0} = System.cmd("kill", ["-TERM", vm])
      {status, output} = await_exit(port, "")

      assert status == 143, "the VM exited #{status}: #{output}"
    end
  end

  # The real VM path for a killed launcher: Lmx.Boot's trap and every other
  # one. A trap registered later stands in for the terminal UI's, which
  # leaves the screen; the watchdog used to stop the VM directly, so it never
  # ran and the person's shell came back inside the alternate screen. The
  # lease is released only after the traps have run. Nothing in this VM
  # ends a command, so Lmx.Boot's trap waits out its three-second grace.
  @tag :unix
  @tag :tmp_dir
  test "a killed launcher's VM runs every SIGTERM trap and exits 143", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "vm.pid")
    marker = Path.join(dir, "screen-closed")
    lease = Path.join(dir, "lease")
    # Not the VM's parent, so the watch loop polls its pid (`kill -0`).
    {launcher, _same} = spawn_pids("echo $$; echo $$; exec sleep 60")

    script = """
    alias Lemieux.Providers.Scripted
    Logger.configure(level: :error)
    {:ok, _apps} = Application.ensure_all_started(:lemieux)
    {:ok, runtime} = Lemieux.Supervisor.start_link(name: Lemieux.Supervisor)
    Process.unlink(runtime)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: Lemieux.Supervisor,
        provider: Scripted.new([Scripted.delayed(60_000, Scripted.complete("too late"))]),
        store: Lemieux.Store.JSONL.new(#{inspect(dir)}),
        model: "test:model",
        tools: []
      )

    :ok = Lemieux.Session.prompt(session, "take your time")
    :ok = Lmx.Boot.stop_on_sigterm()

    {:ok, _id} =
      System.trap_signal(:sigterm, fn ->
        File.write!(#{inspect(marker)}, "lease held: \#{File.exists?(#{inspect(lease)})}")
        :ok
      end)

    System.put_env("LMX_LEASE_FILE", #{inspect(lease)})
    File.write!(#{inspect(lease)}, System.pid())
    :ok = Lmx.Boot.watch_launcher(#{inspect(launcher)})
    File.write!(#{inspect(pid_file)}, System.pid())
    Process.sleep(:infinity)
    """

    port = elixir(script)
    _vm = await_file(pid_file, port, "")
    {_, 0} = System.cmd("kill", ["-KILL", launcher])
    {status, output} = await_exit(port, "")

    assert status == 143, "the VM exited #{status}: #{output}"
    assert output =~ "the launcher is gone"
    assert File.read(marker) == {:ok, "lease held: true"}, "the later trap never ran: #{output}"
    assert transcript(dir) =~ ~s("type":"cancelled")
    refute File.exists?(lease)
  end

  describe "the status a finished command stops with" do
    test "is the command's own when no signal is being handled" do
      assert Lmx.Boot.exit_status(3) == 3
    end

    test "is the signal's once one is recorded" do
      :ok = Lmx.Boot.stop(130, supervisor: Lmx.BootTest.NotMounted, grace: 0, stop: & &1)
      assert Lmx.Boot.exit_status(0) == 130
    end

    # The order a terminal UI's trap produces: it ends the command while the
    # signal is still being handled, before Lmx.Boot's trap records anything.
    test "waits for a signal still being handled and takes the status it records" do
      test = self()

      server =
        signal_server(fn :sigterm ->
          send(test, :handling)
          Process.sleep(300)
          :ok = Lmx.Boot.stop(143, supervisor: Lmx.BootTest.NotMounted, grace: 0, stop: & &1)
          # Lmx.Boot's grace: the command must not wait it out.
          Process.sleep(5_000)
        end)

      :ok = :gen_event.notify(server, :sigterm)
      assert_receive :handling

      {elapsed, status} =
        :timer.tc(fn -> Lmx.Boot.exit_status(0, server: server) end, :millisecond)

      # 143 is the proof that it waited: the trap records it 300 ms after
      # :handling, and nothing earlier would. No lower bound on the time,
      # which shrinks by however late this process saw :handling.
      assert status == 143
      assert elapsed < 2_000
    end

    test "gives up on a signal server that never finishes" do
      test = self()

      server =
        signal_server(fn _signal ->
          send(test, :handling)
          Process.sleep(5_000)
        end)

      :ok = :gen_event.notify(server, :sigusr2)
      assert_receive :handling

      {elapsed, status} =
        :timer.tc(fn -> Lmx.Boot.exit_status(5, server: server, wait: 200) end, :millisecond)

      assert status == 5
      assert elapsed in 150..2_000
    end
  end

  test "the first signal's status wins, and a missing runtime has nothing to cancel" do
    test = self()
    stop = &send(test, {:stopped, &1})
    none = :"Elixir.Lmx.BootTest.NotMounted"

    assert Lmx.Boot.cancel_sessions(none) == 0
    :ok = Lmx.Boot.stop(130, supervisor: none, grace: 0, stop: stop)
    :ok = Lmx.Boot.stop(143, supervisor: none, grace: 0, stop: stop)

    assert_received {:stopped, 130}
    assert_received {:stopped, 130}
  end

  # A launcher killed outright used to leave its VM running the turn alone.
  # Here a shell stands in for the launcher and its `sleep` for the VM.
  @tag :unix
  test "the VM notices when its launcher is killed outright" do
    test = self()

    {launcher, vm} =
      spawn_pids("echo $$; sleep 30 & echo $!; wait")

    stderr =
      capture_io(:stderr, fn ->
        :ok =
          Lmx.Boot.watch_launcher(launcher,
            vm: vm,
            on_exit: fn -> send(test, {:launcher_gone, self()}) end
          )

        refute_receive {:launcher_gone, _watchdog}, 1_500
        {_, 0} = System.cmd("kill", ["-KILL", launcher])
        assert_receive {:launcher_gone, watchdog}, 10_000
        await_down(watchdog)
      end)

    System.cmd("kill", ["-KILL", vm])
    assert stderr =~ "the launcher is gone"
  end

  # The terminal UI's trap leaves its alternate screen, and a line written
  # there first went with it: the person's shell was left with the script
  # runner's exit report and no word of why lmx had stopped.
  @tag :unix
  test "the reason is written once the stop has run" do
    test = self()
    {launcher, _vm} = spawn_pids("echo $$; echo 1; exec sleep 1")

    stderr =
      capture_io(:stderr, fn ->
        :ok =
          Lmx.Boot.watch_launcher(launcher,
            vm: System.pid(),
            on_exit: fn ->
              IO.puts(:stderr, "the screen is left")
              send(test, {:stopped, self()})
            end
          )

        assert_receive {:stopped, watchdog}, 10_000
        await_down(watchdog)
      end)

    assert stderr =~ ~r/the screen is left\n.*lmx: the launcher is gone; stopping/s
  end

  # Where the VM's parent cannot be read, the launcher's pid is polled.
  @tag :unix
  test "the VM notices a launcher that exits, without reading its parent" do
    test = self()
    {launcher, _vm} = spawn_pids("echo $$; echo 1; exec sleep 2")

    capture_io(:stderr, fn ->
      :ok =
        Lmx.Boot.watch_launcher(launcher,
          vm: System.pid(),
          on_exit: fn -> send(test, {:launcher_gone, self()}) end
        )

      refute_receive {:launcher_gone, _watchdog}, 500
      assert_receive {:launcher_gone, watchdog}, 10_000
      await_down(watchdog)
    end)
  end

  @tag :tmp_dir
  test "only this VM's transferred lease is released", %{tmp_dir: dir} do
    previous = System.get_env("LMX_LEASE_FILE")

    on_exit(fn ->
      if previous,
        do: System.put_env("LMX_LEASE_FILE", previous),
        else: System.delete_env("LMX_LEASE_FILE")
    end)

    lease = Path.join(dir, "lease")
    System.put_env("LMX_LEASE_FILE", lease)

    File.write!(lease, "1")
    assert Lmx.Boot.release_transferred_lease() == :ok
    assert File.exists?(lease)

    File.write!(lease, System.pid())
    assert Lmx.Boot.release_transferred_lease() == :ok
    refute File.exists?(lease)
  end

  test "without a launcher pid there is nothing to watch" do
    assert Lmx.Boot.watch_launcher(nil) == :ok
    assert Lmx.Boot.watch_launcher("") == :ok
    assert Lmx.Boot.watch_launcher("not-a-pid") == :ok
  end

  # A handler for a signal server of a test's own: runs a function on each
  # signal, in the server, as a trap does.
  defmodule Trap do
    @moduledoc false
    @behaviour :gen_event

    @impl :gen_event
    def init(on_signal), do: {:ok, on_signal}

    @impl :gen_event
    def handle_event(signal, on_signal) do
      on_signal.(signal)
      {:ok, on_signal}
    end

    @impl :gen_event
    def handle_call(_request, on_signal), do: {:ok, :ok, on_signal}
  end

  # An event manager standing in for the VM's `erl_signal_server`, with one
  # trap. Killed at the end: a trap still sleeping would hold up its stop.
  defp signal_server(on_signal) do
    server =
      start_supervised!(%{
        id: make_ref(),
        start: {:gen_event, :start_link, []},
        shutdown: :brutal_kill
      })

    :ok = :gen_event.add_handler(server, Trap, on_signal)
    server
  end

  # Runs `script` in a VM of its own, with this project's code.
  defp elixir(script) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])

    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: code_paths ++ ["-e", script]
    ])
  end

  # A runtime with one session whose turn is in flight for a minute.
  defp busy_session(dir) do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime}, id: runtime)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([Scripted.delayed(60_000, Scripted.complete("too late"))]),
        store: JSONL.new(dir),
        model: "test:model",
        tools: []
      )

    :ok = Session.prompt(session, "take your time")
    assert Session.snapshot(session).status == :busy
    {runtime, session}
  end

  # The watchdog writes its line after the stop it runs, so a test reading
  # standard error waits for it to finish.
  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # Runs `script` and reads the two pids it prints first.
  defp spawn_pids(script) do
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", script]])
    [first, second] = read_lines(port, "", 2)
    {first, second}
  end

  defp read_lines(port, buffer, count) do
    case String.split(buffer, "\n", trim: true) do
      lines when length(lines) >= count ->
        Enum.take(lines, count)

      _ ->
        receive do
          {^port, {:data, data}} -> read_lines(port, buffer <> data, count)
        after
          5_000 -> flunk("the stand-in launcher printed no pids")
        end
    end
  end

  # Waits for the child VM to write `path`, failing with its output if it
  # exits first.
  defp await_file(path, port, output, attempts \\ 300) do
    case File.read(path) do
      {:ok, pid} when pid != "" ->
        pid

      _not_yet when attempts == 0 ->
        flunk("the VM never started its turn: #{output}")

      _not_yet ->
        receive do
          {^port, {:data, data}} -> await_file(path, port, output <> data, attempts)
          {^port, {:exit_status, status}} -> flunk("the VM exited #{status} early: #{output}")
        after
          100 -> await_file(path, port, output, attempts - 1)
        end
    end
  end

  defp await_exit(port, output, ms \\ 30_000) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data, ms)
      {^port, {:exit_status, status}} -> {status, output}
    after
      ms ->
        # A VM that hung must not outlive the test.
        with {:os_pid, vm} <- Port.info(port, :os_pid), do: System.cmd("kill", ["-KILL", "#{vm}"])
        flunk("the VM did not exit after SIGTERM: #{output}")
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(check, attempts - 1)
    end
  end

  defp transcript(dir) do
    dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
  end
end
