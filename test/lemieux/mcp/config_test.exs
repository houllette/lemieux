defmodule Lemieux.MCP.ConfigTest do
  use ExUnit.Case, async: true
  alias Lemieux.MCP.Config
  @moduletag :tmp_dir

  defp write(dir, contents) do
    path = Path.join(dir, "mcp.json")
    File.write!(path, contents)
    path
  end

  test "reads the shape other clients already use", %{tmp_dir: dir} do
    path = write(dir, ~s({"mcpServers": {"github": {"command": "npx", "args": ["-y", "srv"]}}}))

    assert {:ok, [server]} = Config.read(path)
    assert server["name"] == "github"
    assert server["transport"] == "stdio"
    assert server["command"] == "npx"
    assert server["args"] == ["-y", "srv"]
  end

  test "infers http from a url", %{tmp_dir: dir} do
    path = write(dir, ~s({"mcpServers": {"docs": {"url": "https://example.com/mcp"}}}))

    assert {:ok, [server]} = Config.read(path)
    assert server["transport"] == "http"
  end

  # The file cannot know what a host registered, so a name the library has
  # never heard of is kept for the registry to accept or refuse at connect time.
  test "keeps an explicit transport it has never heard of", %{tmp_dir: dir} do
    path =
      write(dir, ~s({"mcpServers": {"lab": {"transport": "carrier-pigeon", "coop": "north"}}}))

    assert {:ok, [server]} = Config.read(path)
    assert server["transport"] == "carrier-pigeon"
    assert server["coop"] == "north"
  end

  test "an explicit transport wins over what the keys would infer", %{tmp_dir: dir} do
    path = write(dir, ~s({"mcpServers": {"docs": {"transport": "stdio", "url": "https://x"}}}))

    assert {:ok, [%{"transport" => "stdio"}]} = Config.read(path)
  end

  test "accepts a bare object without the wrapper", %{tmp_dir: dir} do
    path = write(dir, ~s({"docs": {"url": "https://example.com/mcp"}}))

    assert {:ok, [%{"name" => "docs"}]} = Config.read(path)
  end

  test "a missing file is an error naming it", %{tmp_dir: dir} do
    assert {:error, message} = Config.read(Path.join(dir, "nope.json"))
    assert message =~ "nope.json"
  end

  test "a file that is not JSON is an error, not a crash", %{tmp_dir: dir} do
    path = write(dir, "not json")

    assert {:error, message} = Config.read(path)
    assert message =~ "not a JSON object"
  end

  test "puts one server without losing existing configuration", %{tmp_dir: dir} do
    path = write(dir, ~s({"mcpServers":{"old":{"url":"https://old.example/mcp"}},"other":true}))

    assert :ok =
             Config.put_server(path, %{
               "name" => "new",
               "transport" => "http",
               "url" => "https://new.example/mcp",
               "headers" => %{"authorization" => "Bearer ${MCP_TOKEN}"}
             })

    assert {:ok, %{"mcpServers" => servers, "other" => true}} =
             path |> File.read!() |> JSON.decode()

    assert servers["old"]["url"] == "https://old.example/mcp"
    assert servers["new"]["headers"] == %{"authorization" => "Bearer ${MCP_TOKEN}"}
    refute Map.has_key?(servers["new"], "name")
  end

  test "refuses to replace invalid JSON", %{tmp_dir: dir} do
    path = write(dir, "broken")
    assert {:error, _reason} = Config.put_server(path, %{"name" => "new", "url" => "https://x"})
    assert File.read!(path) == "broken"
  end

  describe "Claude Code's shape" do
    test "reads \"type\" as the transport, and keeps sse to be refused with directions",
         %{tmp_dir: dir} do
      path =
        write(
          dir,
          ~s({"mcpServers":{"a":{"type":"http","url":"https://a"},"b":{"type":"stdio","command":"run"},"c":{"type":"sse","url":"https://c/sse"}}})
        )

      assert {:ok, servers} = Config.read(path)
      transports = Map.new(servers, &{&1["name"], &1["transport"]})
      assert transports == %{"a" => "http", "b" => "stdio", "c" => "sse"}
    end

    test ~s(writes "type" rather than lemieux's "transport", and never the source),
         %{tmp_dir: dir} do
      path = Path.join(dir, "shared.json")

      assert :ok =
               Config.put_server(path, %{
                 "name" => "docs",
                 "transport" => "http",
                 "url" => "https://docs/mcp",
                 "source" => "personal"
               })

      assert %{"mcpServers" => %{"docs" => written}} = path |> File.read!() |> JSON.decode!()
      assert written == %{"type" => "http", "url" => "https://docs/mcp"}
    end
  end

  test "marks every server with the source it was read from", %{tmp_dir: dir} do
    path = write(dir, ~s({"mcpServers":{"a":{"url":"https://a"}}}))

    assert {:ok, [%{"source" => "project"}]} = Config.read(path, source: "project")
    assert {:ok, [server]} = Config.read(path)
    refute Map.has_key?(server, "source")
  end

  describe "importing" do
    test "Claude Code's user servers and a project's local ones", %{tmp_dir: dir} do
      project = Path.join(dir, "work")

      path =
        write(
          dir,
          JSON.encode!(%{
            "mcpServers" => %{"user" => %{"command" => "u"}, "both" => %{"command" => "user"}},
            "projects" => %{
              Path.expand(project) => %{"mcpServers" => %{"both" => %{"command" => "local"}}}
            }
          })
        )

      assert {:ok, servers} = Config.claude_code(path, project: project)
      by_name = Map.new(servers, &{&1["name"], &1})

      assert by_name["user"]["command"] == "u"
      assert by_name["both"]["command"] == "local"
      assert Enum.all?(servers, &(&1["source"] == "personal"))

      assert {:ok, only_user} = Config.claude_code(path)
      assert Enum.find(only_user, &(&1["name"] == "both"))["command"] == "user"
    end

    test "Codex's config.toml, with variables kept as references", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")

      File.write!(path, """
      model = "gpt-5"

      [mcp_servers.github]
      command = "npx"
      args = ["-y", "@modelcontextprotocol/server-github"]
      startup_timeout_sec = 20
      tool_timeout_sec = 120

      [mcp_servers.github.env]
      GITHUB_TOKEN = "${GITHUB_TOKEN}"

      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"
      bearer_token_env_var = "LINEAR_TOKEN"
      env_http_headers = { "X-Team" = "LINEAR_TEAM" }

      [mcp_servers.off]
      command = "never"
      enabled = false
      """)

      assert {:ok, [github, linear]} = Config.codex(path)

      assert github["name"] == "github"
      assert github["transport"] == "stdio"
      assert github["env"] == %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}
      assert github["startup_timeout"] == 20_000
      assert github["tool_timeout"] == 120_000

      assert linear["transport"] == "http"

      assert linear["headers"] == %{
               "authorization" => "Bearer ${LINEAR_TOKEN}",
               "X-Team" => "${LINEAR_TEAM}"
             }

      assert Enum.all?([github, linear], &(&1["source"] == "personal"))
    end

    test "a Codex file this reader cannot parse is an error, not a guess", %{tmp_dir: dir} do
      path = Path.join(dir, "config.toml")
      File.write!(path, "[mcp_servers.x]\ncommand = = 1\n")

      assert {:error, message} = Config.codex(path)
      assert message =~ "line 2"
    end
  end

  test "deletes one server while keeping unrelated config", %{tmp_dir: dir} do
    path =
      write(
        dir,
        ~s({"mcpServers":{"one":{"url":"https://one.example/mcp"},"two":{"command":"run"}},"other":true})
      )

    assert :ok = Config.delete_server(path, "one")

    assert {:ok, %{"mcpServers" => %{"two" => %{"command" => "run"}}, "other" => true}} =
             path |> File.read!() |> JSON.decode()

    assert {:error, _reason} = Config.delete_server(path, "one")
  end
end
