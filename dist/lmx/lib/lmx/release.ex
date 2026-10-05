defmodule Lmx.Release do
  @moduledoc """
  Assembles native OTP releases and explicit, state compatible upgrade plans.

  Every build gets an identity over its BEAMs, native files and configuration.
  A hot path names an exact prior build, not just a version. Dependency/runtime
  changes and uncovered module changes reject that path. The release author
  records per-platform decisions in `upgrades/VERSION.exs`. Local builds without
  a predecessor are restart-only; CI requires a reviewed plan for every release.
  Soft purge avoids killing processes executing old code; retained anonymous
  callbacks need a separate review and runtime guard.
  State migrations are deliberately not inferred from a BEAM diff.

  ## What the archive runs

  Assembly rewrites a few things Mix and Forecastle generate, each because the
  generated default is wrong for a command people run, rather than a service
  an operator supervises. Every rewrite matches the generated text exactly and
  fails the build when it is not found, so an upstream template change cannot
  silently bring the old behaviour back.

    * **No heart.** Forecastle 1.x adds `-heart` to every start so that
      `release_handler` can prepare a transition that restarts the emulator.
      lmx never declares one: a hot path requires an identical ERTS and
      identical dependencies (`compatible?/2`), so its relup only loads
      modules, and a restart path only repoints `current`. Heart printed
      `heart_beat_kill_pid`, `heart_beat_timeout` and "Would reboot.
      Terminating." around every command, `--version` included.
    * **No distribution, no shared cookie.** `bin/lmx-release` defaults
      `RELEASE_DISTRIBUTION` to `none`, and no `releases/COOKIE` ships. Mix
      writes one cookie per build, so every download of an archive carried the
      same one, and `bin/lmx-release start` registered a node listening on all
      interfaces that anyone holding the public archive could run code on.
      Opting in (`RELEASE_DISTRIBUTION=sname` or `name`) without
      `RELEASE_COOKIE` writes a random cookie for that installation, mode
      0600, the first time.
    * **Launchers.** `bin/lmx` is `priv/launcher.sh` on Unix. On Windows
      (experimental) `bin/lmx.cmd` runs `lmx.ps1` with `-ExecutionPolicy
      Bypass`, because the default client policy refuses unsigned scripts,
      and `bin/lmx` becomes a shim that runs `lmx.cmd` from Git Bash instead
      of Mix's Unix script, which printed the release usage.
    * **One `odu`.** ExCmd ships its process helper for six platforms plus a
      generic copy and only ever runs the one for the platform it is on; the
      other six cost about 11 MB per archive. Linux ERTS binaries also arrive
      with debug information (the launch audit measured beam.smp at 55 MB
      before `strip --strip-debug` and 10 MB after). macOS binaries are not
      stripped: they are code signed, and stripping invalidates the signature.
    * **No Erlang development tools.** ERTS brings `ct_run`, `dialyzer`,
      `erl_call`, `erlc`, `escript`, `typer` and `yielding_c_fun`, about
      0.7 MB on macOS before any compression. Nothing lmx runs starts them:
      a command boots `erl`, DNS lookups run `inet_gethost`, a Castle peer
      runs `erl`, and distribution, when opted into, starts `epmd`. They
      also shadowed the person's own: `erlexec` puts the ERTS `bin`
      directory first on the VM's `PATH`, which the commands the agent runs
      inherit, so `escript` there (rebar3's `#!/usr/bin/env escript`) found
      lmx's copy.
    * **Notices.** `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES` are written
      to the archive root (`Lmx.Notices`), and `check_archive/1` refuses an
      archive without them.
    * **One mode per file, whoever extracts it.** On Unix targets every file
      gets the mode `install.py` and the updater both reproduce
      (`normalize_modes/1`), and `check_archive/1` refuses an archive with
      any other.
  """

  import Bitwise

  alias Lmx.Update.Payload
  alias Mix.Tasks.Compile.Odu

  @targets ~w(linux macos macos_silicon windows)
  # ERTS executables for developing Erlang rather than running it. The
  # moduledoc lists what lmx does start; `heart`, `run_erl` and `to_erl` stay
  # for operators who start the release script themselves.
  @developer_tools ~w(ct_run dialyzer erl_call erlc escript typer yielding_c_fun)

  @doc "Supported native release targets."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "Checks the build host and prepares config-provider support on Unix."
  @spec prepare(release :: Mix.Release.t()) :: Mix.Release.t()
  def prepare(release) do
    target = System.get_env("LMX_TARGET", target())

    if target != target(),
      do: Mix.raise("build #{target} on a matching host (this host is #{target()})")

    if target == "windows", do: release, else: Forecastle.pre_assemble(release)
  end

  @doc "Writes launchers, notices, release identity and any reviewed upgrade instructions."
  @spec assemble(release :: Mix.Release.t()) :: Mix.Release.t()
  def assemble(release) do
    release = if target() == "windows", do: release, else: Forecastle.post_assemble(release)

    if target() != "windows",
      do: rewrite!(Path.join(release.version_path, "env.sh"), &without_heart/1)

    write_launchers(Path.join(release.path, "bin"), target())
    # Mix writes a random cookie per build, which every download then shares.
    File.rm(Path.join([release.path, "releases", "COOKIE"]))
    # Each installation's first start writes its own release_handler record.
    # One left by running a local build in place (`--overwrite` keeps it)
    # names that build's applications and would be packed into the archive.
    File.rm(Path.join([release.path, "releases", "RELEASES"]))
    prune(release.path, target())
    release = Lmx.Notices.write!(release)
    info = identity(release.path, release.version)
    upgrade = upgrade(release, info, System.get_env("LMX_UPGRADE_FROM"))

    File.write!(
      Path.join(release.version_path, "release.json"),
      JSON.encode!(Map.merge(info, upgrade))
    )

    # Last, after every file this step writes. Windows files have no Unix
    # modes (Erlang reports every writable one as 0666, whatever chmod set),
    # and neither install.py nor the updater installs the Windows archive.
    if target() != "windows", do: normalize_modes(release.path)
    release
  end

  @doc """
  Gives every regular file under `root` the mode every extractor of the
  archive reproduces, `Lmx.Update.Payload.canonical_mode/1`, which among
  other things clears group and other write.

  Mix's `:tar` step packs the modes the release tree has, and some files
  arrive from their Hex packages group-writable (0664); `install.py` and the
  updater then made version directories from the same archive that
  disagreed, and each refused the other's (`Lmx.Update.Payload` has the
  history). Directories are left as they are: `:erl_tar` records no
  directory entries, so every extractor creates them with its own umask's
  mode. So are symbolic links: changing a mode through one would change a
  file outside the release, and `check_archive/1` still judges whatever
  `:tar` packs in its place.
  """
  @spec normalize_modes(root :: Path.t()) :: :ok
  def normalize_modes(root) do
    {:ok, %File.Stat{type: :directory}} = File.lstat(root)
    root |> File.ls!() |> Enum.each(&normalize_mode(Path.join(root, &1)))
  end

  defp normalize_mode(path) do
    case File.lstat!(path) do
      %File.Stat{type: :directory} ->
        path |> File.ls!() |> Enum.each(&normalize_mode(Path.join(path, &1)))

      %File.Stat{type: :regular, mode: mode} ->
        wanted = Payload.canonical_mode(mode)
        if (mode &&& 0o7777) != wanted, do: File.chmod!(path, wanted)

      _link_or_other ->
        :ok
    end
  end

  @doc """
  Refuses an archive that a person must not receive.

  Runs after `:tar` and reads the archive itself rather than the release
  directory, because the archive is what is published and installed, and
  `:tar` packs only the directories and overlays it knows about: a file
  written to the release root without being registered as an overlay never
  reaches it.
  """
  @spec check_archive(release :: Mix.Release.t()) :: Mix.Release.t()
  def check_archive(release) do
    path = archive_path(release)

    entries =
      case :erl_tar.table(String.to_charlist(path), [:compressed, :verbose]) do
        {:ok, rows} ->
          Enum.map(rows, fn row -> {to_string(elem(row, 0)), elem(row, 1), elem(row, 4)} end)

        {:error, reason} ->
          Mix.raise("cannot read #{path}: #{inspect(reason)}")
      end

    case archive_problems(entries, target()) do
      [] -> release
      problems -> Mix.raise("#{path} is not publishable: " <> Enum.join(problems, "; "))
    end
  end

  @typedoc "An archive member as `:erl_tar.table/2` lists it: path, type and mode."
  @type archive_entry :: {name :: String.t(), type :: atom(), mode :: non_neg_integer()}

  @doc """
  Lists what is wrong with a `target` archive holding `entries`; empty when
  nothing is. On Unix targets that includes any file whose mode
  `normalize_modes/1` would have changed.
  """
  @spec archive_problems(entries :: [archive_entry()], target :: String.t()) :: [String.t()]
  def archive_problems(entries, target) when is_list(entries) and is_binary(target) do
    names_problems(Enum.map(entries, &elem(&1, 0))) ++ mode_problems(entries, target)
  end

  # Windows archives keep what Erlang reports there, 0666 for every writable
  # file; normalize_modes/1 skips them for the same reason.
  defp mode_problems(_entries, "windows"), do: []

  defp mode_problems(entries, _unix) do
    unstable =
      for {name, :regular, mode} <- Enum.sort(entries),
          (mode &&& 0o7777) != Payload.canonical_mode(mode),
          do: "#{name} (#{octal(mode &&& 0o7777)})"

    case unstable do
      [] ->
        []

      _some ->
        [
          "#{length(unstable)} files have modes install.py and the updater would extract " <>
            "differently (group or other writable, or not owner read-write), so neither would " <>
            "reuse a version directory the other made: " <>
            Enum.join(Enum.take(unstable, 5), ", ") <>
            if(length(unstable) > 5, do: ", ...", else: "") <>
            "; Lmx.Release.normalize_modes/1 should have given them modes both keep"
        ]
    end
  end

  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")

  defp names_problems(names) do
    names = MapSet.new(names, &String.trim_trailing(&1, "/"))

    missing =
      for name <- ~w(LICENSE NOTICE THIRD_PARTY_NOTICES),
          name not in names,
          do: "#{name} is missing from the archive root"

    cookie =
      if "releases/COOKIE" in names,
        do: ["releases/COOKIE ships a cookie every download would share"],
        else: []

    record =
      if "releases/RELEASES" in names,
        do: ["releases/RELEASES is a release_handler record from a build machine run"],
        else: []

    helpers = Enum.filter(names, &Regex.match?(~r{^lib/ex_cmd-[^/]+/priv/odu[^/]*$}, &1))

    odu =
      if length(helpers) == 1,
        do: [],
        else: ["expected exactly one ExCmd odu helper, found #{length(helpers)}"]

    tools =
      for name <- Enum.sort(names),
          developer_tool?(name),
          do: "#{name} is an Erlang development tool that lmx never runs"

    missing ++ cookie ++ record ++ odu ++ tools
  end

  defp developer_tool?(path) do
    match?(["erts-" <> _version, "bin", _tool], Path.split(path)) and
      Path.basename(path, ".exe") in @developer_tools
  end

  @doc "Identifies the running platform. Linux releases use the host's GNU ABI."
  @spec target() :: String.t()
  def target do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    case {:os.type(), arch} do
      {{:unix, :darwin}, "aarch64" <> _} -> "macos_silicon"
      {{:unix, :darwin}, "x86_64" <> _} -> "macos"
      {{:unix, :linux}, "x86_64" <> _} -> "linux"
      {{:win32, _}, _} -> "windows"
      _ -> "unsupported"
    end
  end

  @doc "Reads an unpacked release's build identity."
  @spec read(root :: Path.t(), version :: String.t()) :: {:ok, map()} | {:error, term()}
  def read(root, version) do
    with {:ok, body} <- File.read(Path.join([root, "releases", version, "release.json"])),
         do: JSON.decode(body)
  end

  @doc "Reads the selected boot version, including a release tree with older metadata."
  @spec current(root :: Path.t()) :: {:ok, map()} | {:error, term()}
  def current(root) do
    case File.read(Path.join(root, "releases/start_erl.data")) do
      {:ok, data} -> boot_version(root, String.split(String.trim(data)))
      {:error, :enoent} -> only_release(root)
      error -> error
    end
  end

  defp boot_version(root, [_erts, version]), do: read(root, version)
  defp boot_version(_root, _fields), do: {:error, :invalid_boot_version}

  defp only_release(root) do
    case Path.wildcard(Path.join([root, "releases", "*", "release.json"])) do
      [path] -> with {:ok, body} <- File.read(path), do: JSON.decode(body)
      _ -> {:error, :ambiguous_release}
    end
  end

  @doc "Requires complete compatibility identities; older formats require restart."
  @spec compatible?(old :: map(), new :: map()) :: boolean()
  def compatible?(old, new) do
    keys = ~w(target erts elixir dependencies native_id dependency_id config_id)

    Enum.all?(keys, &(Map.has_key?(old, &1) and Map.has_key?(new, &1))) and
      Map.take(old, keys) == Map.take(new, keys)
  end

  @doc "Hashes assembled code and static config, including same-version dependency changes."
  @spec identity(root :: Path.t(), version :: String.t()) :: map()
  def identity(root, version) do
    {:ok, [{:release, _, {:erts, erts}, apps}]} =
      :file.consult(to_charlist(Path.join([root, "releases", version, "lmx.rel"])))

    apps = Enum.map(apps, &{elem(&1, 0), elem(&1, 1)})

    for app <- [:lemieux, :lmx] do
      if List.keyfind(apps, app, 0) != {app, to_charlist(version)},
        do:
          Mix.raise(
            "#{app} application version differs from release #{version}; recompile the release host before assembling"
          )
    end

    dependencies =
      for {app, vsn} <- apps,
          app not in [:lmx, :lemieux],
          into: %{},
          do: {to_string(app), to_string(vsn)}

    native =
      for {app, vsn} <- apps,
          path <-
            Path.wildcard(Path.join([root, "lib", "#{app}-#{vsn}", "priv", "**/*"]),
              match_dot: true
            ),
          File.regular?(path),
          do:
            {"#{app}/" <> Path.relative_to(path, Path.join([root, "lib", "#{app}-#{vsn}"])), path}

    code =
      for {app, vsn} <- apps,
          path <- Path.wildcard(Path.join([root, "lib", "#{app}-#{vsn}", "ebin", "*.{beam,app}"])),
          do: {"#{app}/ebin/" <> Path.basename(path), path}

    config =
      for name <- ["lmx.rel", "start.boot", "build.config", "sys.config"],
          path = Path.join([root, "releases", version, name]),
          File.regular?(path),
          do: {name, path}

    %{
      "version" => version,
      "target" => target(),
      "erts" => to_string(erts),
      "elixir" => System.version(),
      "dependencies" => dependencies,
      "dependency_id" =>
        digest_files(
          Enum.reject(code, fn {name, _} -> String.starts_with?(name, ["lemieux/", "lmx/"]) end)
        ),
      "config_id" =>
        digest_files(
          Enum.filter(config, fn {name, _} -> name in ["build.config", "sys.config"] end)
        ),
      "native_id" => digest_files(native),
      "build_id" => digest_files(code ++ native ++ config)
    }
  end

  defp digest_files(files) do
    files
    |> Enum.sort()
    |> Enum.map(fn {name, path} -> [name, <<0>>, File.read!(path)] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp upgrade(release, _info, nil) do
    if System.get_env("LMX_REQUIRE_UPGRADE_PLAN") == "1" do
      plan = Lmx.UpgradePlan.read!(release.version)

      if plan.from != nil,
        do: Mix.raise("release decision requires the exact LMX_UPGRADE_FROM artifact")
    end

    File.rm(Path.join(release.version_path, "relup"))
    %{"upgrade_from" => [], "hot_modules" => []}
  end

  defp upgrade(release, info, old_root) do
    plan = Lmx.UpgradePlan.read!(release.version)
    old = Lmx.UpgradePlan.metadata!(old_root)

    if plan.from != old["version"],
      do: Mix.raise("release decision names a different predecessor")

    case plan.targets[target()].mode do
      :hot ->
        hot_upgrade(release, info, old_root, old, plan)

      :restart ->
        File.rm(Path.join(release.version_path, "relup"))
        %{"upgrade_from" => [], "hot_modules" => []}

      :initial ->
        Mix.raise("initial releases cannot name a predecessor")
    end
  end

  defp hot_upgrade(release, info, old_root, old, plan) do
    # Identity is not yet written for this assembled version. Qualify the
    # diff against the freshly computed metadata, never a stale previous build.
    old_version = old["version"]
    File.write!(Path.join(release.version_path, "release.json"), JSON.encode!(info))
    report = Lmx.UpgradePlan.report(old_root, release.path)
    Lmx.UpgradePlan.qualify!(plan, target(), report)
    modules = plan.targets[target()].modules

    Enum.each([:lemieux, :lmx], fn app ->
      instructions = Enum.map(modules[app], &{:load_module, &1, :soft_purge, :soft_purge, []})

      appup =
        {to_charlist(release.version), [{to_charlist(old_version), instructions}],
         [{to_charlist(old_version), instructions}]}

      write_term(
        Path.join([release.path, "lib", "#{app}-#{release.version}", "ebin", "#{app}.appup"]),
        appup
      )
    end)

    new_rel = Path.join(release.version_path, "lmx") |> to_charlist()
    old_rel = Path.join([old_root, "releases", old_version, "lmx"]) |> to_charlist()
    paths = for root <- [old_root, release.path], do: to_charlist(Path.join(root, "lib/*/ebin"))

    case :systools.make_relup(new_rel, [old_rel], [old_rel],
           path: paths,
           outdir: to_charlist(release.version_path),
           silent: true
         ) do
      {:ok, relup, _, []} -> write_term(Path.join(release.version_path, "relup"), relup)
      error -> Mix.raise("could not generate relup: #{inspect(error)}")
    end

    %{
      "upgrade_from" => [%{"version" => old_version, "build_id" => old["build_id"]}],
      "hot_modules" =>
        Enum.flat_map([:lemieux, :lmx], fn app -> Enum.map(modules[app], &Atom.to_string/1) end)
    }
  end

  defp write_term(path, term), do: File.write!(path, :io_lib.format(~c"~tp.~n", [term]))

  @doc """
  Replaces the launchers Mix generated in `bin` with lmx's own for `target`.

  Expects Mix's stock `bin/lmx` and `bin/lmx.bat` (both are generated on every
  target). Unix targets get the rewritten stock script as `bin/lmx-release`
  and `priv/launcher.sh` as `bin/lmx`; every target gets the rewritten batch
  script as `bin/lmx-release.bat`, `bin/lmx.ps1` and `bin/lmx.cmd`; Windows
  gets the Git Bash shim as `bin/lmx`.
  """
  @spec write_launchers(bin :: Path.t(), target :: String.t()) :: :ok
  def write_launchers(bin, target) when is_binary(bin) and is_binary(target) do
    if target == "windows" do
      write_executable(Path.join(bin, "lmx"), git_bash_shim())
    else
      write_executable(
        Path.join(bin, "lmx-release"),
        release_script(File.read!(Path.join(bin, "lmx")))
      )

      write_executable(Path.join(bin, "lmx"), File.read!(priv("launcher.sh")))
    end

    stock_batch = Path.join(bin, "lmx.bat")
    File.write!(Path.join(bin, "lmx-release.bat"), release_batch(File.read!(stock_batch)))
    File.rm!(stock_batch)
    File.cp!(priv("launcher.ps1"), Path.join(bin, "lmx.ps1"))
    File.write!(Path.join(bin, "lmx.cmd"), windows_command())
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp priv(name), do: Application.app_dir(:lmx, Path.join("priv", name))

  @doc """
  `bin/lmx.cmd`: runs the PowerShell launcher whatever the execution policy.

  `-ExecutionPolicy Bypass` applies to this one process. Without it the
  default policy on Windows client editions (`Restricted`) refuses every
  script, and `RemoteSigned` refuses an unsigned one that came from a
  browser download. A policy set by Group Policy still wins.
  """
  @spec windows_command() :: String.t()
  def windows_command do
    "@echo off\r\n" <>
      ~s|powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lmx.ps1" %*\r\n| <>
      "exit /b %ERRORLEVEL%\r\n"
  end

  @doc """
  `bin/lmx` in the Windows archive: Git Bash finds this before `lmx.cmd`.

  Mix's own `bin/lmx` there is its Unix release script, which answered
  `lmx --version` with the release usage and "ERROR: Unknown command".
  """
  @spec git_bash_shim() :: String.t()
  def git_bash_shim do
    """
    #!/bin/sh
    # lmx on Windows is experimental and needs Git Bash, which runs this file
    # rather than lmx.cmd when you type `lmx`. It hands everything to lmx.cmd,
    # the real launcher. Under WSL, install the Linux build inside WSL instead.
    exec "$(dirname "$0")/lmx.cmd" "$@"
    """
  end

  # The lines of Mix's Unix release script (Mix.Tasks.Release.Init.cli_text/0)
  # that release_script/1 rewrites.
  @start_line ~s|start "elixir" --no-halt\n|
  @stock_cookie ~s|RELEASE_COOKIE="${RELEASE_COOKIE:-"$(cat "$RELEASE_ROOT/releases/COOKIE")"}"\n| <>
                  "export RELEASE_COOKIE\n"
  @stock_distribution ~s|RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"sname"}"\n| <>
                        "export RELEASE_DISTRIBUTION\n"
  @stock_cookie_flag ~s|--cookie "$RELEASE_COOKIE"|

  @doc """
  Rewrites Mix's Unix release script into `bin/lmx-release`.

  The CLI boots through `Lmx.Boot` when the launcher passed arguments;
  distribution is off unless asked for; there is no shipped cookie, and none
  is passed to the VM unless one is configured or distribution is on.
  Without a cookie argument, a node that starts distribution later (attaching
  to an application, `Lemieux.Eval.Attach`) uses the person's own
  `~/.erlang.cookie`, as plain Erlang does.
  """
  @spec release_script(stock :: String.t()) :: String.t()
  def release_script(stock) when is_binary(stock) do
    stock
    |> replace!(@stock_cookie_flag, ~s|${RELEASE_COOKIE:+--cookie "$RELEASE_COOKIE"}|, :some)
    |> replace!(
      @start_line,
      ~s|if [ -n "${LMX_ARGV_FILE:-}" ]; then start "elixir" --no-halt --eval 'Lmx.Boot.main()'; else start "elixir" --no-halt; fi\n|,
      1
    )
    |> replace!(@stock_cookie, "", 1)
    |> replace!(@stock_distribution, distribution_and_cookie(), 1)
  end

  defp distribution_and_cookie do
    ~S"""
    # lmx: distribution is opt-in, and the archive ships no cookie. Mix wrote
    # one per build, so every download shared it, and a node it started
    # listened on all interfaces. Opting in without RELEASE_COOKIE creates a
    # random cookie for this installation, readable by its owner only.
    RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"none"}"
    export RELEASE_DISTRIBUTION
    if [ -z "${RELEASE_COOKIE:-}" ] && [ "$RELEASE_DISTRIBUTION" != "none" ]; then
      lmx_cookie="$RELEASE_ROOT/releases/COOKIE"
      if [ ! -f "$lmx_cookie" ]; then
        lmx_cookie_new=$(umask 077 && mktemp "$lmx_cookie.XXXXXXXX") || {
          echo "ERROR: cannot create $lmx_cookie; set RELEASE_COOKIE to use distribution" >&2
          exit 1
        }
        od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$lmx_cookie_new"
        # A hard link publishes the finished file or nothing, so a start and an
        # rpc racing here both read the same cookie.
        ln "$lmx_cookie_new" "$lmx_cookie" 2>/dev/null || true
        rm -f "$lmx_cookie_new"
      fi
      RELEASE_COOKIE=$(cat "$lmx_cookie")
    fi
    if [ -n "${RELEASE_COOKIE:-}" ]; then export RELEASE_COOKIE; fi
    """
  end

  @doc """
  Rewrites Mix's Windows batch script into `bin/lmx-release.bat`: distribution
  off unless asked for, and a cookie passed only when one is configured.
  """
  @spec release_batch(stock :: String.t()) :: String.t()
  def release_batch(stock) when is_binary(stock) do
    # The flag's own definition below spells the stock argument, so the
    # arguments are replaced first.
    stock
    |> replace!(~s|--cookie "!RELEASE_COOKIE!"|, "!RELEASE_COOKIE_FLAG!", :some)
    |> replace!(
      ~s|if not defined RELEASE_COOKIE (set /p RELEASE_COOKIE=<!RELEASE_ROOT!\\releases\\COOKIE)|,
      ~s|if not defined RELEASE_COOKIE if exist "!RELEASE_ROOT!\\releases\\COOKIE" (set /p RELEASE_COOKIE=<"!RELEASE_ROOT!\\releases\\COOKIE")\n| <>
        ~s|if defined RELEASE_COOKIE (set RELEASE_COOKIE_FLAG=--cookie "!RELEASE_COOKIE!") else (set RELEASE_COOKIE_FLAG=)|,
      1
    )
    |> replace!(
      "if not defined RELEASE_DISTRIBUTION (set RELEASE_DISTRIBUTION=sname)",
      "if not defined RELEASE_DISTRIBUTION (set RELEASE_DISTRIBUTION=none)",
      1
    )
  end

  # Forecastle 1.x's env.sh fragment (deps/forecastle/priv/env.sh.eex, "2.
  # heart, deliberately defanged") ends by adding the flag for every start.
  @forecastle_heart ~s|    if [ -z "$castle_heart" ]; then\n| <>
                      ~s|      ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:+$ELIXIR_ERL_OPTIONS }-heart"\n| <>
                      "      export ELIXIR_ERL_OPTIONS\n" <>
                      "    fi\n"

  @doc """
  Removes the `-heart` Forecastle's `env.sh` fragment adds to every start.

  The rest of the fragment stays: it selects a provisional version after a
  restart install and creates `releases/RELEASES`, which `release_handler`
  needs for hot upgrades. The heart settings it exports are dropped too when
  no heart will run, so they do not reach the commands lmx runs. When the
  environment brings a `-heart` of its own (`ERL_FLAGS`, say; Forecastle
  measures that as `castle_heart`), they stay: they are what keeps that heart
  from killing lmx after a missed heartbeat, which heart's defaults would do
  after 60 seconds.
  """
  @spec without_heart(env_sh :: String.t()) :: String.t()
  def without_heart(env_sh) when is_binary(env_sh) do
    replace!(
      env_sh,
      @forecastle_heart,
      "    # lmx starts without heart: Lmx.Release explains why.\n" <>
        ~s|    if [ -z "$castle_heart" ]; then\n| <>
        "      unset HEART_NO_KILL HEART_BEAT_TIMEOUT\n" <>
        "    fi\n",
      1
    )
  end

  defp rewrite!(path, fun), do: File.write!(path, fun.(File.read!(path)))

  defp replace!(text, stock, replacement, expected) do
    found = text |> :binary.matches(stock) |> length()

    if found == 0 or (expected != :some and found != expected) do
      Mix.raise(
        "generated release text changed upstream: expected #{inspect(expected)} of " <>
          "#{inspect(stock)}, found #{found}; review Lmx.Release before building"
      )
    end

    String.replace(text, stock, replacement)
  end

  @doc """
  Removes what this target never runs: the other platforms' ExCmd helpers,
  the Erlang development tools (`developer_tools/1`), and on Linux the debug
  information in ERTS executables and NIFs.
  """
  @spec prune(root :: Path.t(), target :: String.t()) :: :ok
  def prune(root, target) do
    keep = Odu.executable_name()

    for path <- Path.wildcard(Path.join(root, "lib/ex_cmd-*/priv/odu*")),
        Path.basename(path) != keep,
        do: File.rm!(path)

    Enum.each(developer_tools(root), &File.rm!/1)
    strip(root, target, System.find_executable("strip"))
  end

  @doc """
  The ERTS executables under `root` for developing Erlang rather than
  running it, which `prune/2` removes and `archive_problems/2` refuses:
  `ct_run`, `dialyzer`, `erl_call`, `erlc`, `escript`, `typer` and
  `yielding_c_fun`, with `.exe` on Windows.
  """
  @spec developer_tools(root :: Path.t()) :: [Path.t()]
  def developer_tools(root) do
    root
    |> Path.join("erts-*/bin/*")
    |> Path.wildcard()
    |> Enum.filter(&developer_tool?(Path.relative_to(&1, root)))
    |> Enum.sort()
  end

  defp strip(root, "linux", strip) when is_binary(strip) do
    for path <- strippable(root) do
      case System.cmd(strip, ["--strip-debug", path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> Mix.raise("strip #{path} failed (#{status}): #{output}")
      end
    end

    :ok
  end

  defp strip(_root, "linux", nil) do
    Mix.shell().info("strip not found; the Linux release keeps its debug information")
  end

  defp strip(_root, _target, _strip), do: :ok

  @doc """
  The ELF files under `root` that `strip --strip-debug` may shrink: ERTS
  executables and the NIFs in application `priv` directories. ExCmd's Go
  helper is left alone; it is built without debug information already.
  """
  @spec strippable(root :: Path.t()) :: [Path.t()]
  def strippable(root) do
    (Path.wildcard(Path.join(root, "erts-*/bin/*")) ++
       Path.wildcard(Path.join(root, "lib/*/priv/**/*.so")))
    |> Enum.reject(&String.contains?(&1, "/priv/odu"))
    |> Enum.filter(&elf?/1)
    |> Enum.sort()
  end

  defp elf?(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        IO.binread(file, 4) == <<0x7F, "ELF">>
      after
        File.close(file)
      end
    else
      _ -> false
    end
  end

  # Where Mix's `:tar` step writes the archive (Mix.Tasks.Release.make_tar).
  defp archive_path(release) do
    build = Mix.Project.build_path()

    directory =
      if release.path == Path.join([build, "rel", Atom.to_string(release.name)]),
        do: build,
        else: release.path

    Path.join(directory, "#{release.name}-#{release.version}.tar.gz")
  end
end
