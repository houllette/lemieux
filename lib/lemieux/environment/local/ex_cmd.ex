defmodule Lemieux.Environment.Local.ExCmd do
  @moduledoc """
  Demand-driven local command execution through ExCmd.

  ExCmd ties its external process to the BEAM process that starts it and only
  permits that owner to await the exit status. The owner here is therefore a
  small monitored process, not the session or tool task. A dedicated pipe
  owner performs exactly one blocking read for each stream demand while the
  command owner remains responsive when the consumer stops, times out, or
  crosses the output cap. The owner also monitors that consumer, because a
  cancelled task cannot run the stream cleanup callback after it has died.
  Either exit is therefore a cleanup signal: ExCmd closes the helper Port and
  lets the executor terminate the command without turning expected
  cancellation into a GenServer crash.

  Commands start in a new session so their process group is separate from
  the BEAM: through `setsid` where it exists (Linux), and otherwise through the
  same system call made by `perl`, which macOS ships and `setsid` it does not.
  That group is signalled at teardown, and only when the command leads it —
  any other group is one the command merely inherited on its way to being
  started, and signalling that reaches processes belonging to this VM. Without
  either, ExCmd kills only the direct shell, which orphans an ordinary child:
  a timed-out `npm run dev` kept serving after Lemieux reported it stopped.
  Platforms without `/proc` or `ps` retain ExCmd's direct-process fallback.

  Signalling the group is `kill -KILL -- -PGID`. Debian-based images —
  `debian:*-slim`, which Phoenix's generated release Dockerfile runs on —
  ship no `kill` executable (it is in procps), and the teardown used to skip
  the signal there without a word while the timed-out command's children ran
  on. Where there is no executable the shell's builtin does it instead,
  `sh -c 'kill -s KILL -- -PGID'` (dash refuses `-KILL --`), and
  `process_groups?/0` is true only where one of the two exists.

  A new session also has no controlling terminal. That is the second reason
  for it: a command that opens `/dev/tty` — `ssh` confirming a host key, `sudo`
  asking for a password, git asking for credentials — would otherwise read the
  keystrokes meant for the terminal interface running this very session. In a
  session of its own it fails at once, and the model reads why.

  ## Environment

  `:env` is `[{name, value | false}]` on top of what the command inherits.
  ExCmd can add variables but not remove them (its helper appends to its own
  environment), so an unset is made by `env -u NAME` in front of the shell;
  where there is no `env`, the variable is blanked instead, which leaves the
  name but not the secret.

  That makes the owner the only process that knows how to stop the command
  completely, and everything here follows from it: **nothing outside the owner
  may kill the owner while a command is live.** Doing so leaves exactly the
  children the caller was trying to stop. It is not hypothetical — a deadline
  that expired while ExCmd was still opening its helper had the caller reach
  in and kill the owner six milliseconds into its shutdown, after it had
  resolved the process group and before it could signal it. The shell died
  with the helper and the `sleep` it had backgrounded ran on.

  So a caller that gives up walks away instead, and the owner's own deadline
  is armed before the command is opened rather than after it is running, so
  that an overrunning startup still reaches a process able to tear it down.
  `stop/3` keeps a kill for an owner that has genuinely stopped answering, but
  restarts its grace on anything the owner says, so slowness alone never
  triggers it.

  A separate deadline process is intentional. `ExCmd.Process.read/2` blocks
  its caller while the OS pipe is empty, so a timeout message in that caller's
  mailbox could never interrupt a silent command. The deadline process tells
  the non-blocking owner to stop; the stream monitor turns that exit into
  Lemieux's semantic timeout event.

  ## When the VM goes first

  Everything above happens inside the VM, and a VM can stop without asking
  it. Closing the terminal sends SIGHUP, which ends the BEAM outright;
  SIGTERM — `timeout`, `kill`, a container stopping — runs `init:stop/0`,
  which ends every process outside an application's tree with an
  untrappable kill; `kill -9` needs no explanation. Each time the owner died
  without its teardown, ExCmd's helper killed only the direct shell a second
  later, and the command's children ran on as orphans after lmx had exited
  (a `sleep 97` in the report that found it, 2026-10).

  So beside every command that leads a group of its own the owner starts a
  watchdog: a POSIX `sh` reading one line from a pipe whose other end the
  owner holds. When the command has ended by itself the owner writes `done`
  and the watchdog exits — whatever the command left running in the
  background is its own business, as it always was — and it does the same
  once its own teardown has killed the group. Any other way the pipe
  closes — the owner killed, the VM halted, the VM killed — ends the read
  without it, and the watchdog sends KILL to the command's group. It ignores
  HUP, INT and TERM, because a closing terminal signals the VM's whole
  process group and the watchdog is in it. The cost is one `sh` per command,
  blocked in a read.

  The watchdog is started, and has said it is ready — its signals already
  ignored — before the command is opened, and learns the group's number on
  its pipe once the command exists. Started after the command, it left a
  window as long as a shell's startup in which the VM could go first with
  nothing to take the group: under load, CI's teardown tests ended the VM
  in that window and found the command's child still running (2026-10-05).
  One moment remains unguarded: the command runs a little before ExCmd
  tells the owner its process id, and a VM that ends then leaves it
  running. `run/2` returns only once the guard holds.

  The owner traps exits as well, so an exit signal another process sends it
  — `Process.exit(owner, :shutdown)` — is a message it answers by tearing the
  group down before it goes, rather than a death that skips the teardown.
  """

  require Logger

  alias Lemieux.Environment.Local

  @read_size 65_531
  @shutdown_timeout 300

  @doc false
  @spec available?() :: boolean()
  def available? do
    :ex_cmd
    |> Application.app_dir("priv")
    |> File.dir?()
  rescue
    ArgumentError -> false
  end

  @doc false
  @spec run(command :: String.t(), opts :: keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def run(command, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    timeout = Keyword.fetch!(opts, :timeout_ms)
    max_output_bytes = Keyword.fetch!(opts, :max_output_bytes)
    env = Keyword.get(opts, :env, [])

    case shell() do
      nil ->
        {:error, {:command_start_failed, no_shell()}}

      shell ->
        deadline = now() + timeout
        caller = self()
        session = session_prefix()
        launch = launch(session, shell, command, env)
        grouped? = session != []

        {owner, monitor_ref} =
          spawn_monitor(fn -> start_owner(caller, launch, cwd, deadline, grouped?) end)

        await_start(owner, monitor_ref, deadline, timeout, max_output_bytes)
    end
  end

  @doc """
  Whether commands here get a process group of their own, and can be stopped
  with everything they started.

  True where `setsid` or `perl` exists to start the group and a `kill`
  executable or a POSIX `sh` exists to signal it. Where either is missing, a
  timeout stops the shell but not what it started, and a caller that
  promises otherwise — a test, a doctor report — should say so.
  """
  @spec process_groups?() :: boolean()
  def process_groups?, do: session_prefix() != [] and signaller() != nil

  # The shell every command runs under (`Lemieux.Environment.Local.find_bash/0`).
  # There is no hard-coded `/bin/sh` fallback: on Windows without Git Bash that
  # path does not exist either, and the failure it produced — ExCmd unable to
  # spawn a file that is not there — sent people looking at the command rather
  # than at their installation.
  defp shell do
    case Local.find_bash() do
      {:ok, path} -> path
      :error -> nil
    end
  end

  defp no_shell, do: no_shell_message(:os.type(), System.get_env("PATH", ""))

  # Public only so both platforms' wording is tested on whichever one the
  # suite runs on: the Windows sentence is the one a person there needs, and
  # a macOS or Linux CI run would otherwise never read it.
  @doc false
  @spec no_shell_message(os_type :: {atom(), atom()}, path :: String.t()) :: String.t()
  def no_shell_message({:win32, _name}, _path) do
    "no bash was found on PATH or where Git for Windows installs it. Lemieux runs " <>
      "commands with Git Bash: install Git for Windows and start lmx from Git Bash. " <>
      "WSL's bash.exe is never used, because it runs commands inside the Linux " <>
      "distribution rather than on this machine; to work in WSL, run the Linux build " <>
      "of lmx inside it"
  end

  def no_shell_message(_unix, path), do: "neither bash nor sh was found on PATH (#{path})"

  defp await_start(owner, monitor_ref, deadline, timeout, max_output_bytes) do
    remaining = max(deadline - now(), 0)

    receive do
      {:local_command_started, ^owner} ->
        {:ok, stream(owner, monitor_ref, deadline, timeout, max_output_bytes)}

      {:local_command_start_failed, ^owner, reason} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:command_start_failed, reason}}

      {:DOWN, ^monitor_ref, :process, ^owner, reason} ->
        {:error, {:command_start_failed, Exception.format_exit(reason)}}
    after
      remaining ->
        # The caller supplied one wall deadline, not a separate startup allowance, and
        # under scheduler load it can expire while ExCmd is still opening its helper.
        # Reported as the same semantic timeout as a command that started and stayed
        # silent, because classifying it as a launch failure makes identical commands
        # change outcome according to BEAM load.
        #
        # Walk away rather than stopping the owner: its deadline has expired too, and it
        # is the only process that knows which group to signal. Reaching in to kill it
        # here is what left a command's children running.
        Process.demonitor(monitor_ref, [:flush])
        {:ok, [{:timeout, timeout}]}
    end
  end

  defp start_owner(parent, {args, env}, cwd, deadline, grouped?) do
    Process.flag(:trap_exit, true)
    parent_ref = Process.monitor(parent)

    # Armed before the command is opened, not after it is running. A deadline
    # that expires during startup has to reach the owner, because nothing else
    # will stop the command once it exists: the caller has already given up by
    # then, and it cannot signal the process group itself.
    start_deadline(self(), deadline)

    # See "When the VM goes first": ready before there is a command to guard.
    watchdog = if grouped?, do: open_watchdog()

    case start_process(args, env, cwd) do
      {:ok, process, os_pid} ->
        owner = self()
        # Nothing here writes to the command, and an open stdin it will never
        # receive is not neutral: ExCmd's helper keeps offering input to a
        # command that has exited, the write fails, and the Port exits `:epipe`
        # — which becomes the exit status of a command that ran and succeeded.
        # It also makes a command that reads stdin block until the deadline
        # rather than seeing end-of-input.
        :ok = Elixir.ExCmd.Process.close_stdin(process)
        reader = spawn_link(fn -> reader_loop(process, owner) end)
        :ok = Elixir.ExCmd.Process.change_pipe_owner(process, :stdout, reader)
        # Before the caller hears the command started, so a caller that gives
        # up at once still leaves a guard behind. See "When the VM goes first".
        watchdog = arm(watchdog, os_pid)
        send(parent, {:local_command_started, self()})

        owner_loop(%{
          process: process,
          reader: reader,
          os_pid: os_pid,
          parent: parent,
          parent_ref: parent_ref,
          watchdog: watchdog
        })

      {:error, reason} ->
        # Closed before it was given a group, it exits without signalling.
        close_watchdog(watchdog)
        send(parent, {:local_command_start_failed, self(), reason})
    end
  end

  # Says `ready` once its signals are ignored, then reads the group to guard
  # and one more line, whatever happens to the owner. `done` means the
  # command ended by itself; end-of-file without it means the owner never got
  # to say so. End-of-file before a group means there was never a command to
  # guard. HUP, INT and TERM are ignored because a closing terminal or a
  # Ctrl-C signals the VM's whole process group, which this shell belongs to.
  @watchdog "trap '' HUP INT TERM; echo ready; IFS= read -r group || exit 0; " <>
              "IFS= read -r line; " <>
              "[ \"$line\" = done ] || kill -s KILL -- \"-$group\" 2>/dev/null"
  # How long the owner waits for the watchdog's `ready` before it opens the
  # command regardless: a slow shell delays the command, it never stops it.
  @watchdog_ready_ms 5_000

  defp open_watchdog do
    with {:unix, _flavour} <- :os.type(),
         sh when is_binary(sh) <- System.find_executable("sh") do
      port =
        Port.open({:spawn_executable, sh}, [
          :binary,
          args: ["-c", @watchdog, "lemieux-watchdog"]
        ])

      receive do
        {^port, {:data, _ready}} -> port
      after
        @watchdog_ready_ms -> port
      end
    else
      _unavailable -> nil
    end
  rescue
    # A port that cannot be opened — no file descriptors left — costs the
    # guard against the VM going first, not the command.
    ErlangError -> nil
  end

  defp arm(nil, _os_pid), do: nil

  defp arm(watchdog, os_pid) do
    Port.command(watchdog, Integer.to_string(os_pid) <> "\n")
    watchdog
  rescue
    # Its shell is already gone; the command runs unguarded, as without one.
    ArgumentError -> nil
  end

  defp close_watchdog(nil), do: :ok

  defp close_watchdog(watchdog) do
    Port.close(watchdog)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The command ended by itself: the watchdog stands down instead of taking
  # what it left in the background.
  defp release(nil), do: :ok

  defp release(watchdog) do
    Port.command(watchdog, "done\n")
    Port.close(watchdog)
    :ok
  rescue
    # Its shell is already gone; there is nobody to stand down.
    ArgumentError -> :ok
  end

  defp start_process(args, env, cwd) do
    with {:ok, process} <-
           Elixir.ExCmd.Process.start_link(args,
             cd: cwd,
             env: env,
             stderr: :redirect_to_stdout
           ) do
      # The same call as `ExCmd.Process.os_pid/1`, acting as a startup barrier:
      # `start_link` returns before `handle_continue` opens its helper. The server
      # message is sent directly because upstream specifies an integer return but
      # currently returns `{:ok, pid}`, and the wrapper's spec makes Dialyzer erase the
      # real tuple branch below.
      os_pid = GenServer.call(process.pid, :os_pid, :infinity)
      {:ok, process, normalize_os_pid(os_pid)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp normalize_os_pid({:ok, os_pid}) when is_integer(os_pid), do: os_pid
  defp normalize_os_pid(os_pid) when is_integer(os_pid), do: os_pid

  # `{argv, env}` for ExCmd: the session prefix, the environment prefix, then
  # the shell. Unsets go to `env -u`; everything ExCmd's own `:env` can carry
  # goes there.
  defp launch(session, shell, command, env) do
    {prefix, env} = environment_prefix(env)
    {session ++ prefix ++ [shell, "-c", command], env}
  end

  # `setsid(2)` and then exec, with no shell in between to reinterpret the
  # arguments: the indirect-object `exec` runs `$ARGV[0]` with `@ARGV` as its
  # argument vector exactly. A failed `setsid` (the process already leads a
  # group) is not fatal — `kill_target/2` sees that the group never became the
  # command's own and falls back to stopping the shell.
  @perl_setsid "use POSIX (); POSIX::setsid(); exec { $ARGV[0] } @ARGV; " <>
                 "die \"exec $ARGV[0]: $!\\n\";"

  defp session_prefix do
    case {System.find_executable("setsid"), System.find_executable("perl")} do
      {nil, nil} -> []
      {nil, perl} -> [perl, "-e", @perl_setsid, "--"]
      {setsid, _perl} -> [setsid]
    end
  end

  defp environment_prefix([]), do: {[], []}

  defp environment_prefix(env) do
    {unsets, sets} = Enum.split_with(env, fn {_name, value} -> value == false end)
    sets = Enum.map(sets, fn {name, value} -> {name, to_string(value)} end)

    case {unsets, System.find_executable("env")} do
      {[], _env} -> {[], sets}
      {unsets, nil} -> {[], Enum.map(unsets, fn {name, false} -> {name, ""} end) ++ sets}
      {unsets, env} -> {[env | Enum.flat_map(unsets, fn {name, false} -> ["-u", name] end)], sets}
    end
  end

  defp start_deadline(owner, deadline) do
    spawn(fn ->
      monitor_ref = Process.monitor(owner)

      receive do
        {:DOWN, ^monitor_ref, :process, ^owner, _reason} -> :ok
      after
        max(deadline - now(), 0) -> send(owner, :local_command_timeout)
      end
    end)
  end

  defp owner_loop(%{reader: reader, parent: parent, parent_ref: parent_ref} = run) do
    receive do
      {:local_command_demand, consumer, demand_ref} ->
        send(reader, {:read, consumer, demand_ref})
        owner_loop(run)

      {:local_command_eof, consumer, demand_ref} ->
        status = exit_status(run.process)

        # Only a shell that exited stands the watchdog down. One killed by a
        # signal did not end by itself — ExCmd's helper kills it when SIGINT
        # or SIGTERM reaches the VM's process group, which is what Ctrl-C in
        # a terminal does — and what it was running is left to the watchdog,
        # which takes the group when this process exits.
        if match?({:exit_status, _status}, status), do: release(run.watchdog)
        send(consumer, {demand_ref, status})

      {:local_command_read_error, consumer, demand_ref, reason} ->
        send(consumer, {demand_ref, {:error, reason}})
        shutdown(run)

      message when message in [:local_command_stop, :local_command_timeout] ->
        shutdown(run)

      {:EXIT, ^reader, :normal} ->
        owner_loop(run)

      {:EXIT, ^reader, reason} ->
        exit(reason)

      {:EXIT, pid, reason} when pid == run.process.pid ->
        exit(reason)

      # The watchdog's shell was killed by somebody; the command runs on,
      # unguarded against the VM going first, as it would have without one.
      {:EXIT, port, _reason} when is_port(port) and port == run.watchdog ->
        owner_loop(%{run | watchdog: nil})

      {port, _output} when is_port(port) and port == run.watchdog ->
        owner_loop(run)

      # Trapped, so a supervisor-style exit from anyone else arrives here
      # rather than ending the owner before it could signal the group.
      {:EXIT, _from, reason} ->
        shutdown(run)
        exit(reason)

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        shutdown(run)
    end
  end

  defp reader_loop(process, owner) do
    receive do
      {:read, consumer, demand_ref} ->
        case Elixir.ExCmd.Process.read(process, @read_size) do
          {:ok, data} ->
            send(consumer, {demand_ref, {:data, IO.iodata_to_binary(data)}})
            reader_loop(process, owner)

          :eof ->
            send(owner, {:local_command_eof, consumer, demand_ref})

          # `:epipe` on a read is the end of the output, not a broken pipe:
          # `ExCmd.Process` cancels every pending read and answers this way when
          # the helper reports the command's exit status. Closing stdin above
          # removed the interleaving that used to get here, but it stays because
          # it is the upstream contract and because the failure it produced was
          # the expensive kind — a command that succeeded reported as a broken
          # transport with its output thrown away.
          {:error, :epipe} ->
            send(owner, {:local_command_eof, consumer, demand_ref})

          {:error, reason} ->
            send(owner, {:local_command_read_error, consumer, demand_ref, reason})
        end
    end
  end

  defp exit_status(process) do
    case Elixir.ExCmd.Process.await_exit(process, :infinity) do
      {:ok, status} -> {:exit_status, status}
      {:error, reason} -> {:error, reason}
    end
  end

  # The watchdog stands down once the group is known dead: signalled here, or
  # gone already. A second KILL from it would land a moment later on
  # whatever group the system had given that number to by then, without the
  # check `kill_target/1` makes first (found in review, 2026-10). Where this
  # could name no group, or not signal it, the watchdog stays: its signal,
  # when the owner exits, is then the only one.
  defp shutdown(%{process: process, reader: reader, parent: parent, os_pid: os_pid} = run) do
    # Say that teardown has begun, so a caller counting out the grace it allows
    # measures this work rather than however long the command took to start.
    # See `await_stop/3`.
    send(parent, {:local_command_stopping, self()})

    # Keep the reader alive while awaiting: if a read is pending, closing its
    # pipe first can block ExCmd's helper before it receives the kill command.
    # Once the helper reports the command exit, closing the pipe owner lets the
    # ExCmd GenServer finish normally.
    if kill_process_group(kill_target(os_pid)) == :killed, do: release(run.watchdog)
    _result = await_shutdown(process)
    if Process.alive?(reader), do: Process.exit(reader, :kill)
    :ok
  end

  defp await_shutdown(process) do
    Elixir.ExCmd.Process.await_exit(process, @shutdown_timeout)
  catch
    _kind, _reason -> :ok
  end

  # Which process group to signal, and the check that it is ours to signal.
  #
  # `setsid` puts the command in a session of its own, so the only safe group is
  # the one the command itself leads: any other is a group it merely inherited on
  # its way to being started, and signalling that reaches processes belonging to
  # this VM. Immediately after startup `/proc` reports exactly that inherited group
  # about forty-five percent of the time and settles within milliseconds, which is
  # why waiting for it is worth doing. Signalling the wrong group is what let a
  # cancelled command keep running while the kill landed on somebody else's.
  #
  # This runs on the teardown path against the grace `stop/3` allows, so it reads
  # `/proc` rather than forking `ps` — the lookup and the `kill` together used to be
  # three forks racing that grace. `nil` means there is nothing safe to signal.
  @group_settle_attempts 40
  @group_settle_ms 5

  @spec kill_target(os_pid :: pos_integer(), attempts :: non_neg_integer()) ::
          pos_integer() | nil
  defp kill_target(os_pid, attempts \\ @group_settle_attempts)

  defp kill_target(_os_pid, 0), do: nil

  defp kill_target(os_pid, attempts) do
    case process_group(os_pid) do
      {:ok, ^os_pid} ->
        os_pid

      # Started, but not yet in the session `setsid` is about to give it.
      {:ok, _inherited} ->
        Process.sleep(@group_settle_ms)
        kill_target(os_pid, attempts - 1)

      {:error, _unavailable} ->
        nil
    end
  end

  # `:killed` when nothing in `group` is left running: signalled, or found
  # with nothing alive in it. `:not_killed` otherwise, which is what the
  # watchdog is kept for.
  @spec kill_process_group(group :: pos_integer() | nil) :: :killed | :not_killed
  defp kill_process_group(nil), do: :not_killed

  defp kill_process_group(group) do
    case kill_command(group) do
      nil ->
        # Said rather than skipped, which is what this used to do without a
        # word where there was no `kill` executable.
        Logger.error("could not kill process group #{group}: no `kill` executable and no sh")
        :not_killed

      {executable, args} ->
        {output, status} = System.cmd(executable, args, stderr_to_stdout: true)

        # Said rather than swallowed. A group that outlives its command is a
        # command still running after Lemieux reported it stopped, and silence
        # here is what made that take four wrong theories to find.
        #
        # But only when something in it is still alive. macOS refuses to
        # signal a group whose only member is a zombie — a command that has
        # exited and not yet been reaped, as at the output cap — with "not
        # permitted", which would report a stop that in fact had nothing left
        # to stop.
        cond do
          status == 0 ->
            :killed

          group_alive?(group) ->
            Logger.error("could not kill process group #{group}: #{String.trim(output)}")
            :not_killed

          true ->
            :killed
        end
    end
  rescue
    error ->
      Logger.error("could not kill process group #{group}: #{Exception.message(error)}")
      :not_killed
  end

  # The `kill` executable where there is one, else the builtin of a POSIX
  # shell, which every machine that ran the command has. See the moduledoc.
  defp kill_command(group) do
    target = "-" <> Integer.to_string(group)

    case signaller() do
      {:executable, kill} -> {kill, ["-KILL", "--", target]}
      {:shell, sh} -> {sh, ["-c", "kill -s KILL -- " <> target]}
      nil -> nil
    end
  end

  defp signaller do
    cond do
      kill = System.find_executable("kill") -> {:executable, kill}
      sh = System.find_executable("sh") || System.find_executable("bash") -> {:shell, sh}
      true -> nil
    end
  end

  # Whether any member of `group` is still running rather than a zombie. Asked
  # only after a failed kill, so the `ps` fork is off the ordinary path. An
  # answer that cannot be had counts as alive: the error is then reported, as
  # it always was.
  defp group_alive?(group) do
    with executable when is_binary(executable) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(executable, ["-A", "-o", "pgid=,stat="], stderr_to_stdout: true) do
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Enum.any?(fn
        [pgid, stat | _rest] ->
          pgid == Integer.to_string(group) and not String.starts_with?(stat, "Z")

        _unparsable ->
          false
      end)
    else
      _unavailable -> true
    end
  end

  # `/proc` answers this without forking, which matters because the answer is
  # wanted while a command is starting. `ps` is the fallback for platforms
  # without it.
  defp process_group(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> proc_process_group(stat)
      {:error, _reason} -> ps_process_group(os_pid)
    end
  end

  # Field five, counting from the process name — which is parenthesised and may
  # itself contain spaces or `)`, so the split is on the last `)` rather than
  # on whitespace from the start.
  defp proc_process_group(stat) do
    with [_name, _after | _more] = parts <- String.split(stat, ")"),
         [_state, _ppid, pgrp | _tail] <- parts |> List.last() |> String.split() do
      integer(pgrp)
    else
      _unparsable -> {:error, :unavailable}
    end
  end

  defp ps_process_group(os_pid) do
    with executable when is_binary(executable) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(executable, ["-o", "pgid=", "-p", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ),
         {:ok, process_group} <- integer(String.trim(output)) do
      {:ok, process_group}
    else
      _unavailable -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _invalid -> {:error, :invalid_integer}
    end
  end

  defp stream(owner, monitor_ref, deadline, timeout, max_output_bytes) do
    Stream.resource(
      fn ->
        %{
          owner: owner,
          monitor_ref: monitor_ref,
          deadline: deadline,
          timeout: timeout,
          max_output_bytes: max_output_bytes,
          size: 0,
          done?: false
        }
      end,
      &next/1,
      &close/1
    )
  end

  defp next(%{done?: true} = state), do: {:halt, state}

  defp next(state) do
    demand_ref = make_ref()
    send(state.owner, {:local_command_demand, self(), demand_ref})
    await_next(state, demand_ref)
  end

  defp await_next(state, demand_ref) do
    remaining = max(state.deadline - now(), 0)

    receive do
      {^demand_ref, {:data, data}} ->
        data_event(state, data)

      {^demand_ref, {:exit_status, status}} ->
        Process.demonitor(state.monitor_ref, [:flush])
        {[{:exit_status, status}], %{state | done?: true}}

      {^demand_ref, {:error, reason}} ->
        runner_failed(state, reason)

      {:DOWN, monitor_ref, :process, owner, reason}
      when monitor_ref == state.monitor_ref and owner == state.owner ->
        owner_down(state, reason)
    after
      remaining ->
        stop(state.owner, state.monitor_ref)
        {[{:timeout, state.timeout}], %{state | done?: true}}
    end
  end

  defp data_event(state, data) do
    size = state.size + byte_size(data)

    if over_limit?(size, state.max_output_bytes) do
      stop(state.owner, state.monitor_ref)

      {[{:output_limit, state.max_output_bytes}], %{state | size: size, done?: true}}
    else
      {[{:data, data}], %{state | size: size}}
    end
  end

  defp over_limit?(_size, :infinity), do: false
  defp over_limit?(size, max_output_bytes), do: size > max_output_bytes

  # Both of these are the transport breaking, not the command failing, and they used
  # to be reported as `{:exit_status, 1}`. That made a dead pipe indistinguishable
  # from a command that genuinely exited one, sending the reader to look at the
  # command. Naming the failure costs nothing.
  defp runner_failed(state, reason) do
    Logger.error("local ExCmd runner failed: #{inspect(reason)}")
    stop(state.owner, state.monitor_ref)
    {[{:failed, reason}], %{state | done?: true}}
  end

  defp owner_down(state, reason) do
    if now() >= state.deadline do
      {[{:timeout, state.timeout}], %{state | done?: true}}
    else
      Logger.error("local ExCmd owner exited: #{Exception.format_exit(reason)}")
      {[{:failed, Exception.format_exit(reason)}], %{state | done?: true}}
    end
  end

  defp close(%{done?: true}), do: :ok
  defp close(state), do: stop(state.owner, state.monitor_ref)

  # How long the owner gets to answer a stop, measured from the last thing it said
  # rather than from the request. Teardown itself is bounded — `/proc` looks, one
  # `kill`, and `@shutdown_timeout` waiting for the exit — and this covers that
  # with room to spare.
  @stop_grace_ms 1_000

  # The kill at the end of this is a last resort against an owner that has stopped
  # answering, and has to stay one: the owner is the only process that knows which
  # group the command leads, so killing it is also what strands the command's
  # children. A deadline that expired during startup once sent the stop into a
  # mailbox the owner could not read for 493ms, spent the whole grace waiting for a
  # startup, and killed the owner six milliseconds into its shutdown — after it had
  # resolved the process group and before it could signal it.
  #
  # So the clock restarts on anything the owner says. An owner making progress is
  # never killed for being slow; one that has genuinely stopped answering still is.
  @doc false
  @spec stop(owner :: pid(), monitor_ref :: reference(), grace_ms :: pos_integer()) ::
          :stopped | :killed
  def stop(owner, monitor_ref, grace_ms \\ @stop_grace_ms) do
    if Process.alive?(owner), do: send(owner, :local_command_stop)
    await_stop(owner, monitor_ref, grace_ms)
  end

  defp await_stop(owner, monitor_ref, grace_ms) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^owner, _reason} ->
        :stopped

      {:local_command_started, ^owner} ->
        await_stop(owner, monitor_ref, grace_ms)

      {:local_command_stopping, ^owner} ->
        await_stop(owner, monitor_ref, grace_ms)
    after
      grace_ms ->
        if Process.alive?(owner), do: Process.exit(owner, :kill)
        Process.demonitor(monitor_ref, [:flush])
        :killed
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
