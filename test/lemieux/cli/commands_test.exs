defmodule Lemieux.CLI.CommandsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Models

  @moduletag :tmp_dir

  defp config(dir, settings \\ %{}) do
    path = Path.join(dir, "config.json")
    File.write!(path, JSON.encode!(Map.put(settings, "version", 1)))
    File.chmod!(path, 0o600)
    path
  end

  describe "-C / --cwd" do
    test "runs a command as if started in the directory", %{tmp_dir: dir} do
      caller = self()
      runner = fn argv, opts -> send(caller, {:tui, argv, opts[:cwd]}) end

      assert CLI.run(["-C", dir, "--model", "x:y"], tui_runner: runner) ==
               {:tui, ["--model", "x:y"], dir}

      assert CLI.run(["--cwd=#{dir}"], tui_runner: runner) == {:tui, [], dir}
    end

    # A usage error, so `lmx run`'s documented status 2, not 1 (a failed answer).
    test "a directory that does not exist is refused as a usage error", %{tmp_dir: dir} do
      stderr =
        capture_io(:stderr, fn ->
          assert {:error, 2} = CLI.run(["-C", Path.join(dir, "missing")])
          assert {:error, 2} = CLI.run(["run", "--cwd=#{Path.join(dir, "missing")}", "hi"])
          assert {:error, 2} = CLI.run(["run", "hi", "-C"])
        end)

      assert stderr =~ "is not a directory"
      assert stderr =~ "missing value for -C"
    end
  end

  describe "help" do
    test "names its topics and prints one" do
      assert capture_io(fn -> CLI.run(["help"]) end) =~ "Topics: lmx help config | models"
      assert capture_io(fn -> CLI.run(["help", "permissions"]) end) =~ "accept_edits"
      assert capture_io(fn -> CLI.run(["mcp", "--help"]) end) =~ "lmx mcp trust"
      assert capture_io(:stderr, fn -> CLI.run(["help", "nope"]) end) =~ "topics:"
    end

    test "the models topic renders the table the code picks from" do
      text = capture_io(fn -> CLI.run(["help", "models"]) end)

      for row <- Models.recommended(), do: assert(text =~ row.model)
    end
  end

  describe "lmx plugin" do
    test "install saves a local plugin, list shows it, remove forgets it", %{tmp_dir: dir} do
      path = config(dir)
      plugin = Path.join(dir, "my-plugin")
      File.mkdir_p!(Path.join(plugin, ".claude-plugin"))
      File.write!(Path.join([plugin, ".claude-plugin", "plugin.json"]), ~s({"name":"my-plugin"}))

      assert capture_io(fn ->
               assert :ok = CLI.run(["plugin", "install", plugin, "--config", path])
             end) =~
               "Installed my-plugin"

      assert JSON.decode!(File.read!(path))["plugin_dirs"] == [plugin]
      assert capture_io(fn -> CLI.run(["plugin", "list", "--config", path]) end) =~ "my-plugin"

      capture_io(fn ->
        assert :ok = CLI.run(["plugin", "remove", "my-plugin", "--config", path])
      end)

      assert JSON.decode!(File.read!(path))["plugin_dirs"] == []
    end

    test "a Git URL is cloned under the state directory, never run", %{tmp_dir: dir} do
      path = config(dir)
      caller = self()

      git = fn args, _opts ->
        target = List.last(args)
        File.mkdir_p!(target)
        send(caller, {:git, args})
        :ok
      end

      capture_io(fn ->
        CLI.run(["plugin", "install", "https://example.com/org/tool.git", "--config", path],
          git: git
        )
      end)

      assert_received {:git, ["clone", "--depth", "1", "--quiet", "--", _url, target]}
      assert target == Path.join([dir, "plugins", "tool"])
    end
  end

  describe "lmx extension" do
    test "new writes a script extension that list then reports", %{tmp_dir: dir} do
      root = Path.join(dir, "extensions")

      assert capture_io(fn ->
               assert :ok = CLI.run(["extension", "new", "hello"], extensions_dir: root)
             end) =~
               "--extension hello"

      assert capture_io(fn -> CLI.run(["extension", "list"], extensions_dir: root) end) =~
               "hello · script · loads"
    end
  end

  describe "lmx mcp" do
    setup %{tmp_dir: dir} do
      repo = Path.join(dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))

      File.write!(
        Path.join(repo, ".mcp.json"),
        ~s({"mcpServers":{"docs":{"type":"http","url":"https://docs.example/mcp"}}})
      )

      %{repo: repo, path: config(dir)}
    end

    test "trust shows what it would trust and records only with --yes", ctx do
      out = capture_io(fn -> CLI.run(["mcp", "trust", "--config", ctx.path], cwd: ctx.repo) end)
      assert out =~ "docs (http): https://docs.example/mcp"
      assert out =~ "Nothing recorded"

      assert capture_io(fn -> CLI.run(["mcp", "list", "--config", ctx.path], cwd: ctx.repo) end) =~
               "untrusted"

      capture_io(fn ->
        CLI.run(["mcp", "trust", "--yes", "--config", ctx.path], cwd: ctx.repo)
      end)

      assert capture_io(fn -> CLI.run(["mcp", "list", "--config", ctx.path], cwd: ctx.repo) end) =~
               "trusted"
    end

    # A session replaces a repository server that shares a name with one of
    # your own, and gates only the rest; a decision is one digest over the
    # servers asked about. Recorded over the whole file, it never matched the
    # session's set: `docs` stayed held as "changed" on every start.
    test "a server of your own replaces the repository's of the same name", ctx do
      File.write!(
        Path.join(ctx.repo, ".mcp.json"),
        ~s({"mcpServers":{"docs":{"type":"http","url":"https://docs.example/mcp"},) <>
          ~s("search":{"command":"their-search"}}})
      )

      path =
        config(Path.dirname(ctx.path), %{
          "mcp_servers" => %{"search" => %{"command" => "my-search"}}
        })

      listed = capture_io(fn -> CLI.run(["mcp", "list", "--config", path], cwd: ctx.repo) end)
      assert listed =~ "docs (untrusted) · replaced by your own: search"

      asked =
        capture_io(fn -> CLI.run(["mcp", "trust", "--yes", "--config", path], cwd: ctx.repo) end)

      assert asked =~ "docs (http): https://docs.example/mcp"
      refute asked =~ "their-search"
      assert asked =~ "replaced by your own: search"

      mine = [%{"name" => "search", "command" => "my-search"}]

      assert {:ok, harness} =
               Lemieux.Harness.assemble(Lemieux.Harness.new(), [
                 {Lemieux.Extensions.MCP,
                  servers: mine, project: ctx.repo, trust: Path.dirname(path)}
               ])

      assert harness.mcp_servers |> Enum.map(& &1["name"]) |> Enum.sort() == ["docs", "search"]
    end

    test "a file whose servers are all replaced has nothing to trust", ctx do
      path =
        config(Path.dirname(ctx.path), %{
          "mcp_servers" => %{"docs" => %{"url" => "https://mine.example/mcp"}}
        })

      assert capture_io(fn -> CLI.run(["mcp", "list", "--config", path], cwd: ctx.repo) end) =~
               "nothing of its own to start · replaced by your own: docs"

      assert capture_io(fn -> CLI.run(["mcp", "trust", "--config", path], cwd: ctx.repo) end) =~
               "Nothing to trust"
    end

    test "import copies Claude Code's servers into the config", ctx do
      home = Path.join(Path.dirname(ctx.path), "home")
      File.mkdir_p!(home)

      File.write!(
        Path.join(home, ".claude.json"),
        ~s({"mcpServers":{"search":{"type":"stdio","command":"search-server"}}})
      )

      capture_io(fn ->
        assert :ok =
                 CLI.run(["mcp", "import", "claude", "--config", ctx.path],
                   cwd: ctx.repo,
                   home: home
                 )
      end)

      assert %{"search" => %{"type" => "stdio", "command" => "search-server"}} =
               JSON.decode!(File.read!(ctx.path))["mcp_servers"]
    end
  end
end
