defmodule Lemieux.Extensions.MCPTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.MCP
  alias Lemieux.Harness
  alias Lemieux.MCP.Trust

  @moduletag :tmp_dir

  @servers ~s|{"mcpServers": {"tidewave": {"type": "http", "url": "http://localhost:4000/mcp"}}}|

  test "appends the servers a named file declares", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "servers.json")
    File.write!(path, @servers)

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, files: [path]}])

    assert [%{"name" => "tidewave", "transport" => "http", "source" => "explicit"}] =
             harness.mcp_servers

    # Announced before it starts, like a stdio server: an HTTP server receives
    # whatever headers its configuration writes. The host, not the URL.
    assert [notice] = harness.notices
    assert notice =~ "HTTP MCP servers from #{path} connect to: tidewave (localhost)"

    assert [
             %{
               "module" => "Lemieux.Extensions.MCP",
               "options" => %{"files" => [^path], "servers" => ["tidewave"]}
             }
           ] =
             harness.applied
  end

  test "adds the repository's own .mcp.json for a project directory", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.write!(Path.join(tmp_dir, ".mcp.json"), @servers)
    nested = Path.join(tmp_dir, "lib/deep")
    File.mkdir_p!(nested)

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, project: nested}])

    assert [%{"name" => "tidewave", "source" => "project"}] = harness.mcp_servers
    assert [notice] = harness.notices
    assert notice =~ "tidewave (localhost)"
  end

  test "a configured stdio server retains a specific command notice", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "servers.json")
    File.write!(path, ~s({"mcpServers":{"shell":{"command":"local-server"}}}))

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, files: [path]}])

    assert [%{"name" => "shell", "transport" => "stdio"}] = harness.mcp_servers
    assert [notice] = harness.notices
    assert notice =~ "execute commands: shell"
  end

  test "a repository without one adds nothing, and leaves recorded servers alone", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    recorded = [%{"name" => "kept", "transport" => "http", "url" => "http://kept"}]

    assert {:ok, harness} =
             Harness.assemble(Harness.new(mcp_servers: recorded), [{MCP, project: tmp_dir}])

    assert harness.mcp_servers == recorded

    assert {:ok, untouched} = Harness.assemble(Harness.new(), [{MCP, project: tmp_dir}])
    assert untouched.mcp_servers == nil
  end

  # A malformed file is something to tell the person, not a reason the session
  # cannot start: failing would make an unfamiliar checkout's broken
  # `.mcp.json` a reason lmx will not open at all.
  test "a file that cannot be read is a notice, and the session still starts", %{tmp_dir: tmp_dir} do
    broken = Path.join(tmp_dir, "broken.json")
    File.write!(broken, "{not json")
    good = Path.join(tmp_dir, "good.json")
    File.write!(good, @servers)

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, files: [broken, good]}])

    assert [%{"name" => "tidewave"}] = harness.mcp_servers
    assert [notice, _announcement] = harness.notices
    assert notice =~ "broken.json"
  end

  describe "a repository's servers, with a trust store" do
    setup %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))

      File.write!(
        Path.join(tmp_dir, ".mcp.json"),
        ~s({"mcpServers":{"shell":{"command":"local-server"}}})
      )

      %{store: Path.join(tmp_dir, "store")}
    end

    test "are held back until a person trusts them", %{tmp_dir: tmp_dir, store: store} do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [{MCP, project: tmp_dir, trust: store}])

      assert harness.mcp_servers == nil
      assert [notice] = harness.notices
      assert notice =~ "were not started because they have not been reviewed: shell"

      assert [%{"options" => %{"held" => ["shell"]}}] = harness.applied

      assert %{status: :untrusted, workspace: workspace, servers: servers, description: [shown]} =
               MCP.project_trust(tmp_dir, store)

      assert shown.command == "local-server"

      :ok = Trust.record(store, workspace, servers, :trusted)

      assert MCP.project_trust(tmp_dir, store) == nil

      assert {:ok, trusted} =
               Harness.assemble(Harness.new(), [{MCP, project: tmp_dir, trust: store}])

      assert [%{"name" => "shell"}] = trusted.mcp_servers
      # The prompt that recorded the review showed the command; a notice on
      # every launch after that repeats what the person already approved.
      assert trusted.notices == []
    end

    test "a declined repository says so, and asking once is enough", %{
      tmp_dir: tmp_dir,
      store: store
    } do
      %{workspace: workspace, servers: servers} = MCP.project_trust(tmp_dir, store)
      :ok = Trust.record(store, workspace, servers, :denied)

      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [{MCP, project: tmp_dir, trust: store}])

      assert [notice] = harness.notices
      assert notice =~ "you declined them"
      assert %{status: :denied} = MCP.project_trust(tmp_dir, store)
    end

    test "trusted? skips the question for one run", %{tmp_dir: tmp_dir, store: store} do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [
                 {MCP, project: tmp_dir, trust: store, trusted?: true}
               ])

      assert [%{"name" => "shell"}] = harness.mcp_servers
      assert %{status: :untrusted} = MCP.project_trust(tmp_dir, store)
      # Nothing showed the person what starts, so the notice still says it.
      assert [notice] = harness.notices
      assert notice =~ "execute commands: shell"
    end

    test "a server the person configured wins over the repository's of the same name", %{
      tmp_dir: tmp_dir,
      store: store
    } do
      mine = [%{"name" => "shell", "url" => "http://127.0.0.1:9999/mcp"}]

      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [
                 {MCP, servers: mine, project: tmp_dir, trust: store}
               ])

      # One server by that name, the person's, and nothing held back or asked.
      assert [%{"name" => "shell", "source" => "personal", "transport" => "http"}] =
               harness.mcp_servers

      assert harness.notices == []
      assert [%{"options" => options}] = harness.applied
      assert Map.get(options, "held", []) == []
      assert MCP.project_trust(tmp_dir, store, except: ["shell"]) == nil
    end

    test "the trust prompt asks only about the servers nobody else claimed", %{
      tmp_dir: tmp_dir,
      store: store
    } do
      File.write!(
        Path.join(tmp_dir, ".mcp.json"),
        ~s({"mcpServers":{"shell":{"command":"local-server"},"docs":{"command":"docs-server"}}})
      )

      assert %{servers: [%{"name" => "docs"}], status: :untrusted} =
               MCP.project_trust(tmp_dir, store, except: ["shell"])

      %{workspace: workspace, servers: asked} =
        MCP.project_trust(tmp_dir, store, except: ["shell"])

      :ok = Trust.record(store, workspace, asked, :trusted)

      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [
                 {MCP,
                  servers: [%{"name" => "shell", "url" => "http://127.0.0.1:1/mcp"}],
                  project: tmp_dir,
                  trust: store}
               ])

      assert harness.mcp_servers |> Enum.map(& &1["name"]) |> Enum.sort() == ["docs", "shell"]
      assert harness.notices == []
    end
  end

  test "a host's own servers are added as personal", %{tmp_dir: _tmp_dir} do
    servers = [%{"name" => "mine", "url" => "https://mine.example/mcp"}]

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, servers: servers}])

    assert [%{"name" => "mine", "transport" => "http", "source" => "personal"}] =
             harness.mcp_servers
  end

  test "a file named for the run is used over the person's own server of the same name", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "servers.json")
    File.write!(path, ~s({"mcpServers":{"github":{"url":"https://run.example/mcp"}}}))
    mine = [%{"name" => "github", "url" => "https://mine.example/mcp"}]

    assert {:ok, harness} = Harness.assemble(Harness.new(), [{MCP, files: [path], servers: mine}])

    assert [%{"name" => "github", "url" => "https://run.example/mcp", "source" => "explicit"}] =
             harness.mcp_servers

    assert ("Two MCP servers are named github; the one from a file named for this run is " <>
              "used, and the one from your own settings is left out.") in harness.notices
  end

  # A plugin declaring `github` beside the person's own `github` used to be
  # one name for two servers, and the session kept the plugin's — the last
  # appended — without a word. The plugin's server is named for its plugin,
  # as Claude Code names it, so both run.
  test "a plugin's server beside the person's own of the same name: both, under two names", %{
    tmp_dir: tmp_dir
  } do
    plugin = Path.join(tmp_dir, "tools")
    File.mkdir_p!(plugin)

    File.write!(
      Path.join(plugin, ".mcp.json"),
      ~s({"mcpServers":{"github":{"url":"https://plugin.example/mcp"}}})
    )

    mine = [%{"name" => "github", "url" => "https://mine.example/mcp"}]

    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [
               {MCP, servers: mine},
               {Lemieux.Extensions.Workspace,
                cwd: tmp_dir, plugin_dirs: [plugin], personal?: false, bundled_skills?: false}
             ])

    assert [
             %{"name" => "github", "url" => "https://mine.example/mcp", "source" => "personal"},
             %{"name" => "plugin_tools_github", "source" => "plugin"}
           ] = harness.mcp_servers

    refute Enum.any?(harness.notices, &(&1 =~ "Two MCP servers"))
  end
end
