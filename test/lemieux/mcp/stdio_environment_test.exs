defmodule Lemieux.MCP.StdioEnvironmentTest do
  @moduledoc """
  What a stdio server written for Claude Code finds in its environment:
  `CLAUDE_PROJECT_DIR` for every server, and a plugin's data directory made
  before the server that is told about it starts.
  """
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Transport.Stdio

  @moduletag :tmp_dir

  test "a server is told the session's directory unless its configuration says otherwise" do
    assert {:ok, %{env: env}} = Stdio.configure(%{"command" => "server"}, cwd: "/work/project")
    assert env["CLAUDE_PROJECT_DIR"] == "/work/project"

    own = %{"command" => "server", "env" => %{"CLAUDE_PROJECT_DIR" => "/elsewhere"}}
    assert {:ok, %{env: env}} = Stdio.configure(own, cwd: "/work/project")
    assert env["CLAUDE_PROJECT_DIR"] == "/elsewhere"

    assert {:ok, %{env: env}} = Stdio.configure(%{"command" => "server"}, [])
    refute Map.has_key?(env, "CLAUDE_PROJECT_DIR")
  end

  test "a plugin's data directory exists by the time its server is launched", %{tmp_dir: dir} do
    data = Path.join(dir, "plugin-data/kit")

    config = %{
      "command" => "lmx-definitely-not-a-server",
      "env" => %{"CLAUDE_PLUGIN_DATA" => data}
    }

    assert {:ok, configured} = Stdio.configure(config, cwd: dir)
    refute File.exists?(data), "configuring a server creates nothing"

    assert {:error, reason} = Stdio.connect(configured)
    assert reason =~ "there is no lmx-definitely-not-a-server"
    assert File.dir?(data)
    assert Bitwise.band(File.stat!(data).mode, 0o777) == 0o700, "a plugin keeps tokens there"
  end
end
