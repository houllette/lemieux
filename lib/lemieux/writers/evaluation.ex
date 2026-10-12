defmodule Lemieux.Writers.Evaluation do
  @moduledoc """
  Matched serial/parallel receipts, separate from permission to enable writers.

  Each observation identifies the task, base, model/policy and independent grader.
  Unauthorized writes, unresolved effects and lost critical findings are hard
  failures, even when the other numbers improve. Unknown dollars stay unknown.
  A fixture comparison exercises mechanics; it does not establish model quality.
  No result here changes lmx defaults or authorizes a hosted-model run.
  """
  @identity ~w(case_id base_revision policy_digest grader_digest)
  @gates ~w(unauthorized_writes missing_effects lost_findings)

  @doc """
  Compares two measured observations under a host-selected cost ratio.
  Required fields: identity keys, `source`, `quality`, `requests`,
  `spent_usd`, `wall_ms`, `violations` and nonempty `evidence`.
  `:max_cost_ratio` defaults to 1.25. A passing pair still needs broader
  matched evaluation and host review before adoption.
  """
  @spec compare(serial :: map(), parallel :: map(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def compare(serial, parallel, opts \\ []) do
    ratio = Keyword.get(opts, :max_cost_ratio, 1.25)

    with :ok <- valid(serial),
         :ok <- valid(parallel),
         true <- Enum.all?(@identity, &(serial[&1] == parallel[&1])),
         true <- is_number(ratio) and ratio >= 1 do
      reasons = reasons(serial, parallel, ratio)

      {:ok,
       %{
         "version" => 1,
         "serial" => serial,
         "parallel" => parallel,
         "pair_passed" => reasons == [],
         "reasons" => reasons,
         "evidence_kind" =>
           if(serial["source"] == "live" and parallel["source"] == "live",
             do: "model_comparison",
             else: "fixture"
           ),
         "wider_use_enabled" => false
       }}
    else
      false -> {:error, :unmatched_or_invalid_policy}
      error -> error
    end
  end

  defp valid(observation) when is_map(observation) do
    identity? = Enum.all?(@identity, &(is_binary(observation[&1]) and observation[&1] != ""))
    metrics? = Enum.all?(~w(quality requests wall_ms), &nonnegative?(observation[&1]))
    dollars? = money?(observation["spent_usd"])

    gates? = gates?(observation["violations"])

    evidence? = is_map(observation["evidence"]) and map_size(observation["evidence"]) > 0

    if identity? and metrics? and dollars? and gates? and evidence? and
         observation["source"] in ["scripted", "live"],
       do: :ok,
       else: {:error, :invalid_observation}
  end

  defp valid(_observation), do: {:error, :invalid_observation}
  defp gates?(gates) when is_map(gates), do: Enum.all?(@gates, &nonnegative?(gates[&1]))
  defp gates?(_gates), do: false

  defp money?(nil), do: true
  defp money?(value), do: nonnegative?(value)

  defp nonnegative?(value), do: is_number(value) and value >= 0

  defp reasons(serial, parallel, ratio) do
    checks = [
      {"hard_failure",
       Enum.any?(@gates, &(serial["violations"][&1] > 0 or parallel["violations"][&1] > 0))},
      {"quality_regression", parallel["quality"] < serial["quality"]},
      {"no_measured_gain",
       not (parallel["quality"] > serial["quality"] or parallel["wall_ms"] < serial["wall_ms"])},
      {"unknown_cost", is_nil(serial["spent_usd"]) or is_nil(parallel["spent_usd"])},
      {"cost_regression", over_cost?(serial["spent_usd"], parallel["spent_usd"], ratio)}
    ]

    for {reason, failed?} <- checks, failed?, do: reason
  end

  defp over_cost?(nil, _parallel, _ratio), do: false
  defp over_cost?(_serial, nil, _ratio), do: false
  defp over_cost?(serial, parallel, ratio), do: parallel > serial * ratio
end
