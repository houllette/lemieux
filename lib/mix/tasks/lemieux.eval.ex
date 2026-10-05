defmodule Mix.Tasks.Lemieux.Eval do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs a mechanically graded Lemieux evaluation and exits non-zero when its
  policy fails.

      mix lemieux.eval --suite eval/corpus/v1/manifest.json \
        --fixture-set eval/fixture_sets/v1.json --baseline baseline \
        --tag smoke --format console --output tmp/eval.json

  Live candidates and LLM judges are impossible unless `--approve-live` is
  present. Paid candidates and judges additionally require `--cost-cap` and
  `--estimated-cost`, so an over-budget run is refused before it starts.

  Repeat `--model` to compare multiple live models in one invocation. Use
  `--change release|dependency --from X.Y.Z --to X.Y.Z` for SemVer minor gates,
  or `model|prompt|tool_schema` with stable host-owned identifiers. Other
  options include repeated `--tag`, `--threshold`, `--max-regression`,
  `--concurrency`, `--seed`, `--judge`, `--judge-model`, `--judge-cache`,
  `--format console|json`, and `--output`.
  """

  use Mix.Task

  alias Lemieux.Benchmark.CLI
  alias Lemieux.Benchmark.Judging
  alias Lemieux.Benchmark.Reporter.Console
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime

  # Without this the task runs against a compiled but unstarted application, and
  # `req_llm` fills its provider registry — a `:persistent_term` — when it starts.
  # Every live model therefore resolved to `Unknown provider` before a single
  # request was built, so `--model` had never once worked. Nothing noticed because
  # the only thing that runs here is the recorded corpus, where a fixture replay
  # makes no provider call.
  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    # The judge's route and default model come from this host's environment and
    # personal configuration, resolved here so the benchmark library never reads
    # either. Both are functions: a run without `--judge` never calls them.
    host = [
      judge_provider: &Runtime.provider/0,
      default_judge_model: fn -> Options.inference_default(Judging.default_model()) end
    ]

    case CLI.run(args, host) do
      {:ok, report} ->
        Mix.shell().info(format(report, args))

      {:gate_failed, report} ->
        Mix.shell().error(format(report, args))
        Mix.raise("Lemieux evaluation gate failed; inspect the JSON artifact for evidence")

      {:error, reason} ->
        Mix.raise("Lemieux evaluation could not run: #{inspect(reason)}")
    end
  end

  defp format(report, args) do
    if option(args, "--format") == "json", do: JSON.encode!(report), else: Console.format(report)
  end

  defp option(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^name, value] -> value
      _pair -> nil
    end)
  end
end
