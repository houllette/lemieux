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
end
