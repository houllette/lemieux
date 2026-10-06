defmodule Lmx.Boot do
  @moduledoc """
  Runs after application startup. Arguments travel through a private, NUL
  separated file rather than an evaluated expression, so shell metacharacters
  and multiline prompts remain data. The launcher owns this file; the release
  consumes and removes it before dispatching anything.

  The release starts this with `elixir --eval`, so anything that escapes
  `main/0` is printed by Elixir's evaluator instead of becoming a status. That
  printer writes to the standard error device, which may already be gone while
  the runtime is failing; the write then raised in turn and the VM left a crash
  dump in whatever directory lmx was started from. `run/2` therefore turns
  every exception and exit into a message and status 1, and `report/2` falls
  back to the emulator's own standard error when the device is missing.

  ## Stopping

  A command ends with `System.stop/1`, an orderly shutdown that keeps the
  status, rather than `System.halt/1`, which skipped every application's
  shutdown (and, while the release ran under heart, was what heart reported as
  "Erlang has closed").

  The launcher turns Ctrl-C, a closed terminal and `kill` into SIGTERM for the
  VM: the VM itself ignores SIGINT (`+Bi`) and SIGHUP (the launcher starts it
  with SIGHUP ignored), so the launcher's SIGTERM is the only way those reach
  it. Left to the VM's default, SIGTERM stopped the system at once: the turn
  in flight was never recorded as cancelled and the agent's running command
  kept going with nobody attached. `stop/2` cancels every running session
  first, which kills each command's process group and writes the
  cancellation to the transcript, then, if a turn was in flight, gives the
  command up to three seconds to report it before stopping the VM with 143.
  Whatever status the command returns meanwhile, the VM still exits with 143,
  and the launcher exits with the status of the signal it received: 130 for
  Ctrl-C, 129 for a closed terminal, 143 for SIGTERM.

  All of that runs inside the SIGTERM trap, before it returns. Elixir runs a
  trap and then OTP's own SIGTERM handler, which calls `init:stop/0` with
  status 0 as soon as the trap returns. A trap that spawned the stop and
  returned at once therefore lost to it: the VM exited 0 within milliseconds,
  and the cancellation raced the shutdown. The trap asks `init` itself
  (`:init.stop/1` only queues the request, and the first request wins), so
  the 143 asked for inside the trap is the status the VM exits with.

  Traps run one after another, newest first, so a trap a command registers
  while it runs (the terminal UI's, which leaves its screen) runs before this
  one, and can end the command before the 143 is recorded: by letting it
  return, after which `finish/1` waits for the signal still being handled
  (`exit_status/2`), or by killing it, after which Elixir's script runner
  would halt the VM with 1 (`hold_exit_for_signals/0` holds it). The VM
  exits 143 either way, and a command that is gone has nothing left to
  report, so the grace ends there rather than running its three seconds.

  A launcher killed outright (SIGKILL, a subprocess timeout) cannot forward
  anything, and its VM used to carry on alone: retrying a stalled provider for
  ten minutes, running tools, spending. The VM therefore watches the
  launcher's pid, and when it disappears handles SIGTERM as though the
  launcher had forwarded one (`watch_launcher/2`), every trap included.

  ## Callbacks other processes hold

  The signal server holds the trap, and Elixir's configuration server the
  exit hook, for as long as the VM runs; the upgrade guard
  (`Lmx.Update.Callbacks`) inspects neither. Both are external captures of
  public functions (`&__MODULE__.on_sigterm/0`,
  `&__MODULE__.hold_for_signal/1`), which call whatever version of this
  module is current. A local function keeps the version that made it, and
  soft purge ignores functions held as data, so one was safe only while some
  process still executed that version. Reloaded and soft-purged in a test
  VM, a local trap raised `BadFunctionError` on the next SIGTERM, the signal
  server dropped it, and OTP's default stopped the VM with 0 and nothing
  cancelled. In the release the command's process and the watchdog do
  execute this module for the whole command, which soft purge respects (a
  second hot upgrade that changes this module falls back to a restart), but
  the callbacks no longer depend on that.
  """

  @grace_ms 3_000
  @poll_ms 50
  # How long a finished command waits for a signal still being handled.
  # The traps that run before this module's are bounded (the terminal UI
  # gives its screen five seconds to close); a trap that never returns must
  # not keep a finished command from ending at all.
  @settle_ms 10_000
  @signal_status {__MODULE__, :signal_status}
  # The process whose report of a cancellation the grace waits for: the one
  # that set the trap (`stop_on_sigterm/0`), which in the release is the
  # command `main/0` runs.
  @command {__MODULE__, :command}
  # `:pending` from the moment the launcher is found gone until the notice
  # is written, then `:reported`; see `watch_launcher/2`.
  @launcher_notice {__MODULE__, :launcher_notice}
  @launcher_gone "lmx: the launcher is gone; stopping"

  @doc "Consumes launcher arguments and runs the CLI with a process lease."
  @spec main() :: no_return()
  def main do
    path = System.fetch_env!("LMX_ARGV_FILE")
    argv = path |> File.read!() |> String.split(<<0>>, trim: false) |> Enum.drop(-1)
    File.rm!(path)
    System.delete_env("LMX_ARGV_FILE")
    # Before anything can start a command: what the person's commands
    # inherit is their environment, not this VM's (`Lmx.CLI`, "What the
    # commands lmx starts inherit").
    :ok = Lmx.CLI.inherit()
    {:ok, _} = Application.ensure_all_started(:lmx)
    :ok = hold_exit_for_signals()
    :ok = stop_on_sigterm()
    :ok = watch_launcher(System.get_env("LMX_LAUNCHER_PID"))
    lease = Lmx.Update.lease()

    status =
      try do
        run(argv, &Lmx.CLI.run/1)
      after
        Lmx.Update.release_lease(lease)
      end

    finish(status)
  end

  @doc """
  Ends the command: an orderly stop with `status`, or with the status of a
  signal that is stopping the VM (`exit_status/2`).
  """
  @spec finish(status :: non_neg_integer()) :: no_return()
  def finish(status) when is_integer(status) and status >= 0 do
    System.stop(exit_status(status))
    # System.stop/1 returns at once; the shutdown takes this process with it.
    Process.sleep(:infinity)
  end

  @doc """
  The status a command that ended with `status` stops the VM with: a
  signal's, once `stop/2` has recorded one, else `status`.

  A signal still being handled when the command ends is waited for. The
  signal server runs traps newest first, so a trap the command registered
  after `stop_on_sigterm/0` runs before this module's, and it can let the
  command return: closing the terminal UI's screen ends that command. A
  command that reached `finish/1` before the 143 was recorded stopped the
  VM with its own status, 0 for a screen that closed cleanly, because `init`
  keeps the first status it is asked for. (The terminal UI's command is held
  back by chance: removing its trap on the way out waits for the signal
  server. A trap that stays registered holds nothing back.)

  So, unless a status is already recorded, this asks the signal server a
  question it can only answer between signals. A status recorded while it
  waits is taken at once, without waiting out `stop/2`'s grace, which ends
  only once the VM is stopping; when the answer comes, the status recorded by
  then, if any, wins. With no signal being handled the answer is immediate.
  The wait gives up after ten seconds, so a trap that never returns cannot
  keep a finished command from ending.

  Options (for tests): `:server`, the signal server (default
  `:erl_signal_server`), and `:wait` in milliseconds.
  """
  @spec exit_status(status :: non_neg_integer(), opts :: keyword()) :: non_neg_integer()
  def exit_status(status, opts \\ []) when is_integer(status) and status >= 0 do
    case :persistent_term.get(@signal_status, nil) do
      nil -> await_signals(status, opts)
      signal -> signal
    end
  end

  defp await_signals(status, opts) do
    server = Keyword.get(opts, :server, :erl_signal_server)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait, @settle_ms)
    # The question: a call the server answers after the event it is handling,
    # every trap included. A server that is gone answers nothing, and that
    # ends the wait as well.
    {_pid, ref} = spawn_monitor(fn -> :gen_event.which_handlers(server) end)
    await_signals(ref, deadline, status)
  end

  defp await_signals(ref, deadline, status) do
    receive do
      {:DOWN, ^ref, :process, _pid, _between_signals} ->
        :persistent_term.get(@signal_status, status)
    after
      @poll_ms -> polled(:persistent_term.get(@signal_status, nil), ref, deadline, status)
    end
  end

  defp polled(nil, ref, deadline, status) do
    if System.monotonic_time(:millisecond) < deadline,
      do: await_signals(ref, deadline, status),
      else: settled(ref, status)
  end

  defp polled(signal, ref, _deadline, _status), do: settled(ref, signal)

  defp settled(ref, status) do
    Process.demonitor(ref, [:flush])
    status
  end

  @doc """
  Runs `runner` on `argv` and returns an OS exit status, whatever happens.

  Split from `main/0`, which halts, so the translation can be tested without
  taking the test VM down.
  """
  @spec run(argv :: [String.t()], runner :: ([String.t()] -> non_neg_integer())) ::
          non_neg_integer()
  def run(argv, runner) when is_list(argv) and is_function(runner, 1) do
    runner.(argv)
  rescue
    error ->
      report("lmx crashed: " <> Exception.message(error))
      1
  catch
    :exit, reason ->
      report("lmx stopped: " <> Exception.format_exit(reason))
      1

    :throw, value ->
      report("lmx stopped on an uncaught throw: " <> inspect(value))
      1
  end

  @doc """
  Writes one line to standard error, even when `device` no longer exists.

  The standard error device is a registered process, and during a failing
  boot it can be missing (`IO.puts/2` raises `ArgumentError`), or it can end
  while the line is being written, as it does when the launcher that held the
  terminal is gone (`ErlangError` with `:terminated`). The emulator's own
  standard error still works, so the message goes there.
  """
  @spec report(message :: String.t(), device :: atom()) :: :ok
  def report(message, device \\ :stderr) when is_binary(message) do
    IO.puts(device, message)
  rescue
    _gone in [ArgumentError, ErlangError] ->
      :erlang.display_string(:stderr, String.to_charlist(message <> "\n"))
      :ok
  end

  @doc """
  Keeps Elixir's script runner from halting the VM while a signal is
  stopping it.

  The release runs `main/0` with `elixir --eval`. When that process dies of
  an exit signal from a process linked to it, the runner prints the exit
  and halts the VM with status 1, ahead of the orderly stop a signal's trap
  asks for. The terminal UI's trap stops its screen with `:shutdown`, and the
  screen is linked to the command, which that kills: a SIGTERM sent to a
  terminal UI's VM ended it with 1 before this module's trap had run. The
  runner calls the `System.at_exit/1` hooks before it halts. This one waits
  while a signal is being handled (`exit_status/2`) and, when a signal is
  stopping the VM, holds the runner, so `init` ends the VM with the signal's
  status. Any other death of the command still ends in the runner's halt
  with 1. The runner's line, `** (EXIT from #PID<…>) shutdown`, is printed
  before the hooks run; only a screen stopped with `:normal` avoids it.
  """
  @spec hold_exit_for_signals() :: :ok
  def hold_exit_for_signals do
    # External, so a hot upgrade cannot leave the hook pointing at purged
    # code; the moduledoc's "Callbacks other processes hold" says why.
    System.at_exit(&__MODULE__.hold_for_signal/1)
  end

  @doc false
  # The exit hook `hold_exit_for_signals/0` registers. It runs in a process
  # of the script runner's, which waits for it before halting.
  @spec hold_for_signal(status :: integer()) :: :ok
  def hold_for_signal(_status) do
    if exit_status(0) > 0, do: Process.sleep(:infinity)
    :ok
  end

  @doc """
  Makes SIGTERM run `stop/2` with status 143 before the VM's own SIGTERM
  handler stops the system; the moduledoc explains the order. Unsupported
  platforms (Windows) keep the default.

  The calling process is the command whose report of a cancellation the
  grace waits for (`stop/2`); in the release that is the one `main/0` runs.
  """
  @spec stop_on_sigterm() :: :ok
  def stop_on_sigterm do
    :persistent_term.put(@command, self())

    # External, so a hot upgrade cannot leave the trap pointing at purged
    # code; the moduledoc's "Callbacks other processes hold" says why.
    case System.trap_signal(:sigterm, :lmx_stop, &__MODULE__.on_sigterm/0) do
      {:ok, _id} -> :ok
      {:error, :already_registered} -> :ok
      {:error, :not_sup} -> :ok
    end
  end

  @doc false
  # Runs in the signal server, and OTP's default handler (init:stop/0, status
  # 0) runs the moment this returns. So the whole stop happens here: the
  # cancellation, the grace while a turn reports it, and the request for 143,
  # which reaches init first and wins. Blocking the signal server meanwhile
  # only delays other signals.
  @spec on_sigterm() :: :ok
  def on_sigterm, do: stop(143)

  @doc """
  Cancels the running sessions, waits for the command to report that, then
  stops the VM with `status`. The first signal's status wins. With no turn
  in flight there is nothing to report, and the stop is immediate.

  The wait ends early once the VM is already stopping: a command that has
  reported the cancellation stops the VM itself (`finish/1`, with the
  signal's status), and a trap still sleeping in the signal server would only
  hold up that shutdown until the kernel killed the server, two seconds on.
  It also ends once the command is gone, since nothing is left to report. A
  trap that runs before this one can end it: the terminal UI's stopped its
  screen with `:shutdown`, which killed the command linked to the screen,
  and the VM then sat out the whole grace before exiting. The cancellation
  itself is already on the transcript by then: `Lemieux.Session.cancel/2`
  records it before it returns.

  The VM is stopped with `:init.stop/1`, not `System.stop/1`, because this
  runs in the signal server. `System.stop/1` first registers an exit hook
  with Elixir's configuration server, and a process adding or removing a
  signal trap holds that server while it waits for the signal server. The
  terminal UI's command adds a trap when its screen opens and removes it
  when the screen closes, and a SIGTERM can arrive at either moment, or be
  what closed the screen. Each waited for the other, and the VM hung with
  every later signal queued behind the SIGTERM.

  Options (for tests): `:supervisor` (default `Lemieux.Supervisor`), `:grace`
  in milliseconds (default 3000), `:stop`, the function that stops the VM,
  `:status`, the function that reads `init`'s status, and `:command`, the
  command's pid (default the process that called `stop_on_sigterm/0`, if
  any; `nil` for none).
  """
  @spec stop(status :: pos_integer(), opts :: keyword()) :: :ok
  def stop(status, opts \\ []) when is_integer(status) and status > 0 do
    if :persistent_term.get(@signal_status, nil) == nil,
      do: :persistent_term.put(@signal_status, status)

    in_flight = cancel_sessions(Keyword.get(opts, :supervisor, Lemieux.Supervisor))
    init_status = Keyword.get(opts, :status, &:init.get_status/0)
    command = Keyword.get_lazy(opts, :command, fn -> :persistent_term.get(@command, nil) end)

    if in_flight > 0,
      do: await_report(Keyword.get(opts, :grace, @grace_ms), init_status, command)

    # With the launcher gone, everything that has to happen before the VM
    # stops happens here, ahead of the request to stop it: the watcher that
    # found the launcher gone runs after the traps, racing the shutdown they
    # started, and a loaded runner stopped the VM first (`watch_launcher/2`).
    if :persistent_term.get(@launcher_notice, nil) == :pending do
      release_transferred_lease()
      report_launcher_gone()
    end

    stop = Keyword.get(opts, :stop, &:init.stop/1)
    stop.(:persistent_term.get(@signal_status))
    :ok
  end

  defp await_report(ms, _init_status, _command) when ms <= 0, do: :ok

  defp await_report(ms, init_status, command) do
    if stopping?(init_status.()) or gone?(command) do
      :ok
    else
      Process.sleep(min(ms, @poll_ms))
      await_report(ms - @poll_ms, init_status, command)
    end
  end

  defp stopping?({:stopping, _progress}), do: true
  defp stopping?(_running), do: false

  defp gone?(nil), do: false
  defp gone?(command) when is_pid(command), do: not Process.alive?(command)

  @doc """
  Cancels every session under the runtime `supervisor` (the one lmx mounts
  is `Lemieux.Supervisor`), as the TUI's Ctrl-C does, and returns how many of
  them had a turn in flight. A runtime that is not running has none.
  """
  @spec cancel_sessions(supervisor :: atom()) :: non_neg_integer()
  def cancel_sessions(supervisor) when is_atom(supervisor) do
    sessions =
      try do
        Lemieux.sessions(supervisor)
      rescue
        # No registry: nothing was ever mounted under this name.
        ArgumentError -> []
      end

    Enum.count(sessions, fn {_id, session} -> cancel(session) end)
  end

  defp cancel(session) do
    busy? = Lemieux.Session.snapshot(session).status == :busy
    :ok = Lemieux.Session.cancel(session, :cancelled)
    busy?
  catch
    # A session that ended meanwhile has nothing left to cancel.
    :exit, _reason -> false
  end

  # The watch loop. It asks whether the VM's parent is still the launcher,
  # rather than whether the launcher's pid exists: a killed launcher that its
  # own parent has not yet reaped is a zombie, and `kill -0` still finds it,
  # while the VM is reparented the moment the launcher dies. The VM is the
  # launcher's direct child (every script on the way execs). Linux reads
  # /proc, which minimal images have when they lack ps; macOS has ps. If
  # neither answers, it falls back to `kill -0`, the shell builtin. The loop
  # also ends with the VM, and it gives up the VM's standard error first: a
  # port program inherits it, and a caller reading lmx's output to the end
  # waited for this loop as long as it ran.
  @watch ~S"""
  exec 2>/dev/null
  launcher=$1
  vm=$2
  parent() {
    if [ -r "/proc/$vm/stat" ]; then
      read -r _pid _comm _state ppid _rest < "/proc/$vm/stat" && echo "$ppid"
    else
      ps -o ppid= -p "$vm" | tr -d ' '
    fi
  }
  if [ "$(parent)" = "$launcher" ]; then
    while [ "$(parent)" = "$launcher" ]; do sleep 1; done
  else
    while kill -0 "$launcher" && kill -0 "$vm"; do sleep 1; done
  fi
  """

  @doc """
  When the launcher process `pid` is gone, handles SIGTERM as though the
  launcher had forwarded one, then releases the lease the launcher handed
  this VM (`release_transferred_lease/0`).

  A shell loop in a port watches the launcher once a second; its exit is the
  signal. Without a pid (an embedder, Windows) it does nothing.

  The SIGTERM is the event ERTS gives the VM's signal server for a real one,
  handled the same way: every trap, newest first, then OTP's handler, and
  this waits until they have run. The watchdog used to call `stop/2`
  itself, which skipped every other trap: under the terminal UI, whose trap
  leaves its screen, the VM stopped with the screen still up, and the shell
  the person got back was left in the alternate screen with mouse reporting
  on. The launcher that would have restored it is the process that was
  killed.

  The line saying why (`lmx: the launcher is gone; stopping`) is written
  after every other trap, by this module's own (`stop/2`), just before it
  stops the VM. Written before the traps, it went to the terminal UI's
  alternate screen, which its trap then left, taking the line with it.
  Written by the watcher once the traps had returned, it raced the shutdown
  they had started, and a loaded macOS runner stopped the VM first: status
  143, and no line (2026-10-05). The watcher still writes it when nothing
  else did, as with `:on_exit`.

  The lease is released at the same point, for the same reason: released
  by the watcher after the traps, it raced the same shutdown, and a loaded
  macOS runner stopped the VM with the lease still in `running/`
  (2026-10-06, the 0.8.1 rehearsal). The watcher still releases it when
  nothing else did.

  Options (for tests): `:vm`, the pid whose parent is watched (default this
  VM's), and `:on_exit`, which replaces both steps.
  """
  @spec watch_launcher(pid :: String.t() | nil, opts :: keyword()) :: :ok
  def watch_launcher(pid, opts \\ [])

  def watch_launcher(pid, opts) when is_binary(pid) and pid != "" do
    if Regex.match?(~r/\A[0-9]+\z/, pid) do
      on_exit = Keyword.get(opts, :on_exit, &stop_without_launcher/0)
      vm = Keyword.get(opts, :vm, System.pid())

      spawn(fn ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :exit_status,
            args: ["-c", @watch, "lmx-watch", pid, vm]
          ])

        receive do
          {^port, {:exit_status, _status}} ->
            # The stop must not depend on the message (an orphaned VM's
            # standard error may have gone with its launcher), and the
            # message comes after it, outside the terminal UI's screen.
            :persistent_term.put(@launcher_notice, :pending)

            try do
              on_exit.()
            after
              report_launcher_gone()
            end
        end
      end)
    end

    :ok
  end

  def watch_launcher(_none, _opts), do: :ok

  # `stop/2`, the last trap, has normally released the lease by the time the
  # traps return; this is for a VM whose trap is not registered.
  defp stop_without_launcher do
    :ok = :gen_event.sync_notify(:erl_signal_server, :sigterm)
    release_transferred_lease()
  end

  # Once per launcher found gone, by whichever gets there first: `stop/2`,
  # or the watcher afterwards.
  defp report_launcher_gone do
    if :persistent_term.get(@launcher_notice, nil) == :pending do
      :persistent_term.put(@launcher_notice, :reported)
      report(@launcher_gone)
    end

    :ok
  end

  @doc """
  Removes the launch lease the launcher handed to this VM, when it is still
  this VM's. The launcher removes it after the VM exits; a launcher killed
  outright cannot, and its lease used to stay behind in the installation's
  `running/` directory. Called by `stop/2` before it stops the VM, and by
  the watcher afterwards for a VM whose trap is not registered; a lease
  already gone is nothing to remove.
  """
  @spec release_transferred_lease() :: :ok
  def release_transferred_lease do
    with path when is_binary(path) <- System.get_env("LMX_LEASE_FILE"),
         {:ok, owner} <- File.read(path),
         true <- String.trim(owner) == System.pid() do
      File.rm(path)
    end

    :ok
  end
end
