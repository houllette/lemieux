defmodule Lemieux.A2A.PeerToolTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{Config, Options, Runtime}
  alias Lemieux.Conversation.Command.A2A, as: A2ACommand
  alias Lemieux.Extensions.A2A, as: A2AExtension
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.{Session, Tool}
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  defp fixture do
    File.read!("test/fixtures/a2a/task.json") |> JSON.decode!()
  end

  defp endpoint do
    parent = self()

    LemieuxTest.HTTPAgent.start(fn _path, body, headers ->
      send(parent, {:headers, headers})
      request = JSON.decode!(body)
      {200, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"task" => fixture()}}}
    end)
  end

  test "peer allowlists, call bounds and untrusted results are enforced" do
    peers = %{"backend" => %{"url" => endpoint()}}
    {:ok, state} = A2AExtension.init(peers: peers, max_calls: 1)
    tool = state.tool
    assert {:error, error} = Tool.invoke(tool, %{"peer" => "invented", "message" => "hello"}, %{})
    assert error =~ "allowlist"
    assert {:ok, result} = Tool.invoke(tool, %{"peer" => "backend", "message" => "hello"}, %{})
    assert result.structured_content["id"] == "independent-task"
    assert result.metadata == %{"peer" => "backend", "untrusted" => true}
    assert result.model_text =~ "Untrusted peer result"
    assert result.cost == nil
    assert {:error, error} = Tool.invoke(tool, %{"peer" => "backend", "message" => "again"}, %{})
    assert error =~ "allowance"
    refute Tool.read_only?(tool)
    assert Tool.schema(tool)["properties"]["peer"]["enum"] == ["backend"]
    refute inspect(tool) =~ peers["backend"]["url"]
  end

  test "credentials are resolved at use and excluded from descriptor provenance" do
    # Fixture credential lives in the environment only for this process-independent
    # test name, avoiding mutation of a real host credential.
    env = "LMX_A2A_FIXTURE_#{System.unique_integer([:positive])}"
    System.put_env(env, "fixture-token")
    on_exit(fn -> System.delete_env(env) end)

    {:ok, state} =
      A2AExtension.init(peers: %{"backend" => %{"url" => endpoint(), "bearer_env" => env}})

    assert {:ok, _} = Tool.invoke(state.tool, %{"peer" => "backend", "message" => "hello"}, %{})
    assert_receive {:headers, headers}
    assert headers["authorization"] == "Bearer fixture-token"
    descriptor = Tool.Descriptor.new(state.tool) |> Tool.Descriptor.to_map() |> JSON.encode!()
    refute descriptor =~ "fixture-token"
    refute descriptor =~ env
    assert A2AExtension.describe(state)["peers"] == ["backend"]
  end

  test "a fresh CLI session equips configured peers and runs the ordinary tool pipeline", %{
    tmp_dir: dir
  } do
    config = Path.join(dir, "config.json")

    File.write!(
      config,
      JSON.encode!(%{"version" => 1, "a2a_peers" => %{"backend" => %{"url" => endpoint()}}})
    )

    File.chmod!(config, 0o600)
    {:ok, options} = Options.parse(["--config", config, "--no-delegate"])
    runtime = :"a2a_cli_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    provider =
      Scripted.new([
        Scripted.tool_call("peer-call", "ask_agent", %{"peer" => "backend", "message" => "hello"}),
        Scripted.complete("Reviewed peer evidence")
      ])

    {:ok, prepared} =
      Runtime.prepare(options, provider: provider, supervisor: runtime, store: JSONL.new(dir))

    assert A2ACommand in prepared.harness.commands
    assert Enum.any?(prepared.harness.tools || [], &(Tool.name(&1) == "ask_agent"))
    assert {:ok, session} = Runtime.start(prepared)
    :ok = Session.prompt(session, "Ask the backend")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [request, followup] = Scripted.requests(provider)
    assert Enum.any?(request.tools, &(Tool.name(&1) == "ask_agent"))

    assert Enum.any?(
             followup.entries,
             &(&1.type == :tool_result and &1.payload["output"] =~ "Independent response")
           )

    refute Process.whereis(Lemieux.A2A.Server)
  end

  test "CLI configuration validates endpoints and can disable the opt-in recipe", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "a2a_peers" => %{"bad" => %{"url" => "https://user:secret@example.org"}}
      })
    )

    assert {:error, error} = Config.load(path)
    refute error =~ "secret"

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "a2a_peers" => %{"backend" => %{"url" => "https://example.org/rpc"}},
        "disabled_extensions" => ["a2a"]
      })
    )

    {:ok, options} = Options.parse(["--config", path, "--no-delegate"])
    {:ok, prepared} = Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(dir))
    refute Enum.any?(prepared.harness.tools || [], &(Tool.name(&1) == "ask_agent"))
    assert {:error, _} = A2AExtension.validate(%{"bad" => %{"url" => "http://host:bad"}})
  end

  test "extension application is pure and /a2a uses the ordinary prompt workflow" do
    {:ok, state} =
      A2AExtension.init(
        peers: %{"backend" => %{"url" => "https://example.org/rpc"}},
        commands: [A2ACommand]
      )

    first = A2AExtension.apply(%Harness{}, state)
    second = A2AExtension.apply(first, state)
    assert first == second
    assert A2ACommand.parse("", %{}) == [:a2a_status]
    assert [{:prompt, prompt}] = A2ACommand.parse("ask backend where is auth?", %{busy?: false})
    assert prompt =~ "ask_agent"
    assert prompt =~ "where is auth?"
    assert [{:say, _}] = A2ACommand.parse("ask backend question", %{busy?: true})
  end
end
