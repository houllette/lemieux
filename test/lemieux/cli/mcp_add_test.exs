defmodule Lemieux.CLI.MCPAddTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Lemieux.CLI
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo with spaces")
    cwd = Path.join(root, "nested")
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(cwd)
    config = Path.join(dir, "personal.json")
    File.write!(config, JSON.encode!(%{"version" => 1, "model" => "test:model"}))
    File.chmod!(config, 0o600)
    %{root: root, cwd: cwd, config: config}
  end

  defp run(ctx, args),
    do: CLI.run(["mcp", "add", "--config", ctx.config, "--non-interactive" | args], cwd: ctx.cwd)

  test "global HTTP add preserves settings and uses secret references", ctx do
    output =
      capture_io(fn ->
        assert :ok =
                 run(ctx, [
                   "--global",
                   "--transport",
                   "http",
                   "--header",
                   "Authorization=Bearer private-token",
                   "linear",
                   "https://mcp.linear.app/mcp"
                 ])
      end)

    settings = JSON.decode!(File.read!(ctx.config))
    assert settings["model"] == "test:model"
    assert settings["mcp_servers"]["linear"]["url"] == "https://mcp.linear.app/mcp"

    assert settings["mcp_servers"]["linear"]["headers"]["Authorization"] ==
             "Bearer ${MCP_LINEAR_AUTHORIZATION}"

    assert output =~ "global"
    assert output =~ ctx.config
    refute output =~ "private-token"
    refute File.exists?(Path.join(ctx.root, ".mcp.json"))
    assert Bitwise.band(File.stat!(ctx.config).mode, 0o777) == 0o600
  end

  test "local stdio add uses repository root and preserves arguments and unrelated entries",
       ctx do
    local = Path.join(ctx.root, ".mcp.json")

    File.write!(
      local,
      JSON.encode!(%{
        "metadata" => "keep",
        "mcpServers" => %{"existing" => %{"command" => "keep"}}
      })
    )

    original = File.read!(ctx.config)

    capture_io(fn ->
      assert :ok =
               run(ctx, [
                 "--local",
                 "--env",
                 "ACCESS_TOKEN=${MY_TOKEN}",
                 "tracker",
                 "--",
                 "/path with spaces/tracker",
                 "--stdio",
                 "an argument",
                 "--local"
               ])
    end)

    document = JSON.decode!(File.read!(local))
    assert document["metadata"] == "keep"
    assert document["mcpServers"]["existing"] == %{"command" => "keep"}
    assert document["mcpServers"]["tracker"]["args"] == ["--stdio", "an argument", "--local"]
    assert document["mcpServers"]["tracker"]["command"] == "/path with spaces/tracker"
    assert document["mcpServers"]["tracker"]["env"] == %{"ACCESS_TOKEN" => "${MY_TOKEN}"}
    assert File.read!(ctx.config) == original
  end

  test "duplicate names require explicit replacement", ctx do
    capture_io(fn -> assert :ok = run(ctx, ["--global", "docs", "https://one.test/mcp"]) end)
    before = File.read!(ctx.config)

    capture_io(:stderr, fn ->
      assert capture_io(fn ->
               assert {:error, 1} = run(ctx, ["--global", "docs", "https://two.test/mcp"])
             end) == ""
    end)

    assert File.read!(ctx.config) == before

    capture_io(fn ->
      assert :ok = run(ctx, ["--global", "--replace", "docs", "https://two.test/mcp"])
    end)

    assert JSON.decode!(File.read!(ctx.config))["mcp_servers"]["docs"]["url"] ==
             "https://two.test/mcp"
  end

  test "piped stdin never connects even when stdout is a terminal", ctx do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(
                   [
                     "mcp",
                     "add",
                     "--global",
                     "--config",
                     ctx.config,
                     "piped",
                     "http://127.0.0.1:1/mcp"
                   ],
                   cwd: ctx.cwd,
                   interactive?: true,
                   stdin_terminal?: false
                 )
      end)

    assert output =~ "connection not attempted"
    assert JSON.decode!(File.read!(ctx.config))["mcp_servers"]["piped"]
  end

  test "invalid descriptors and scope conflicts write nothing and never echo values", ctx do
    before = File.read!(ctx.config)

    for args <- [
          ["--global", "--local", "x", "https://x.test"],
          ["x", "https://x.test"],
          ["--global", "x", "not-a-url-private-value"],
          ["--local", "--transport", "bogus", "x", "private-value"],
          ["--local", "--env", "private-value", "x", "--", "cat"],
          ["--local", "--env", "bad name=private-value", "x", "--", "cat"],
          ["--global", "--header", "X-Test=private-value\r\ninjected", "x", "https://x.test"]
        ] do
      output = capture_io(:stderr, fn -> assert {:error, 1} = run(ctx, args) end)
      refute output =~ "private-value"
      assert File.read!(ctx.config) == before
      refute File.exists?(Path.join(ctx.root, ".mcp.json"))
    end
  end
end
