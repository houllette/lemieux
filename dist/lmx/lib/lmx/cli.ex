defmodule Lmx.CLI do
  @moduledoc """
  Process boundary for the installed release.

  The reusable command behavior stays in `Lemieux.CLI`; this module owns only
  release concerns: proving the packaged TUI NIF can
  load on this machine, translating the command result into an OS status,
  and handing the commands lmx starts the environment the person started it
  with.

  Loading the NIF even for `--version` makes every CI smoke test exercise the
  target-specific native artifact rather than merely the wrapper.

  It returns a status and never ends the VM. The release's process entry is
  `Lmx.Boot.main/0`, which turns anything this raises into status 1
  (`Lmx.Boot.run/2`) and ends the command with an orderly `System.stop/1`
  (`Lmx.Boot.finish/1`). A `main/2` here that halted with `System.halt/1`
  outlived the move to `Lmx.Boot`: nothing called it but its own test, and
  a launcher that did would have skipped every application's shutdown and
  the status of a signal that was stopping the VM.

  ## What the commands lmx starts inherit

  The VM's environment is not the person's. `erlexec` puts the release's
  ERTS `bin` and its `bin` first on `PATH` and sets `BINDIR`, `ROOTDIR`,
  `EMU` and `PROGNAME`; the release script sets `RELEASE_*`; the launcher
  sets `ERL_CRASH_DUMP`, `ELIXIR_ERL_OPTIONS` (`+fnu`) and its own `LMX_*`. The agent's commands, hooks and
  MCP servers inherited all of it, so the person's `erl` — and their
  `elixir`, `mix` and `iex`, which run it — booted the release's ERTS and
  stopped with `cannot get bootfile`: an Elixir developer could not run
  their own tests through lmx (found in the launch review, 2026-10).

  So the launcher records, before it or the release script changes
  anything, the person's `PATH` (`LMX_PARENT_PATH`) and the value of every
  one of those variables they had set themselves (`LMX_PARENT__<NAME>`), and
  `inherited/1` turns that into the changes `Lemieux.Environment.Inherited`
  applies to every process started for the person: `PATH` back, each of
  those variables back to the person's value or removed, the launcher's
  own variables removed. A person's own `ERL_FLAGS`, `ERL_LIBS` or
  `ERL_CRASH_DUMP` stays theirs. The VM keeps its own environment: the
  Elixir evaluation node boots from the release's ERTS and needs it.
  """

  @type option ::
          {:configure, (-> :ok)}
          | {:native_loader, (-> :ok)}
          | {:runner, ([String.t()] -> :ok | {:error, pos_integer()})}

  # What erlexec sets for the VM, whatever the person had.
  @erts ~w(BINDIR ROOTDIR EMU PROGNAME)
  # The launcher's, and the wrapper install.sh writes: nothing a person's
  # command has any use for. `LMX_PARENT_*` are the records themselves.
  @launcher ~w(LMX_INSTALL_HOME LMX_RELEASE_ROOT LMX_ARGV_FILE LMX_RESTART_FILE LMX_LAUNCHER_PID LMX_LEASE_FILE
               LMX_PARENT_PATH)
  @recorded "LMX_PARENT__"

  @doc "Runs through the release boundary and returns an OS exit status."
  @spec run(argv :: [String.t()], opts :: [option()]) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    configure = Keyword.get(opts, :configure, &Lemieux.CLI.configure/0)
    native_loader = Keyword.get(opts, :native_loader, &ExRatatui.Native.ensure_loaded/0)
    runner = Keyword.get(opts, :runner, &run_cli/1)

    argv = restart_arguments(argv, System.get_env("LMX_RESTART_FILE"))

    with :ok <- configure.(),
         :ok <- native_loader.() do
      exit_status(runner.(argv))
    end
  end

  defp run_cli(argv) do
    updates = &update_host(&1, argv)
    Lemieux.CLI.run(argv, updates: updates)
  end

  defp update_host(options, argv) do
    host = Lmx.Update.host(options)

    case {host, System.get_env("LMX_RESTART_FILE"), System.get_env("LMX_INSTALL_HOME")} do
      {%{apply: _apply}, path, home} when is_binary(path) and is_binary(home) ->
        host
        |> Map.put(:restart, &prepare_restart(argv, &1, path))
        |> Map.put(:refresh, fn -> update_host(options, argv) end)

      _other ->
        host
    end
  end

  # The launcher owns a private one-use receipt. Restart never repeats --prompt
  # or guesses the latest session, which might belong to another screen.
  @doc false
  @spec prepare_restart(argv :: [String.t()], receipt :: map(), path :: Path.t()) ::
          :ok | {:error, term()}
  def prepare_restart(argv, %{id: id, cwd: cwd}, path) do
    args = restart_flags(drop_tui(argv)) ++ ["--resume", id] ++ if(cwd, do: ["-C", cwd], else: [])
    with :ok <- File.write(path, JSON.encode!(args)), do: File.chmod(path, 0o600)
  end

  defp drop_tui(["tui" | rest]), do: rest
  defp drop_tui(argv), do: argv

  # Match complete option/value pairs, not arbitrary tokens: a config path
  # named "tui" is still a path. Like Runtime.resume_options/2, do not replay
  # the initial model/system/tool instructions over changes saved in-session.
  @restart_values ~w(--resume --prompt -C --cwd --model -m --system --mcp-config)
  @restart_booleans ~w(-c --continue --no-continue --elixir --no-elixir)
  defp restart_flags([flag, _value | rest]) when flag in @restart_values,
    do: restart_flags(rest)

  defp restart_flags([flag | rest]) when flag in @restart_booleans,
    do: restart_flags(rest)

  defp restart_flags([flag | rest]) do
    cond do
      Enum.any?(@restart_values, &String.starts_with?(flag, &1 <> "=")) ->
        restart_flags(rest)

      String.starts_with?(flag, "-") and not String.contains?(flag, "=") ->
        keep_restart_value(flag, rest)

      true ->
        [flag | restart_flags(rest)]
    end
  end

  defp restart_flags([]), do: []

  defp keep_restart_value(flag, [value | rest]) do
    if String.starts_with?(value, "-"),
      do: [flag | restart_flags([value | rest])],
      else: [flag, value | restart_flags(rest)]
  end

  defp keep_restart_value(flag, []), do: [flag]

  defp restart_arguments(argv, nil), do: argv

  defp restart_arguments(argv, path) do
    case File.read(path) do
      {:ok, ""} ->
        argv

      {:ok, bytes} ->
        :ok = File.write(path, "")
        JSON.decode!(bytes)

      {:error, _reason} ->
        argv
    end
  end

  defp exit_status(:ok), do: 0
  defp exit_status({:error, status}) when is_integer(status) and status > 0, do: status

  @doc """
  Records, for every process started on the person's behalf, how its
  environment differs from this VM's (`inherited/1` of `env`). Called once,
  as the release boots (`Lmx.Boot.main/0`).
  """
  @spec inherit(env :: %{optional(String.t()) => String.t()}) :: :ok
  def inherit(env \\ System.get_env()), do: Lemieux.Environment.Inherited.put(inherited(env))

  @doc """
  The changes, from the VM's environment `env`, that give a process started
  for the person their own environment back (see "What the commands lmx
  starts inherit"): `%{name => value}` to set, `%{name => nil}` to remove.

  With the launcher's records: `PATH` is the person's, and each variable
  erlexec, the release script or the launcher sets — `BINDIR`, `ROOTDIR`,
  `EMU`, `PROGNAME`, `ERL_CRASH_DUMP`, every `RELEASE_*` — is the person's
  value, or removed where they had none.

  Without them — a VM a hot upgrade gave this code, started by a launcher
  that recorded nothing, or `bin/lmx-release` run by hand — erlexec's own
  addition to `PATH` is taken off its front (`$BINDIR:$ROOTDIR/bin:`), and
  those variables are removed, since nothing says which were the person's.
  """
  @spec inherited(env :: %{optional(String.t()) => String.t()}) ::
          Lemieux.Environment.Inherited.changes()
  def inherited(env) when is_map(env) do
    recorded = for {@recorded <> name, value} <- env, name != "", into: %{}, do: {name, value}
    path = path_name(env)

    path_change =
      case Map.fetch(env, "LMX_PARENT_PATH") do
        {:ok, parent} -> %{path => parent}
        :error -> erts_path_removed(env, path)
      end

    set_for_the_vm =
      (@erts ++
         ["ERL_CRASH_DUMP", "ELIXIR_ERL_OPTIONS"] ++
         release_names(env) ++
         release_names(recorded))
      |> Map.new(&{&1, Map.get(recorded, &1)})

    launcher =
      Map.new(@launcher ++ for({@recorded <> _ = name, _} <- env, do: name), &{&1, nil})

    set_for_the_vm
    |> Map.merge(launcher)
    |> Map.merge(path_change)
  end

  defp release_names(env), do: for({"RELEASE_" <> _ = name, _value} <- env, do: name)

  # Windows keeps `Path`, whatever letter case a person types.
  defp path_name(env), do: Enum.find(Map.keys(env), "PATH", &(String.upcase(&1) == "PATH"))

  # erlexec's addition is exactly `$BINDIR:$ROOTDIR/bin:` in front of what
  # it found; anything else on the front is somebody's choice, kept.
  defp erts_path_removed(env, path) do
    with bindir when is_binary(bindir) <- env["BINDIR"],
         rootdir when is_binary(rootdir) <- env["ROOTDIR"],
         current when is_binary(current) <- env[path],
         prefix = bindir <> separator() <> Path.join(rootdir, "bin"),
         {:ok, rest} <- strip(current, prefix) do
      %{path => rest}
    else
      _unchanged -> %{}
    end
  end

  defp strip(prefix, prefix), do: {:ok, ""}

  defp strip(current, prefix) do
    front = prefix <> separator()

    if String.starts_with?(current, front),
      do: {:ok, String.replace_prefix(current, front, "")},
      else: :error
  end

  defp separator, do: if(match?({:win32, _name}, :os.type()), do: ";", else: ":")
end
