defmodule Lemieux.Environment.SandboxPathsTest do
  # What `lmx --sandbox` hides: the library's fixed list under the home
  # directory, plus every place this run's options say lmx keeps a secret.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Runtime.SecretPaths
  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  import Bitwise

  @moduletag :tmp_dir

  @seatbelt? :os.type() == {:unix, :darwin} and System.find_executable("sandbox-exec") != nil

  @root? (case System.find_executable("id") do
            nil -> false
            id -> match?({"0\n", 0}, System.cmd(id, ["-u"]))
          end)

  test "the library's own credential store is hidden by default, beside lmx's" do
    hidden = Sandbox.default_hidden("/home/someone")

    assert "/home/someone/.lemieux" in hidden
    assert "/home/someone/.lmx" in hidden
    assert "/home/someone/.ssh" in hidden
    assert Sandbox.default_hidden(nil) == []
  end

  describe "the locations an lmx run keeps secrets in" do
    setup %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(work)
      %{root: tmp_dir, work: work}
    end

    test "are the directories the options name, wherever they point", context do
      config = config_file(Path.join(context.root, "alt-lmx"))
      credentials = Path.join([context.root, "tokens", "mcp.json"])
      sessions = Path.join(context.root, "transcripts")

      options =
        [
          "--sandbox",
          "--config",
          config,
          "--credentials",
          credentials,
          "--sessions-dir",
          sessions
        ]
        |> options!()
        |> with_state(Path.dirname(config))

      paths = SecretPaths.paths(options, JSONL.new(sessions), context.work)

      # The config file's directory is also the state directory here, and
      # holds nothing but lmx's: it goes whole.
      assert real(Path.dirname(config)) in paths
      assert real(Path.dirname(credentials)) in paths
      assert real(sessions) in paths
      refute real(context.work) in paths

      # Created when absent, owner-only, so the sandbox has something to hide
      # before the first OAuth flow or the first transcript writes there.
      for created <- [Path.dirname(credentials), sessions] do
        assert File.dir?(created)

        if match?({:unix, _}, :os.type()),
          do: assert((File.stat!(created).mode &&& 0o777) == 0o700)
      end
    end

    test "never hide the working directory: a file kept there is hidden alone", context do
      config = config_file(context.work, "lmx.json")
      credentials = Path.join(context.work, "tokens.json")
      File.write!(credentials, "{}")

      options =
        options!([
          "--sandbox",
          "--config",
          config,
          "--credentials",
          credentials,
          "--sessions-dir",
          context.work
        ])

      paths = SecretPaths.paths(options, JSONL.new(context.work), context.work)

      assert real(config) in paths
      assert real(credentials) in paths
      refute real(context.work) in paths
      refute Enum.any?(paths, &String.starts_with?(real(context.work), &1 <> "/"))
    end

    test "the sessions directory is the store's, not the option's", context do
      sessions = Path.join(context.root, "the-store-dir")
      unused = Path.join(context.root, "unused")
      credentials = Path.join([context.root, "tokens", "mcp.json"])

      options =
        ["--sandbox", "--sessions-dir", unused, "--credentials", credentials]
        |> options!()
        |> without_state()

      assert real(sessions) in SecretPaths.paths(options, JSONL.new(sessions), context.work)

      # A store that is not a directory of files has no directory to hide.
      paths = SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)
      assert real(Path.dirname(credentials)) in paths
      refute real(sessions) in paths
      refute real(unused) in paths
      refute File.exists?(unused)
    end

    # The finding this answers: `--config ./config/lmx.json` hid the
    # project's config/ — config.exs and the rest — from every command, and
    # `LMX_CONFIG=~/.config/lmx.json` would have hidden git's settings.
    test "a directory with other things in it is not hidden whole, only lmx's files in it",
         context do
      shared = Path.join(context.work, "config")
      File.mkdir_p!(shared)
      File.write!(Path.join(shared, "config.exs"), "import Config\n")
      config = config_file(shared, "lmx.json")
      # The state directory is the config file's: what lmx left there before.
      File.write!(Path.join(shared, "history.jsonl"), "")
      File.mkdir_p!(Path.join(shared, "permissions"))

      options =
        [
          "--sandbox",
          "--config",
          config,
          "--credentials",
          Path.join([context.root, "tokens", "mcp.json"]),
          "--sessions-dir",
          Path.join(context.root, "sessions")
        ]
        |> options!()
        |> with_state(shared)

      paths = SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)

      refute real(shared) in paths
      assert real(config) in paths
      assert real(Path.join(shared, "history.jsonl")) in paths
      assert real(Path.join(shared, "permissions")) in paths
      refute Enum.any?(paths, &Sandbox.within?(real(Path.join(shared, "config.exs")), &1))
      refute File.exists?(Path.join(shared, "checkpoints"))
    end

    # `--config ./lmx.json` with no `LMX_HOME`: lmx's state lands in the
    # project, beside a `plugins/` that may be the project's own.
    test "a state directory that is the work gives up only what no project would name",
         context do
      config = config_file(context.work, "lmx.json")
      File.mkdir_p!(Path.join(context.work, "plugins"))
      File.write!(Path.join(context.work, "history.jsonl"), "")
      File.write!(Path.join(context.work, "trusted-mcp.json"), "{}")

      options =
        ["--sandbox", "--config", config, "--sessions-dir", Path.join(context.root, "s")]
        |> options!()
        |> with_state(context.work)

      paths = SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)

      assert real(config) in paths
      assert real(Path.join(context.work, "history.jsonl")) in paths
      assert real(Path.join(context.work, "trusted-mcp.json")) in paths
      refute real(Path.join(context.work, "plugins")) in paths
      refute real(context.work) in paths
    end

    test "a token file beside the work is created empty and private, and hidden alone",
         context do
      credentials = Path.join(context.work, "mcp-tokens.json")

      options =
        ["--sandbox", "--credentials", credentials, "--sessions-dir", context.work]
        |> options!()
        |> without_state()

      paths = SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)

      assert paths == [real(credentials)]
      assert File.read!(credentials) == "{}"

      if match?({:unix, _}, :os.type()),
        do: assert((File.stat!(credentials).mode &&& 0o777) == 0o600)
    end

    # `--credentials .` from the working directory, or `~`: the "file" is
    # the work, and its parent holds the work too.
    test "a path that is the work itself hides nothing", context do
      for named <- [context.work, System.user_home!()] do
        options =
          ["--sandbox", "--credentials", named, "--sessions-dir", context.work]
          |> options!()
          |> without_state()

        assert SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work) == []
      end
    end

    # A token file named directly under the root once made the root itself
    # the directory to hide: the whole filesystem, and a sandbox that could
    # not start without saying why. (As root the file would be created and
    # hidden alone, which is right but not for a test to do in `/`.)
    @tag skip: if(@root?, do: "root may create files in /", else: false)
    test "the root is never hidden", context do
      credentials = "/lmx-test-#{System.unique_integer([:positive])}.json"

      options =
        ["--sandbox", "--credentials", credentials, "--sessions-dir", context.work]
        |> options!()
        |> without_state()

      paths = SecretPaths.paths(options, {__MODULE__, :elsewhere}, context.work)

      refute "/" in paths
      refute File.exists?(credentials)
    end

    test "nothing is created or hidden for a run without a sandbox", context do
      sessions = Path.join(context.root, "not-created")
      options = options!(["--sessions-dir", sessions])

      assert {:ok, prepared} =
               Runtime.prepare(options,
                 provider: Scripted.new([]),
                 store: JSONL.new(sessions),
                 cwd: context.work
               )

      assert prepared.sandbox == nil
      refute File.exists?(sessions)
    end
  end

  describe "a sandboxed lmx session" do
    unless @seatbelt?, do: @describetag(skip: "requires macOS sandbox-exec")

    # The finding this answers: `--config` pointed at a file holding a saved
    # provider key, and `cat` read it from inside the sandbox because only the
    # literal ~/.lmx was hidden.
    test "cannot read a config file kept outside ~/.lmx", %{tmp_dir: root} do
      work = Path.join(root, "work")
      File.mkdir_p!(work)
      File.write!(Path.join(work, "notes.txt"), "visible\n")
      config = config_file(Path.join(root, "alt-lmx"))
      sessions = Path.join(root, "sessions")
      # Named, so building the sandbox creates nothing in the real home.
      credentials = Path.join([root, "tokens", "mcp.json"])

      options =
        options!([
          "--sandbox",
          "--config",
          config,
          "--sessions-dir",
          sessions,
          "--credentials",
          credentials
        ])

      assert {:ok, prepared} =
               Runtime.prepare(options,
                 provider: Scripted.new([]),
                 store: JSONL.new(sessions),
                 cwd: work,
                 state_dir: Path.dirname(config)
               )

      assert real(Path.dirname(config)) in prepared.sandbox["hidden"]
      assert real(sessions) in prepared.sandbox["hidden"]

      environment = prepared.harness.environment

      assert {output, status} = run(environment, "cat '#{config}'", work)
      assert status != 0, output
      refute output =~ "sk-test-not-a-real-key"

      assert {"visible\n", 0} = run(environment, "cat notes.txt", work)
    end

    # Hidden on its own, in the working directory: out of `cat`'s reach, and
    # — once found in review — still in `read`'s.
    test "cannot read a config file kept in the working directory, by command or file tool",
         %{tmp_dir: root} do
      work = Path.join(root, "work")
      config = config_file(work, "lmx.json")
      File.write!(Path.join(work, "notes.txt"), "visible\n")

      options =
        options!([
          "--sandbox",
          "--config",
          config,
          "--sessions-dir",
          Path.join(root, "sessions"),
          "--credentials",
          Path.join([root, "tokens", "mcp.json"])
        ])

      assert {:ok, prepared} =
               Runtime.prepare(options,
                 provider: Scripted.new([]),
                 store: JSONL.new(Path.join(root, "sessions")),
                 cwd: work,
                 state_dir: work
               )

      assert real(config) in prepared.sandbox["hidden"]
      refute real(work) in prepared.sandbox["hidden"]

      environment = prepared.harness.environment

      assert {output, status} = run(environment, "cat lmx.json", work)
      assert status != 0, output
      refute output =~ "sk-test-not-a-real-key"

      assert Environment.read_file(environment, work, "lmx.json") == {:error, :eacces}
      assert {:ok, "visible\n"} = Environment.read_file(environment, work, "notes.txt")
    end
  end

  defp options!(argv) do
    {:ok, options} = Options.parse(argv)
    options
  end

  # Whatever `LMX_HOME` the shell running the suite has, these runs keep no
  # state, or keep it where the test says: `LMX_HOME` would otherwise be one
  # more directory to hide, and to create.
  defp without_state(options), do: with_state(options, nil)
  defp with_state(options, dir), do: put_in(options.host.state_dir, dir)

  # An explicit --config must exist and be private, as lmx's own is.
  defp config_file(dir, name \\ "config.json") do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "providers" => %{"openai" => %{"api_key" => "sk-test-not-a-real-key"}}
      })
    )

    File.chmod!(path, 0o600)
    path
  end

  defp run(environment, command, cwd) do
    {:ok, events} = Environment.run(environment, command, cwd: cwd, timeout_ms: 15_000)

    Enum.reduce(events, {"", nil}, fn
      {:data, data}, {output, status} -> {output <> data, status}
      {:exit_status, status}, {output, _status} -> {output, status}
      other, {output, _status} -> {output, other}
    end)
  end

  defp real(path), do: Sandbox.real(path)
end
