defmodule Lemieux.CLI.DesktopTest do
  # `lmx desktop install | uninstall | status`, end to end against a
  # temporary data home. Nothing here reads this machine's home directory,
  # PATH, desktop or Omarchy installation: the operating system, the
  # environment, the home directory, the PATH lookup and the user id all come
  # in through options, as `Lemieux.CLI.Desktop` takes them.
  #
  # Not async: `capture_io(:stderr)` captures the VM's one standard-error
  # device, so the assertion that install writes nothing there also caught
  # another test's session banner when they ran together (CI, 2026-10-05).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Desktop

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    data = Path.join(dir, "data")
    File.mkdir_p!(home)
    lmx = executable(Path.join([dir, "path-bin", "lmx"]))

    %{
      home: home,
      data: data,
      lmx: lmx,
      entry: Path.join([data, "applications", "lemieux.desktop"]),
      icon: Path.join([data, "icons", "hicolor", "scalable", "apps", "lemieux.svg"])
    }
  end

  defp executable(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  # What `lmx desktop` sees: Linux, an ordinary user, this test's data home,
  # and a PATH holding only what `path` names.
  defp machine(context, overrides \\ []) do
    path = Keyword.get(overrides, :path, %{"lmx" => context.lmx})

    Keyword.merge(
      [
        os_type: {:unix, :linux},
        env: %{"XDG_DATA_HOME" => context.data},
        home: context.home,
        find_executable: &Map.get(path, &1),
        euid: 1000
      ],
      Keyword.delete(overrides, :path)
    )
  end

  defp desktop(argv, opts) do
    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn -> send(self(), {:status, CLI.run(["desktop" | argv], opts)}) end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:status, status}
    assert_received {:stderr, stderr}
    %{status: status, stdout: stdout, stderr: stderr}
  end

  defp keys(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{key, value}]
        _header -> []
      end
    end)
    |> Map.new()
  end

  defp shipped_icon, do: File.read!(Application.app_dir(:lemieux, "priv/desktop/lemieux.svg"))

  describe "install, on a desktop without Omarchy" do
    test "writes a managed entry that opens lmx in a terminal, in the home directory", ctx do
      result = desktop(["install"], machine(ctx))

      assert result.status == :ok
      assert result.stderr == ""
      fields = keys(ctx.entry)

      assert fields["Type"] == "Application"
      assert fields["Exec"] == "#{ctx.lmx} -C #{ctx.home}"
      assert fields["Terminal"] == "true"
      assert fields["Icon"] == ctx.icon
      assert fields["X-Lemieux-Managed"] == "true"
      assert fields["X-Lemieux-Version"] == Lemieux.version()
      refute Map.has_key?(fields, "StartupWMClass")

      assert File.read!(ctx.icon) == shipped_icon()
      assert File.stat!(ctx.entry).mode |> Bitwise.band(0o777) == 0o644
      assert File.stat!(ctx.icon).mode |> Bitwise.band(0o777) == 0o644

      assert result.stdout =~ ctx.entry
      assert result.stdout =~ "lmx desktop uninstall"
      # Written atomically: nothing but the entry is left in the directory.
      assert File.ls!(Path.dirname(ctx.entry)) == ["lemieux.desktop"]
    end

    # `omarchy-agent` starts in ~/Work, so the Omarchy entry does; a desktop
    # without Omarchy has no such convention to follow.
    test "a ~/Work directory changes nothing without Omarchy", ctx do
      File.mkdir_p!(Path.join(ctx.home, "Work"))

      assert desktop(["install"], machine(ctx)).status == :ok
      assert keys(ctx.entry)["Exec"] == "#{ctx.lmx} -C #{ctx.home}"
    end

    test "a relative XDG_DATA_HOME is ignored, as the base directory spec says", ctx do
      opts = machine(ctx, env: %{"XDG_DATA_HOME" => "relative/data"})

      assert desktop(["install"], opts).status == :ok

      assert File.regular?(
               Path.join([ctx.home, ".local", "share", "applications", "lemieux.desktop"])
             )
    end
  end

  describe "install, on Omarchy" do
    defp omarchy(ctx),
      do: %{"lmx" => ctx.lmx, "omarchy-launch-tui" => "/usr/bin/omarchy-launch-tui"}

    test "runs lmx through omarchy-launch-tui with its own app id, in ~/Work", ctx do
      work = Path.join(ctx.home, "Work")
      File.mkdir_p!(work)

      assert desktop(["install"], machine(ctx, path: omarchy(ctx))).status == :ok
      fields = keys(ctx.entry)

      assert fields["Exec"] ==
               "omarchy-launch-tui --app-id=org.omarchy.lemieux #{ctx.lmx} -C #{work}"

      assert fields["Terminal"] == "false"
      assert fields["StartupWMClass"] == "org.omarchy.lemieux"
    end

    test "starts in the home directory when there is no ~/Work", ctx do
      assert desktop(["install"], machine(ctx, path: omarchy(ctx))).status == :ok
      assert keys(ctx.entry)["Exec"] =~ ~r/ -C #{Regex.escape(ctx.home)}$/
    end

    test "--no-omarchy writes the generic entry anyway", ctx do
      File.mkdir_p!(Path.join(ctx.home, "Work"))

      assert desktop(["install", "--no-omarchy"], machine(ctx, path: omarchy(ctx))).status ==
               :ok

      assert keys(ctx.entry)["Exec"] == "#{ctx.lmx} -C #{ctx.home}"
      assert keys(ctx.entry)["Terminal"] == "true"
    end

    test "--omarchy writes the Omarchy entry where it was not detected, and says so", ctx do
      result = desktop(["install", "--omarchy"], machine(ctx))

      assert result.status == :ok
      assert keys(ctx.entry)["Exec"] =~ "omarchy-launch-tui --app-id=org.omarchy.lemieux "
      assert result.stdout =~ "omarchy-launch-tui is not on PATH"
    end
  end

  describe "the starting directory" do
    test "--directory is quoted in Exec as the Desktop Entry spec says", ctx do
      dir = Path.join(ctx.home, "My Work 100%")
      File.mkdir_p!(dir)

      assert desktop(["install", "--directory", dir], machine(ctx)).status == :ok
      exec = keys(ctx.entry)["Exec"]

      assert exec == ~s(#{ctx.lmx} -C "#{ctx.home}/My Work 100%%")
      assert Desktop.exec_arguments(exec) == [ctx.lmx, "-C", dir]

      status = desktop(["status"], machine(ctx))
      assert status.stdout =~ dir
    end

    test "a relative --directory is taken from where lmx ran", ctx do
      dir = Path.join(ctx.home, "project")
      File.mkdir_p!(dir)
      relative = Path.relative_to(dir, File.cwd!(), force: true)

      assert desktop(["install", "--directory", relative], machine(ctx)).status == :ok
      assert Desktop.exec_arguments(keys(ctx.entry)["Exec"]) == [ctx.lmx, "-C", dir]
    end

    test "a --directory that does not exist is refused and nothing is written", ctx do
      result = desktop(["install", "--directory", Path.join(ctx.home, "gone")], machine(ctx))

      assert result.status == {:error, 1}
      assert result.stderr =~ "is not a directory"
      refute File.exists?(ctx.data)
    end

    # `mix lmx` run from `dist/lmx` passes the repository root as `:cwd`,
    # the router's `-C`; a checkout must never be a launcher's workspace.
    test "-C, and the checkout root a source run passes, do not choose it", ctx do
      checkout = Path.join(ctx.home, "lemieux")
      File.mkdir_p!(checkout)

      result = desktop(["install", "-C", checkout], machine(ctx, program: "mix lmx"))

      assert result.status == :ok
      assert keys(ctx.entry)["Exec"] == "#{ctx.lmx} -C #{ctx.home}"
      assert result.stdout =~ "in #{ctx.home},"
    end
  end

  describe "Exec quoting" do
    test "plain arguments stay bare, and % is doubled even then" do
      assert Desktop.exec_quote("/home/me/.local/bin/lmx") == "/home/me/.local/bin/lmx"
      assert Desktop.exec_quote("--app-id=org.omarchy.lemieux") == "--app-id=org.omarchy.lemieux"
      assert Desktop.exec_quote("/srv/100%") == "/srv/100%%"
    end

    test "reserved characters quote the argument, and quoting's own characters are escaped" do
      assert Desktop.exec_quote("/a b") == ~s("/a b")
      assert Desktop.exec_quote("~/x") == ~s("~/x")
      assert Desktop.exec_quote("it's") == ~s("it's")
      assert Desktop.exec_quote(~s(say "hi")) == ~S("say \\"hi\\"")
      assert Desktop.exec_quote("$HOME") == ~S("\\$HOME")
      assert Desktop.exec_quote("`ls`") == ~S("\\`ls\\`")
      # A literal backslash in a quoted argument is four in the file: one
      # escape for the quoting, then each doubled by the string escapes.
      assert Desktop.exec_quote("a\\b") == ~S("a\\\\b")
      assert Desktop.exec_quote("") == ~s("")
    end

    test "every quoted argument reads back as itself" do
      arguments = [
        "/plain/path",
        "/with space/and 100%",
        "quote\"d",
        "dollar$ and `tick`",
        "back\\slash",
        "semi;colon|pipe&amp<>*?#()",
        "~tilde",
        "it's",
        "%f",
        ""
      ]

      line = Enum.map_join(arguments, " ", &Desktop.exec_quote/1)
      assert Desktop.exec_arguments(line) == arguments
    end
  end

  describe "an entry lmx did not write" do
    test "is not overwritten without --force, and the refusal says how to proceed", ctx do
      File.mkdir_p!(Path.dirname(ctx.entry))
      File.write!(ctx.entry, "[Desktop Entry]\nName=Mine\nExec=my-lemieux\n")

      result = desktop(["install"], machine(ctx))

      assert result.status == {:error, 1}
      assert result.stderr =~ "--force"
      assert File.read!(ctx.entry) =~ "Exec=my-lemieux"
      refute File.exists?(ctx.icon)

      assert desktop(["install", "--force"], machine(ctx)).status == :ok
      assert keys(ctx.entry)["X-Lemieux-Managed"] == "true"
    end

    test "one lmx wrote is replaced without asking", ctx do
      assert desktop(["install"], machine(ctx)).status == :ok
      other = Path.join(ctx.home, "elsewhere")
      File.mkdir_p!(other)

      assert desktop(["install", "--directory", other], machine(ctx)).status == :ok
      assert keys(ctx.entry)["Exec"] == "#{ctx.lmx} -C #{other}"
    end

    test "an icon that is not lmx's is kept unless --force replaces it", ctx do
      File.mkdir_p!(Path.dirname(ctx.icon))
      File.write!(ctx.icon, "<svg>mine</svg>")

      result = desktop(["install"], machine(ctx))

      assert result.status == :ok
      assert File.read!(ctx.icon) == "<svg>mine</svg>"
      assert result.stdout =~ "Kept #{ctx.icon}"

      assert desktop(["install", "--force"], machine(ctx)).status == :ok
      assert File.read!(ctx.icon) == shipped_icon()
    end
  end

  describe "uninstall" do
    test "removes the entry and the icon install wrote, and nothing else", ctx do
      settings = Path.join([ctx.home, ".lmx", "config.json"])
      File.mkdir_p!(Path.dirname(settings))
      File.write!(settings, "{}")
      assert desktop(["install"], machine(ctx)).status == :ok
      neighbour = Path.join(Path.dirname(ctx.entry), "other.desktop")
      File.write!(neighbour, "[Desktop Entry]\n")

      result = desktop(["uninstall"], machine(ctx))

      assert result.status == :ok
      refute File.exists?(ctx.entry)
      refute File.exists?(ctx.icon)
      assert File.exists?(neighbour)
      assert File.read!(settings) == "{}"
      assert File.exists?(ctx.lmx)
      assert result.stdout =~ "Removed #{ctx.entry}"
      assert result.stdout =~ "Removed #{ctx.icon}"
    end

    test "keeps an entry lmx did not write and an icon that was changed", ctx do
      assert desktop(["install"], machine(ctx)).status == :ok
      File.write!(ctx.icon, "<svg>changed</svg>")
      File.write!(ctx.entry, "[Desktop Entry]\nName=Mine\n")

      result = desktop(["uninstall"], machine(ctx))

      assert result.status == :ok
      assert File.read!(ctx.entry) == "[Desktop Entry]\nName=Mine\n"
      assert File.read!(ctx.icon) == "<svg>changed</svg>"
      assert result.stdout =~ "Kept #{ctx.entry}"
      assert result.stdout =~ "Kept #{ctx.icon}"
    end

    test "with nothing installed says so", ctx do
      result = desktop(["uninstall"], machine(ctx))

      assert result.status == :ok
      assert result.stdout =~ "nothing to remove"
    end
  end

  describe "status" do
    test "shows the entry, what it runs and where, and whether Omarchy is here", ctx do
      work = Path.join(ctx.home, "Work")
      File.mkdir_p!(work)
      path = %{"lmx" => ctx.lmx, "omarchy-launch-tui" => "/usr/bin/omarchy-launch-tui"}
      assert desktop(["install"], machine(ctx, path: path)).status == :ok

      result = desktop(["status"], machine(ctx, path: path))

      assert result.status == :ok
      assert result.stdout =~ ctx.entry
      assert result.stdout =~ "written by lmx #{Lemieux.version()}"
      assert result.stdout =~ "omarchy-launch-tui --app-id=org.omarchy.lemieux #{ctx.lmx}"
      assert result.stdout =~ "#{ctx.lmx} (present)"
      assert result.stdout =~ "#{work} (present)"
      assert result.stdout =~ "Omarchy: detected"
    end

    test "says when the executable the entry runs is gone", ctx do
      assert desktop(["install"], machine(ctx)).status == :ok
      File.rm!(ctx.lmx)

      result = desktop(["status"], machine(ctx, path: %{}))

      assert result.stdout =~ "#{ctx.lmx} (missing"
      assert result.stdout =~ "Omarchy: not detected"
    end

    test "names an entry lmx did not write as such", ctx do
      File.mkdir_p!(Path.dirname(ctx.entry))
      File.write!(ctx.entry, "[Desktop Entry]\nExec=my-lemieux --flag\n")

      result = desktop(["status"], machine(ctx))

      assert result.stdout =~ "not written by lmx"
      assert result.stdout =~ "my-lemieux --flag"
    end

    test "with no entry says how to add one", ctx do
      result = desktop(["status"], machine(ctx))

      assert result.status == :ok
      assert result.stdout =~ "lmx desktop install"
      refute File.exists?(ctx.data)
    end
  end

  describe "which lmx the entry runs" do
    test "--exec wins over everything else", ctx do
      named = executable(Path.join([ctx.home, "bin", "my-lmx"]))
      install_home = Path.join([ctx.home, "prefix", "share", "lmx"])
      executable(Path.join([ctx.home, "prefix", "bin", "lmx"]))
      env = %{"XDG_DATA_HOME" => ctx.data, "LMX_INSTALL_HOME" => install_home}

      assert desktop(["install", "--exec", named], machine(ctx, env: env)).status == :ok
      assert Desktop.exec_arguments(keys(ctx.entry)["Exec"]) |> hd() == named
    end

    # The launcher the installer wrote, not the release inside it: updates
    # swap `current` behind a launcher whose path stays the same.
    test "an installed release names its launcher before anything on PATH", ctx do
      install_home = Path.join([ctx.home, "prefix", "share", "lmx"])
      wrapper = executable(Path.join([ctx.home, "prefix", "bin", "lmx"]))
      env = %{"XDG_DATA_HOME" => ctx.data, "LMX_INSTALL_HOME" => install_home}

      assert desktop(["install"], machine(ctx, env: env)).status == :ok
      assert Desktop.exec_arguments(keys(ctx.entry)["Exec"]) |> hd() == wrapper
    end

    test "PATH's lmx is used when no installed launcher is known", ctx do
      install_home = Path.join([ctx.home, "no-prefix", "share", "lmx"])
      env = %{"XDG_DATA_HOME" => ctx.data, "LMX_INSTALL_HOME" => install_home}

      assert desktop(["install"], machine(ctx, env: env)).status == :ok
      assert Desktop.exec_arguments(keys(ctx.entry)["Exec"]) |> hd() == ctx.lmx
    end

    test "with no lmx anywhere, the error names --exec and nothing is written", ctx do
      result = desktop(["install"], machine(ctx, path: %{}))

      assert result.status == {:error, 1}
      assert result.stderr =~ "--exec PATH"
      refute File.exists?(ctx.data)
    end

    test "from a source checkout with no installed lmx, it says a checkout cannot be launched",
         ctx do
      result = desktop(["install"], machine(ctx, path: %{}, program: "mix lmx"))

      assert result.status == {:error, 1}
      assert result.stderr =~ "source checkout"
      assert result.stderr =~ "--exec PATH"
      refute File.exists?(ctx.data)
    end

    test "an --exec that is not an executable file is refused", ctx do
      result = desktop(["install", "--exec", Path.join(ctx.home, "nope")], machine(ctx))

      assert result.status == {:error, 1}
      assert result.stderr =~ "is not an executable file"
      refute File.exists?(ctx.data)
    end
  end

  describe "where it refuses" do
    test "on a system that is not Linux it writes nothing and exits 2", ctx do
      for argv <- [["install"], ["uninstall"], ["status"]] do
        result = desktop(argv, machine(ctx, os_type: {:unix, :darwin}))

        assert result.status == {:error, 2}
        assert result.stderr =~ "Linux"
      end

      refute File.exists?(ctx.data)
    end

    test "as root it installs only when --force says so", ctx do
      result = desktop(["install"], machine(ctx, euid: 0))

      assert result.status == {:error, 1}
      assert result.stderr =~ "root"
      refute File.exists?(ctx.data)

      assert desktop(["install", "--force"], machine(ctx, euid: 0)).status == :ok
      assert File.exists?(ctx.entry)
    end

    test "a missing or unknown subcommand, or a flag it does not take, is a usage error", ctx do
      for argv <- [[], ["frobnicate"], ["status", "--force"], ["install", "--exec"]] do
        result = desktop(argv, machine(ctx))

        assert result.status == {:error, 2}, inspect(argv)
        assert result.stderr =~ "lmx desktop", inspect(argv)
      end

      refute File.exists?(ctx.data)
    end

    test "--help prints the topic, which names every flag and fits 80 columns" do
      text = capture_io(fn -> assert CLI.run(["desktop", "--help"]) == :ok end)

      for flag <- ~w(--exec --directory --omarchy --no-omarchy --force),
          do: assert(text =~ flag)

      assert text =~ "lmx desktop uninstall"
      assert text =~ "https://hexdocs.pm/lemieux/desktop.html"

      for line <- String.split(text, "\n"),
          do: assert(String.length(line) <= 80, "longer than 80 columns: #{inspect(line)}")

      assert capture_io(fn -> CLI.run(["--help"]) end) =~ "lmx desktop install|uninstall"
    end
  end
end
