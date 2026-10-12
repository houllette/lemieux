defmodule Lemieux.MCP.ClientFailuresTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Client
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.MCP.Transport.Stdio

  @moduletag :tmp_dir
  @fixture Path.expand("../../fixtures/mcp_script.py", __DIR__)

  defp probe(result \\ %{"supportedVersions" => ["2026-07-28"]}) do
    %{method: "server/discover", reply: %{result: result}}
  end

  defp page(method, result, params \\ %{}),
    do: %{method: method, params: params, reply: %{result: result}}

  defp rpc_error(method, message, params \\ %{}, code \\ -32_603),
    do: %{method: method, params: params, reply: %{error: %{code: code, message: message}}}

  defp initialization(reply) do
    %{
      method: "initialize",
      params: %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "lemieux", "version" => Lemieux.version()}
      },
      reply: reply
    }
  end

  defp handshake(:discovery, reply), do: [%{method: "server/discover", reply: reply}]

  defp handshake(:initialization, reply),
    do: [rpc_error("server/discover", "method not found", %{}, -32_601), initialization(reply)]

  defp start(dir, script) do
    path = Path.join(dir, "script.json")
    journal = Path.join(dir, "requests.jsonl")
    File.write!(path, JSON.encode!(script))

    client =
      start_supervised!(
        {Client,
         server: "script",
         transport: {Stdio, %{command: "python3", args: [@fixture, path, journal]}},
         timeout: 5_000}
      )

    {client, journal}
  end

  defp requests(journal),
    do: journal |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp cursor(journal),
    do: journal |> requests() |> Enum.drop(1) |> Enum.map(&get_in(&1, ["params", "cursor"]))

  defp tool(name),
    do: %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}

  test "all tool pages are collected before names are assigned", %{tmp_dir: dir} do
    {client, journal} =
      start(dir, [
        probe(),
        page("tools/list", %{"tools" => [tool("read")], "nextCursor" => "opaque token / α"}),
        page("tools/list", %{"tools" => [tool("write")]}, %{"cursor" => "opaque token / α"})
      ])

    assert {:ok,
            [
              %RemoteTool{name: "read", client: ^client},
              %RemoteTool{name: "write", client: ^client}
            ]} = Client.list_tools(client)

    assert cursor(journal) == [nil, "opaque token / α"]
  end

  for {kind, list} <- [{:prompts, "prompts"}, {:resources, "resources"}] do
    test "#{kind} pagination preserves order and opaque cursors", %{tmp_dir: dir} do
      kind = unquote(kind)
      list = unquote(list)
      first = %{"name" => "first", "uri" => "fixture://first", "arguments" => []}
      second = %{"name" => "second", "uri" => "fixture://second", "arguments" => []}

      {client, journal} =
        start(dir, [
          probe(),
          page("#{list}/list", %{list => [first], "nextCursor" => "next"}),
          page("#{list}/list", %{list => [second]}, %{"cursor" => "next"})
        ])

      assert {:ok, [^first, ^second]} = apply(Client, :"list_#{kind}", [client])
      assert cursor(journal) == [nil, "next"]
    end
  end

  for cursors <- [["A", "A"], ["A", "B", "A"]] do
    test "repeated pagination cursors #{inspect(cursors)} fail without returning a partial catalog",
         %{tmp_dir: dir} do
      cursors = unquote(cursors)

      {steps, _last} =
        Enum.map_reduce(cursors, nil, fn next, previous ->
          params = if previous, do: %{"cursor" => previous}, else: %{}

          {page("tools/list", %{"tools" => [tool("partial")], "nextCursor" => next}, params),
           next}
        end)

      {client, journal} = start(dir, [probe() | steps])

      assert {:error, "the server repeated a pagination cursor"} = Client.list_tools(client)
      assert length(requests(journal)) == 1 + length(cursors)
      assert Client.info(client).ready?
    end
  end

  test "a later-page error discards partial tools and a new listing can recover", %{tmp_dir: dir} do
    {client, journal} =
      start(dir, [
        probe(),
        page("tools/list", %{"tools" => [tool("partial")], "nextCursor" => "next"}),
        rpc_error("tools/list", "page unavailable", %{"cursor" => "next"}),
        page("tools/list", %{"tools" => [tool("recovered")]})
      ])

    assert {:error, "page unavailable"} = Client.list_tools(client)
    assert {:ok, [%RemoteTool{name: "recovered"}]} = Client.list_tools(client)
    assert cursor(journal) == [nil, "next", nil]
    assert Client.info(client).ready?
  end

  test "an unreadable tool listing is an error and does not poison the next listing", %{
    tmp_dir: dir
  } do
    {client, _journal} =
      start(dir, [
        probe(),
        page("tools/list", "not an object"),
        page("tools/list", %{"tools" => [tool("ok")]})
      ])

    assert {:error, message} = Client.list_tools(client)
    assert message =~ "unreadable response"
    assert {:ok, [%RemoteTool{name: "ok"}]} = Client.list_tools(client)
  end

  test "method-not-found lists are empty, while other RPC failures remain errors", %{tmp_dir: dir} do
    {client, journal} =
      start(dir, [
        probe(),
        rpc_error("prompts/list", "no prompts", %{}, -32_601),
        rpc_error("resources/list", "resource access denied")
      ])

    assert Client.list_prompts(client) == {:ok, []}
    assert Client.list_resources(client) == {:error, "resource access denied"}
    assert length(requests(journal)) == 3
  end

  test "prompt and resource reads report RPC and malformed replies without crashing", %{
    tmp_dir: dir
  } do
    {client, journal} =
      start(dir, [
        probe(),
        rpc_error("prompts/get", "unknown prompt", %{"name" => "missing", "arguments" => %{}}),
        page("resources/read", ["not an object"], %{"uri" => "fixture://bad"}),
        page("resources/read", %{"contents" => [%{"text" => "recovered"}]}, %{
          "uri" => "fixture://ok"
        })
      ])

    assert Client.get_prompt(client, "missing") == {:error, "unknown prompt"}
    assert {:error, message} = Client.read_resource(client, "fixture://bad")
    assert message =~ "unreadable response"

    assert Client.read_resource(client, "fixture://ok") ==
             {:ok, %{"contents" => [%{"text" => "recovered"}]}}

    assert length(requests(journal)) == 4
  end

  test "a failed legacy initialization remains unavailable and never lists tools", %{tmp_dir: dir} do
    {client, journal} =
      start(dir, [
        rpc_error("server/discover", "method not found", %{}, -32_601),
        initialization(%{error: %{code: -32_603, message: "initialization denied"}})
      ])

    info = Client.info(client)
    refute info.ready?
    assert info.failure == "the server refused to initialize: initialization denied"
    assert Client.list_tools(client) == {:error, info.failure}
    assert Enum.map(requests(journal), & &1["method"]) == ["server/discover", "initialize"]
    assert Process.alive?(client)
  end

  for phase <- [:discovery, :initialization],
      {label, reply} <- [
        {"non-object result", %{result: "invalid"}},
        {"non-object error", %{error: "invalid"}},
        {"missing result/error", %{}}
      ] do
    test "#{phase} with #{label} fails gracefully instead of crashing the client", %{tmp_dir: dir} do
      {client, _journal} = start(dir, handshake(unquote(phase), unquote(Macro.escape(reply))))

      info = Client.info(client)
      refute info.ready?
      assert info.failure =~ "unreadable response"
      assert Client.list_tools(client) == {:error, info.failure}
      assert Process.alive?(client)
    end
  end

  test "a discovery without versions uses the requested version and skips undeclared lists", %{
    tmp_dir: dir
  } do
    {client, journal} =
      start(dir, [probe(%{"capabilities" => %{}}), page("tools/list", %{"tools" => []})])

    assert %{version: "2026-07-28", ready?: true} = Client.info(client)
    assert Client.list_prompts(client) == {:ok, []}
    assert Client.list_resources(client) == {:ok, []}
    assert Client.list_tools(client) == {:ok, []}
    assert [_, listing] = requests(journal)

    assert get_in(listing, ["params", "_meta", "io.modelcontextprotocol/protocolVersion"]) ==
             "2026-07-28"
  end

  test "an unsupported-version error can negotiate a version the server actually supports", %{
    tmp_dir: dir
  } do
    {client, _journal} =
      start(dir, [
        %{
          method: "server/discover",
          reply: %{
            error: %{
              code: -32_022,
              message: "unsupported version",
              data: %{supported: ["2026-07-28"]}
            }
          }
        },
        page("tools/list", %{"tools" => []})
      ])

    assert %{era: :modern, version: "2026-07-28", ready?: true} = Client.info(client)
    assert Client.list_tools(client) == {:ok, []}
  end

  for {label, data} <- [
        {"empty versions", %{supported: []}},
        {"non-list versions", %{supported: "2026-07-28"}},
        {"missing versions", nil},
        {"non-object data", "invalid"}
      ] do
    test "an unsupported-version error with #{label} cannot accept the rejected version", %{
      tmp_dir: dir
    } do
      {client, _journal} =
        start(dir, [
          %{
            method: "server/discover",
            reply: %{
              error: %{
                code: -32_022,
                message: "unsupported version",
                data: unquote(Macro.escape(data))
              }
            }
          }
        ])

      info = Client.info(client)
      refute info.ready?
      assert info.failure =~ "no protocol version in common"
      assert Client.list_tools(client) == {:error, info.failure}
      assert Process.alive?(client)
    end
  end

  test "a lost connection during legacy initialization remains unavailable", %{tmp_dir: dir} do
    script = [
      rpc_error("server/discover", "method not found", %{}, -32_601),
      initialization(%{}) |> Map.put(:close, true)
    ]

    {client, journal} = start(dir, script)

    info = Client.info(client)
    refute info.ready?
    assert info.failure =~ "python3"
    assert Client.list_tools(client) == {:error, info.failure}
    assert Enum.map(requests(journal), & &1["method"]) == ["server/discover", "initialize"]
  end

  test "a disconnected resource read is an error rather than a dead client", %{tmp_dir: dir} do
    {client, _journal} =
      start(dir, [
        probe(),
        %{method: "resources/read", params: %{"uri" => "fixture://gone"}, close: true}
      ])

    assert {:error, message} = Client.read_resource(client, "fixture://gone")
    assert message =~ "python3"
    refute Client.info(client).ready?
    assert Process.alive?(client)
  end
end
