defmodule Lemieux.ExtensionToolsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extension.CLI
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Builder
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  defmodule AuditTool do
    @behaviour Lemieux.Tool
    def name, do: "audit_ports"
    def description, do: "Check a recorded list of open ports using deterministic policy."

    def schema,
      do: %{
        "type" => "object",
        "properties" => %{"ports" => %{"type" => "array", "items" => %{"type" => "integer"}}},
        "required" => ["ports"]
      }

    def run(%{"ports" => ports}, _context),
      do: {:ok, JSON.encode!(Enum.filter(ports, &(&1 in [23, 2375])))}
  end

  @moduletag :tmp_dir

  defp profile,
    do:
      Builder.profile("test:model")
      |> Map.put("tools", ["read", "audit_ports"])
      |> Profile.quota(4)

  test "only explicitly registered tools resolve; built-in collisions and unknown modules fail" do
    assert {:error, :invalid_session_profile} = Profile.validate(profile())
    assert :ok = Profile.validate(profile(), tool_registry: [AuditTool])

    assert {:ok, opts} =
             Profile.session_options(profile(), Scripted.new([]), tool_registry: [AuditTool])

    assert opts[:tools] == [Lemieux.Tools.Read, AuditTool]

    assert {:error, _} =
             Profile.session_options(profile(), Scripted.new([]),
               tool_registry: [AuditTool, AuditTool]
             )

    assert {:error, _} =
             Profile.session_options(profile(), Scripted.new([]),
               tool_registry: [Lemieux.Tools.Read]
             )

    assert {:error, _} = Profile.validate(profile(), tool_registry: [__MODULE__.Missing])
  end

  test "compiled extension tools are identical across CLI modes and Agent configuration", %{
    tmp_dir: root
  } do
    provider = Scripted.new([])
    {:ok, options} = Options.parse([])

    host = [
      extension_profile: profile(),
      tool_registry: [AuditTool],
      provider: provider,
      cwd: root
    ]

    # One profile extension leaves the experience; each host equips it the
    # way it equips any new session, so the headless catalog is the profile's
    # and an attached host adds only the question tool.
    assert {:ok, prepared_options, prepared} = ExtensionExperience.prepare(options, host)
    assert prepared_options.model == "test:model"
    assert {Profile, _opts} = prepared[:profile]

    assert {:ok, headless} = Runtime.standard_tools(options, prepared)
    assert headless == [Lemieux.Tools.Read, AuditTool]

    assert {:ok, attached} =
             Runtime.standard_tools(options, Keyword.put(prepared, :interactive?, true))

    assert attached == headless ++ [Lemieux.Tools.AskUser]

    assert {:ok, agent_opts, _} =
             Profile.configure(profile(), provider: provider, tool_registry: [AuditTool])

    assert agent_opts[:session_options][:tools] == headless
    {:ok, conflicting} = Options.parse(["--model", "test:other"])
    assert {:error, _} = ExtensionExperience.prepare(conflicting, host)
  end

  test "extension CLI executes a packaged deterministic tool through the ordinary loop", %{
    tmp_dir: root
  } do
    provider =
      Scripted.new([
        Scripted.tool_call("ports", "audit_ports", %{"ports" => [22, 23, 443]}),
        Scripted.complete("Port 23 needs review")
      ])

    runtime = :"extension_tools_#{System.unique_integer([:positive])}"

    opts = [
      tool_registry: [AuditTool],
      provider: provider,
      supervisor: runtime,
      store: JSONL.new(root),
      cwd: root
    ]

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert :ok = CLI.run(profile(), ["run", "Review these ports"], opts)
        end)
      end)

    assert output =~ "Port 23 needs review"
    [_first, second] = Scripted.requests(provider)
    result = Enum.find(second.entries, &(&1.type == :tool_result))
    assert result.payload["name"] == "audit_ports"
    assert result.payload["output"] == "[23]"
    refute result.payload["error"]
  end
end
