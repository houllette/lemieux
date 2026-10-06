defmodule Lemieux.CLI.Update do
  @moduledoc """
  `lmx update`: checks for a newer release and installs it, from a terminal.

  The terminal UI's `/update` did this already, through the host's update
  callbacks (`Lemieux.TUI.Updates`). This command drives the same callbacks
  without a screen, so an update needs no session, no model credentials and
  no readable personal configuration (issue #5): a person whose config file
  keeps the screen from opening can still update to the release that reads
  it. The command never reads the config file at all. The one thing the
  installed host's callbacks took from it was whether extensions are
  selected, which turns automatic installation off because a new version can
  break a bundle built for the old one; an explicit `lmx update` installs
  either way, as `/update` does, and the notice says to rebuild them.

  The host is whatever `Lemieux.CLI.run/2`'s `:updates` option names:
  `Lmx.Update.host/1` in the installed `lmx`, which verifies the release's
  Ed25519 signature before it installs anything, or the source checkout's
  Git fast-forward (`Lemieux.CLI.UpdateCheck.host/2`) when nothing does.
  Everything those callbacks verify — signature, checksum, archive safety,
  ownership — they verify here too, because this command only calls them;
  there is no second verification path to keep in step with the first.

  What a terminal command cannot do is load new code into a running screen.
  A staged release is selected for the next launch (`{:ok, :restart}`), and
  the command says so: a terminal UI that is open keeps running the version
  it started on until it is restarted, is never stopped from here, and the
  host's lock keeps the two from installing at once.

  Exit status: 0 when `lmx` is up to date, when an update was installed, or
  when `--check` reported; 1 when the check or the installation failed; 2
  for a usage error.
  """

  alias Lemieux.CLI
  alias Lemieux.CLI.UpdateCheck

  @releases "https://github.com/houllette/lemieux/releases"
  @usage "usage: lmx update [--check]"

  @doc "Runs `lmx update`, returning `:ok` or `{:error, exit_status}`."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts) do
    case OptionParser.parse(argv, strict: [check: :boolean]) do
      {parsed, [], []} -> update(Keyword.get(parsed, :check, false), host(opts), opts)
      {_parsed, rest, invalid} -> usage(rest, invalid)
    end
  end

  # The installed host's factory takes the parsed options for one thing,
  # whether extensions are selected (`Lmx.Update.host/1`); this command
  # parses none and installs on request regardless, so it hands the factory
  # an empty selection. A factory that answers `nil` is an `lmx` nothing
  # installed — an archive unpacked by hand, a release script run directly.
  # No option at all is a source checkout (`mix lmx update`), which updates
  # through Git as its screen's `/update` does.
  defp host(opts) do
    case Keyword.fetch(opts, :updates) do
      {:ok, factory} when is_function(factory, 1) -> factory.(%{extensions: []})
      {:ok, host} -> host
      :error -> source_host(opts)
    end
  end

  defp source_host(opts) do
    {:ok, tasks} = Task.Supervisor.start_link()
    UpdateCheck.host(tasks, opts)
  end

  defp update(_check?, nil, _opts), do: fail(not_installed())

  # A host that checks and cannot install (an unpacked archive, Windows)
  # answers the question it can, whatever was asked.
  defp update(_check?, %{install?: false} = host, opts),
    do: update(true, Map.delete(host, :install?), opts)

  defp update(check?, host, opts) do
    say(Map.get(host, :request_notice, "Checking #{@releases} for a newer lmx…"))
    host |> check() |> checked(check?, host, opts)
  end

  # An explicit request, where the host distinguishes one from the periodic
  # check (`Lemieux.CLI.UpdateCheck.host/2` fetches only on request).
  defp check(%{request: request}) when is_function(request, 0), do: request.()
  defp check(%{check: check}) when is_function(check, 0), do: check.()

  # One clause per answer `Lmx.Update.check/1` and its kin can give, the
  # shapes `Lemieux.TUI.Updates` reads.
  defp checked(:current, _check?, _host, _opts),
    do: say("lmx v#{Lemieux.version()} is up to date.")

  defp checked({:installed, version}, _check?, _host, _opts) when is_binary(version),
    do: say("lmx v#{version} is already installed; it runs the next time you start lmx.")

  defp checked({:ok, %{"version" => version}}, true, host, opts) when is_binary(version),
    do: available(version, host, opts)

  defp checked({:ok, %{"version" => version} = info}, false, host, _opts) when is_binary(version),
    do: install(info, host)

  defp checked({:unverified, version, reason}, _check?, host, _opts) when is_binary(version),
    do:
      fail(
        host_notice(host, :unverified_notice, [version, reason]) || unverified(version, reason)
      )

  defp checked({:error, reason}, _check?, host, _opts),
    do: fail(host_notice(host, :error_notice, [reason]) || check_failed(reason))

  defp checked(other, _check?, _host, _opts),
    do: fail("The update host returned an invalid result: #{inspect(other)}.")

  defp available(version, %{stage: stage}, opts) when is_function(stage, 1),
    do: say("lmx v#{version} is available. Run #{CLI.program(opts)} update to install it.")

  defp available(version, _checks_only, _opts),
    do:
      say(
        "lmx v#{version} is available. This lmx can check for updates but not install them; " <>
          "download it from #{@releases}."
      )

  defp install(%{"version" => version} = info, host) do
    say(
      Map.get(
        host,
        :stage_notice,
        "Downloading lmx v#{version} and checking it against its signed manifest…"
      )
    )

    case host.stage.(info) do
      {:ok, staged} -> activate(staged, version, host)
      {:error, reason} -> fail(install_failed(host, version, reason))
    end
  end

  # `self()` stands where the screen's pid goes. The installed host loads new
  # code live only into a screen that answers it (`Lmx.Update.Callbacks`),
  # which this process never does, so the release is selected for the next
  # launch instead: the restart path, which every CLI update takes.
  defp activate(staged, version, host) do
    say(Map.get(host, :apply_notice, "Installing lmx v#{version}…"))

    case host.apply.(staged, self()) do
      {:ok, :hot} -> say("lmx v#{version} is installed and running.")
      {:ok, :restart} -> say(host_notice(host, :restart_notice, [version]) || installed(version))
      {:error, :superseded_update} -> say(superseded())
      {:error, reason} -> fail(install_failed(host, version, reason))
    end
  end

  defp installed(version) do
    "lmx v#{version} is installed. It runs the next time you start lmx; a terminal UI that is " <>
      "open keeps running v#{Lemieux.version()} until you restart it. If you selected extensions " <>
      "of your own, rebuild them for the new version."
  end

  defp superseded,
    do:
      "A newer update is already installed by another session; it runs the next time you start lmx."

  defp not_installed do
    "This lmx was not installed by install.sh, so it has no update host. Download a release " <>
      "from #{@releases}; on macOS and Linux, installing it with install.sh gives you " <>
      "lmx update from then on."
  end

  defp unverified(version, reason) do
    "lmx v#{version} is available but could not be verified (#{describe(reason)}), so nothing " <>
      "was installed. lmx keeps running v#{Lemieux.version()}."
  end

  defp check_failed(:update_unavailable),
    do: "The update check is unavailable: lmx could not reach #{@releases}. Try again later."

  defp check_failed(reason), do: "The update check failed (#{describe(reason)})."

  # The wording the installed host does not supply itself; `Lemieux.TUI.Updates`
  # says the same things in the notice box.
  defp install_failed(_host, version, :manual_install) do
    "This lmx cannot install updates itself. Download lmx v#{version} from #{@releases} and " <>
      "restart lmx. On macOS and Linux, install lmx with install.sh to get lmx update."
  end

  defp install_failed(_host, _version, :update_in_progress),
    do: "Another lmx is installing an update; try again when it has finished."

  defp install_failed(_host, _version, :quarantined_update) do
    "This update previously failed its live activation. Wait for a newer release, or review " <>
      "and reinstall its verified archive explicitly."
  end

  defp install_failed(host, version, reason) do
    host_notice(host, :error_notice, [reason]) ||
      "lmx v#{version} could not be installed (#{describe(reason)}). lmx keeps running " <>
        "v#{Lemieux.version()}."
  end

  defp host_notice(host, name, arguments) do
    case Map.get(host, name) do
      notice when is_function(notice, length(arguments)) -> apply(notice, arguments)
      _none -> nil
    end
  end

  defp describe(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp describe({:source_update, reason}), do: describe(reason)
  defp describe(reason), do: inspect(reason)

  defp say(text) do
    IO.puts(text)
    :ok
  end

  defp fail(message) do
    IO.puts(:stderr, "lmx update: #{message}")
    {:error, 1}
  end

  defp usage(rest, invalid) do
    problem =
      case {rest, invalid} do
        {[word | _rest], _invalid} -> "unrecognised argument #{word}"
        {[], [{flag, _value} | _invalid]} -> "unrecognised option #{flag}"
      end

    IO.puts(:stderr, "lmx update: #{problem}\n#{@usage}")
    {:error, 2}
  end
end
