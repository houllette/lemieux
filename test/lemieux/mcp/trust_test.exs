defmodule Lemieux.MCP.TrustTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Trust

  @moduletag :tmp_dir

  @servers [
    %{
      "name" => "github",
      "transport" => "stdio",
      "command" => "npx",
      "args" => ["-y", "server-github"],
      "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"},
      "source" => "project"
    },
    %{
      "name" => "docs",
      "transport" => "http",
      "url" => "https://docs.example/mcp",
      "headers" => %{"authorization" => "Bearer ${DOCS_KEY:-none}"}
    }
  ]

  setup %{tmp_dir: dir} do
    %{store: Path.join(dir, "store"), workspace: Path.join(dir, "repo")}
  end

  test "servers nobody decided about are untrusted", %{store: store, workspace: workspace} do
    assert Trust.status(store, workspace, @servers) == :untrusted
    assert Trust.allowed_env(store, workspace, @servers) == []
  end

  test "trusting them is remembered, with the variables they read", context do
    assert :ok = Trust.record(context.store, context.workspace, @servers, :trusted)

    assert Trust.status(context.store, context.workspace, @servers) == :trusted

    assert Trust.allowed_env(context.store, context.workspace, @servers) == [
             "DOCS_KEY",
             "GITHUB_TOKEN"
           ]
  end

  test "the store is private to its owner", context do
    :ok = Trust.record(context.store, context.workspace, @servers, :trusted)

    %File.Stat{mode: mode} = File.stat!(Path.join(context.store, "trusted-mcp.json"))
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "a declined decision is remembered as denied", context do
    :ok = Trust.record(context.store, context.workspace, @servers, :denied)

    assert Trust.status(context.store, context.workspace, @servers) == :denied
    assert Trust.allowed_env(context.store, context.workspace, @servers) == []
  end

  test "a changed command asks again, and allows nothing meanwhile", context do
    :ok = Trust.record(context.store, context.workspace, @servers, :trusted)

    changed = List.update_at(@servers, 0, &Map.put(&1, "command", "curl"))

    assert Trust.status(context.store, context.workspace, changed) == :changed
    assert Trust.allowed_env(context.store, context.workspace, changed) == []
  end

  test "order, key order and where a server was read from do not change the digest" do
    [first, second] = @servers
    reordered = [second, Map.new(Enum.reverse(Map.to_list(Map.delete(first, "source"))))]

    assert Trust.digest(reordered) == Trust.digest(@servers)
    refute Trust.digest([first]) == Trust.digest(@servers)
  end

  test "a decision belongs to one workspace", context do
    :ok = Trust.record(context.store, context.workspace, @servers, :trusted)

    assert Trust.status(context.store, context.workspace <> "-other", @servers) == :untrusted
    assert :ok = Trust.forget(context.store, context.workspace)
    assert Trust.status(context.store, context.workspace, @servers) == :untrusted
  end

  test "an unreadable store asks again rather than failing", context do
    File.mkdir_p!(context.store)
    File.write!(Path.join(context.store, "trusted-mcp.json"), "{not json")

    assert Trust.status(context.store, context.workspace, @servers) == :untrusted
    assert :ok = Trust.record(context.store, context.workspace, @servers, :trusted)
    assert Trust.status(context.store, context.workspace, @servers) == :trusted
  end

  test "describe shows what runs, where it connects and which variables it reads" do
    assert [github, docs] = Trust.describe(@servers)

    assert github == %{
             name: "github",
             transport: "stdio",
             command: "npx -y server-github",
             url: nil,
             env: ["GITHUB_TOKEN"]
           }

    assert docs.transport == "http"
    assert docs.url == "https://docs.example/mcp"
    assert docs.env == ["DOCS_KEY"]
  end
end
