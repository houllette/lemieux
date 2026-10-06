defmodule Lemieux.CLI.UpdateTest do
  # `lmx update`, end to end through the router, against host maps that stand
  # in for the installed host's callbacks (`Lmx.Update.host/1`), the way the
  # terminal UI's `/update` is tested (`Lemieux.TUI.UpdatesTest`). Nothing
  # here reaches the network or reads a config file.
  #
  # Not async: one test sets `LMX_CONFIG` to show the command never reads it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Lemieux.CLI

  @moduletag :tmp_dir

  @releases "https://github.com/houllette/lemieux/releases"

  defp update(argv, host) do
    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn -> send(self(), {:result, CLI.run(argv, updates: host)}) end)

        send(self(), {:stderr, stderr})
      end)

    assert_received {:result, result}
    assert_received {:stderr, stderr}
    %{result: result, stdout: stdout, stderr: stderr}
  end

  # The installed host's shape, with every step that must not run failing
  # the test if it does.
  defp host(overrides) do
    Map.merge(
      %{
        check: fn -> :current end,
        stage: fn _info -> flunk("nothing should have been staged") end,
        apply: fn _staged, _tui -> flunk("nothing should have been activated") end,
        tasks: nil,
        auto?: false
      },
      Map.new(overrides)
    )
  end

  test "says so and succeeds when lmx is up to date" do
    result = update(["update"], host(check: fn -> :current end))

    assert result.result == :ok
    assert result.stdout =~ "Checking #{@releases}"
    assert result.stdout =~ "lmx v#{Lemieux.version()} is up to date."
    assert result.stderr == ""
  end

  test "installs a verified newer release for the next launch and says a running screen keeps its version" do
    owner = self()
    info = %{"version" => "9.9.9", "signed_manifest" => %{"manifest" => "{}", "signature" => "x"}}

    host =
      host(
        check: fn -> {:ok, info} end,
        stage: fn ^info ->
          send(owner, :staged)
          {:ok, %{info: info, directory: "/versions/9.9.9", payload: []}}
        end,
        apply: fn %{info: ^info}, tui when is_pid(tui) ->
          send(owner, :applied)
          {:ok, :restart}
        end
      )

    result = update(["update"], host)

    assert result.result == :ok
    assert_received :staged
    assert_received :applied
    assert result.stdout =~ "Downloading lmx v9.9.9"
    assert result.stdout =~ "lmx v9.9.9 is installed. It runs the next time you start lmx"
    assert result.stdout =~ "keeps running v#{Lemieux.version()} until you restart it"
  end

  test "--check reports an available release without staging it" do
    result = update(["update", "--check"], host(check: fn -> {:ok, %{"version" => "9.9.9"}} end))

    assert result.result == :ok
    assert result.stdout =~ "lmx v9.9.9 is available. Run lmx update to install it."
  end

  # The config file is unreadable by design: a mistake in it must not keep a
  # person from updating to the release that reads it (issues #3 and #5).
  test "the installed host's factory gets an empty extension selection, and the config file is never read",
       %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    File.write!(path, "{not json")
    previous = System.get_env("LMX_CONFIG")
    System.put_env("LMX_CONFIG", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("LMX_CONFIG", previous),
        else: System.delete_env("LMX_CONFIG")
    end)

    owner = self()

    factory = fn options ->
      send(owner, {:options, options})
      host(check: fn -> :current end)
    end

    result = update(["update"], factory)

    assert result.result == :ok
    assert_received {:options, %{extensions: []}}
    assert result.stdout =~ "is up to date"
    assert result.stderr == ""
  end

  test "a newer release that cannot be verified is reported, in the host's words, and not installed" do
    host =
      host(
        check: fn -> {:unverified, "9.9.9", :signature_missing} end,
        unverified_notice: fn "9.9.9", :signature_missing -> "v9.9.9 is not signed yet" end
      )

    result = update(["update"], host)

    assert result.result == {:error, 1}
    assert result.stderr =~ "lmx update: v9.9.9 is not signed yet"
  end

  test "an lmx nothing installed says how to update instead" do
    result = update(["update"], fn _options -> nil end)

    assert result.result == {:error, 1}
    assert result.stderr =~ "lmx update: This lmx was not installed by install.sh"
    assert result.stderr =~ @releases
  end

  test "a host that only checks says where to download, and an installer that cannot install says so" do
    checks_only =
      host(
        install?: false,
        check: fn -> {:ok, %{"version" => "9.9.9"}} end,
        stage: nil,
        apply: nil
      )

    result = update(["update"], checks_only)
    assert result.result == :ok

    assert result.stdout =~
             "lmx v9.9.9 is available. This lmx can check for updates but not install them"

    manual =
      host(
        check: fn -> {:ok, %{"version" => "9.9.9"}} end,
        stage: fn _ -> {:error, :manual_install} end
      )

    result = update(["update"], manual)
    assert result.result == {:error, 1}
    assert result.stderr =~ "Download lmx v9.9.9 from #{@releases}"
    assert result.stderr =~ "install.sh"
  end

  test "a check that cannot reach the releases fails and says so" do
    result = update(["update"], host(check: fn -> {:error, :update_unavailable} end))

    assert result.result == {:error, 1}

    assert result.stderr =~
             "lmx update: The update check is unavailable: lmx could not reach #{@releases}"
  end

  test "another session's newer installation, or one that supersedes this one, is success" do
    result = update(["update"], host(check: fn -> {:installed, "9.9.9"} end))
    assert result.result == :ok

    assert result.stdout =~
             "lmx v9.9.9 is already installed; it runs the next time you start lmx."

    superseded =
      host(
        check: fn -> {:ok, %{"version" => "9.9.9"}} end,
        stage: fn info -> {:ok, %{info: info}} end,
        apply: fn _staged, _tui -> {:error, :superseded_update} end
      )

    result = update(["update"], superseded)
    assert result.result == :ok
    assert result.stdout =~ "A newer update is already installed by another session"
  end

  test "an installation that fails names the reason, in the host's words when it has them" do
    failing =
      host(
        check: fn -> {:ok, %{"version" => "9.9.9"}} end,
        stage: fn info -> {:ok, %{info: info}} end,
        apply: fn _staged, _tui -> {:error, :update_in_progress} end
      )

    result = update(["update"], failing)
    assert result.result == {:error, 1}
    assert result.stderr =~ "lmx update: Another lmx is installing an update"

    worded =
      host(
        check: fn -> {:ok, %{"version" => "9.9.9"}} end,
        stage: fn _info -> {:error, :unsigned_update} end,
        error_notice: fn :unsigned_update -> "no verified signature" end
      )

    result = update(["update"], worded)
    assert result.result == {:error, 1}
    assert result.stderr =~ "lmx update: no verified signature"
  end

  test "an unknown option or argument is a usage error" do
    result = update(["update", "--now"], host([]))
    assert result.result == {:error, 2}
    assert result.stderr =~ "lmx update: unrecognised option --now"
    assert result.stderr =~ "usage: lmx update [--check]"

    result = update(["update", "now"], host([]))
    assert result.result == {:error, 2}
    assert result.stderr =~ "unrecognised argument now"
  end

  test "lmx update --help prints its topic" do
    stdout = capture_io(fn -> assert :ok = CLI.run(["update", "--help"], updates: host([])) end)
    assert stdout =~ "Usage: lmx update [--check]"
    assert stdout =~ "--replace is only for installing over an lmx it did not write"
  end
end
