defmodule Lemieux.CLI.Runtime.SecretPaths do
  @moduledoc """
  Where this `lmx` run keeps secrets, for `--sandbox` to hide.

  `Lemieux.Environment.Sandbox` hides a fixed list under the home directory,
  `~/.lmx` among them. That is where `lmx` keeps things only by default:
  `--config`/`LMX_CONFIG` move the config file and the provider keys saved
  in it — and with it the state directory (prompt history, trust decisions,
  checkpoints holding the pre-images of edited files) unless `LMX_HOME`
  names one — `--sessions-dir`/`LMX_SESSIONS_DIR` move the transcripts, and
  `--credentials`/`LMX_CREDENTIALS` the MCP OAuth tokens. A sandbox that hid
  the literal `~/.lmx` while the keys sat in `~/alt-lmx/config.json` let
  `cat` print them (2026-10), and a key read into the conversation goes to
  the model provider with the next request. So the paths come from what
  this run resolved, not from a list.

  ## A whole directory, or the files in it

  A directory is hidden whole when it is lmx's own: `~/.lmx`, a state
  directory named apart from the config file (`LMX_HOME`), the transcript
  directory, one that holds nothing but what lmx keeps there, or one this
  module creates. It creates a missing one, `0700`, because the sandbox
  passes on only paths that exist when it is built, and the token file a
  first OAuth flow writes mid-session has to land somewhere already hidden.

  Anywhere else the files lmx keeps there are hidden one by one: the config
  file, the token file (created empty and private when absent, for the same
  reason) and the state directory's entries that exist when the sandbox
  starts — history, checkpoints, permission rules, MCP trust, plugins, logs,
  crash dumps. A directory with other things in it was hidden whole at
  first, and `--config ./config/lmx.json` hid the project's `config.exs`
  from every command while `LMX_CONFIG=~/.config/lmx.json` hid git's own
  settings, without a word about why (found in review, 2026-10). Hiding the entries
  matters for more than reading: a state directory inside the working
  directory is writable from the sandbox, and its permission rules, MCP
  trust and plugins decide what runs outside it.

  Nothing is hidden that is, or holds, the working directory, the home
  directory, a temporary directory or the root. A sandbox that hid the code
  it was asked to work on, or every tool under the home directory, is one
  nobody keeps on; a file kept in one of those (`--config ./lmx.json`) is
  hidden on its own, and of a state directory that is one of them only the
  entries no project would name for itself — history, MCP trust, permission
  rules, and lmx's own files inside `logs/` and `crash/`. `LMX_HOME` keeps
  the rest out of the work.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.Environment.Sandbox
  alias Lemieux.MCP.Auth.Store.File, as: TokenFile
  alias Lemieux.Store.JSONL

  # What `lmx` keeps in its state directory (`Lemieux.CLI.Options.state_dir/1`):
  # the terminal UI's prompt history, `Lemieux.MCP.Trust`, remembered
  # permission rules — names no project uses for its own — and
  # `Lemieux.CLI.State`, `/undo`'s checkpoints and cloned plugins, names a
  # project may well use (`plugins/` in a Nuxt app, `checkpoints/` beside a
  # model), and the `logs/` (`Lemieux.CLI.Logs`) and `crash/`
  # (`Lemieux.CLI.crash_dump/2`) every start makes there. Something new kept
  # there belongs here too, or a sandbox around a state directory it cannot
  # hide whole leaves it in reach — and a directory that holds it is no
  # longer one of lmx's own (`@own_names`): `logs/` missing here once kept a
  # dedicated config directory from ever being hidden whole after its first
  # run, with `logs/lmx.log` in reach (found in review, 2026-10).
  @lmx_only_entries ~w(history.jsonl trusted-mcp.json permissions)
  @state_entries @lmx_only_entries ++ ~w(state.json checkpoints plugins logs crash)

  # lmx's own files in those two, for a state directory that is the work or
  # the home directory, whose `logs/` may well be somebody else's: the log
  # and the three old ones `Lemieux.CLI.Logs` keeps as it rotates, and the
  # crash dump.
  @lmx_only_files ~w(logs/lmx.log logs/lmx.log.0 logs/lmx.log.1 logs/lmx.log.2
                     crash/erl_crash.dump)

  # What else may sit in a directory of lmx's own without making it anybody
  # else's: the default names of the files and directories it keeps there.
  @own_names ~w(config.json mcp-credentials.json sessions extensions .DS_Store) ++ @state_entries

  @doc """
  The paths a sandbox for this run hides beside its defaults, creating the
  directories it hides whole that do not exist yet with mode `0700` and an
  empty token file where that is hidden alone.

  `store` is the transcript store the session will write to; a
  `Lemieux.Store.JSONL` contributes its directory, any other store nothing.
  `cwd` is the session's working directory.
  """
  @spec paths(options :: Options.t(), store :: Lemieux.Store.t(), cwd :: Path.t()) :: [Path.t()]
  def paths(%Options{} = options, store, cwd) when is_binary(cwd) do
    config = expand(Config.path(options.config))
    credentials = expand(options.credentials)
    state = expand(options.host.state_dir)
    sessions = expand(store_directory(store))

    rules = %{
      protected: protected(cwd),
      own: own(config, state, sessions),
      names:
        @own_names ++ Enum.map(Enum.reject([config, credentials], &is_nil/1), &Path.basename/1)
    }

    [
      file(config, rules, :existing),
      file(credentials, rules, :create),
      state(state, rules),
      directory(sessions, rules)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)

  defp store_directory({JSONL, %{dir: dir}}) when is_binary(dir), do: dir
  defp store_directory(_store), do: nil

  # A file goes with its directory when the directory can go whole, and on
  # its own otherwise — never when the "file" is itself the work
  # (`--credentials .`).
  defp file(nil, _rules, _absent), do: []

  defp file(path, rules, absent) do
    directory = Path.dirname(path)

    cond do
      protects?(path, rules) -> []
      whole?(directory, rules) -> ensure_directory(directory)
      true -> alone(path, absent)
    end
  end

  defp alone(path, absent) do
    cond do
      File.exists?(path) -> [Sandbox.real(path)]
      absent == :create and TokenFile.create(path) == :ok -> [Sandbox.real(path)]
      true -> []
    end
  end

  # A state directory that is the work itself (`--config ./lmx.json` with no
  # `LMX_HOME`) gives up only the entries no project would name: hiding a
  # `plugins/` there would hide the project's own.
  defp state(nil, _rules), do: []

  defp state(directory, rules) do
    cond do
      whole?(directory, rules) ->
        ensure_directory(directory)

      protects?(directory, rules) ->
        entries(directory, @lmx_only_entries ++ @lmx_only_files, rules)

      true ->
        entries(directory, @state_entries, rules)
    end
  end

  defp entries(directory, names, rules) do
    for name <- names,
        path = Path.join(directory, name),
        File.exists?(path),
        not protects?(path, rules),
        do: Sandbox.real(path)
  end

  # The transcript directory exists to hold transcripts, so it is lmx's own
  # wherever it is; only the work can keep it in reach.
  defp directory(nil, _rules), do: []

  defp directory(path, rules) do
    if protects?(path, rules), do: [], else: ensure_directory(path)
  end

  defp whole?(directory, rules) do
    not protects?(directory, rules) and
      (Sandbox.real(directory) in rules.own or not File.exists?(directory) or
         holds_only?(directory, rules.names))
  end

  # Whether hiding `path` would hide something that must stay in reach: it
  # is, or holds, one of the protected paths. The root holds them all.
  defp protects?(path, rules) do
    real = Sandbox.real(path)
    Enum.any?(rules.protected, &Sandbox.within?(&1, real))
  end

  defp holds_only?(directory, names) do
    case File.ls(directory) do
      {:ok, entries} -> Enum.all?(entries, &(&1 in names))
      {:error, _unreadable} -> false
    end
  end

  # What hiding must never cover, as the sandbox will see it.
  defp protected(cwd) do
    [cwd, System.user_home(), System.tmp_dir(), "/tmp", "/var/tmp", "/private/tmp"]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Sandbox.real/1)
  end

  # lmx's own by name: the default home, a state directory named apart from
  # the config file (`LMX_HOME`), and the transcript directory.
  defp own(config, state, sessions) do
    home = System.user_home()
    config_directory = config && Path.dirname(config)

    [home && Path.join(home, ".lmx"), state != config_directory && state, sessions]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Sandbox.real/1)
  end

  # Created owner-only when absent; an existing directory keeps the mode
  # somebody gave it. One that cannot be created is left out rather than
  # failing the run: the sandbox drops paths that do not exist anyway, and
  # nothing can be written there to leak.
  defp ensure_directory(directory) do
    cond do
      File.dir?(directory) ->
        [Sandbox.real(directory)]

      File.mkdir_p(directory) == :ok ->
        _ = File.chmod(directory, 0o700)
        [Sandbox.real(directory)]

      true ->
        []
    end
  end
end
