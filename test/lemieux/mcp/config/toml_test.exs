defmodule Lemieux.MCP.Config.TOMLTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Config.TOML

  test "reads tables, dotted and quoted keys, and the scalar types" do
    text = """
    # A comment
    model = "gpt-5" # trailing comment
    approval = 'never'
    limit = 1_000
    ratio = 0.5
    big = 1e3
    hex = 0xff
    enabled = true
    when = 1979-05-27T07:32:00Z

    [mcp_servers.github]
    command = "npx"
    args = ["-y", "@modelcontextprotocol/server-github",]
    env = { GITHUB_TOKEN = "t\\u00e9st", "odd key" = 'raw\\n' }

    [mcp_servers."docs site".nested]
    url = "https://example.com/mcp"
    """

    assert {:ok, doc} = TOML.decode(text)

    assert doc["model"] == "gpt-5"
    assert doc["approval"] == "never"
    assert doc["limit"] == 1000
    assert doc["ratio"] == 0.5
    assert doc["big"] == 1000.0
    assert doc["hex"] == 255
    assert doc["enabled"] == true
    assert doc["when"] == "1979-05-27T07:32:00Z"

    github = doc["mcp_servers"]["github"]
    assert github["args"] == ["-y", "@modelcontextprotocol/server-github"]
    assert github["env"] == %{"GITHUB_TOKEN" => "tést", "odd key" => "raw\\n"}
    assert doc["mcp_servers"]["docs site"]["nested"]["url"] == "https://example.com/mcp"
  end

  test "reads multi-line strings and arrays that span lines" do
    # Built by lines: the document holds both kinds of triple quote, which no
    # Elixir heredoc delimiter can contain.
    text =
      Enum.join(
        [
          ~s(notes = """),
          "first \\",
          ~s(  second"""),
          "raw = '''",
          "kept \\n as written'''",
          "list = [",
          "  1, # one",
          "  2,",
          "]",
          ""
        ],
        "\n"
      )

    assert {:ok, doc} = TOML.decode(text)
    assert doc["notes"] == "first second"
    assert doc["raw"] == "kept \\n as written"
    assert doc["list"] == [1, 2]
  end

  test "reads arrays of tables" do
    text = """
    [[profiles]]
    name = "a"
    [[profiles]]
    name = "b"
    """

    assert {:ok, %{"profiles" => [%{"name" => "a"}, %{"name" => "b"}]}} = TOML.decode(text)
  end

  test "an unreadable line is an error naming it" do
    assert {:error, message} = TOML.decode("a = 1\nb = = 2\n")
    assert message =~ "line 2"

    assert {:error, unterminated} = TOML.decode(~s(a = "never closed\n))
    assert unterminated =~ "unterminated"
  end
end
