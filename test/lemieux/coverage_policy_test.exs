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
    Lemieux.Learning.Extension.Consumer,
    LemieuxTest.A2AAgent,
    LemieuxTest.HTTPAgent
  ]

  @support_modules [Lemieux.TUI.TestSupport, Lemieux.TestSupport.HarnessLearningFixtures]

  @derived_modules [
    Inspect.Lemieux.A2A.Server.State,
    Inspect.Lemieux.A2A.PeerTool,
    Inspect.Lemieux.CLI.Config,
    Inspect.Lemieux.CLI.ProviderMux,
    Inspect.Lemieux.Extensions.Web.Brave,
    Inspect.Lemieux.Ixway,
    Inspect.Lemieux.Learning.Builder.Workflow,
    Inspect.Lemieux.Providers.ReqLLM.State,
    Inspect.LemieuxTest.StaticRoute
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
    Lemieux.MCP.Client,
    Lemieux.Clock.System,
    Lemieux.OpenTelemetry.OTelAdapter,
    Lemieux.Learning.Extension.Build,
    Lemieux.Learning.Extension.Confirmation,
    Mix.Tasks.Lemieux.Discovery,
    Mix.Tasks.Lemieux.Discovery.Cycle,
    Mix.Tasks.Lemieux.Extension.Confirm,
    Lemieux.Subagent,
    Lemieux.Tools.Bash,
    Lemieux.TUI,
    Lemieux.TUI.Window
  ]

  test "coverage has an explicit exclusion ledger and retains product decisions" do
    coverage = Keyword.fetch!(Mix.Project.config(), :test_coverage)
    ignored = Keyword.fetch!(coverage, :ignore_modules)

    assert length(ignored) == 21
    assert Enum.all?(@topology_modules, &ignored?(&1, ignored))
    assert Enum.all?(@support_modules ++ @derived_modules, &ignored?(&1, ignored))
    refute Enum.any?(@critical_modules, &ignored?(&1, ignored))
    assert Keyword.fetch!(coverage, :summary) == [threshold: 85]
  end

  test "support exclusions come from test scaffolding, not library files" do
    for module <- @support_modules do
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
      assert String.starts_with?(source, Path.expand("test/support") <> "/")
    end
  end

  test "every other compiled library module remains in the coverage denominator" do
    ignored =
      Mix.Project.config() |> Keyword.fetch!(:test_coverage) |> Keyword.fetch!(:ignore_modules)

    reviewed = @topology_modules ++ @derived_modules
    library = Path.expand("lib") <> "/"
    assert {:ok, modules} = :application.get_key(:lemieux, :modules)

    for module <- modules do
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()

      if String.starts_with?(source, library) and module not in reviewed do
        refute ignored?(module, ignored),
               "#{inspect(module)} is product code, not a reviewed exclusion"
      end
    end
  end

  test "generated exclusions are Inspect implementations of the reviewed structs" do
    for module <- @derived_modules do
      assert module.__impl__(:protocol) == Inspect
      assert inspect(module) == "Inspect." <> inspect(module.__impl__(:for))
    end
  end

  defp ignored?(module, ignored) do
    Enum.any?(ignored, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      exact -> exact == module
    end)
  end
end
