defmodule Lemieux.Extensions.MCPDiscoveryTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.MCPDiscovery
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @moduletag :tmp_dir
  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  test "discovery exposes selected schemas and executes with the real remote identity", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    parent = self()

    audit = fn call, ctx ->
      send(parent, {:policy, call.name, ctx.tool_descriptor["origin"]["type"]})
      :allow
    end

    harness = MCPDiscovery.apply(%Harness{tools: [], hooks: [before_tool_call: audit]}, [])

    provider =
      Scripted.new([
        call("mcp_discover", %{"action" => "search", "query" => "echo"}),
        call("fixture__echo", %{"text" => "not enabled"}),
        call("mcp_discover", %{"action" => "enable", "names" => ["fixture__echo"]}),
        call("fixture__echo", %{"text" => "hello"}),
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        model: "test:mcp",
        harness: harness,
        subscriber: self(),
        store: JSONL.new(dir),
        mcp_servers: [
          %{
            "name" => "fixture",
            "transport" => "stdio",
            "command" => "python3",
            "args" => [@fixture, "modern"]
          }
        ]
      )

    :ok = Session.prompt(session, "go")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000
    [first, _, _, selected, final] = Scripted.requests(provider)
    assert Enum.map(first.tools, &Tool.name/1) == ["mcp_discover"]
    assert Enum.map(selected.tools, &Tool.name/1) == ["mcp_discover", "fixture__echo"]
    results = Enum.filter(final.entries, &(&1.type == :tool_result))

    assert Enum.any?(
             results,
             &(&1.payload["name"] == "fixture__echo" and &1.payload["error"] == true)
           )

    successful = List.last(results)
    assert successful.payload["name"] == "fixture__echo"
    assert successful.payload["output"] =~ "hello"
    assert successful.payload["descriptor_digest"]
    assert_receive {:policy, "fixture__echo", "mcp"}
    [discovery] = harness.tools
    request = %{selected | tools: Session.catalog(session)}

    assert {:ok, stale} =
             MCPDiscovery.prepare(%{discovery | binding: "new-auth-binding"}, request, %{
               session: session
             })

    refute Enum.any?(stale.tools, &(Tool.name(&1) == "fixture__echo"))
    remote = Enum.find(Session.catalog(session), &(Tool.name(&1) == "fixture__echo"))
    descriptor = Tool.descriptor(remote)

    assert {:deny, _} =
             MCPDiscovery.authorize(discovery, %{}, %{
               session: session,
               tool_descriptor: Descriptor.to_map(%{descriptor | digest: "changed-schema"})
             })
  end

  describe "the automatic mode" do
    test "below the threshold offers every schema and leaves discovery out", %{tmp_dir: dir} do
      harness = MCPDiscovery.apply(%Harness{tools: []}, mode: :auto, threshold_bytes: 100_000)

      provider =
        Scripted.new([call("fixture__echo", %{"text" => "direct"}), Scripted.complete("done")])

      session = session_with(harness, provider, dir, runtime())
      :ok = Session.prompt(session, "go")
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

      [first, final] = Scripted.requests(provider)
      names = Enum.map(first.tools, &Tool.name/1)
      assert "fixture__echo" in names
      refute "mcp_discover" in names

      result = Enum.find(final.entries, &(&1.type == :tool_result))
      assert result.payload["output"] =~ "direct"
      refute result.payload["error"]
    end

    test "above the threshold hides schemas behind discovery", %{tmp_dir: dir} do
      harness = MCPDiscovery.apply(%Harness{tools: []}, mode: :auto, threshold_bytes: 10)
      provider = Scripted.new([Scripted.complete("done")])

      session = session_with(harness, provider, dir, runtime())
      :ok = Session.prompt(session, "go")
      id = Session.id(session)
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

      [first] = Scripted.requests(provider)
      assert Enum.map(first.tools, &Tool.name/1) == ["mcp_discover"]
    end

    test "off adds nothing, and a context window sets the threshold" do
      assert MCPDiscovery.apply(%Harness{tools: []}, mode: :off) == %Harness{tools: []}

      harness = MCPDiscovery.apply(%Harness{tools: []}, mode: :auto, context_window: 200_000)
      assert [%MCPDiscovery{mode: :auto, threshold_bytes: 80_000}] = harness.tools

      assert_raise ArgumentError, fn ->
        MCPDiscovery.apply(%Harness{tools: []}, mode: :sometimes)
      end
    end
  end

  defp session_with(harness, provider, dir, runtime) do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        model: "test:mcp",
        harness: harness,
        subscriber: self(),
        store: JSONL.new(dir),
        mcp_servers: [
          %{
            "name" => "fixture",
            "transport" => "stdio",
            "command" => "python3",
            "args" => [@fixture, "modern"]
          }
        ]
      )

    session
  end

  defp runtime do
    runtime = Module.concat(__MODULE__, "Auto#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    runtime
  end

  defp call(name, args),
    do: [
      {:tool_call, %{id: Lemieux.ID.generate(), name: name, arguments: args}},
      {:done, :tool_calls}
    ]
end
