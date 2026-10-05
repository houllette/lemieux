defmodule Lemieux.TUI.Signals do
  @moduledoc """
  Leaving the screen properly when the VM is told to stop, for a host that
  asks for it with `trap_signals: true`.

  The screen puts the terminal in raw mode on the alternate screen, with
  bracketed paste and any-motion mouse reporting on and the cursor hidden,
  and only its own `terminate/2` puts all of that back. A SIGTERM — `kill
  PID`, `timeout`, a service manager — runs `init:stop/0`, which stops the
  applications and then kills every process left, and a screen started by
  a host's process, outside any application, is one of those: it was
  killed outright and restored nothing. The shell came back inside the
  alternate screen, every mouse movement typed escape codes into it, and the
  next program drew over the garbage.

  The trap asks the screen to leave, exactly as Ctrl-C twice does, and waits
  up to three seconds for it to go. The VM's own stop follows either way:
  Elixir runs SIGTERM's default after every trap, so the trap changes when
  the VM stops, never whether. A screen that is stuck is not waited on
  forever.

  ## Off unless the host asks

  `System.trap_signal/3` warns libraries off traps, because how a VM shuts
  down is its owner's decision, and this is a library. So a screen sets none
  unless its host passes `trap_signals: true`; a headless screen
  (`test_mode`) and a remote transport never do, whatever the host says,
  because the terminal they would restore is not this process's. `lmx`
  traps SIGTERM in its own host, around the screen it starts
  (`Lemieux.CLI.TUI`), which is where its release launcher's TERM lands —
  the launcher turns a hangup or an interrupt into one.

  ## Never SIGHUP

  Trapping SIGHUP replaces the operating system's answer to it, which is to
  end the process, with a handler; and the VM does nothing with a SIGHUP it
  handles. A hangup almost always means the terminal is already gone — the
  window closed, the SSH connection dropped, the tmux pane killed — so there
  is nothing left to restore, and the screen could not do it anyway: its
  input poll is a dirty NIF that spins on a hung-up terminal and never
  returns, so it never reads the request to leave. With SIGHUP trapped,
  closing the terminal under `mix lmx.tui` left the VM running at full CPU
  with its session alive (2026-10-03, in a pty: beam.smp still there 20
  seconds after the terminal closed). Untrapped, the kernel ends the VM at
  once, which is what a closed terminal asks for.

  ## Releasing the trap

  A screen releases its trap as it stops, and the release happens in a
  process of its own. It is a call to the VM's signal server, which runs
  handlers one at a time, and the screen may be stopping *because* a handler
  running there asked it to — a host's own SIGTERM trap calling
  `GenServer.stop/3` on it, say. A release made from inside `terminate/2`
  waited for the signal server, which waited for the screen to stop, so with
  a host's trap beside the screen's every SIGTERM stalled for both timeouts:
  eight seconds from `kill` to exit, where it now takes a twentieth of one
  (2026-10-04, in a pty).

  The function each trap runs is defined in this module and held by the
  VM's signal server for as long as the screen runs: a retained local
  callback in a process the upgrade guard does not inspect. A release that
  changes this module restarts rather than upgrading hot
  (`dist/lmx/upgrades/AGENTS.md`).
  """

  @grace 3_000

  @typedoc "The traps a screen set, with the id to release each by."
  @type traps :: [{:sigterm, reference()}]

  @doc """
  Whether a screen started with `opts` sets the trap: only when its host
  asked with `trap_signals: true`, and only over a local terminal. A
  headless screen (`test_mode`) and a remote transport never do, because
  the terminal they would restore is not this process's.
  """
  @spec wanted?(opts :: keyword()) :: boolean()
  def wanted?(opts) when is_list(opts) do
    Keyword.get(opts, :trap_signals, false) == true and
      Keyword.get(opts, :transport, :local) == :local and
      not Keyword.has_key?(opts, :test_mode)
  end

  @doc """
  Traps SIGTERM so that `screen` is asked to leave first.

  `screen` receives `{:terminal_signal, :sigterm}` and is expected to stop;
  see `Lemieux.TUI.Lifecycle.signalled/2`. Answers the trap that could be
  set, which is none where the OS cannot trap SIGTERM.
  """
  @spec trap(screen :: pid()) :: traps()
  def trap(screen) when is_pid(screen) do
    case System.trap_signal(:sigterm, handler(screen, :sigterm)) do
      {:ok, id} -> [sigterm: id]
      {:error, _unsupported} -> []
    end
  end

  @doc """
  Releases traps set by `trap/1`, from a process of its own; see the
  moduledoc for why the caller must not wait for it.
  """
  @spec release(traps :: traps()) :: :ok
  def release([]), do: :ok

  def release(traps) when is_list(traps) do
    # Unlinked, because it has to outlive the screen whose `terminate/2`
    # starts it.
    {:ok, _releaser} = Task.start(fn -> Enum.each(traps, &untrap/1) end)
    :ok
  end

  # An id the signal server does not hold is answered `{:error, :not_found}`:
  # a trap already gone. A signal server that is itself gone — the VM is
  # stopping, which is what a SIGTERM was for — holds no traps either, and
  # its exit would only have been a crash report printed over a terminal
  # just restored.
  defp untrap({signal, id}) do
    System.untrap_signal(signal, id)
  catch
    :exit, _stopping -> :ok
  end

  @doc false
  # The function a trap runs in the signal server. Public so a test can run
  # it without sending this VM a SIGTERM, which would stop it.
  @spec handler(screen :: pid(), signal :: :sigterm) :: (-> :ok)
  def handler(screen, signal), do: fn -> leave(screen, signal) end

  @doc false
  # Runs in the signal server. Must return `:ok` and must not raise, or the
  # handler is removed and the signal's default behaviour lost with it.
  @spec leave(screen :: pid(), signal :: :sigterm) :: :ok
  def leave(screen, signal) do
    ref = Process.monitor(screen)
    send(screen, {:terminal_signal, signal})

    receive do
      {:DOWN, ^ref, :process, ^screen, _reason} -> :ok
    after
      @grace ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end
end
