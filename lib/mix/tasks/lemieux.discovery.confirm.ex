defmodule Mix.Tasks.Lemieux.Discovery.Confirm do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs the independent confirmation lane for a candidate from a campaign archive.

      mix lemieux.discovery.confirm examples/discovery/campaign.exs CANDIDATE_ID \\
        --allow-live --model openai:gpt-5-mini --max-cost-usd 3.0
      mix lemieux.discovery.confirm examples/discovery/meta.exs CANDIDATE_ID --meta --allow-live

  The configuration is the same trusted file the campaign used; the archive
  under its `:output_dir` supplies the plan, the candidate bytes and the seed
  control. Cases are the manifest members the search never saw. `--model`
  runs both arms on a different model than the search used, which is the
  transfer check. `--holdout a,b,c` restricts the holdout to named cases (they
  must still be unseen by the search). `--legacy-rule` uses the fixed-n
  interval instead of the e-process. The directory under `confirmations/` is
  single-use.

  `--meta` confirms a proposer-profile candidate from a meta archive instead
  (`Lemieux.Learning.Discovery.Meta.confirm/3`): the validation inner campaigns
  the outer search never ran are each run with the seed proposer and with the
  candidate, and the paired objectives decide. The holdout-lane flags do not
  apply there and are refused rather than ignored.
  """

  use Mix.Task

  alias Lemieux.Learning.Discovery.Confirm
  alias Lemieux.Learning.Discovery.Meta

  @switches [
    allow_live: :boolean,
    meta: :boolean,
    model: :string,
    control: :string,
    repetitions: :integer,
    alpha: :float,
    minimum_effect: :float,
    minimum_pairs: :integer,
    max_cost_usd: :float,
    max_cost_per_attempt_usd: :float,
    legacy_rule: :boolean,
    usage_mode: :string,
    holdout: :string
  ]
  @meta_switches [:allow_live, :meta]
  @usage "Usage: mix lemieux.discovery.confirm CONFIG.exs CANDIDATE_ID " <>
           "[--allow-live] [--meta | --model M ...]"

  @typedoc "A parsed invocation: which lane, which archive, which candidate, with what options."
  @type invocation :: %{
          lane: :holdout | :meta,
          path: String.t(),
          candidate_id: String.t(),
          allow_live: boolean(),
          options: keyword()
        }

  @impl true
  def run(args) do
    case parse(args) do
      {:ok, invocation} ->
        Mix.Task.run("app.start")
        {config, _bindings} = Code.eval_file(invocation.path)
        config = Keyword.put(config, :allow_live, invocation.allow_live)
        confirm(invocation, config)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc """
  Parses the task's arguments without running anything.

  Public so the routing can be tested without a live archive: `--meta` sends
  the same CONFIG and CANDIDATE_ID to the meta lane with no options, and a
  holdout-lane flag beside it is an error rather than a silently ignored one.
  """
  @spec parse(args :: [String.t()]) :: {:ok, invocation()} | {:error, String.t()}
  def parse(args) when is_list(args) do
    {flags, paths, invalid} = OptionParser.parse(args, strict: @switches)
    meta? = Keyword.get(flags, :meta, false)
    foreign = flags |> Keyword.keys() |> Enum.uniq() |> Kernel.--(@meta_switches)

    case {paths, invalid} do
      {[path, candidate_id], []} when meta? and foreign != [] ->
        {:error,
         "--meta takes no holdout-lane flags (#{Enum.map_join(foreign, ", ", &flag/1)}); " <>
           @usage <> " for #{path} #{candidate_id}"}

      {[path, candidate_id], []} ->
        {:ok,
         %{
           lane: if(meta?, do: :meta, else: :holdout),
           path: path,
           candidate_id: candidate_id,
           allow_live: Keyword.get(flags, :allow_live, false),
           options: if(meta?, do: [], else: options(flags))
         }}

      _other ->
        {:error, @usage}
    end
  end

  defp flag(name), do: "--" <> String.replace(Atom.to_string(name), "_", "-")

  defp confirm(%{lane: :meta} = invocation, config) do
    case Meta.confirm(config, invocation.candidate_id, invocation.options) do
      {:ok, result} -> summarize_meta(result, config, invocation.candidate_id)
      {:error, reason} -> Mix.raise("Meta confirmation could not complete: #{inspect(reason)}")
    end
  end

  defp confirm(%{lane: :holdout} = invocation, config) do
    case Confirm.run(config, invocation.candidate_id, invocation.options) do
      {:ok, result} -> summarize(result, config, invocation.candidate_id)
      {:error, reason} -> Mix.raise("Confirmation could not complete: #{inspect(reason)}")
    end
  end

  defp options(flags) do
    flags
    |> Keyword.drop([:allow_live, :meta, :legacy_rule, :holdout])
    |> then(fn opts ->
      case Keyword.get(flags, :holdout) do
        nil ->
          opts

        ids ->
          Keyword.put(
            opts,
            :holdout_case_ids,
            ids |> String.split(",") |> Enum.map(&String.trim/1)
          )
      end
    end)
    |> then(fn opts ->
      if Keyword.get(flags, :legacy_rule, false),
        do:
          Keyword.put(opts, :stopping_rule, %{
            "minimum_pairs" => Keyword.get(flags, :minimum_pairs, 2),
            "confidence" => 0.9
          }),
        else: opts
    end)
  end

  defp summarize(result, config, candidate_id) do
    Mix.shell().info(
      "Confirmation of #{candidate_id}: #{result["verdict"]} (#{result["reason"]})"
    )

    Mix.shell().info(
      "Arms: control #{result["arms"]["control"]}, variant #{result["arms"]["variant"]}, model #{result["arms"]["model"]}"
    )

    Mix.shell().info("Cluster pairs: #{JSON.encode!(result["pairs"])}")
    Mix.shell().info("Resources: #{JSON.encode!(result["resources"])}")
    Mix.shell().info("Archive: #{Path.expand(Path.join([config[:output_dir], "confirmations"]))}")
    Mix.shell().info("Confirmation evidence only; nothing is activated.")
  end

  defp summarize_meta(result, config, candidate_id) do
    n = result["sample"]["validation_campaigns"]

    Mix.shell().info(
      "Meta confirmation of #{candidate_id}: #{result["verdict"]} (#{result["reason"]}), " <>
        "development-grade evidence over n=#{n} validation inner campaign(s)"
    )

    Mix.shell().info(
      "Arms: control #{result["arms"]["control"]}, variant #{result["arms"]["variant"]}"
    )

    Enum.each(result["pairs"], fn pair ->
      Mix.shell().info(
        "#{pair["case_id"]}: control #{JSON.encode!(pair["control"])} " <>
          "variant #{JSON.encode!(pair["variant"])} improvement #{JSON.encode!(pair["improvement"])}"
      )
    end)

    Mix.shell().info("Resources: #{JSON.encode!(result["resources"])}")

    Mix.shell().info(
      "Report: #{Path.expand(Path.join([config[:output_dir], "confirmations", candidate_id, "report.md"]))}"
    )

    Mix.shell().info("Confirmation evidence only; nothing is activated.")
  end
end
