defmodule Lemieux.CLI.Learning.Calibration do
  @moduledoc """
  A complete, accounted fixed sample before difficulty selection.

  A hosted overload left one request unmeasured and caused later calls to be
  refused before dispatch. Their untouched workspaces all failed grading, so
  dividing those failures by the sample size misleadingly reported zero
  capability. Keep the observations, but withhold a score and headroom decision
  until every declared pair has complete evidence and known request/token facts.
  Complete, accounted task failures still count as failures.
  """

  @spec report(plan :: map(), rows :: [map()]) :: map()
  def report(plan, rows) do
    baseline = Enum.filter(rows, &(&1["arm"] == "disabled"))

    expected =
      for task <- plan["tasks"],
          arm <- plan["arms"],
          repetition <- 1..plan["repetitions"],
          do: {task["id"], arm, repetition}

    actual = Enum.map(rows, &{&1["task_id"], &1["arm"], &1["repetition"]})

    complete? =
      baseline != [] and Enum.sort(expected) == Enum.sort(actual) and
        Enum.all?(rows, &complete?/1)

    rate = if complete?, do: Enum.count(baseline, & &1["passed"]) / length(baseline)

    %{
      "kind" => "development_calibration_only",
      "plan_sha256" => plan["sha256"],
      "rows" => rows,
      "status" => if(complete?, do: "complete", else: "incomplete"),
      "execution_complete" => complete?,
      "unknown_token_rows" => Enum.count(rows, &(not is_integer(&1["tokens"]))),
      "incomplete_rows" =>
        rows
        |> Enum.reject(&complete?/1)
        |> Enum.map(
          &Map.take(&1, ~w(task_id arm repetition requests tokens qualification_complete))
        ),
      "baseline_success" => rate,
      "has_headroom" => if(complete?, do: rate >= 0.1 and rate <= 0.9),
      "benefit" => "not_tested",
      "independent_confirmation" => false
    }
  end

  defp complete?(row),
    do:
      row["qualification_complete"] == true and is_boolean(row["passed"]) and
        is_integer(row["tokens"]) and row["tokens"] >= 0 and
        is_integer(row["requests"]) and row["requests"] > 0
end
