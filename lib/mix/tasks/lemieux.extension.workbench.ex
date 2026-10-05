defmodule Mix.Tasks.Lemieux.Extension.Workbench do
  @shortdoc "Opens the local agent extension evaluation workbench (experimental)"
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Opens a terminal workbench using a trusted Elixir configuration:

      mix lemieux.extension.workbench bench/compare.exs

  The file uses the `mix lemieux.extension.eval` configuration shape. Paths are
  relative to the current Mix project. Optional `:workbench_dir` defaults to
  `tmp/extension-workbench`; `:execution` defaults to `:live`. Live runs require
  explicit confirmation, `:cost_cap_usd` and `:max_cost_per_attempt_usd` in
  `:benchmark_options`. Declare `execution: :scripted` for offline fixtures;
  that declaration does not sandbox arbitrary configuration or extension code.

  Configuration is evaluated once at entry and must be trusted before launch.
  Use zero-arity agent option factories for fresh providers on each attempt.
  Case and variant edits are saved separately from extension source. Type `help`
  for commands. These are development comparisons, not confirmation holdouts.
  """

  use Mix.Task

  alias Lemieux.CLI.ExtensionWorkbench

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    {config, _bindings} = Code.eval_file(path)

    case ExtensionWorkbench.run(config) do
      0 -> :ok
      _status -> Mix.raise("Could not open extension workbench")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix lemieux.extension.workbench CONFIG.exs")
end
