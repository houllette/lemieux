defmodule Lemieux.Environment.LocalTeardownTest do
  # A command the agent is running must not outlive the VM that started it,
  # however the VM ends: a closed terminal (SIGHUP to its process group),
  # `timeout` or a container stopping (SIGTERM), `kill -9`. Each case boots a
  # VM of its own, starts a command that backgrounds a child, ends the VM, and
  # looks for the child afterwards.
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local.ExCmd

  @moduletag :tmp_dir

  unless match?({:unix, _}, :os.type()) and ExCmd.process_groups?() do
    @moduletag skip: "needs process groups: setsid or perl, and kill or sh"
  end

  # The child is short-lived on purpose: if teardown fails, the orphan goes
  # away by itself shortly after the suite has said so, and so does a VM the
  # signal missed. Nothing here signals a pid after the test, when the system
  # may already have given it to somebody else.
  @script """
  dir = System.fetch_env!("LMX_TEARDOWN_DIR")
  {:ok, _apps} = Application.ensure_all_started(:ex_cmd)
  File.write!(Path.join(dir, "vm.pid"), System.pid())

  {:ok, events} =
    Lemieux.Environment.Local.ExCmd.run("sleep 20 & echo $! > child.pid; wait",
      cwd: dir,
      timeout_ms: 60_000,
      max_output_bytes: 1_000_000
    )

  File.write!(Path.join(dir, "started"), "started")
  Enum.each(events, fn _event -> :ok end)
  """

  test "SIGTERM to the VM stops the command it was running", %{tmp_dir: dir} do
    {port, vm} = start_vm(dir, own_group?: false)
    child = await_started(dir)

    signal("TERM", vm)

    assert_vm_exited(port)
    assert gone?(child), "the command's child #{child} outlived the VM"
  end

  test "a closed terminal — SIGHUP to the VM's process group — stops it too", %{tmp_dir: dir} do
    {port, vm} = start_vm(dir, own_group?: true)
    child = await_started(dir)

    signal("HUP", "-" <> vm)

    assert_vm_exited(port)
    assert gone?(child), "the command's child #{child} outlived the VM"
  end

  test "so does kill -9 of the VM", %{tmp_dir: dir} do
    {port, vm} = start_vm(dir, own_group?: false)
    child = await_started(dir)

    signal("KILL", vm)

    assert_vm_exited(port)
    assert gone?(child), "the command's child #{child} outlived the VM"
  end

  # The owner traps exits; an exit signal somebody sends it used to sit in
  # its mailbox, unread, while the command ran on.
  test "an exit signal sent to the command's owner tears the command down", %{tmp_dir: dir} do
    {:ok, events} =
      ExCmd.run("sleep 20 & echo $! > child.pid; wait",
        cwd: dir,
        timeout_ms: 60_000,
        max_output_bytes: 1_000_000
      )

    consumer = Task.async(fn -> Enum.to_list(events) end)
    child = await_file(Path.join(dir, "child.pid"))
    # The owner watches the process that ran the command: this one.
    owner = owner_of(self())
    ref = Process.monitor(owner)

    Process.exit(owner, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}, 10_000
    assert gone?(child), "the command's child #{child} outlived its owner"
    Task.shutdown(consumer, :brutal_kill)
  end

  # What ExCmd's helper does to the shell when SIGINT or SIGTERM reaches the
  # VM's process group — Ctrl-C in a terminal — while the VM itself lives on.
  # The child keeps no hold on the output, so the command's end is seen at once.
  @tag :capture_log
  test "a shell killed by a signal does not leave what it was running", %{tmp_dir: dir} do
    {:ok, events} =
      ExCmd.run(
        "echo $$ > shell.pid; sleep 20 > /dev/null 2>&1 & echo $! > child.pid; wait",
        cwd: dir,
        timeout_ms: 60_000,
        max_output_bytes: 1_000_000
      )

    consumer = Task.async(fn -> Enum.to_list(events) end)
    shell = await_file(Path.join(dir, "shell.pid"))
    child = await_file(Path.join(dir, "child.pid"))

    signal("KILL", shell)

    assert [{:failed, :killed}] = Task.await(consumer, 10_000)
    assert gone?(child), "the killed shell's child #{child} ran on"
  end

  # Ended by itself, a command's background work is its own, as it always
  # was: the watchdog stands down instead of taking it.
  test "a command that finishes leaves what it started in the background", %{tmp_dir: dir} do
    {:ok, events} =
      ExCmd.run("(sleep 20 > /dev/null 2>&1 & echo $! > child.pid)",
        cwd: dir,
        timeout_ms: 30_000,
        max_output_bytes: 1_000_000
      )

    assert Enum.to_list(events) == [{:exit_status, 0}]
    child = await_file(Path.join(dir, "child.pid"))

    Process.sleep(500)
    assert alive?(child)
    signal("KILL", child)
  end

  defp start_vm(dir, own_group?: own_group?) do
    elixir = System.find_executable("elixir")
    libraries = :lemieux |> :code.lib_dir() |> to_string() |> Path.dirname()
    {executable, args} = command(elixir, ["-e", @script], own_group?)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [
          {~c"ERL_LIBS", String.to_charlist(libraries)},
          {~c"LMX_TEARDOWN_DIR", String.to_charlist(dir)}
        ]
      ])

    {port, await_file(Path.join(dir, "vm.pid"))}
  end

  # A VM leading a process group of its own, as one started from a terminal
  # does, so the whole group can be signalled without signalling this one.
  defp command(executable, args, false), do: {executable, args}

  defp command(executable, args, true) do
    case System.find_executable("setsid") do
      nil ->
        perl = System.find_executable("perl")

        {perl,
         ["-e", "use POSIX (); POSIX::setsid(); exec { $ARGV[0] } @ARGV", "--", executable | args]}

      setsid ->
        {setsid, [executable | args]}
    end
  end

  # The command's child is running, and `run/2` has returned. The command
  # starts a moment before ExCmd tells its owner the process id, and a VM
  # that ends in that moment leaves it unguarded (see "When the VM goes
  # first" in `Lemieux.Environment.Local.ExCmd`). Signalling as soon as
  # `child.pid` appeared hit that moment under load on Linux CI, on every
  # run (2026-10-05); what these tests hold to is a command `run/2` has
  # reported started.
  defp await_started(dir) do
    child = await_file(Path.join(dir, "child.pid"))
    await_file(Path.join(dir, "started"))
    child
  end

  defp await_file(path, deadline \\ System.monotonic_time(:millisecond) + 30_000) do
    case File.read(path) do
      {:ok, contents} when contents != "" ->
        String.trim(contents)

      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("#{path} was never written")

        Process.sleep(50)
        await_file(path, deadline)
    end
  end

  defp assert_vm_exited(port) do
    assert_receive {^port, {:exit_status, _status}}, 30_000
  end

  # The shell's own `kill`, so the test needs no procps either.
  defp signal(name, target),
    do: System.cmd("sh", ["-c", "kill -s #{name} -- #{target} 2>/dev/null"])

  defp alive?(pid),
    do: match?({_output, 0}, System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null"]))

  defp gone?(pid, attempts \\ 100)
  defp gone?(pid, 0), do: not alive?(pid)

  defp gone?(pid, attempts) do
    if alive?(pid) do
      Process.sleep(50)
      gone?(pid, attempts - 1)
    else
      true
    end
  end

  # The owner of a command `caller` started: it waits in the owner loop and
  # monitors the process that ran the command.
  defp owner_of(caller) do
    owner =
      Enum.find(Process.list(), fn pid ->
        # Each answer can be nil: another test's owner may finish meanwhile.
        with {:current_function, {ExCmd, :owner_loop, 1}} <-
               Process.info(pid, :current_function),
             {:monitors, monitors} <- Process.info(pid, :monitors) do
          {:process, caller} in monitors
        else
          _other -> false
        end
      end)

    owner || flunk("no command owner found for #{inspect(caller)}")
  end
end
