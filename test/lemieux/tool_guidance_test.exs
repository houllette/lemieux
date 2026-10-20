defmodule Lemieux.ToolGuidanceTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.{Delegation, MCPDiscovery}
  alias Lemieux.{Harness, Prompt, Tool, Tools}

  test "shell and analysis guidance respects native tools and automatic completion" do
    bash = Tool.description(Tools.Bash) |> prose()
    assert bash =~ "prefer read for files, glob for paths and grep for content searches"
    assert bash =~ "completion is delivered without polling or another watch registration"
    assert bash =~ "Otherwise use task_id with wait_ms"
    readonly = Tool.description(Tools.ReadOnlyBash)
    assert readonly =~ "purpose summary"
    assert readonly =~ "network is disabled"
    assert readonly =~ "yield"
    assert Tool.description(Tools.Eval) |> prose() =~ "Variable bindings do not survive calls"
  end

  test "configured investigators advertise native delegation and their real analysis capability" do
    {:ok, config} = Delegation.init(model: "test:model", priced?: false)
    harness = Delegation.apply(Harness.new(), config)
    tool = Enum.find(harness.tools, &(Tool.name(&1) == "subagents"))
    description = Tool.description(tool) |> prose()
    assert description =~ "native delegation; no external agent CLI"
    assert description =~ "sandboxed read-only analysis scripts"
    assert description =~ "writers tool for host-authorized isolated implementation"

    assert tool.definitions["repository-scout"].system_prompt =~
             "yield for its result instead of polling"
  end

  test "conditional capabilities and configured MCP limits are visible in the descriptions" do
    tool = %MCPDiscovery{max_tools: 2, ttl_ms: 10_000}
    description = Tool.description(tool)
    assert description =~ "up to 2 exact names"
    assert description =~ "expires after 10000 ms"
    assert description =~ "already visible tools directly"
    assert description =~ "cannot authorize a disabled tool"
    assert Tool.description(Tools.WebFetch) |> prose() =~ "when available, use research_check"
    assert Prompt.default() |> prose() =~ "Prefer an available tool specialized for the action"
  end

  defp prose(text), do: text |> String.split() |> Enum.join(" ")
end
