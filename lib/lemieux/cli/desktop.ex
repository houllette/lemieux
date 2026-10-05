defmodule Lemieux.CLI.Desktop do
  @moduledoc """
  `lmx desktop install | uninstall | status`: an entry in a Linux desktop's
  application launcher that opens lmx in a terminal.

  Opt-in, and never part of installing or updating lmx: the installer puts a
  launcher on `PATH` and changes nothing about anybody's desktop, and this
  command is the separate, explicit step that does. It writes two files, both
  in the user's own data directory (`$XDG_DATA_HOME`, else
  `~/.local/share`):

    * `applications/lemieux.desktop`, the entry; and
    * `icons/hicolor/scalable/apps/lemieux.svg`, a copy of the icon shipped
      in `priv/desktop`.

  It runs nothing else: no `update-desktop-database`, no compositor reload.
  Launchers watch `applications/` for themselves, and a command that
  reloaded somebody's desktop to show one icon would be doing more than it
  was asked. Root-owned and packaged locations — `/usr/share/applications`,
  Omarchy's own files — are never written: an entry there is a system
  administrator's decision, and Omarchy's packaged files are replaced by
  Omarchy's updates.

  The entry's `Icon` is the icon file's absolute path rather than the theme
  name `lemieux`. A theme name is found through the icon theme's index and,
  in some launchers, a cache; the user's own `hicolor` directory has no
  index of its own, and refreshing a cache is a command this one does not
  run. A path is found by every launcher as soon as the entry is read.

  ## The entry runs an absolute path, with an explicit directory

  `Exec` names lmx by its absolute path. A desktop session's `PATH` is often
  not the shell's — `~/.local/bin` is added by a shell profile the session
  never reads — so a bare `lmx` that works in a terminal finds nothing from
  the launcher. The path is the installer's launcher (`PREFIX/bin/lmx`,
  found from `LMX_INSTALL_HOME`, which the release VM sees) rather than the
  release behind it, because updates swap the release and keep the
  launcher's path; then whatever `lmx` is on `PATH`; then `--exec PATH`
  names one outright, and wins over both.

  `Exec` also passes `-C DIR`. A launcher starts programs in its own working
  directory — usually the home directory, sometimes `/` — and lmx would
  otherwise take that, or nothing better, for the workspace. `--directory`
  chooses it; the default is the home directory, and on Omarchy `~/Work`
  when it exists, which is where Omarchy's own agent launcher
  (`omarchy-agent`) starts, because agents will not remember trust for the
  home directory. Where lmx was started does not count, and neither does
  the router's `-C` (`:cwd`): `mix lmx` run from `dist/lmx` passes the
  repository root that way, and a source checkout must never become a
  launcher's workspace. `install` prints the directory it chose.

  ## Omarchy

  Where `omarchy-launch-tui` is on `PATH` (or `--omarchy` says so), the entry
  runs lmx through it, with the app id `org.omarchy.lemieux`, and sets
  `Terminal=false` and a matching `StartupWMClass`: Omarchy's launcher opens
  its configured terminal with Omarchy's styling, and window rules can single
  lmx out by that id. `omarchy-launch-tui` is named bare, not by its path:
  it is Omarchy's public command, on `PATH` in every Omarchy session by
  Omarchy's own design, and where it lives has changed between Omarchy
  releases. Elsewhere `Terminal=true` asks the desktop for its terminal.

  ## What it will not overwrite or remove

  The entry carries `X-Lemieux-Managed=true` and the version that wrote it.
  An existing `lemieux.desktop` without that marker is somebody's own, and is
  left alone unless `--force` says to replace it. An existing icon whose
  bytes differ from the shipped one is kept the same way. `uninstall`
  removes the entry only when it carries the marker, and the icon only when
  its bytes are the shipped icon's, and reports what it kept. It never
  touches `~/.lmx` — settings, keys, sessions — the installed release, or
  any Omarchy or Hyprland file.

  Files are written to a temporary name beside the target, made `0644` and
  renamed over it, so a launcher watching the directory never reads half an
  entry. As root, `install` refuses unless `--force` says so, as the
  installer refuses root without an explicit prefix: under `sudo` the home
  directory can still be the invoking user's, and a root-owned entry in it
  is one that user can neither change nor remove.

  ## Seams

  Everything this reads about the machine comes from `opts`, for the tests:
  `:os_type` (`:os.type/0`), `:env` (a map; `System.get_env/0`), `:home`
  (`System.user_home/0`), `:find_executable` (`System.find_executable/1`),
  `:euid` (the effective user id; read from `/proc/self/status`), and `:icon`
  (the SVG to install; the one in this application's `priv/desktop`).
  `:program` is how hints name lmx (`Lemieux.CLI.program/1`).
  """

  import Bitwise

  alias Lemieux.CLI

  @app_id "org.omarchy.lemieux"
  @entry_name "lemieux.desktop"
  @marker "X-Lemieux-Managed"
  @launcher "omarchy-launch-tui"

  @switches %{
    "install" => [exec: :string, directory: :string, omarchy: :boolean, force: :boolean],
    "uninstall" => [],
    "status" => []
  }

  @usage "usage: lmx desktop install [--exec PATH] [--directory DIR] " <>
           "[--omarchy|--no-omarchy] [--force] | lmx desktop uninstall | lmx desktop status"

  # Reserved by the Desktop Entry Specification's Exec key: an argument
  # holding any of them must be quoted.
  @reserved [" ", "\t", "\n", "\"", "'", "\\", ">", "<", "~", "|", "&", ";", "$", "*", "?"] ++
              ["#", "(", ")", "`"]

  @doc """
  Runs a `desktop` subcommand, returning `:ok` or `{:error, exit_status}`:
  2 for a usage error or a system that is not Linux, 1 for anything else
  that stopped it. See the module documentation for `opts`.
  """
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts \\ []) do
    with :ok <- linux(opts),
         {:ok, command, flags} <- parse(argv) do
      command(command, flags, opts)
    end
  end

  # Desktop entries, XDG data directories and Omarchy are Linux's. Elsewhere
  # the command says so and writes nothing — not even a directory.
  defp linux(opts) do
    case Keyword.get_lazy(opts, :os_type, &:os.type/0) do
      {:unix, :linux} ->
        :ok

      _other ->
        usage_fail("desktop entries are a Linux feature; nothing was written")
    end
  end

  defp parse([command | argv]) when is_map_key(@switches, command) do
    case OptionParser.parse(argv, strict: Map.fetch!(@switches, command)) do
      {flags, [], []} ->
        {:ok, command, flags}

      {_flags, [word | _rest], []} ->
        usage_fail("unexpected argument #{inspect(word)}; #{@usage}")

      {_flags, _rest, [invalid | _]} ->
        usage_fail(invalid_flag(invalid, command))
    end
  end

  defp parse(_argv), do: usage_fail(@usage)

  defp invalid_flag({flag, nil}, "install") when flag in ~w(--exec --directory),
    do: "missing value for #{flag}; #{@usage}"

  defp invalid_flag({flag, _value}, command) do
    known? = Enum.any?(@switches, fn {_command, switches} -> flag_in?(flag, switches) end)

    if known?,
      do: "#{flag} does not apply to lmx desktop #{command}; #{@usage}",
      else: "unrecognised option #{flag}; #{@usage}"
  end

  defp flag_in?(flag, switches) do
    Enum.any?(switches, fn {name, _type} ->
      option = name |> Atom.to_string() |> String.replace("_", "-")
      flag in ["--" <> option, "--no-" <> option]
    end)
  end

  defp command("install", flags, opts), do: install(flags, opts)
  defp command("uninstall", _flags, opts), do: uninstall(opts)
  defp command("status", _flags, opts), do: status(opts)

  ## install

  defp install(flags, opts) do
    force? = Keyword.get(flags, :force, false)
    paths = paths(opts)
    omarchy? = Keyword.get_lazy(flags, :omarchy, fn -> omarchy?(opts) end)

    # Everything is checked before anything is written, and the icon goes
    # first: an entry is only ever written beside the icon it names.
    with :ok <- not_root(force?, opts),
         {:ok, executable} <- executable(flags[:exec], opts),
         {:ok, directory} <- directory(flags[:directory], omarchy?, opts),
         {:ok, icon} <- read_icon(opts),
         :ok <- writable(paths.entry, force?),
         {:ok, entry} <- entry(executable, directory, omarchy?, paths.icon),
         {:ok, icon_outcome} <- install_icon(paths.icon, icon, force?),
         :ok <- write(paths.entry, entry) do
      report_install(paths, executable, directory, omarchy?, icon_outcome, opts)
    else
      {:error, message} -> fail(message)
    end
  end

  defp read_icon(opts) do
    case File.read(icon_source(opts)) do
      {:ok, icon} ->
        {:ok, icon}

      {:error, reason} ->
        {:error,
         "lmx's icon is missing from this build (#{icon_source(opts)}: " <>
           "#{:file.format_error(reason)}); nothing was written"}
    end
  end

  # The installer's rule, kept consistent: an installation, and a desktop
  # entry, belong to one user, and made as root they belong to root. The
  # escape is an explicit say-so, as the installer's is an explicit prefix.
  defp not_root(true = _force?, _opts), do: :ok

  defp not_root(false, opts) do
    case Keyword.get_lazy(opts, :euid, &effective_uid/0) do
      0 ->
        user = Map.get(env(opts), "SUDO_USER")

        again =
          if user, do: "Run it again without sudo, as #{user}.", else: "Run it as that user."

        {:error,
         "a desktop entry belongs to the user whose launcher shows it, and this one would be " <>
           "written by root. #{again} If root itself uses this desktop, pass --force."}

      _user ->
        :ok
    end
  end

  defp effective_uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_line, uids] <- Regex.run(~r/^Uid:\s+\d+\s+(\d+)/m, status) do
      String.to_integer(uids)
    else
      _unknown -> nil
    end
  end

  defp executable(nil, opts) do
    case installed_launcher(opts) || on_path(opts) do
      nil -> {:error, no_executable(opts)}
      path -> {:ok, path}
    end
  end

  defp executable(given, _opts) do
    path = Path.expand(given)
    if executable?(path), do: {:ok, path}, else: {:error, "#{given} is not an executable file"}
  end

  # `install.py` sets `LMX_INSTALL_HOME=PREFIX/share/lmx` in the launcher it
  # writes at `PREFIX/bin/lmx`, and the release VM sees it.
  defp installed_launcher(opts) do
    with home when is_binary(home) and home != "" <- Map.get(env(opts), "LMX_INSTALL_HOME"),
         home = Path.expand(home),
         "lmx" <- Path.basename(home),
         share = Path.dirname(home),
         "share" <- Path.basename(share),
         launcher = Path.join([Path.dirname(share), "bin", "lmx"]),
         true <- executable?(launcher) do
      launcher
    else
      _not_installed -> nil
    end
  end

  defp on_path(opts) do
    case find_executable(opts).("lmx") do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp no_executable(opts) do
    checkout =
      if CLI.program(opts) == "mix lmx",
        do: "this lmx runs from a source checkout, which a desktop entry cannot start, and ",
        else: ""

    "#{checkout}no installed lmx was found (no installer launcher, and no lmx on PATH): " <>
      "install a release (https://hexdocs.pm/lemieux/releases.html), or name the executable " <>
      "with lmx desktop install --exec PATH"
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _missing -> false
    end
  end

  defp directory(nil, omarchy?, opts) do
    case Keyword.get_lazy(opts, :home, &System.user_home/0) do
      home when is_binary(home) ->
        work = Path.join(home, "Work")
        {:ok, if(omarchy? and File.dir?(work), do: work, else: home)}

      nil ->
        {:error, "there is no home directory to start in; pass --directory DIR"}
    end
  end

  defp directory(given, _omarchy?, _opts) do
    dir = Path.expand(given)
    if File.dir?(dir), do: {:ok, dir}, else: {:error, "--directory #{given} is not a directory"}
  end

  defp writable(_entry, true = _force?), do: :ok

  defp writable(entry, false) do
    case File.read(entry) do
      {:error, :enoent} ->
        :ok

      {:ok, contents} ->
        if managed?(contents), do: :ok, else: not_ours(entry)

      {:error, _unreadable} ->
        not_ours(entry)
    end
  end

  defp not_ours(entry),
    do:
      {:error,
       "#{entry} exists and lmx did not write it, so it is left alone; " <>
         "lmx desktop install --force replaces it"}

  defp entry(executable, directory, omarchy?, icon) do
    with :ok <- storable(executable),
         :ok <- storable(directory),
         :ok <- storable(icon) do
      lmx = [executable, "-C", directory]

      {command, terminal, window} =
        if omarchy?,
          do: {[@launcher, "--app-id=#{@app_id}" | lmx], "false", ["StartupWMClass=#{@app_id}"]},
          else: {lmx, "true", []}

      lines =
        [
          "[Desktop Entry]",
          "Type=Application",
          "Version=1.5",
          "Name=lmx",
          "GenericName=Coding agent",
          "Comment=The Lemieux coding agent, in a terminal",
          "Exec=" <> Enum.map_join(command, " ", &exec_quote/1),
          "Icon=" <> string_escape(icon),
          "Terminal=" <> terminal,
          "Categories=Development;",
          "Keywords=lemieux;lmx;agent;coding;ai;"
        ] ++ window ++ ["#{@marker}=true", "X-Lemieux-Version=#{Lemieux.version()}"]

      {:ok, Enum.map(lines, &[&1, ?\n])}
    end
  end

  # A desktop entry is UTF-8 text with one key per line, and a control
  # character in a path — a newline above all — would end the line it is on.
  defp storable(path) do
    if String.valid?(path) and not String.match?(path, ~r/[\x00-\x1f\x7f]/u),
      do: :ok,
      else: {:error, "#{inspect(path)} cannot be written into a desktop entry"}
  end

  defp install_icon(path, icon, force?) do
    case File.read(path) do
      {:ok, ^icon} ->
        {:ok, :current}

      {:ok, _theirs} when not force? ->
        {:ok, :kept}

      _absent_or_forced ->
        with :ok <- write(path, icon), do: {:ok, :written}
    end
  end

  defp report_install(paths, executable, directory, omarchy?, icon, opts) do
    how =
      if omarchy?,
        do: "through #{@launcher} (app id #{@app_id})",
        else: "in the desktop's terminal"

    case icon do
      :kept ->
        IO.puts("Wrote #{paths.entry}.")
        IO.puts("Kept #{paths.icon}: it is not lmx's icon (--force replaces it).")

      _written_or_current ->
        IO.puts("Wrote #{paths.entry} and its icon, #{paths.icon}.")
    end

    IO.puts("It runs #{executable} in #{directory}, #{how}.")

    if omarchy? and is_nil(find_executable(opts).(@launcher)),
      do: IO.puts("#{@launcher} is not on PATH here; the entry needs it to open.")

    IO.puts(
      "If the launcher does not list it yet, log out and back in. " <>
        "lmx desktop uninstall removes it."
    )

    :ok
  end

  ## uninstall

  defp uninstall(opts) do
    paths = paths(opts)

    outcomes = [
      remove(paths.entry, &managed?/1, "lmx did not write it"),
      remove(paths.icon, &(&1 == shipped_icon(opts)), "it is not lmx's icon")
    ]

    case Enum.filter(outcomes, &is_binary/1) do
      [] -> IO.puts("No desktop entry or icon from lmx; nothing to remove.")
      said -> Enum.each(said, &IO.puts/1)
    end

    if Enum.any?(outcomes, &match?({:error, _reason}, &1)), do: {:error, 1}, else: :ok
  end

  defp remove(path, ours?, why_kept) do
    case File.read(path) do
      {:ok, contents} ->
        if ours?.(contents), do: removed(path, File.rm(path)), else: "Kept #{path}: #{why_kept}."

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        "Kept #{path}: #{:file.format_error(reason)}."
    end
  end

  defp removed(path, :ok), do: "Removed #{path}."

  defp removed(path, {:error, reason}) do
    IO.puts(:stderr, "lmx: could not remove #{path}: #{:file.format_error(reason)}")
    {:error, reason}
  end

  defp shipped_icon(opts) do
    case File.read(icon_source(opts)) do
      {:ok, icon} -> icon
      {:error, _missing} -> nil
    end
  end

  ## status

  defp status(opts) do
    paths = paths(opts)

    case File.read(paths.entry) do
      {:ok, contents} ->
        entry_status(paths.entry, contents, opts)

      {:error, _absent} ->
        IO.puts("Desktop entry: none at #{paths.entry} (lmx desktop install adds one)")
    end

    IO.puts("Icon: #{paths.icon} (#{icon_status(paths.icon, opts)})")

    IO.puts(
      if omarchy?(opts),
        do: "Omarchy: detected (#{@launcher} is on PATH)",
        else: "Omarchy: not detected (no #{@launcher} on PATH)"
    )

    :ok
  end

  defp entry_status(path, contents, opts) do
    fields = fields(contents)
    exec = Map.get(fields, "Exec", "")
    {named, directory} = launched(exec_arguments(exec))
    executable = located(named, opts)

    who =
      if managed?(contents),
        do: "written by lmx #{Map.get(fields, "X-Lemieux-Version", "(unknown version)")}",
        else: "not written by lmx; install leaves it alone without --force"

    IO.puts("Desktop entry: #{path} (#{who})")
    IO.puts("  Exec: #{exec}")
    IO.puts("  runs: #{presence(executable, &executable?/1, "missing; the entry cannot open")}")

    IO.puts(
      "  starts in: " <>
        presence(directory, &File.dir?/1, "missing; lmx will refuse to start") <>
        if(directory, do: "", else: " (no -C: the launcher's own working directory)")
    )
  end

  # A bare name in an entry lmx did not write is looked up as the launcher
  # would look it up; one lmx wrote is always a path.
  defp located(nil, _opts), do: nil

  defp located(named, opts) do
    if String.contains?(named, "/"),
      do: named,
      else: find_executable(opts).(named) || named
  end

  defp presence(nil, _check, _why), do: "not named"
  defp presence(path, check, why), do: "#{path} (#{if check.(path), do: "present", else: why})"

  defp icon_status(path, opts) do
    case File.read(path) do
      {:ok, icon} -> if icon == shipped_icon(opts), do: "lmx's", else: "not lmx's"
      {:error, _absent} -> "absent"
    end
  end

  # What an entry runs and where: the program after the Omarchy launcher and
  # its app id, if it has them, and the value of its `-C`.
  defp launched([launcher | rest]) when launcher == @launcher,
    do: launched(Enum.drop_while(rest, &String.starts_with?(&1, "--app-id")))

  defp launched([executable | arguments]), do: {executable, directory_argument(arguments)}
  defp launched([]), do: {nil, nil}

  defp directory_argument([flag, dir | _rest]) when flag in ~w(-C --cwd), do: dir
  defp directory_argument(["--cwd=" <> dir | _rest]), do: dir
  defp directory_argument([_other | rest]), do: directory_argument(rest)
  defp directory_argument([]), do: nil

  # The `[Desktop Entry]` group's keys, the first of each; localised keys
  # (`Name[fr]`) are left out, since nothing here reads them.
  defp fields(contents) do
    contents
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) != "[Desktop Entry]"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "[")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{String.trim(key), String.trim_leading(value)}]
        _comment_or_blank -> []
      end
    end)
    |> Enum.reverse()
    |> Map.new()
  end

  defp managed?(contents), do: fields(contents)[@marker] == "true"

  ## Exec quoting

  @doc """
  `argument` as one argument of a desktop entry's `Exec` key, as the
  Desktop Entry Specification reads it back.

  Three layers, in the order a reader undoes them in reverse: `%` is doubled,
  because Exec expands field codes (`%f`, `%u`) after unquoting; an argument
  holding a reserved character (space, quotes, `\\`, `$`, `~` and the
  shell's other metacharacters) is put in double quotes, inside which `"`,
  `` ` ``, `$` and `\\` are escaped with a backslash; and then every
  backslash is doubled, because the key's value is a string and the string
  escapes are undone first. So a literal backslash in a quoted argument is
  four in the file, and a `$` is `\\\\$`, as the specification says.
  Everything else is written bare, which is how a path without spaces reads
  best.
  """
  @spec exec_quote(argument :: String.t()) :: String.t()
  def exec_quote(argument) when is_binary(argument) do
    argument = String.replace(argument, "%", "%%")

    if argument == "" or String.contains?(argument, @reserved) do
      quoted = String.replace(argument, ["\\", "\"", "`", "$"], &("\\" <> &1))
      string_escape("\"" <> quoted <> "\"")
    else
      argument
    end
  end

  # The string escapes every desktop entry value takes: `\\` for a backslash.
  defp string_escape(value), do: String.replace(value, "\\", "\\\\")

  @doc """
  The arguments an `Exec` value holds: `exec_quote/1` undone, for what
  `status` reports and for the tests that hold the two to each other.
  Field codes other than `%%` are left as they are.
  """
  @spec exec_arguments(exec :: String.t()) :: [String.t()]
  def exec_arguments(exec) when is_binary(exec) do
    exec
    |> unescape_string()
    |> tokens(nil, [])
    |> Enum.map(&String.replace(&1, "%%", "%"))
  end

  defp unescape_string(value) do
    Regex.replace(~r/\\([sntr\\])/, value, fn _whole, code ->
      %{"s" => " ", "n" => "\n", "t" => "\t", "r" => "\r", "\\" => "\\"}[code]
    end)
  end

  # `token` is the argument being read, `nil` between arguments; `acc` holds
  # the finished ones, newest first.
  defp tokens("", nil, acc), do: Enum.reverse(acc)
  defp tokens("", token, acc), do: Enum.reverse([token | acc])
  defp tokens(" " <> rest, nil, acc), do: tokens(rest, nil, acc)
  defp tokens(" " <> rest, token, acc), do: tokens(rest, nil, [token | acc])
  defp tokens("\"" <> rest, token, acc), do: quoted(rest, token || "", acc)

  defp tokens(<<char::utf8, rest::binary>>, token, acc),
    do: tokens(rest, (token || "") <> <<char::utf8>>, acc)

  defp quoted("\\" <> <<char::utf8, rest::binary>>, token, acc) when char in ~c(\\"`$),
    do: quoted(rest, token <> <<char::utf8>>, acc)

  defp quoted("\"" <> rest, token, acc), do: tokens(rest, token, acc)

  defp quoted(<<char::utf8, rest::binary>>, token, acc),
    do: quoted(rest, token <> <<char::utf8>>, acc)

  defp quoted("", token, acc), do: Enum.reverse([token | acc])

  ## Shared

  defp paths(opts) do
    data = data_home(env(opts), Keyword.get_lazy(opts, :home, &System.user_home/0))

    %{
      entry: Path.join([data, "applications", @entry_name]),
      icon: Path.join([data, "icons", "hicolor", "scalable", "apps", "lemieux.svg"])
    }
  end

  # The XDG Base Directory rule: an unset, empty or relative `XDG_DATA_HOME`
  # is ignored, and `~/.local/share` used instead.
  defp data_home(env, home) do
    case Map.get(env, "XDG_DATA_HOME", "") do
      "/" <> _absolute = data -> data
      _unset_or_relative -> Path.join([home || "/", ".local", "share"])
    end
  end

  defp omarchy?(opts), do: not is_nil(find_executable(opts).(@launcher))

  defp env(opts), do: Keyword.get_lazy(opts, :env, &System.get_env/0)

  defp find_executable(opts),
    do: Keyword.get(opts, :find_executable, &System.find_executable/1)

  defp icon_source(opts),
    do:
      Keyword.get_lazy(opts, :icon, fn ->
        Application.app_dir(:lemieux, "priv/desktop/lemieux.svg")
      end)

  defp write(path, contents) do
    dir = Path.dirname(path)

    temporary =
      Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    result =
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(temporary, contents, [:exclusive]),
           :ok <- File.chmod(temporary, 0o644) do
        File.rename(temporary, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp usage_fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 2}
  end

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
