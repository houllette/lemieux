defmodule Lemieux.CLI do
  @moduledoc """
  Command router shared by the standalone `lmx` release host and source tools.

  This module is a host like any other: when a command needs the runtime, it
  mounts `Lemieux.Supervisor` itself rather than relying on the library to
  have started already. Keeping the CLI on the same footing as an embedder is
  what stops library behaviour from quietly depending on the CLI's setup — a
  class of bug that only ever surfaces in the *embedded* case, where it is
  hardest to diagnose.

  `main/1` does nothing but translate `run/1`'s result into an exit status.
  The split exists so the behaviour is testable: `System.halt/1` takes the
  whole VM down, so a test that drove `main/1` down the failure path would
  kill the test run rather than fail it.

  This module is a router and nothing else. Each command's own reasoning
  lives with its implementation — `Lemieux.CLI.Run`, and the shared setup in
  `Lemieux.CLI.Runtime`; the help text is `Lemieux.CLI.Help`'s.

  ## How hints name the command

  A hint that tells a person what to type next — "use `lmx run PROMPT`",
  "`lmx -c` resumes it" — is only right if they can type it. From a source
  checkout they cannot: there is no `lmx` on the path, and the command is
  `mix lmx` (`Mix.Tasks.Lmx`). The Mix tasks therefore pass `program: "mix
  lmx"` among `run/2`'s options, and every hint is spelled with
  `program/1`, which is `"lmx"` everywhere else.
  """

  alias Lemieux.CLI.Corpus
  alias Lemieux.CLI.Desktop
  alias Lemieux.CLI.Explain
  alias Lemieux.CLI.ExtensionCommands
  alias Lemieux.CLI.Feedback
  alias Lemieux.CLI.Harness
  alias Lemieux.CLI.Help
  alias Lemieux.CLI.History
  alias Lemieux.CLI.Logs
  alias Lemieux.CLI.MCPCommands
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Plugins
  alias Lemieux.CLI.Run
  alias Lemieux.CLI.Skills
  alias Lemieux.CLI.TUI
  alias Lemieux.CLI.Update

  # The subcommands, so a help flag after one of them is recognised as a
  # request for the manual rather than passed on as an option.
  @commands ~w(tui run log request fork feedback harness corpus explain help plugin extension mcp
                skills desktop update)

  @doc """
  The command words `lmx` routes, so a command that was given one where it
  takes none — `mix lmx.tui run …` — can say which command was meant.
  """
  @spec commands() :: [String.t()]
  def commands, do: @commands

  @doc """
  Process entry point. Halts non-zero when `run/1` reports failure.
  """
  @spec main(argv :: [String.t()]) :: :ok
  def main(argv) do
    configure()

    case run(argv) do
      :ok -> :ok
      {:error, status} -> System.halt(status)
    end
  end

  @doc """
  Applies the process-wide CLI settings shared by release and Mix entry points.

  Kept separate from `run/1`, which tests drive without mutating Logger or
  dependency configuration. Source Mix tasks cannot call `main/1` because that
  function may halt Mix, but they still need the same logging setup: log
  lines go to a file in the state directory rather than over the terminal
  UI's frame or into `lmx run`'s output (`Lemieux.CLI.Logs`).

  The crash dump goes into the state directory too, for every command
  (`crash_dump/2` into `crash_state_dir/2`). Only the terminal UI used to
  point it there, so `mix lmx run …` left `erl_crash.dump`, which can hold
  keys, in the directory it ran in. The installed `lmx`'s launcher sets
  `ERL_CRASH_DUMP` before the VM starts, to the same place, so there this
  finds it set and leaves it.
  """
  @spec configure() :: :ok
  def configure, do: configure(state_dir: crash_state_dir(System.get_env()))

  @doc """
  `configure/0`, with a test's directories in place of the environment's.

  `:logs` is passed to `Lemieux.CLI.Logs.install/1`. `:state_dir` is the
  state directory the crash dump goes into (`crash_dump/2`); without it the
  crash dump is left alone. `ERL_CRASH_DUMP` is the VM's OS environment,
  which every test shares and every process a test starts inherits, and the
  directory `configure/0` names is in the home directory, which a test
  that passes only `:logs` must not write into.
  """
  @spec configure(opts :: keyword()) :: :ok
  def configure(opts) do
    Logger.configure(level: Options.log_level())
    :ok = Logs.install(Keyword.get(opts, :logs, []))
    _ = opts |> Keyword.get(:state_dir) |> crash_dump()

    # `req_llm` warns when a model is not in its catalog, which every locally served
    # model is — through `IO.warn/1`, so it carries a stack trace and no log level
    # silences it. Three times a turn it reads as something being broken. The one
    # thing it is saying, that nothing knows how big this model's window is, the
    # front ends say once and in a sentence.
    Application.put_env(:req_llm, :warn_unverified_models, false)

    # The shared stream pool is sized here, by the host, not by the library when
    # the runtime mounts: `ensure/1` writes `:req_llm`'s environment and may
    # restart that application, which is a decision about this VM that belongs
    # to whoever owns it. Before anything mounts is also the cheap moment — the
    # pool is read when `:req_llm` starts, so there is nothing in flight to
    # disturb. The result is advisory: an undersized pool queues delegated
    # children, it does not fail a command.
    {:ok, _outcome} = Lemieux.ProviderPool.ensure()
    :ok
  end

  @doc """
  Points `ERL_CRASH_DUMP` into `state_dir/crash`, unless it is already set;
  returns the path it set, or `nil`.

  ERTS writes `erl_crash.dump` into the current directory — the person's
  project — and a dump holds what the VM held: provider keys and transcript
  text. The release launcher points it at the state directory before the VM
  starts; a source run has no launcher, so `configure/0` does it here, for
  every command. ERTS reads the variable when it writes the dump, so setting
  it now covers the rest of the run. The directory, and a state directory
  that does not exist yet, are made `0700`
  (`Lemieux.CLI.Logs.mkdir_private/1`); one that cannot be made, or no
  state directory, leaves the variable alone. `current` is the variable's
  value, read from the environment unless a test says; empty is unset, as
  the launcher reads it.

  It is the OS environment, so the processes a session starts — commands,
  hooks, MCP servers — inherit it: a BEAM among them that crashes writes its
  dump here rather than into the project, and under the sandbox, which hides
  `~/.lmx`, writes none. Set `ERL_CRASH_DUMP` yourself to choose otherwise:
  a value already set is left alone.
  """
  @spec crash_dump(state_dir :: Path.t() | nil, current :: String.t() | nil) :: Path.t() | nil
  def crash_dump(state_dir, current \\ System.get_env("ERL_CRASH_DUMP"))
  def crash_dump(nil, _current), do: nil
  def crash_dump(_state_dir, current) when is_binary(current) and current != "", do: nil

  def crash_dump(state_dir, current) when is_binary(state_dir) and current in [nil, ""] do
    dir = Path.join(state_dir, "crash")

    with :ok <- Logs.mkdir_private(dir),
         :ok <- File.chmod(dir, 0o700) do
      path = Path.join(dir, "erl_crash.dump")
      System.put_env("ERL_CRASH_DUMP", path)
      path
    else
      {:error, _unwritable} -> nil
    end
  end

  @doc """
  The state directory a crash dump goes into: `LMX_HOME` from `env` (blank
  is unset), else `.lmx` in `home`, else `nil`. `home` is the VM's home
  directory unless a test says.

  The release launcher's rule (`dist/lmx/priv/launcher.sh` and
  `launcher.ps1`), so a dump lands in the same place however `lmx` was
  started. Not the log file's state directory
  (`Lemieux.CLI.Logs.default_dir/2`), which follows `LMX_CONFIG`: a source
  run that went by it put dumps beside a config file named elsewhere, and
  under `LMX_CONFIG=none` set nothing, so they landed in the working
  directory, where the installed `lmx` kept them in `~/.lmx/crash` either
  way (found in review, 2026-10). A dump is neither configuration nor
  anything `lmx` remembers: only what a crash left, keys included, which
  wants one private place whatever the configuration says.
  """
  @spec crash_state_dir(
          env :: %{optional(String.t()) => String.t()},
          home :: Path.t() | nil
        ) :: Path.t() | nil
  def crash_state_dir(env, home \\ System.user_home()) when is_map(env) do
    case {String.trim(env["LMX_HOME"] || ""), home} do
      {"", home} when is_binary(home) -> Path.join(home, ".lmx")
      {"", nil} -> nil
      {_set, _home} -> Path.expand(env["LMX_HOME"])
    end
  end

  @doc """
  `argument` as a POSIX shell reads it back: bare when every character is
  one no shell treats specially, else in single quotes, each `'` inside
  closed, escaped and reopened. For the lines a hint asks a person to paste
  — the command that would have taken a stray prompt, the `-C DIR` of the
  resume hint — here and in `Lemieux.CLI.TUI`, which used to keep a copy of
  its own.

  `\\A`/`\\z` rather than `^`/`$`, which also match before a final newline:
  the copy used them, so an argument ending in one was printed bare, and the
  pasted line ran as two. And never bare with a leading `=`, which zsh, the
  macOS default, expands to a command's path: `=foo` pasted failed with
  "foo not found".
  """
  @spec shell_quoted(argument :: String.t()) :: String.t()
  def shell_quoted(argument) when is_binary(argument) do
    if argument =~ ~r/\A[\w@%+:,.\/-][\w@%+=:,.\/-]*\z/,
      do: argument,
      else: "'" <> String.replace(argument, "'", ~S('\'')) <> "'"
  end

  @doc """
  Runs a command, returning `:ok` or `{:error, exit_status}`.

  Writes its own output; the caller decides what to do with the status.
  """
  @spec run(argv :: [String.t()]) :: :ok | {:error, pos_integer()}
  def run(argv), do: run(argv, [])

  @doc """
  Runs a command with parts of the runtime supplied rather than built.

  `:provider`, `:store` and `:supervisor` override what a command would
  otherwise construct. This is how the CLI is tested end to end without a
  network, a key or a home directory — the alternative being to test the
  commands through their own private functions, which is testing something
  other than what a person types.
  """
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts) do
    # `configure/0` placed the log file by the environment; a `--config` on
    # the line names another state directory, or none.
    :ok = Logs.follow(argv)

    result =
      case working_directory(argv) do
        {:ok, argv, nil} -> argv |> help_requested() |> route(opts)
        {:ok, argv, dir} -> argv |> help_requested() |> route(Keyword.put(opts, :cwd, dir))
        {:error, message} -> usage_fail(message)
      end

    # Whoever called this halts next, and a halt does not wait for the log
    # file's buffered lines: the last error before an exit is the one most
    # worth having.
    Logs.flush()
    result
  end

  @doc """
  How hints spell the command in `opts`: `"lmx"`, or what the host passed as
  `:program` (`"mix lmx"` from a source checkout; see the module
  documentation).
  """
  @spec program(opts :: keyword()) :: String.t()
  def program(opts) when is_list(opts), do: Keyword.get(opts, :program, "lmx")

  # `-C DIR` / `--cwd DIR` / `--cwd=DIR`, anywhere on the line: run as if lmx
  # had been started in DIR — its tools, the repository's instructions and
  # `.mcp.json`, `--continue` — which is how `mix lmx -C ../project` points
  # a source checkout's lmx at another repository. Taken out here, before
  # any command parses, through the same `:cwd` seam every command already
  # honours. Paths given to other flags are still read from where lmx was run.
  defp working_directory(argv), do: working_directory(argv, [], nil)

  defp working_directory([], acc, dir), do: {:ok, Enum.reverse(acc), dir}

  defp working_directory([flag, value | rest], acc, _dir) when flag in ~w(-C --cwd),
    do: with({:ok, dir} <- directory(value), do: working_directory(rest, acc, dir))

  defp working_directory([flag], _acc, _dir) when flag in ~w(-C --cwd),
    do: {:error, "missing value for #{flag}"}

  defp working_directory(["--cwd=" <> value | rest], acc, _dir),
    do: with({:ok, dir} <- directory(value), do: working_directory(rest, acc, dir))

  defp working_directory([arg | rest], acc, dir), do: working_directory(rest, [arg | acc], dir)

  defp directory(value) do
    dir = Path.expand(value)
    if File.dir?(dir), do: {:ok, dir}, else: {:error, "-C/--cwd: #{value} is not a directory"}
  end

  # A help flag further along the line — `lmx run --model x --help`, `lmx log
  # SESSION -h` — asks for the same manual as one right after the command,
  # and got "unrecognised option --help" from the command's parser. Read as
  # help only where it cannot be anything else: before a `--`, after which
  # words are arguments (`lmx mcp add NAME -- npx server --help`), and not
  # straight after a flag written without `=`, whose value it may be (`--system
  # -h`, as below). Not for `lmx help TOPIC`, which already is the manual.
  defp help_requested([command | rest] = argv) when command in @commands and command != "help",
    do: if(later_help?(rest), do: [command, "--help"], else: argv)

  defp help_requested(["-" <> _flag | _rest] = argv),
    do: if(later_help?(argv), do: ["--help"], else: argv)

  defp help_requested(argv), do: argv

  defp later_help?(words), do: later_help?(words, nil)

  defp later_help?([], _previous), do: false
  defp later_help?(["--" | _arguments], _previous), do: false

  defp later_help?([word | rest], previous) do
    (word in ~w(--help -h) and not value_flag?(previous)) or later_help?(rest, word)
  end

  defp value_flag?("-" <> _ = word), do: word != "-" and not String.contains?(word, "=")
  defp value_flag?(_word), do: false

  # Every command answers a help flag, not just the bare executable: `lmx tui
  # --help` reached the option parser and came back "unrecognised option --help",
  # which is the one thing a help flag must never do. Matched only where a person
  # would type it, so a `--system -h` never has its value read as a request for the
  # manual. A command with a topic of its own prints the topic.
  defp route([flag | _rest], _opts) when flag in ~w(--help -h), do: IO.puts(Help.usage())

  defp route([command, flag | _rest], _opts)
       when flag in ~w(--help -h) and command in @commands do
    case Help.command(command) do
      {:ok, text} -> IO.puts(text)
      :none -> IO.puts(Help.usage())
    end
  end

  defp route(["--version"], _opts), do: IO.puts("lmx #{Lemieux.version()}")
  defp route(["-v"], opts), do: route(["--version"], opts)
  # The standalone executable exists to carry the native terminal renderer,
  # so the full-screen interface is its default.
  defp route([], opts), do: tui([], opts)
  defp route(["help"], _opts), do: IO.puts(Help.usage())
  defp route(["help", topic | _rest], _opts), do: help(topic)
  defp route(["tui" | argv], opts), do: tui(argv, opts)
  defp route(["run" | argv], opts), do: Run.main(argv, opts)
  defp route(["explain" | argv], opts), do: Explain.run(argv, opts)
  defp route(["log" | argv], opts), do: History.log(argv, opts)
  defp route(["request" | argv], opts), do: History.request(argv, opts)
  defp route(["fork" | argv], opts), do: History.fork(argv, opts)
  defp route(["feedback" | argv], opts), do: Feedback.run(argv, opts)
  defp route(["harness" | argv], _opts), do: Harness.run(argv)
  defp route(["corpus" | argv], opts), do: Corpus.run(argv, opts)
  defp route(["plugin" | argv], opts), do: Plugins.run(argv, opts)
  defp route(["extension" | argv], opts), do: ExtensionCommands.run(argv, opts)
  defp route(["mcp" | argv], opts), do: MCPCommands.run(argv, opts)
  defp route(["skills" | argv], opts), do: Skills.run(argv, opts)
  defp route(["desktop" | argv], opts), do: Desktop.run(argv, opts)
  defp route(["update" | argv], opts), do: Update.run(argv, opts)

  # Options with no command belong to the default TUI — `lmx --mcp-config f`
  # opens the full-screen session with those servers attached.
  # A bare word that is not a command is still a mistake worth naming.
  defp route(["-" <> _rest | _tail] = argv, opts), do: tui(argv, opts)

  defp route([first | _rest] = argv, opts) do
    if sentence?(first), do: stray_prompt(argv, opts), else: unrecognised(argv)
  end

  # A word with whitespace in it was quoted as one argument: a sentence, so a
  # prompt — `lmx "fix the bug"`, the way other agents' commands take their
  # first one. It used to get "unrecognised arguments" and fifty lines of
  # usage, none of which said that lmx takes a prompt through `run`, or in
  # the terminal UI once it is open. A single bare word (`lmx lgo`, `lmx
  # resume`) is more likely a command misspelled or a flag without its
  # dashes, and the usage, which lists both, is still the answer to that.
  # So are a few unquoted ones: `lmx resume 01ABC` means `--resume 01ABC`,
  # and a hint offering `lmx run resume 01ABC` would send that to a model.
  defp sentence?(argument), do: String.match?(argument, ~r/\s/u)

  defp unrecognised(argv) do
    IO.puts(:stderr, "lmx: unrecognised arguments: #{Enum.join(argv, " ")}\n")
    IO.puts(:stderr, Help.usage())
    {:error, 1}
  end

  # The two lines that would have taken the prompt, spelled the way
  # `Lemieux.CLI.TUI`'s own stray-prompt refusal spells its `run` line: the
  # whole command line again, each argument quoted for a POSIX shell so it
  # can be pasted as it reads, or the shape of it when it is too long to
  # repeat. The terminal UI's line opens it with the prompt as `--prompt`,
  # the words before the first flag joined into one argument as `lmx run`
  # joins them, and keeps whatever followed — `--model X`, `-c` — and
  # `-C DIR`, which was taken off the line before routing
  # (`working_directory/1`).
  defp stray_prompt([prompt | _rest] = argv, opts) do
    program = program(opts)
    {words, flags} = Enum.split_while(argv, &(not String.starts_with?(&1, "-")))
    dir = if opts[:cwd], do: ["-C", opts[:cwd]], else: []
    run = Enum.reject(argv, &(&1 in ~w(--mouse --no-mouse)))
    opening = dir ++ flags ++ ["--prompt", Enum.join(words, " ")]

    IO.puts(:stderr, "lmx: #{shown(prompt)} is not a command")

    IO.puts(
      :stderr,
      "to ask once and exit: #{command([program, "run"], dir ++ run, "[options] PROMPT")}; " <>
        "to open the terminal UI with it: " <>
        command([program], opening, "[options] --prompt PROMPT")
    )

    {:error, 1}
  end

  defp command(head, [], _shape), do: Enum.join(head, " ")

  defp command(head, args, shape) do
    line = Enum.map_join(args, " ", &shell_quoted/1)

    if String.length(line) <= 60,
      do: Enum.join(head ++ [line], " "),
      else: Enum.join(head ++ [shape], " ")
  end

  # The prompt as the person typed it, cut to its first line and forty
  # characters: it is quoted back so they can see which word was taken for
  # a command, not reproduced.
  defp shown(prompt) do
    line = prompt |> String.split("\n", parts: 2) |> hd()
    cut = String.slice(line, 0, 40)
    if cut == prompt, do: inspect(cut), else: inspect(String.trim_trailing(cut) <> "…")
  end

  defp help(topic) do
    case Help.topic(topic) do
      {:ok, text} -> IO.puts(text)
      {:error, message} -> fail(message)
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end

  # A bad -C/--cwd is a usage error whichever command follows it, and
  # `lmx run`'s contract says usage errors exit 2 (docs/cli.md, "Exit
  # status"); the router takes the flag off the line before `run` sees it,
  # so it answers for `run` here. It exited 1, which a script reading the
  # status took for a failed answer.
  defp usage_fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 2}
  end

  defp tui(argv, opts) do
    opts
    |> Keyword.get(:tui_runner, &TUI.main/2)
    |> then(& &1.(argv, opts))
  end
end
