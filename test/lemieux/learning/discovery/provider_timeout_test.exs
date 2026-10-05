defmodule Lemieux.Learning.Discovery.ProviderTimeoutTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Evaluator
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # One provider shared by every attempt, so its script is a timeline: the
  # first `stalls` requests die mid-stream and the run that gets past them
  # solves the case. `Scripted.requests/1` then counts exactly how many
  # provider calls the lane paid for.
  defp flaky_provider(stalls) do
    Scripted.new(
      List.duplicate(Scripted.stream_timeout(), stalls) ++
        [
          Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "fixed"},
            usage: %{"input_tokens" => 10, "output_tokens" => 5}
          ),
          Scripted.complete("done", usage: %{"input_tokens" => 12, "output_tokens" => 4})
        ]
    )
  end

  defp calls(provider), do: provider |> Scripted.requests() |> length()

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)

    {:ok, manifest} =
      Manifest.from_map(
        %{
          "version" => 1,
          "tasks" => [
            %{
              "id" => "dev-1",
              "prompt" => "Create result.txt containing exactly fixed.",
              "cwd" => "fixture",
              "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
              "metadata" => %{"safety" => %{"allowed_changed_paths" => ["result.txt"]}}
            },
            %{
              "id" => "val-1",
              "prompt" => "unused",
              "cwd" => "fixture",
              "grader" => %{"command" => ["sh", "-c", "false"]},
              "metadata" => %{}
            }
          ]
        },
        tmp_dir
      )

    plan = plan()

    %{manifest: manifest, plan: plan, candidate: candidate(plan)}
  end

  defp run(ctx, provider, opts) do
    Evaluator.run(
      ctx.plan,
      ctx.candidate,
      [
        manifest: ctx.manifest,
        profile: profile(),
        provider: provider,
        case_ids: ["dev-1"],
        sandbox: :not_applicable,
        sessions_dir: Path.join(ctx.tmp_dir, "sessions"),
        benchmark: [workspace_root: Path.join(ctx.tmp_dir, "work")]
      ] ++ opts
    )
  end

  test "a stalled stream is retried once, and the discarded try is kept beside the attempt it replaced",
       ctx do
    provider = flaky_provider(1)
    assert {:ok, %{evaluations: [evaluation], incomplete: []}} = run(ctx, provider, [])

    # Three provider calls — the stall, then the two turns that solved it —
    # and one recorded attempt: a retry is not a second sample.
    assert calls(provider) == 3
    assert evaluation.observations["attempt"] == 1
    assert evaluation.objectives["task_success"] == 1.0
    assert evaluation.within_budget
    assert Evaluation.eligible?(evaluation)

    assert [discarded] = evaluation.observations["retries"]
    assert discarded["discarded"] == true
    assert discarded["finish_reason"] == ":error"
    assert discarded["provider_error"]["category"] == "timeout"
    assert discarded["provider_error"]["reason"] =~ "timeout"
    assert is_binary(discarded["session_id"])
  end

  test "a stall that outlives its retry is recorded as unmeasured, never as a wrong answer",
       ctx do
    provider = flaky_provider(2)
    assert {:ok, %{evaluations: [evaluation]}} = run(ctx, provider, [])

    # One retry and no more: the lane does not keep paying for a dead stream.
    assert calls(provider) == 2
    assert evaluation.observations["finish_reason"] == ":error"
    assert evaluation.observations["provider_error"]["category"] == "timeout"
    assert [_discarded] = evaluation.observations["retries"]

    # The distinction the roadmap asks for: this attempt measured nothing, so
    # it is outside budget and ineligible rather than a failed candidate.
    refute evaluation.within_budget
    refute Evaluation.eligible?(evaluation)
    assert evaluation.objectives["task_success"] == 0.0
  end

  test "the retry can be declined, and then the first failure is what the report keeps", ctx do
    provider = flaky_provider(1)

    assert {:ok, %{evaluations: [evaluation]}} =
             run(ctx, provider, retry_provider_timeouts: false)

    assert calls(provider) == 1
    assert evaluation.observations["retries"] == []
    assert evaluation.observations["provider_error"]["category"] == "timeout"
    refute evaluation.within_budget
  end

  test "a wrong answer is not retried and stays the candidate's own failure", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "wrong"},
          usage: %{"input_tokens" => 10, "output_tokens" => 5}
        ),
        Scripted.complete("done", usage: %{"input_tokens" => 1, "output_tokens" => 1})
      ])

    assert {:ok, %{evaluations: [evaluation]}} = run(ctx, provider, [])

    assert calls(provider) == 2
    assert evaluation.observations["retries"] == []
    assert evaluation.observations["provider_error"] == nil
    assert evaluation.observations["finish_reason"] == ":stop"
    assert evaluation.objectives["task_success"] == 0.0
    # Hard evidence about the candidate, unlike the stall above.
    assert evaluation.within_budget
    assert Evaluation.eligible?(evaluation)
  end

  test "the failure digest clusters a stalled stream apart from a failed grader", ctx do
    {:ok, %{evaluations: [stalled], artifacts: artifacts}} =
      run(ctx, flaky_provider(2), retry_provider_timeouts: false)

    digest = Digest.build(ctx.plan, [stalled], artifacts, %{})

    assert [cluster] = digest["clusters"]
    assert cluster["signature"]["cause"] == "provider_timeout"
    assert cluster["case_ids"] == ["dev-1"]
  end

  defp profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "You are a careful coding agent.",
          "max_turns" => 4,
          "max_tokens" => 512,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0
        }
      },
      4
    )
  end

  defp plan do
    scope = %{"id" => "tenant-a/project-a"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-provider-timeout",
        "scope" => scope,
        "target_interface" => %{"id" => "profile/v1"},
        "mutation_surface" => [%{"path" => "options.system"}],
        "seeds" => [%{"id" => "seed-1", "content_sha256" => String.duplicate("a", 64)}],
        "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("b", 64)},
        "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("c", 64)},
        "development_case_ids" => ["dev-1"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
        "interface_validator" => %{"id" => "validator", "sha256" => String.duplicate("d", 64)},
        "budget" => %{
          "maximum_candidates" => 5,
          "maximum_tokens" => 100_000,
          "maximum_cost_usd" => 10.0,
          "maximum_time_ms" => 600_000,
          "unknown_cost" => "allow"
        }
      })

    plan
  end

  defp candidate(plan) do
    scope = plan.scope

    content =
      ArtifactReference.from_bytes("candidate_content", "{}",
        id: "content-1",
        media_type: "application/json",
        content_schema: "profile/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why",
        id: "rationale-1",
        media_type: "text/plain",
        content_schema: "rationale/v1",
        scope: scope
      )

    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => "cand-1",
        "scope" => scope,
        "parents" => [],
        "content" => ArtifactReference.to_map(content),
        "proposer" => plan.proposer,
        "rationale" => ArtifactReference.to_map(rationale),
        "interface_validation" => %{
          "status" => "passed",
          "validator_sha256" => plan.interface_validator["sha256"]
        },
        "exposures" => [],
        "mutation_kind" => "seed"
      })

    candidate
  end
end
