defmodule Lemieux.CLI.MCPImportTest do
  @moduledoc """
  `lmx mcp import claude` copies the person's own servers, not one project's.
  A Claude Code local-scope server — `claude mcp add`'s default, one
  project's, often holding its credentials — once became a server every
  session started in every repository.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.MCP.Config, as: MCPConfig

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    project = Path.join(dir, "project-a")
    File.mkdir_p!(home)
    File.mkdir_p!(project)

    File.write!(
      Path.join(home, ".claude.json"),
      JSON.encode!(%{
        "mcpServers" => %{"user-docs" => %{"type" => "stdio", "command" => "docs-server"}},
        "projects" => %{
          project => %{
            "mcpServers" => %{
              "proja-prod-db" => %{
                "command" => "db-server",
                "env" => %{"DATABASE_URL" => "postgres://prod"}
              }
            }
          }
        }
      })
    )

    config = Path.join(dir, "config.json")
    File.write!(config, JSON.encode!(%{"version" => 1}))
    File.chmod!(config, 0o600)

    %{home: home, project: project, config: config}
  end

  test "imports the user's servers and names the project's it left out", ctx do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["mcp", "import", "claude", "--config", ctx.config],
                   cwd: ctx.project,
                   home: ctx.home
                 )
      end)

    servers = JSON.decode!(File.read!(ctx.config))["mcp_servers"]
    assert Map.keys(servers) == ["user-docs"]
    refute File.read!(ctx.config) =~ "postgres://prod"

    assert output =~ "Imported 1 server(s) from claude: user-docs"
    assert output =~ "Not imported, local to #{ctx.project} in Claude Code: proja-prod-db"
    assert output =~ "add it to the repository's .mcp.json or pass --mcp-config"
  end

  test "says nothing more where the project has no servers of its own", ctx do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(["mcp", "import", "claude", "--config", ctx.config],
                   cwd: ctx.home,
                   home: ctx.home
                 )
      end)

    assert output =~ "Imported 1 server(s) from claude: user-docs"
    refute output =~ "Not imported"
  end

  test "the library still reads a project's effective set when asked for it", ctx do
    path = Path.join(ctx.home, ".claude.json")

    assert {:ok, [%{"name" => "proja-prod-db", "source" => "personal"}]} =
             MCPConfig.claude_code_local(path, ctx.project)

    assert {:ok, []} = MCPConfig.claude_code_local(path, ctx.home)

    assert {:ok, effective} = MCPConfig.claude_code(path, project: ctx.project)
    assert Enum.map(effective, & &1["name"]) |> Enum.sort() == ["proja-prod-db", "user-docs"]
  end
end
