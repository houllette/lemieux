defmodule Mix.Tasks.Lmx do
  @shortdoc "Runs any lmx command from a source checkout"

  @moduledoc """
  Runs `lmx` from a source checkout, taking exactly the installed binary's
  arguments:

      mix lmx                                   # the terminal UI, like bare `lmx`
      mix lmx run "Summarize this repository"   # one prompt, the answer on stdout
      mix lmx -C ../my-project                  # work in another repository
      mix lmx log wayne-gretzky
      mix lmx fork wayne-gretzky --at-turn 2
      mix lmx explain
      mix lmx help models

  `mix lmx.tui` always opens the terminal UI, so a source checkout had no way
  to reach `run`, `log`, `fork`, `explain`, `help`, `--version` or the `mcp`,
  `plugin` and `extension` commands short of building a release — while the
  guides, written for the binary, use all of them. This task is the binary's
  front door under Mix: `Lemieux.CLI.configure/0`, then `Lemieux.CLI.run/2`
  with the arguments untouched, then the command's status as the exit
  status. `configure/0` is also what keeps a crash dump, which can hold
  keys, out of the directory the task runs in: it points `ERL_CRASH_DUMP`
  at `~/.lmx/crash` (`crash/` under `LMX_HOME` when that is set), as the
  release launcher does (`Lemieux.CLI.crash_state_dir/2`).

  From any directory, with the checkout in `~/src/lemieux`:

      lmx() { mise -C ~/src/lemieux exec -- mix lmx -C "$PWD" "$@"; }

  Mix prints compilation progress to standard output, so run `mix compile`
  once before redirecting `mix lmx run …` into a file.

  Hints that name a command — the terminal UI's "use `lmx run PROMPT`", the
  resume line on exit — say `mix lmx` here, because a source checkout has no
  `lmx` on its path.
  """

  use Mix.Task

  @requirements ["app.start"]

  # What hints call the command when it was started through Mix.
  @program "mix lmx"

  @impl Mix.Task
  def run(argv), do: run_with(argv, &Lemieux.CLI.run/2)

  @doc """
  Runs `argv` through `runner` with the source host's options, as `run/1`
  does with `Lemieux.CLI.run/2`. `configure` is the process-wide setup,
  `Lemieux.CLI.configure/0` unless a test replaces it.

  `Lemieux.CLI.run/2`, never `main/1`: `main/1` halts the VM, which inside
  Mix would take the build tool down with it. A failure leaves through
  `exit({:shutdown, status})`, which Mix turns into the exit status.
  """
  @spec run_with(
          argv :: [String.t()],
          runner :: ([String.t()], keyword() -> :ok | {:error, pos_integer()}),
          configure :: (-> :ok)
        ) :: :ok
  def run_with(argv, runner, configure \\ &Lemieux.CLI.configure/0)
      when is_list(argv) and is_function(runner, 2) and is_function(configure, 0) do
    :ok = configure.()

    case runner.(argv, source_host_options()) do
      :ok -> :ok
      {:error, status} -> exit({:shutdown, status})
    end
  end

  @doc """
  What a source run adds to `Lemieux.CLI.run/2`'s options.

  `:program` is how hints spell the command. `:cwd` is the repository root
  when the task runs from the distribution host in `dist/lmx`: its Mix
  working directory would otherwise make workspace discovery, project MCP
  and the shell tools operate on `dist/lmx` instead of the source tree the
  developer opened. `-C DIR` on the command line still wins over it.
  """
  @spec source_host_options() :: keyword()
  def source_host_options do
    if Mix.Project.config()[:app] == :lmx,
      do: [program: @program, cwd: Path.expand("../../..", __DIR__)],
      else: [program: @program]
  end
end
