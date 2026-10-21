defmodule Lemieux.Learning.Qualification.EndpointsTest do
  use ExUnit.Case, async: true
  alias Lemieux.Contract
  alias Lemieux.Learning.Qualification
  alias Lemieux.Learning.Qualification.Endpoints

  test "efficiency can be supported with equal quality, without inventing a quality gain" do
    plan = plan(60)
    assert {:ok, report} = Endpoints.report(plan, rows(plan))
    assert report["quality"] == "inconclusive"
    assert report["efficiency"] == "supported_in_registered_scope"
    assert report["comparisons"]["retry"]["total_request_saving"] == 0.75
    refute report["independent_confirmation"]
    assert :ok = Contract.verify_digest(report, "sha256")
  end

  test "quality gains survive higher inference costs but do not qualify efficiency" do
    plan = plan(60)

    rows =
      Enum.map(rows(plan), fn row ->
        row
        |> Map.put("passed", row["arm"] in ~w(updating frozen))
        |> Map.put("requests", if(row["arm"] == "updating", do: 100, else: 8))
      end)

    assert {:ok, report} = Endpoints.report(plan, rows)
    assert report["quality"] == "supported_in_registered_scope"
    assert report["efficiency"] == "inconclusive"
  end

  test "acquisition costs, tiny pilots, unsafe runs and missing usage cannot qualify cheapness" do
    expensive = plan(60, 100)
    assert {:ok, report} = Endpoints.report(expensive, rows(expensive))
    assert report["efficiency"] == "inconclusive"
    assert report["comparisons"]["retry"]["total_request_saving"] < 0

    small = plan(8)
    assert {:ok, report} = Endpoints.report(small, rows(small))
    assert report["efficiency"] == "inconclusive"
    assert report["comparisons"]["retry"]["quality_regression_upper_bound"] > 0.1

    plan = plan(60)
    [first | rest] = rows(plan)

    for row <- [
          Map.put(first, "tokens", nil),
          Map.put(first, "safety_failures", ["immutable_changed"])
        ] do
      assert {:ok, report} = Endpoints.report(plan, [row | rest])
      assert report["quality"] == "inconclusive"
      assert report["efficiency"] == "inconclusive"
    end
  end

  test "a historical or incompletely accounted plan is never reinterpreted" do
    plan = plan(2)

    for runtime <- [
          Map.delete(plan["runtime"], "research_protocol"),
          Map.delete(plan["runtime"], "seed_usage")
        ] do
      attrs =
        Map.take(
          plan,
          ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks analysis ablation)
        )

      assert {:ok, historical} = Qualification.plan(Map.put(attrs, "runtime", runtime))
      assert {:error, _} = Endpoints.report(historical, rows(historical))
    end
  end

  test "unexercised learning cannot qualify and asset-only execution can qualify" do
    plan = plan(60)

    unexercised =
      Enum.map(
        rows(plan),
        &Map.merge(&1, %{"candidate_count" => 0, "promotion_count" => 0, "rollback_count" => 0})
      )

    assert {:ok, report} = Endpoints.report(plan, unexercised)
    refute report["mechanism_exercised"]
    assert report["efficiency"] == "inconclusive"

    assets =
      Enum.map(unexercised, fn row ->
        if row["arm"] == "updating",
          do:
            Map.merge(row, %{
              "asset_candidate_count" => 2,
              "asset_application_count" => 1,
              "asset_restoration_count" => 1
            }),
          else: row
      end)

    assert {:ok, report} = Endpoints.report(plan, assets)
    assert report["mechanism_exercised"]
    assert report["efficiency"] == "supported_in_registered_scope"
    assert report["quality_power"]["alpha_per_test"] == 0.05 / 6
    assert report["efficiency_power"] == "not_estimated_no_quality_power_claim_for_efficiency"
  end

  defp plan(n, acquisition \\ 0) do
    seeds = Map.new(1..n, &{"stream-#{&1}", acquisition})

    runtime = %{
      "research_protocol" => %{"endpoints" => Endpoints.policy()},
      "seed_usage" => %{"requests_by_stream" => seeds, "requests" => n * acquisition}
    }

    runtime = Map.put(runtime, "sha256", Contract.digest(runtime))

    assert {:ok, plan} =
             Qualification.plan(%{
               "id" => "endpoints",
               "model" => "test:model",
               "effort" => "low",
               "runtime" => runtime,
               "seed_case_ids" => [],
               "initial_library_sha256" => Contract.sha256("library"),
               "repetitions" => 2,
               "alpha" => 0.05,
               "ablation" => "withheld_proposer_experience/v1",
               "claim" => "development_qualification",
               "allowance" => %{
                 "requests" => 200,
                 "tokens" => 1000,
                 "time_ms" => 1000,
                 "cost_usd" => nil
               },
               "analysis" => %{
                 "method" => "exact_paired_stream_success",
                 "minimum_effect" => 0.1,
                 "maximum_regression_rate" => 0.1,
                 "desired_power" => 0.8,
                 "win_probability" => 0.25,
                 "loss_probability" => 0.05,
                 "maximum_request_ratio" => 8,
                 "maximum_latency_ratio" => 10
               },
               "tasks" =>
                 for(
                   i <- 1..n,
                   phase <- ~w(learning confirmation),
                   do: %{
                     "id" => "#{i}-#{phase}",
                     "cluster" => "stream-#{i}",
                     "phase" => phase,
                     "source_sha256" => Contract.sha256("#{i}-#{phase}")
                   }
                 )
             })

    plan
  end

  defp rows(plan) do
    for repetition <- 1..2, task <- plan["tasks"], arm <- arms(plan, repetition) do
      %{
        "arm" => arm,
        "task_id" => task["id"],
        "repetition" => repetition,
        "passed" => true,
        "requests" => if(arm == "updating", do: 2, else: 8),
        "tokens" => 10,
        "latency_ms" => 10,
        "cost_usd" => nil,
        "safety_failures" => [],
        "exposed_case_ids" => [],
        "created_lesson_ids" => [],
        "evidence_sha256" => Contract.sha256(task["id"] <> arm),
        "candidate_count" => if(arm == "updating", do: 1, else: 0),
        "promotion_count" => if(arm == "updating", do: 1, else: 0),
        "rollback_count" => if(arm == "updating", do: 1, else: 0)
      }
    end
  end

  defp arms(plan, 1), do: plan["arms"]
  defp arms(plan, 2), do: tl(plan["arms"]) ++ [hd(plan["arms"])]
end
