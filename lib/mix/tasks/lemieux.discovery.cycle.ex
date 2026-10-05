defmodule Mix.Tasks.Lemieux.Discovery.Cycle do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs one generation of routine harness improvement.

      mix lemieux.discovery.cycle examples/discovery/cycle.exs --allow-live
      mix lemieux.discovery.cycle examples/discovery/cycle.exs --status

  The trusted configuration is a campaign configuration plus a `:confirmation`
  section; see `Lemieux.Learning.Discovery.Cycle`. The cycle seeds from the
  configuration's `:seed_profile` with the overlay file (`:overlay_path`,
  `.lmx/harness.json` by default) applied whole, so each generation starts
  from what the last exported overlay changed. It searches, confirms the best
  frontier member on every configured confirmation model, appends to
  `cycles.jsonl` under the output directory, and prints a recommendation. It
  never writes the overlay: `lmx harness export` does, under your review.

  `--status` reads the ledger and the configuration's `:allowance`, prints
  the generation count, the last verdict, the spend inside the allowance
  window, and whether the next cycle would be admitted, and runs nothing.
  A refused cycle exits non-zero with the reason, which is what a scheduler
  should see when the allowance is used up.
  """

  use Mix.Task

  alias Lemieux.Learning.Discovery.Cycle

  @impl true
  def run(args) do
    {flags, paths, _invalid} =
      OptionParser.parse(args, strict: [allow_live: :boolean, status: :boolean])

    case paths do
      [path] ->
        Mix.Task.run("app.start")
        {config, _bindings} = Code.eval_file(path)
        config = Keyword.put(config, :allow_live, Keyword.get(flags, :allow_live, false))

        if Keyword.get(flags, :status, false),
          do: status(Cycle.status(config)),
          else: run_cycle(config)

      _other ->
        Mix.raise("Usage: mix lemieux.discovery.cycle CONFIG.exs [--allow-live | --status]")
    end
  end

  defp run_cycle(config) do
    case Cycle.run(config) do
      {:ok, entry} ->
        summarize(entry)

      {:error, reason, _state} ->
        Mix.raise("Cycle campaign failed: #{inspect(reason)}")

      {:error, {:allowance_exhausted, detail}} ->
        Mix.raise(
          "Cycle refused: the allowance would be exceeded on #{Enum.join(detail["exceeded"], ", ")} " <>
            "(spent #{JSON.encode!(detail["spent_before"])} in the last #{detail["window_days"] || "∞"} days, " <>
            "this cycle could spend #{JSON.encode!(detail["planned"])}, limits #{JSON.encode!(detail["limits"])})"
        )

      {:error, reason} ->
        Mix.raise("Cycle could not start: #{inspect(reason)}")
    end
  end

  defp status(status) do
    last = status["last"]

    Mix.shell().info(
      "Cycles: #{status["cycles"]} under #{status["root"]} " <>
        "(#{status["recommendations"] |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)})"
    )

    if last,
      do:
        Mix.shell().info(
          "Last: #{last["cycle_id"]} at #{last["at"]}: #{last["recommendation"]} — #{last["next"]}"
        )

    Mix.shell().info(
      "Spend: #{JSON.encode!(status["spend"])} in the last #{status["window_days"] || "∞"} days; " <>
        "#{JSON.encode!(status["spend_all_time"])} all time"
    )

    if status["admitted"],
      do: Mix.shell().info("Next cycle: admitted"),
      else: Mix.shell().info("Next cycle: refused, #{JSON.encode!(status["refusal"])}")
  end

  defp summarize(entry) do
    campaign = entry["campaign"]

    Mix.shell().info(
      "Cycle #{entry["cycle_id"]}: #{campaign["status"]}, #{campaign["candidates"]} candidates, " <>
        "#{campaign["evaluations"]} evaluations, frontier #{inspect(campaign["frontier"])}"
    )

    Enum.each(entry["confirmations"], fn confirmation ->
      Mix.shell().info(
        "  confirmed on #{confirmation["model"]}: #{confirmation["verdict"]} (#{confirmation["reason"]})"
      )
    end)

    Mix.shell().info("Calibration: #{JSON.encode!(campaign["calibration"])}")
    Mix.shell().info("Spend: #{JSON.encode!(entry["spend"])}")
    Mix.shell().info("Recommendation: #{entry["recommendation"]}")
    Mix.shell().info("Next: #{entry["next"]}")
  end
end
