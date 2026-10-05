defmodule Mix.Tasks.Lemieux.Eval.Bless do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Creates an explicit, reviewable baseline from a passing JSON report.

      mix lemieux.eval.bless --input tmp/eval.json \
        --runtime candidate --version 1.2.0 \
        --output eval/baselines/current.json

  A failed gate cannot be blessed. `--version` must be SemVer; `--change`
  defaults to `release`.
  """

  use Mix.Task

  alias Lemieux.Benchmark.Baseline

  @switches [input: :string, runtime: :string, version: :string, output: :string, change: :string]

  @impl Mix.Task
  def run(args) do
    with {:ok, opts} <- parse(args),
         {:ok, report} <- read(opts[:input]),
         {:ok, baseline} <-
           Baseline.from_report(report, opts[:runtime],
             version: opts[:version],
             change: Keyword.get(opts, :change, "release")
           ),
         :ok <- Baseline.write(opts[:output], baseline) do
      Mix.shell().info("Blessed #{opts[:runtime]} at #{opts[:version]} to #{opts[:output]}")
    else
      {:error, reason} -> Mix.raise("Could not bless evaluation baseline: #{inspect(reason)}")
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> required(opts)
      {_opts, rest, invalid} -> {:error, {:invalid_arguments, rest, invalid}}
    end
  end

  defp required(opts) do
    missing = Enum.filter([:input, :runtime, :version, :output], &(not is_binary(opts[&1])))
    if missing == [], do: {:ok, opts}, else: {:error, {:missing_options, missing}}
  end

  defp read(path) do
    with {:ok, body} <- File.read(path) do
      case JSON.decode(body) do
        {:ok, report} -> {:ok, report}
        {:error, reason} -> {:error, {:invalid_json, Lemieux.JSON.describe_error(reason)}}
      end
    end
  end
end
