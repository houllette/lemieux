defmodule Lemieux.Learning.QualificationTest do
  use ExUnit.Case, async: true
  alias Lemieux.Contract
  alias Lemieux.Learning.Qualification, as: Q

  defp plan do
    {:ok, plan} =
      Q.plan(%{
        "id" => "offline",
        "model" => "test:model",
        "effort" => "medium",
        "runtime" => %{"sha256" => Contract.sha256("runtime")},
        "seed_case_ids" => ["warmup"],
        "initial_library_sha256" => Contract.sha256("library"),
        "repetitions" => 2,
        "tasks" =>
          for(
            n <- 1..3,
            do: %{
              "id" => "task-#{n}",
              "cluster" => "related",
              "source_sha256" => Contract.sha256("#{n}")
            }
          ),
        "allowance" => %{
          "requests" => 20,
          "tokens" => 1000,
          "time_ms" => 10_000,
          "cost_usd" => nil
        },
        "alpha" => 0.05,
        "claim" => "development_qualification"
      })

    plan
  end

  defp row(ctx) do
    %{
      "arm" => ctx["arm"],
      "task_id" => ctx["task"]["id"],
      "repetition" => ctx["repetition"],
      "passed" => true,
      "requests" => 2,
      "tokens" => if(ctx["arm"] == "disabled", do: 10, else: 12),
      "latency_ms" => 100,
      "cost_usd" => nil,
      "safety_failures" => [],
      "exposed_case_ids" => ctx["available_case_ids"],
      "created_lesson_ids" => [ctx["task"]["id"] <> "-lesson"],
      "evidence_sha256" => Contract.sha256(JSON.encode!(ctx))
    }
  end

  test "all arms share outer allowances and only the updating library sees prior tasks" do
    owner = self()

    assert {:ok, report} =
             Q.run(plan(), fn ctx ->
               send(owner, {:episode, ctx})
               {:ok, row(ctx)}
             end)

    contexts =
      for _ <- 1..30,
          do:
            (
              assert_receive {:episode, ctx}
              ctx
            )

    assert length(Enum.uniq_by(contexts, & &1["allowance"])) == 1

    for ctx <- contexts do
      if ctx["arm"] == "updating" and ctx["task"]["id"] == "task-3" do
        assert ctx["available_case_ids"] == ["warmup", "task-1", "task-2"]
        assert ctx["prior_lesson_ids"] == ["task-1-lesson", "task-2-lesson"]
      else
        if ctx["arm"] != "updating", do: assert(ctx["prior_lesson_ids"] == [])
      end
    end

    assert report["mechanics"] == "passed"
    assert report["benefit"] == "inconclusive"
    assert report["comparisons"]["updating"]["clusters"] == 1
    assert report["arms"]["updating"]["tokens"] > report["arms"]["disabled"]["tokens"]
  end

  test "future source exposure and changed or exceeded allowances refuse qualification" do
    assert {:error, _} =
             Q.run(plan(), fn ctx -> {:ok, Map.put(row(ctx), "exposed_case_ids", ["task-3"])} end)

    assert {:error, _} = Q.run(plan(), fn ctx -> {:ok, Map.put(row(ctx), "tokens", 1001)} end)

    assert {:error, _} =
             Q.run(put_in(plan(), ["allowance", "requests"], 30), fn _ ->
               flunk("tampered plan")
             end)
  end

  test "refinement must beat equal-budget retries before a benefit claim" do
    attrs =
      plan()
      |> Map.take(
        ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks)
      )

    tasks =
      for n <- 1..40,
          do: %{
            "id" => "independent-#{n}",
            "cluster" => "cluster-#{n}",
            "source_sha256" => Contract.sha256("#{n}")
          }

    attrs = Map.put(attrs, "tasks", tasks)
    assert {:ok, frozen} = Q.plan(attrs)

    assert {:ok, report} =
             Q.run(frozen, fn ctx ->
               {:ok, Map.put(row(ctx), "passed", ctx["arm"] != "disabled")}
             end)

    assert hd(report["comparisons"]["updating"]["interval"]) > 0
    assert report["comparisons_to_retry"]["updating"]["effect"] == 0
    assert report["benefit"] == "inconclusive"

    assert {:ok, supported} =
             Q.run(frozen, fn ctx ->
               {:ok, Map.put(row(ctx), "passed", ctx["arm"] in ~w(frozen updating))}
             end)

    assert supported["benefit"] == "supported_in_this_scope"
    assert_in_delta supported["updating_vs_frozen"]["alpha_per_comparison"], 0.05 / 7, 1.0e-10
  end

  test "intent is checkpointed before execution and checkpoint failure dispatches nothing" do
    assert {:error, _} =
             Q.run(plan(), fn _ -> flunk("uncommitted intent") end,
               observer: fn "intent", _ -> {:error, :disk_full} end
             )

    assert {:error, :incomplete_qualification_report} = Q.report(plan(), [])
  end

  test "safety failures cannot be compensated by task success" do
    assert {:ok, report} =
             Q.run(plan(), fn ctx ->
               {:ok, Map.put(row(ctx), "safety_failures", ["outside_workspace"])}
             end)

    assert report["mechanics"] == "safety_failure"
    assert report["benefit"] == "inconclusive"
  end

  test "an incomplete learning experiment cannot qualify a successful retained baseline" do
    assert {:ok, report} =
             Q.run(plan(), fn ctx ->
               {:ok, Map.put(row(ctx), "qualification_complete", false)}
             end)

    assert report["mechanics"] == "incomplete_execution"
    assert report["execution_complete"] == false
    assert report["benefit"] == "inconclusive"

    assert {:error, _} =
             Q.run(plan(), fn ctx ->
               {:ok, Map.put(row(ctx), "qualification_complete", "false")}
             end)
  end

  test "report construction rechecks causal order and accounting rather than trusting completed rows" do
    assert {:ok, report} = Q.run(plan(), fn ctx -> {:ok, row(ctx)} end)
    assert {:error, _} = Q.report(plan(), Enum.reverse(report["rows"]))
    [first | rest] = report["rows"]
    assert {:error, _} = Q.report(plan(), [Map.put(first, "exposed_case_ids", ["task-3"]) | rest])
    assert {:ok, partial} = Q.report(plan(), [Map.put(first, "tokens", nil) | rest])
    assert partial["mechanics"] == "incomplete_accounting"
    assert partial["benefit"] == "inconclusive"
    assert {:error, _} = Q.verify(nil)
    substituted = plan() |> Map.put("arms", ["updating"]) |> Map.delete("sha256")
    substituted = Map.put(substituted, "sha256", Contract.digest(substituted))
    assert {:error, :invalid_qualification_plan} = Q.verify(substituted)

    assert {:error, :invalid_qualification_plan} =
             Q.run(substituted, fn _ -> flunk("substituted protocol") end)
  end

  defp stream_plan(count) do
    attrs =
      Map.take(
        plan(),
        ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks)
      )

    tasks =
      for n <- 1..count,
          phase <- ~w(learning confirmation),
          do: %{
            "id" => "#{n}-#{phase}",
            "cluster" => "stream-#{n}",
            "phase" => phase,
            "source_sha256" => Contract.sha256("#{n}-#{phase}")
          }

    Q.plan(
      Map.merge(attrs, %{
        "tasks" => tasks,
        "analysis" => %{
          "method" => "exact_paired_stream_success",
          "minimum_effect" => 0.1,
          "maximum_regression_rate" => 0.1,
          "desired_power" => 0.8,
          "win_probability" => 0.25,
          "loss_probability" => 0.05,
          "maximum_request_ratio" => 8,
          "maximum_latency_ratio" => 10
        }
      })
    )
  end

  test "independent streams isolate causal libraries and related repetitions remain one unit" do
    assert {:ok, plan} = stream_plan(2)
    assert :ok = Q.verify(plan)
    owner = self()

    assert {:ok, report} =
             Q.run(plan, fn ctx ->
               send(owner, {:stream, ctx})
               {:ok, row(ctx)}
             end)

    contexts =
      for _ <- 1..40,
          do:
            (
              assert_receive {:stream, ctx}
              ctx
            )

    for ctx <- contexts do
      assert ctx["stream_id"] in ~w(stream-1 stream-2)

      if ctx["arm"] in ~w(updating retrieval) and ctx["task"]["phase"] == "confirmation" do
        [number, _phase] = String.split(ctx["task"]["id"], "-")
        assert ctx["available_case_ids"] == ["warmup", "#{number}-learning"]
      else
        assert ctx["available_case_ids"] == ["warmup"]
      end
    end

    assert report["comparisons"]["updating"]["clusters"] == 2
    assert report["comparisons"]["updating"]["p_value"] == 1.0
    refute report["analysis"]["adequately_powered"]
  end

  test "version 4 withholds all prior experience from the matched improver without changing historical plans" do
    assert {:ok, original} = stream_plan(2)

    attrs =
      Map.take(
        original,
        ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks analysis)
      )

    assert {:ok, plan} = Q.plan(Map.put(attrs, "ablation", "withheld_proposer_experience/v1"))
    assert plan["schema_version"] == 4
    assert plan["arms"] == original["arms"] ++ ["no_experience"]
    assert :ok = Q.verify(original)
    assert :ok = Q.verify(plan)
    owner = self()

    assert {:ok, report} =
             Q.run(plan, fn ctx ->
               if ctx["arm"] == "no_experience", do: send(owner, {:ablation, ctx})
               {:ok, row(ctx)}
             end)

    for _ <- 1..8 do
      assert_receive {:ablation, ctx}
      assert ctx["available_case_ids"] == []
      assert ctx["prior_lesson_ids"] == []
    end

    assert report["arms"]["no_experience"]["attempts"] == 8
    assert report["benefit"] == "not_assessed_use_registered_research_endpoints"
    assert {:error, _} = Q.plan(Map.put(attrs, "ablation", "unknown"))
  end

  test "preregistered paired inference detects a useful effect with a bounded regression" do
    assert {:ok, plan} = stream_plan(80)

    assert {:ok, report} =
             Q.run(plan, fn ctx ->
               [number, _phase] = String.split(ctx["task"]["id"], "-")
               n = String.to_integer(number)

               passed =
                 cond do
                   ctx["task"]["phase"] == "learning" -> false
                   n <= 10 -> ctx["arm"] == "updating"
                   n == 11 -> ctx["arm"] != "updating"
                   true -> true
                 end

               {:ok,
                Map.merge(row(ctx), %{
                  "passed" => passed,
                  "candidate_count" => 1,
                  "promotion_count" => 1,
                  "rollback_count" => 1
                })}
             end)

    assert report["analysis"]["adequately_powered"]
    assert report["comparisons"]["updating"]["regressions"] == 1
    assert_in_delta report["comparisons"]["updating"]["effect"], 9 / 80, 1.0e-12
    assert report["benefit"] == "supported_in_this_scope"
    refute report["updating_vs_frozen"]["confirmatory"]
    assert report["comparisons_to_retry"]["updating"]["confirmatory"]

    without_mechanism =
      Enum.map(
        report["rows"],
        &Map.merge(&1, %{"candidate_count" => 0, "promotion_count" => 0, "rollback_count" => 0})
      )

    assert {:ok, no_mechanism} = Q.report(plan, without_mechanism)
    assert no_mechanism["benefit"] == "inconclusive"
  end

  test "independent confirmation refuses an underpowered plan before any dispatch" do
    {:ok, development} = stream_plan(8)

    attrs =
      Map.take(
        development,
        ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks analysis)
      )

    assert {:error, :invalid_qualification_plan} =
             Q.plan(Map.put(attrs, "claim", "independent_confirmation"))

    {:ok, powered} = stream_plan(80)

    attrs =
      Map.take(
        powered,
        ~w(id model effort runtime seed_case_ids initial_library_sha256 repetitions allowance alpha claim tasks analysis)
      )

    assert {:ok, confirmation} = Q.plan(Map.put(attrs, "claim", "independent_confirmation"))
    assert :ok = Q.verify(confirmation)
  end
end
