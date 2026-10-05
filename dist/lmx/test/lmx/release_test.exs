defmodule Lmx.ReleaseTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.Odu
  alias Mix.Tasks.Release.Init

  test "keeps the executable application separate from the library" do
    assert Application.get_application(Lmx.Application) == :lmx
    assert Application.get_application(Lemieux) == :lemieux
    assert Application.spec(:lemieux, :mod) == []
  end

  test "assembles platform releases with explicit upgrade metadata" do
    release = Mix.Project.config()[:releases][:lmx]
    assert Lmx.Release.targets() == ~w(linux macos macos_silicon windows)

    assert release[:steps] == [
             &Lmx.Release.prepare/1,
             :assemble,
             &Lmx.Release.assemble/1,
             :tar,
             &Lmx.Release.check_archive/1
           ]

    assert :sasl in Application.spec(:lmx, :applications)
  end

  # A cloned repository's .env used to run its $(...) commands and set
  # LMX_BASE_URL, LMX_CONFIG and LMX_PROJECT_MCP in the installed binary.
  test "the release never loads a working directory's .env" do
    assert Config.Reader.read!("config/config.exs")[:req_llm][:load_dotenv] == false
  end

  test "the installed library carries the TUI's extension skills" do
    root = Application.app_dir(:lemieux, "priv/skills")
    assert File.regular?(Path.join(root, "create-extension/SKILL.md"))
    assert File.regular?(Path.join(root, "evaluate-extension/SKILL.md"))
  end

  # `lmx desktop install` copies the icon from the installed library.
  test "the installed library carries the desktop entry's icon" do
    assert File.regular?(Application.app_dir(:lemieux, "priv/desktop/lemieux.svg"))
  end

  # A release copies the library's whole priv tree and hashes every file in it
  # into the build identity. Dialyzer's nine-megabyte PLT used to live at
  # priv/plts, so every local release shipped it and changed identity whenever
  # Dialyzer ran. The PLT now lives under _build; this keeps it from drifting
  # back into the packaged tree.
  test "the installed library carries no development caches" do
    refute File.exists?(Application.app_dir(:lemieux, "priv/plts"))
  end

  @tag :tmp_dir
  test "same dependency version with changed code or static config requires restart", %{
    tmp_dir: tmp
  } do
    version = "0.1.0"
    File.mkdir_p!(Path.join([tmp, "releases", version]))
    File.mkdir_p!(Path.join([tmp, "lib", "fixture-1.0.0", "ebin"]))

    rel =
      {:release, {~c"lmx", ~c"0.1.0"}, {:erts, ~c"17"},
       [{:fixture, ~c"1.0.0"}, {:lmx, ~c"0.1.0"}, {:lemieux, ~c"0.1.0"}]}

    File.write!(
      Path.join([tmp, "releases", version, "lmx.rel"]),
      :io_lib.format(~c"~tp.~n", [rel])
    )

    beam = Path.join([tmp, "lib", "fixture-1.0.0", "ebin", "Fixture.beam"])
    File.write!(beam, "first dependency build")
    old = Lmx.Release.identity(tmp, version)
    File.write!(beam, "different dependency build at same version")
    new = Lmx.Release.identity(tmp, version)
    assert old["dependencies"] == new["dependencies"]
    refute old["dependency_id"] == new["dependency_id"]
    refute Lmx.Release.compatible?(old, new)
    File.write!(Path.join([tmp, "releases", version, "build.config"]), "different static config")
    configured = Lmx.Release.identity(tmp, version)
    assert new["dependency_id"] == configured["dependency_id"]
    refute Lmx.Release.compatible?(new, configured)
    File.write!(Path.join([tmp, "releases", version, "sys.config"]), "Castle 1.x static config")
    current_config = Lmx.Release.identity(tmp, version)
    assert configured["dependency_id"] == current_config["dependency_id"]
    refute Lmx.Release.compatible?(configured, current_config)
    stale = put_elem(rel, 3, [{:lmx, ~c"0.0.9"}, {:lemieux, ~c"0.1.0"}])

    File.write!(
      Path.join([tmp, "releases", version, "lmx.rel"]),
      :io_lib.format(~c"~tp.~n", [stale])
    )

    assert_raise Mix.Error, ~r/application version differs/, fn ->
      Lmx.Release.identity(tmp, version)
    end
  end

  describe "launchers" do
    @describetag :tmp_dir

    test "Windows gets a policy-proof lmx.cmd and a Git Bash shim", %{tmp_dir: tmp} do
      bin = stock_bin(tmp)
      assert Lmx.Release.write_launchers(bin, "windows") == :ok

      assert File.read!(Path.join(bin, "lmx.cmd")) ==
               "@echo off\r\n" <>
                 ~s|powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lmx.ps1" %*\r\n| <>
                 "exit /b %ERRORLEVEL%\r\n"

      shim = File.read!(Path.join(bin, "lmx"))
      assert shim =~ ~s|exec "$(dirname "$0")/lmx.cmd" "$@"|
      refute shim =~ "RELEASE_ROOT"
      refute File.exists?(Path.join(bin, "lmx-release"))
      refute File.exists?(Path.join(bin, "lmx.bat"))
      assert File.read!(Path.join(bin, "lmx.ps1")) =~ "Lmx.Boot.main()"

      batch = File.read!(Path.join(bin, "lmx-release.bat"))
      assert batch =~ "(set RELEASE_DISTRIBUTION=none)"
      refute batch =~ "RELEASE_DISTRIBUTION=sname"
      assert batch =~ ~s|if exist "!RELEASE_ROOT!\\releases\\COOKIE"|
      # start, eval, remote and rpc pass the flag, which is set only from a
      # configured cookie.
      assert occurrences(batch, "!RELEASE_COOKIE_FLAG!") == 4

      assert occurrences(batch, ~s|--cookie "!RELEASE_COOKIE!"|) ==
               occurrences(batch, ~s|(set RELEASE_COOKIE_FLAG=--cookie "!RELEASE_COOKIE!")|)
    end

    test "Unix gets the launcher and a release script without shared cookie", %{tmp_dir: tmp} do
      bin = stock_bin(tmp)
      assert Lmx.Release.write_launchers(bin, "macos_silicon") == :ok

      assert File.read!(Path.join(bin, "lmx")) ==
               File.read!(Application.app_dir(:lmx, "priv/launcher.sh"))

      script = File.read!(Path.join(bin, "lmx-release"))
      assert script =~ ~s|RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"none"}"|
      refute script =~ ~s|cat "$RELEASE_ROOT/releases/COOKIE")"}"|
      # rpc, start, eval and remote pass a cookie only when there is one.
      assert occurrences(script, ~s|${RELEASE_COOKIE:+--cookie "$RELEASE_COOKIE"}|) == 4
      assert occurrences(script, ~s|--cookie "$RELEASE_COOKIE"|) == 4
      assert script =~ "--eval 'Lmx.Boot.main()'"
      assert File.read!(Path.join(bin, "lmx.cmd")) =~ "-ExecutionPolicy Bypass"
    end

    # Windows reports execute permission only for .exe, .cmd, .bat and .com.
    @tag :unix
    test "the launchers without an extension are executable", %{tmp_dir: tmp} do
      unix = stock_bin(Path.join(tmp, "unix"))
      Lmx.Release.write_launchers(unix, "macos_silicon")
      assert executable?(Path.join(unix, "lmx"))
      assert executable?(Path.join(unix, "lmx-release"))

      windows = stock_bin(Path.join(tmp, "windows"))
      Lmx.Release.write_launchers(windows, "windows")
      assert executable?(Path.join(windows, "lmx"))
    end

    test "a stock template that changed upstream stops the build" do
      assert_raise Mix.Error, ~r/changed upstream/, fn ->
        Lmx.Release.release_script("#!/bin/sh\necho not the Mix template\n")
      end

      assert_raise Mix.Error, ~r/changed upstream/, fn -> Lmx.Release.without_heart("") end
    end

    # Runs the rewritten script for real, with a stand-in for the release's
    # `elixir` that prints the arguments it was given; both are sh scripts.
    @tag :unix
    test "distribution is off, and opting in creates a private cookie once", %{tmp_dir: tmp} do
      root = fake_release_root(tmp)

      {args, 0} = release_cmd(root, [])
      refute args =~ "--cookie"
      refute args =~ "--sname"
      refute File.exists?(Path.join(root, "releases/COOKIE"))

      {args, 0} = release_cmd(root, [{"RELEASE_DISTRIBUTION", "sname"}])
      cookie_path = Path.join(root, "releases/COOKIE")
      cookie = File.read!(cookie_path)
      assert cookie =~ ~r/\A[0-9a-f]{64}\z/
      assert File.stat!(cookie_path).mode |> Bitwise.band(0o077) == 0
      assert args =~ "--cookie #{cookie}"
      assert args =~ "--sname"

      {again, 0} = release_cmd(root, [{"RELEASE_DISTRIBUTION", "sname"}])
      assert again =~ "--cookie #{cookie}"

      {given, 0} =
        release_cmd(root, [{"RELEASE_DISTRIBUTION", "sname"}, {"RELEASE_COOKIE", "chosen"}])

      assert given =~ "--cookie chosen"
    end
  end

  # Heart and env.sh are the Unix start path; the Windows archive skips both.
  describe "heart" do
    @describetag :tmp_dir
    @describetag :unix

    # Forecastle's real fragment, sourced the way bin/lmx-release sources it.
    test "a start no longer adds -heart or exports heart settings", %{tmp_dir: tmp} do
      fragment = forecastle_env_sh()
      assert sourced_heart(tmp, fragment) == "-heart|TRUE|65535"
      assert sourced_heart(tmp, Lmx.Release.without_heart(fragment)) == "||"
    end

    # A heart the environment starts anyway must keep the settings that make
    # it inert: with heart's defaults it kills a VM that misses a heartbeat.
    test "a -heart from the environment keeps its inert settings", %{tmp_dir: tmp} do
      fragment = Lmx.Release.without_heart(forecastle_env_sh())

      assert sourced_heart(tmp, fragment, [{"ELIXIR_ERL_OPTIONS", "-heart"}]) ==
               "-heart|TRUE|65535"
    end
  end

  describe "pruning" do
    @describetag :tmp_dir

    test "only this platform's ExCmd helper stays", %{tmp_dir: tmp} do
      priv = Path.join(tmp, "lib/ex_cmd-0.18.0/priv")
      File.mkdir_p!(priv)

      names =
        ~w(odu odu_darwin_amd64 odu_darwin_arm64 odu_linux_amd64 odu_linux_arm64
           odu_windows_amd64.exe odu_windows_arm64.exe)

      for name <- names, do: File.write!(Path.join(priv, name), "helper")

      assert Lmx.Release.prune(tmp, "macos_silicon") == :ok
      assert File.ls!(priv) == [Odu.executable_name()]
    end

    test "the Erlang development tools go, and what lmx runs stays", %{tmp_dir: tmp} do
      bin = Path.join(tmp, "erts-17.0.2/bin")
      File.mkdir_p!(bin)

      runtime =
        ~w(beam.smp epmd erl erl.src erl_child_setup erlexec heart inet_gethost run_erl
           start start.src start_erl.src to_erl)

      tools = ~w(ct_run dialyzer erl_call erlc erlc.exe escript typer yielding_c_fun)
      for name <- runtime ++ tools, do: File.write!(Path.join(bin, name), "program")

      assert Lmx.Release.developer_tools(tmp) == Enum.map(Enum.sort(tools), &Path.join(bin, &1))
      assert Lmx.Release.prune(tmp, "macos_silicon") == :ok
      assert Enum.sort(File.ls!(bin)) == Enum.sort(runtime)
    end

    test "strips ELF executables and NIFs, never the Go helper", %{tmp_dir: tmp} do
      elf = <<0x7F, "ELF", 0::size(64)>>

      files = %{
        "erts-17.0.2/bin/beam.smp" => elf,
        "erts-17.0.2/bin/erl" => "#!/bin/sh\n",
        "lib/crypto-5.9/priv/lib/crypto.so" => elf,
        "lib/ex_cmd-0.18.0/priv/odu_linux_amd64" => elf,
        "lib/app-1.0/priv/data.txt" => elf
      }

      for {name, data} <- files do
        File.mkdir_p!(Path.dirname(Path.join(tmp, name)))
        File.write!(Path.join(tmp, name), data)
      end

      assert Lmx.Release.strippable(tmp) == [
               Path.join(tmp, "erts-17.0.2/bin/beam.smp"),
               Path.join(tmp, "lib/crypto-5.9/priv/lib/crypto.so")
             ]
    end
  end

  describe "archive check" do
    @describetag :tmp_dir

    @complete ~w(LICENSE NOTICE THIRD_PARTY_NOTICES bin/lmx releases/0.1.0/lmx.rel
                 lib/ex_cmd-0.18.0/priv/odu_darwin_arm64)

    test "a complete archive passes" do
      assert Lmx.Release.archive_problems(entries(@complete), "macos_silicon") == []
    end

    test "missing notices, a shared cookie, a stale record or foreign helpers are refused" do
      problems =
        Lmx.Release.archive_problems(
          entries(
            (@complete -- ["THIRD_PARTY_NOTICES"]) ++
              [
                "releases/COOKIE",
                "releases/RELEASES",
                "lib/ex_cmd-0.18.0/priv/odu_linux_amd64"
              ]
          ),
          "linux"
        )

      assert Enum.any?(problems, &(&1 =~ "THIRD_PARTY_NOTICES is missing"))
      assert Enum.any?(problems, &(&1 =~ "releases/COOKIE"))
      assert Enum.any?(problems, &(&1 =~ "releases/RELEASES"))
      assert Enum.any?(problems, &(&1 =~ "found 2"))
      assert length(problems) == 4
    end

    test "Erlang development tools are refused, the runtime's own programs are not" do
      names =
        @complete ++
          ~w(erts-17.0.2/bin/erl erts-17.0.2/bin/inet_gethost erts-17.0.2/bin/escript
             erts-17.0.2/bin/erlc.exe lib/app-1.0/priv/escript)

      assert Lmx.Release.archive_problems(entries(names), "windows") == [
               "erts-17.0.2/bin/erlc.exe is an Erlang development tool that lmx never runs",
               "erts-17.0.2/bin/escript is an Erlang development tool that lmx never runs"
             ]
    end

    # Every extractor must give a file the same mode: install.py's Python
    # "data" filter clears group and other write, adds owner read-write and
    # drops group and other execute without owner execute, while the
    # updater's :erl_tar keeps the archive's mode, and each refused a version
    # directory the other had made from the same archive.
    test "on Unix targets, only modes every extractor keeps pass" do
      archive =
        entries(@complete) ++
          [
            {"lib/jsv-0.21.2/priv/grammars/email-address.abnf", :regular, 0o100664},
            {"lib/app-1.0/priv/read-only", :regular, 0o444},
            {"lib/app-1.0/priv/odd", :regular, 0o654},
            {"bin/lmx-release", :regular, 0o100755},
            # Extractors give directories their own umask's mode.
            {"lib/app-1.0/", :directory, 0o40775}
          ]

      assert [problem] = Lmx.Release.archive_problems(archive, "linux")
      assert problem =~ "3 files have modes install.py and the updater would extract differently"

      assert problem =~
               "lib/app-1.0/priv/odd (0654), lib/app-1.0/priv/read-only (0444), " <>
                 "lib/jsv-0.21.2/priv/grammars/email-address.abnf (0664);"

      refute problem =~ "bin/lmx-release"
      refute problem =~ "lib/app-1.0 "
      # Windows reports every writable file as 0666; nothing extracts that
      # archive into a version directory.
      assert Lmx.Release.archive_problems(archive, "windows") == []
    end

    test "reads the archive :tar wrote", %{tmp_dir: tmp} do
      release = %Mix.Release{name: :lmx, version: "0.1.0", path: tmp}

      for name <- @complete do
        File.mkdir_p!(Path.dirname(Path.join(tmp, name)))
        File.write!(Path.join(tmp, name), "x")
        # Whatever this machine's umask: the check reads modes on Unix.
        File.chmod!(Path.join(tmp, name), 0o644)
      end

      archive = Path.join(tmp, "lmx-0.1.0.tar.gz")

      entries =
        for name <- @complete -- ["NOTICE"], do: {~c"#{name}", ~c"#{Path.join(tmp, name)}"}

      :ok = :erl_tar.create(~c"#{archive}", entries, [:compressed])

      assert_raise Mix.Error, ~r/NOTICE is missing/, fn -> Lmx.Release.check_archive(release) end

      entries = for name <- @complete, do: {~c"#{name}", ~c"#{Path.join(tmp, name)}"}
      :ok = :erl_tar.create(~c"#{archive}", entries, [:compressed])
      assert Lmx.Release.check_archive(release) == release
    end

    # A Hex package's 0664 grammar reached every archive: nothing changed
    # the modes the release tree had before `:tar`.
    @tag :unix
    test "normalized modes pass the check a group-writable tree fails", %{tmp_dir: tmp} do
      root = Path.join(tmp, "release")
      release = %Mix.Release{name: :lmx, version: "0.1.0", path: root}

      modes = %{
        "LICENSE" => 0o644,
        "NOTICE" => 0o600,
        "THIRD_PARTY_NOTICES" => 0o664,
        "bin/lmx" => 0o775,
        "releases/0.1.0/lmx.rel" => 0o444,
        "lib/ex_cmd-0.18.0/priv/odu_darwin_arm64" => 0o755,
        "lib/jsv-0.21.2/priv/grammars/email-address.abnf" => 0o664
      }

      for {name, mode} <- modes do
        File.mkdir_p!(Path.dirname(Path.join(root, name)))
        File.write!(Path.join(root, name), "x")
        File.chmod!(Path.join(root, name), mode)
      end

      # A link is never followed: its target may be outside the release.
      outside = Path.join(tmp, "outside")
      File.write!(outside, "not part of the release")
      File.chmod!(outside, 0o664)
      File.ln_s!(outside, Path.join(root, "lib/outside-link"))

      tar = fn ->
        tops = [
          "LICENSE",
          "NOTICE",
          "THIRD_PARTY_NOTICES",
          "bin",
          "releases",
          "lib/ex_cmd-0.18.0",
          "lib/jsv-0.21.2"
        ]

        files = for top <- tops, do: {~c"#{top}", ~c"#{Path.join(root, top)}"}
        :ok = :erl_tar.create(~c"#{Path.join(root, "lmx-0.1.0.tar.gz")}", files, [:compressed])
      end

      tar.()
      error = assert_raise Mix.Error, fn -> Lmx.Release.check_archive(release) end
      assert error.message =~ "lib/jsv-0.21.2/priv/grammars/email-address.abnf (0664)"
      assert error.message =~ "releases/0.1.0/lmx.rel (0444)"

      assert Lmx.Release.normalize_modes(root) == :ok
      mode = &Bitwise.band(File.lstat!(Path.join(root, &1)).mode, 0o7777)

      assert Map.new(modes, fn {name, _mode} -> {name, mode.(name)} end) == %{
               "LICENSE" => 0o644,
               "NOTICE" => 0o600,
               "THIRD_PARTY_NOTICES" => 0o644,
               "bin/lmx" => 0o755,
               "releases/0.1.0/lmx.rel" => 0o644,
               "lib/ex_cmd-0.18.0/priv/odu_darwin_arm64" => 0o755,
               "lib/jsv-0.21.2/priv/grammars/email-address.abnf" => 0o644
             }

      assert Bitwise.band(File.stat!(outside).mode, 0o7777) == 0o664

      tar.()
      assert Lmx.Release.check_archive(release) == release
    end
  end

  defp entries(names), do: Enum.map(names, &{&1, :regular, 0o644})

  # Mix's own bin/lmx and bin/lmx.bat for this Elixir, as `mix release`
  # writes them. Rendering the real templates keeps these tests honest about
  # the text the rewrites must find.
  defp stock_bin(tmp) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "lmx"), render_stock(Init.cli_text()))
    File.write!(Path.join(bin, "lmx.bat"), render_stock(Init.cli_bat_text()))
    bin
  end

  defp render_stock(template) do
    template
    |> String.replace(~r/<%= release_mode\(@release, "([^"]+)"\) %>/, "-mode \\1")
    |> EEx.eval_string(assigns: [release: %Mix.Release{name: :lmx, options: []}])
  end

  defp executable?(path), do: Bitwise.band(File.stat!(path).mode, 0o111) == 0o111

  defp occurrences(text, pattern), do: text |> :binary.matches(pattern) |> length()

  defp fake_release_root(tmp) do
    root = Path.join(tmp, "release")
    stock_bin(root)
    Lmx.Release.write_launchers(Path.join(root, "bin"), "macos_silicon")
    version = Path.join(root, "releases/0.1.0")
    File.mkdir_p!(version)
    File.write!(Path.join(root, "releases/start_erl.data"), "17.0.2 0.1.0\n")
    File.write!(Path.join(version, "env.sh"), "")
    File.write!(Path.join(version, "sys.config"), "[].\n")
    File.write!(Path.join(version, "elixir"), ~s|#!/bin/sh\nprintf '%s ' "$@"\n|)
    File.chmod!(Path.join(version, "elixir"), 0o755)
    root
  end

  defp release_cmd(root, env) do
    env = [{"RELEASE_DISTRIBUTION", nil}, {"RELEASE_COOKIE", nil}, {"LMX_ARGV_FILE", nil} | env]

    System.cmd(Path.join(root, "bin/lmx-release"), ["start"],
      env: Enum.uniq_by(Enum.reverse(env), &elem(&1, 0)),
      stderr_to_stdout: true
    )
  end

  defp forecastle_env_sh do
    :forecastle
    |> :code.priv_dir()
    |> Path.join("env.sh.eex")
    |> EEx.eval_file(release: %Mix.Release{name: :lmx})
  end

  defp sourced_heart(tmp, fragment, env \\ []) do
    version = Path.join(tmp, "releases/0.1.0")
    File.mkdir_p!(version)
    File.write!(Path.join(tmp, "releases/RELEASES"), "[].\n")
    File.write!(Path.join(version, "env.sh"), fragment)

    script =
      ~s|set -e\n. "$REL_VSN_DIR/env.sh"\n| <>
        ~s|printf '%s\|%s\|%s' "${ELIXIR_ERL_OPTIONS-}" "${HEART_NO_KILL-}" "${HEART_BEAT_TIMEOUT-}"|

    base = [
      {"RELEASE_COMMAND", "start"},
      {"RELEASE_ROOT", tmp},
      {"REL_VSN_DIR", version},
      {"ELIXIR_ERL_OPTIONS", nil},
      {"HEART_NO_KILL", nil},
      {"HEART_BEAT_TIMEOUT", nil},
      {"HEART_COMMAND", nil}
    ]

    {output, 0} =
      System.cmd("sh", ["-c", script], env: Enum.uniq_by(env ++ base, &elem(&1, 0)))

    output
  end
end
