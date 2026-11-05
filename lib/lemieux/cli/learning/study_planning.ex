defmodule Lemieux.CLI.Learning.StudyPlanning do
  @moduledoc """
  Provider-free review of a frozen study before authorizing hosted work.

  The runner builds the same registration for planning and execution. This
  projection states the complete sample's maximum request envelope and the
  separately proposed shared ceiling. A smaller ceiling may stop execution;
  it cannot shrink the registered sample or qualify a partial run. This
  document never opens a ledger, prepares credentials or grants authority.
  """
  alias Lemieux.Contract

  @doc "Describes a registration and proposed outer limits without executing work."
  @spec review(registration :: map(), limits :: keyword()) :: map()
  def review(registration, limits) do
    plan = registration["template"]
    seed_count = length(registration["seed_tasks"])
    episodes = length(plan["tasks"]) * plan["repetitions"] * length(plan["arms"])

    maximum_requests =
      seed_count * registration["seed_allowance"]["requests"] +
        episodes * plan["allowance"]["requests"]

    review = %{
      "schema_version" => 1,
      "kind" => "learning_study_plan_only/v1",
      "registration_sha256" => Contract.digest(registration),
      "template_sha256" => plan["sha256"],
      "hosted_authorization" => "required_separately",
      "dispatches" => 0,
      "credentials_prepared" => false,
      "model" => plan["model"],
      "effort" => plan["effort"],
      "editor_model" => get_in(plan, ["runtime", "research_protocol", "editor_model"]),
      "editor_effort" => get_in(plan, ["runtime", "research_protocol", "editor_effort"]),
      "claim" => plan["claim"] || "development_calibration",
      "arms" => plan["arms"],
      "tasks" => length(plan["tasks"]),
      "streams" => plan["tasks"] |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> length(),
      "repetitions" => plan["repetitions"],
      "seed_episodes" => seed_count,
      "target_episodes" => episodes,
      "maximum_registered_requests" => maximum_requests,
      "proposed_shared_limits" =>
        Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end),
      "ceiling_can_stop_sample" =>
        is_integer(limits[:max_requests]) and limits[:max_requests] < maximum_requests,
      "interpretation" => "planning_only_no_execution_or_efficacy_evidence"
    }

    Map.put(review, "sha256", Contract.digest(review))
  end
end
