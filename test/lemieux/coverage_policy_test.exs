defmodule Lemieux.CoveragePolicyTest do
  use ExUnit.Case, async: true

  @topology_modules [
    Lemieux.A2A.Transport.Distribution,
    Lemieux.CLI.TUI,
    Lemieux.Eval.Attach,
    Lemieux.Eval.Runner,
    Mix.Tasks.Lemieux.Eval,
    Mix.Tasks.Lemieux.Eval.Bless,
    Mix.Tasks.Lmx,
    Mix.Tasks.Lmx.Tui,
    LemieuxTest.A2AAgent,
    LemieuxTest.HTTPAgent
  ]

  @critical_modules [
    Lemieux.A2A.Server,
    Lemieux.A2A.Skill,
    Lemieux,
    Lemieux.Session,
    Lemieux.Turn,
    Lemieux.Transcript,
    Lemieux.Store.JSONL,
    Lemieux.Hooks,
    Lemieux.MCP,
    Lemieux.Subagent,
    Lemieux.Tools.Bash,
    Lemieux.TUI,
    Lemieux.TUI.Window
  ]

  test "excludes only topology and optional dispatcher modules from coverage" do
    coverage = Keyword.fetch!(Mix.Project.config(), :test_coverage)
    ignored = Keyword.fetch!(coverage, :ignore_modules)

    assert length(ignored) == 9
    assert Enum.all?(@topology_modules, &ignored?(&1, ignored))
    refute Enum.any?(@critical_modules, &ignored?(&1, ignored))
    assert Keyword.fetch!(coverage, :summary) == [threshold: 80]
  end

  defp ignored?(module, ignored) do
    Enum.any?(ignored, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      exact -> exact == module
    end)
  end
end
