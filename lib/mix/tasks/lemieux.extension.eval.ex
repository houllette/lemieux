defmodule Mix.Tasks.Lemieux.Extension.Eval do
  @shortdoc "Compares native extensions using a trusted local evaluation configuration (experimental)"
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs the existing paired benchmark machinery with installed agent modules.

      mix lemieux.extension.eval bench/compare.exs --allow-live

  The trusted Elixir file returns a keyword list with `:suite` (manifest path),
  `:agents` (`{name, module, options}` tuples), and optional `:benchmark_options`
  and `:execution`.

  `:execution` is `:live` by default, as in `mix lemieux.extension.workbench`,
  and a live configuration runs only with `--allow-live`: its agents may call
  paid providers, and without the flag the command was the one task in this
  family that started spending as soon as it was typed. A configuration that
  declares `execution: :scripted` (offline fixtures, scripted providers) runs
  without it. The declaration is the configuration's own word and does not
  sandbox its code.
  Options may be a keyword list or a zero-arity factory evaluated per attempt;
  use factories for providers whose state must reset between attempts.
  Paths are relative to the current Mix project. The configuration is executable
  code, just like a Mix script; inspect it before running. Its options may select
  paid providers, so use explicit session caps and benchmark reservations for
  live work. Nothing auto-loads this file or starts an experiment at installation.

  Failed task attempts are comparison results, not a command-level error. This
  development command does not select a winner, qualify a candidate or activate
  anything. Raw reports stay at the explicit benchmark `:output` path.
  """

  use Mix.Task

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Agent

  @usage "Usage: mix lemieux.extension.eval CONFIG.exs [--allow-live]"

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [allow_live: :boolean]) do
      {flags, [path], []} -> evaluate(path, Keyword.get(flags, :allow_live, false))
      _other -> Mix.raise(@usage)
    end
  end

  defp evaluate(path, allow_live?) do
    Mix.Task.run("app.start")
    {config, _bindings} = Code.eval_file(path)
    authorize!(Keyword.get(config, :execution, :live), allow_live?)
    suite = Keyword.fetch!(config, :suite)
    opts = Keyword.get(config, :benchmark_options, [])

    runtimes =
      Enum.map(Keyword.fetch!(config, :agents), fn {name, module, options} ->
        Runtime.new(name, Agent, agent: module, agent_options: options)
      end)

    case Benchmark.run_file(suite, runtimes, opts) do
      {:ok, report} -> summarize(report, opts)
      {:error, reason} -> Mix.raise("Extension evaluation failed: #{inspect(reason)}")
    end
  end

  defp authorize!(:scripted, _allow_live?), do: :ok
  defp authorize!(:live, true), do: :ok

  defp authorize!(:live, false) do
    Mix.raise(
      "This configuration runs live (execution: :live, the default), and its agents may " <>
        "call paid providers. Review its agents, session caps and benchmark options, then " <>
        "pass --allow-live; declare execution: :scripted for offline fixtures."
    )
  end

  # Anything else is a typo, and reading a typo as "offline" would run the
  # agents live without the flag.
  defp authorize!(execution, _allow_live?) do
    Mix.raise(":execution must be :live or :scripted, got: #{inspect(execution)}")
  end

  defp summarize(report, opts) do
    report["results"]
    |> Enum.group_by(& &1["runtime"])
    |> Enum.sort()
    |> Enum.each(fn {name, results} ->
      passed = Enum.count(results, & &1["passed"])
      Mix.shell().info("#{name}: #{passed}/#{length(results)} completed and passed")
    end)

    Mix.shell().info("Development comparison; no qualification or activation.")
    if opts[:output], do: Mix.shell().info("Report: #{Path.expand(opts[:output])}")
  end
end
