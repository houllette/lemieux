defmodule Lemieux.CLI.Logs do
  @moduledoc """
  Where `lmx`'s log lines go: a file in its state directory, and the
  terminal only when somebody asked.

  The VM's default handler writes to standard output. For `lmx` that is the
  one place a log line can never be right: in the terminal UI it lands in
  the middle of the drawn frame — `req_llm` logs every failed connection
  with `Logger.error`, so Ollama not running painted `[error] Finch
  streaming transport failed …` over the input box (2026-10) — and in `lmx
  run` it lands in the answer, or in front of the result object a script is
  about to parse. Moving the handler to standard error would have fixed the
  second and not the first: in the terminal UI standard error is the same
  screen. So `install/1`, which `Lemieux.CLI.configure/0` calls before any
  command runs, removes the default handler and puts a size-capped file in
  its place:

      ~/.lmx/logs/lmx.log    (rotated at 1 MB, three old files kept)

  in the state directory `Lemieux.CLI.Options.state_dir/1` names: `LMX_HOME`
  when it is set, else the directory of the configuration file (`--config
  PATH` or `LMX_CONFIG`), else `~/.lmx`. Without a configuration file —
  `--config none` or `LMX_CONFIG=none` — `lmx` has no state directory and
  remembers nothing between runs, and it keeps no log either. `install/1`
  runs before any command has read its arguments, so it goes by the
  environment alone; `follow/1`, which `Lemieux.CLI.run/2` calls with the
  command line, moves the file when a `--config` flag says otherwise. The
  file opened first stays where it was, empty unless something logged in
  the moment between.

  The session already reports a failure as a sentence
  (`Lemieux.CLI.Errors`), so the file is for when the sentence is not
  enough. `LMX_LOG_LEVEL` is that case made explicit: setting it, to any
  level, also writes to standard error — at the level it names, which the
  file follows too (`Lemieux.CLI.Options.log_level/0`). At `warning` and
  below, `req_llm`'s failed-request reports include the provider's response
  headers, cookies among them; the directory the file is in is private
  because of what it holds.

  ## Private directories

  The directory the file is in is private (0700), and so is every directory
  this module has to create on the way to it (`mkdir_private/1`) — the state
  directory too, when it does not exist yet. That is not only about the
  log: `install/1` is the first thing that touches the state directory on a
  fresh machine — `lmx --version` runs it — and the state directory holds
  transcripts, checkpoints and saved permissions, written by code that
  relies on the directory around them for privacy. Made with
  `File.mkdir_p/1`, as this module first made it, `~/.lmx` came out with the
  process umask, 0755, and stayed so: `Lemieux.CLI.Config` makes it 0700
  only when it is the one creating it, and by then it existed, so every
  local user could read the transcripts inside (found in review, 2026-10).
  """

  @file_handler :lmx_file
  @stderr_handler :lmx_stderr
  @max_bytes 1_048_576
  @max_files 3

  @doc """
  Replaces the default log handler with `lmx`'s, as the module documentation
  describes. Safe to call more than once.

  Options, for tests: `:dir` — the state directory (`nil` writes no file;
  default from the environment, see `default_dir/2`); `:stderr?` — also
  write to standard error (default: whether `LMX_LOG_LEVEL` is set).
  """
  @spec install(opts :: keyword()) :: :ok
  def install(opts \\ []) do
    dir = Keyword.get_lazy(opts, :dir, fn -> default_dir(System.get_env()) end)
    stderr? = Keyword.get_lazy(opts, :stderr?, &level_requested?/0)

    Enum.each([@file_handler, @stderr_handler], &:logger.remove_handler/1)
    silence_consoles()
    add_file(dir)
    if stderr?, do: add_stderr()
    :ok
  end

  @doc """
  Moves the log file to the state directory `argv` names.

  `install/1` placed the file by the environment, before any command parsed
  its arguments. A `--config` flag moves the configuration and, with it, the
  state directory, so the file follows: beside the named file, or nowhere
  for `--config none`. `LMX_HOME` still wins, as it does for the state
  directory. Read the way `Lemieux.CLI.run/2` reads `-C`: anywhere on the
  line, the last one counting, up to a `--`.

  Does nothing unless `install/1` opened a file, so a host or a test that
  never asked for `lmx`'s logging keeps its own handlers.
  """
  @spec follow(argv :: [String.t()]) :: :ok
  def follow(argv) when is_list(argv) do
    with current when is_binary(current) <- file(),
         config when is_binary(config) <- config_flag(argv, nil) do
      move(current, default_dir(System.get_env(), config))
    end

    :ok
  end

  defp move(current, dir) when is_binary(dir) do
    if log_path(dir) != current, do: reopen(dir)
  end

  defp move(_current, nil), do: :logger.remove_handler(@file_handler)

  defp reopen(dir) do
    _ = :logger.remove_handler(@file_handler)
    add_file(dir)
  end

  defp config_flag([], found), do: found
  defp config_flag(["--" | _rest], found), do: found
  defp config_flag(["--config", value | rest], _found), do: config_flag(rest, value)
  defp config_flag(["--config=" <> value | rest], _found), do: config_flag(rest, value)
  defp config_flag([_arg | rest], found), do: config_flag(rest, found)

  # Every handler already writing to a console: the VM's `:default`, which
  # goes, and the one `:ssl` adds for its own domain (`ssl_handler`, standard
  # output at `:debug`), which is `:ssl`'s to remove — so it is muted
  # instead. Left alone it prints `:ssl`'s reports, TLS alerts among them,
  # whenever the level lets them through, and standard output is the frame.
  defp silence_consoles do
    for %{id: id, module: :logger_std_h, config: %{type: type}} <- :logger.get_handler_config(),
        type in [:standard_io, :standard_error] do
      if id == :default,
        do: :logger.remove_handler(id),
        else: :logger.update_handler_config(id, :level, :none)
    end

    :ok
  end

  @doc """
  Writes out what the log file's handler still holds.

  The handler buffers, and `System.halt/1` — how every `lmx` command ends —
  does not wait for it, so without this the lines just before an exit, the
  ones most worth having, would be the ones lost. Answers `:ok` whether or
  not a file is installed.
  """
  @spec flush() :: :ok
  def flush do
    # Asked first because the sync is a call to the handler's process, and a
    # call to one that is not there exits rather than answering.
    if match?({:ok, _config}, :logger.get_handler_config(@file_handler)),
      do: _ = :logger_std_h.filesync(@file_handler)

    :ok
  end

  @doc "The file this VM is logging to, or `nil` when it logs to none."
  @spec file() :: Path.t() | nil
  def file do
    case :logger.get_handler_config(@file_handler) do
      {:ok, %{config: %{file: file}}} -> to_string(file)
      _none -> nil
    end
  end

  @doc """
  The state directory a log file goes in: `LMX_HOME` from `env`, else the
  directory of the configuration file — `config`, a `--config` flag's
  value, before `env`'s `LMX_CONFIG` — else `~/.lmx`; `nil` when the
  configuration is `none`.

  The same answer `Lemieux.CLI.Options.state_dir/1` gives once a command has
  read its configuration, asked earlier and from less: log lines can arrive
  before any command has parsed its arguments.
  """
  @spec default_dir(env :: %{optional(String.t()) => String.t()}, config :: String.t() | nil) ::
          Path.t() | nil
  def default_dir(env, config \\ nil) when is_map(env) do
    case {non_empty(env["LMX_HOME"]), non_empty(config) || non_empty(env["LMX_CONFIG"])} do
      {home, _config} when is_binary(home) -> Path.expand(home)
      {nil, "none"} -> nil
      {nil, config} when is_binary(config) -> config |> Path.expand() |> Path.dirname()
      {nil, nil} -> Path.expand("~/.lmx")
    end
  end

  @doc """
  Makes `path` a directory, as `File.mkdir_p/1` does, except that each
  directory this call has to create — `path` and any missing parent — is
  made private (0700). A directory that already exists is left as it is:
  its mode is somebody's decision.

  For directories under the state directory, which may not exist yet; see
  the module documentation for what a umask-mode state directory exposed.
  """
  @spec mkdir_private(path :: Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_private(path) when is_binary(path) do
    path = Path.expand(path)

    created =
      path
      |> missing([])
      |> Enum.reduce_while(:ok, fn directory, :ok ->
        case create_private(directory) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- created do
      if File.dir?(path), do: :ok, else: {:error, :enotdir}
    end
  end

  # `path` and each of its ancestors that does not exist, outermost first.
  defp missing(path, acc) do
    parent = Path.dirname(path)

    if parent == path or File.exists?(path),
      do: acc,
      else: missing(parent, [path | acc])
  end

  # Another lmx starting at the same moment may have made it first, and made
  # it private too.
  defp create_private(directory) do
    case File.mkdir(directory) do
      :ok -> File.chmod(directory, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value

  defp level_requested?, do: non_empty(System.get_env("LMX_LOG_LEVEL")) != nil

  defp log_path(dir), do: Path.join([dir, "logs", "lmx.log"])

  # A directory that cannot be made — a read-only home, a container — costs
  # the log file, not the command: lines are then dropped, which is what the
  # terminal needed anyway. `logs` is lmx's own, so it is made private even
  # when it already existed.
  defp add_file(nil), do: :ok

  defp add_file(dir) do
    logs = Path.join(dir, "logs")

    with :ok <- mkdir_private(logs),
         :ok <- File.chmod(logs, 0o700) do
      _ =
        :logger.add_handler(@file_handler, :logger_std_h, %{
          config: %{
            file: String.to_charlist(log_path(dir)),
            max_no_bytes: @max_bytes,
            max_no_files: @max_files
          },
          formatter:
            Logger.Formatter.new(
              format: "$date $time [$level] $message\n",
              colors: [enabled: false]
            )
        })

      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp add_stderr do
    _ =
      :logger.add_handler(@stderr_handler, :logger_std_h, %{
        config: %{type: :standard_error},
        formatter: Logger.Formatter.new(colors: [enabled: false])
      })

    :ok
  end
end
