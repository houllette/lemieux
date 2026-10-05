defmodule Mix.Tasks.Lemieux.Discovery do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs a shadow-mode harness discovery campaign on this machine.

      mix lemieux.discovery examples/discovery/campaign.exs
      mix lemieux.discovery examples/discovery/campaign.exs --allow-live
      mix lemieux.discovery examples/discovery/campaign.exs --allow-live --resume
      mix lemieux.discovery examples/discovery/meta.exs --allow-live --meta
      mix lemieux.discovery examples/discovery/meta.exs --allow-live --meta --resume

  The trusted Elixir file returns the keyword configuration documented in
  `Lemieux.Learning.Discovery.Campaign`. It is executable code: inspect it
  before running it. Without `--allow-live` the campaign refuses any provider
  other than the scripted test double, so a mistyped path cannot spend money.

  The result is a development archive under the configuration's
  `:output_dir` — plan, exposure, candidates, evaluations, transcripts,
  frontier, calibration and a report. `--resume` continues an interrupted
  campaign from that archive without repeating recorded work; with `--meta`
  it also reuses inner campaigns that already ran to a frontier instead of
  buying them a second time. Nothing is confirmed, installed or activated; a
  frontier member is a candidate for the separate confirmation lane, not an
  improvement.
  """

  use Mix.Task

  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Meta

  @impl true
  def run(args) do
    {flags, paths, _invalid} =
      OptionParser.parse(args, strict: [allow_live: :boolean, resume: :boolean, meta: :boolean])

    case paths do
      [path] ->
        campaign(path, flags)

      _other ->
        Mix.raise("Usage: mix lemieux.discovery CONFIG.exs [--allow-live] [--meta] [--resume]")
    end
  end

  defp campaign(path, flags) do
    Mix.Task.run("app.start")
    {config, _bindings} = Code.eval_file(path)
    config = Keyword.put(config, :allow_live, Keyword.get(flags, :allow_live, false))

    case runner(flags).(config) do
      {:ok, result} ->
        summarize(config, result)

      {:error, reason, _state} ->
        Mix.raise(
          "Discovery campaign failed: #{inspect(reason)}; partial archive in #{config[:output_dir]}"
        )

      {:error, reason} ->
        Mix.raise("Discovery campaign could not start: #{inspect(reason)}")
    end
  end

  # `--meta` and `--resume` compose: a meta campaign is the one most worth
  # resuming, because each of its evaluations is a whole inner campaign. The
  # earlier `cond` silently ran a fresh meta campaign when both were given,
  # which is the opposite of what was asked for.
  defp runner(flags) do
    case {Keyword.get(flags, :meta, false), Keyword.get(flags, :resume, false)} do
      {true, true} -> &Meta.resume/1
      {true, false} -> &Meta.run/1
      {false, true} -> &Campaign.resume/1
      {false, false} -> &Campaign.run/1
    end
  end

  defp summarize(config, result) do
    members = Enum.map(result.frontier.members, & &1["candidate_id"])

    Mix.shell().info(
      "Campaign #{result.state.status}: #{length(result.candidates)} candidates, #{length(result.evaluations)} evaluations"
    )

    Mix.shell().info(
      "Frontier: #{if members == [], do: "(none)", else: Enum.join(members, ", ")}"
    )

    Mix.shell().info("Calibration: #{get_in(result, [:calibration, "status"])}")
    Mix.shell().info("Report: #{Path.expand(Path.join(config[:output_dir], "report.md"))}")
    Mix.shell().info("Development result over exposed cases; no confirmation or activation.")
  end
end
