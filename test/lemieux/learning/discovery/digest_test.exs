defmodule Lemieux.Learning.Discovery.DigestTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  test "a passing evaluation has cause passed and mechanism none" do
    plan = plan()

    signature =
      Digest.signature(evaluation(plan, "c1", "dev-1", 1.0, ":end_turn"), [], Policy.read(plan))

    assert signature["cause"] == "passed"
    assert signature["mechanism"] == "none"
    assert signature["causal_status"] == "end_turn"
    assert signature["success"]
  end

  test "mechanisms follow the fixed priority order over recorded tool outcomes" do
    plan = plan()
    policy = Policy.read(plan)
    failed = evaluation(plan, "c1", "dev-1", 0.0, ":end_turn")

    assert Digest.signature(failed, [], policy)["mechanism"] == "unknown"

    assert Digest.signature(failed, [assistant()], policy)["mechanism"] ==
             "answered_without_tools"

    edits = for _ <- 1..3, do: tool_result("edit", error: true)
    assert Digest.signature(failed, [assistant() | edits], policy)["mechanism"] == "edit_mismatch"

    bashes = for _ <- 1..3, do: tool_result("bash", error: true)

    assert Digest.signature(failed, [assistant() | bashes], policy)["mechanism"] ==
             "tool_error_loop"

    denied = [assistant(), tool_result("bash", outcome: "denied")]
    assert Digest.signature(failed, denied, policy)["mechanism"] == "denied_tool"

    timeout = [assistant(), tool_result("bash", outcome: "timeout")]
    assert Digest.signature(failed, timeout, policy)["mechanism"] == "command_timeout"

    unverified = [assistant(), tool_result("read"), tool_result("write")]

    assert Digest.signature(failed, unverified, policy)["mechanism"] ==
             "no_verification_after_change"

    verified = [assistant(), tool_result("write"), tool_result("bash")]
    assert Digest.signature(failed, verified, policy)["mechanism"] == "unknown"

    looped = evaluation(plan, "c1", "dev-1", 0.0, ":no_progress")
    assert Digest.signature(looped, verified, policy)["mechanism"] == "repeated_tool_wave"
    assert Digest.signature(looped, verified, policy)["cause"] == "budget_stopped"
  end

  test "safety failures and non-terminal runs are named as causes before any mechanism" do
    plan = plan()
    policy = Policy.read(plan)

    unsafe = evaluation(plan, "c1", "dev-1", 0.0, ":end_turn", safety: false)
    assert Digest.signature(unsafe, [assistant()], policy)["cause"] == "safety_violation"

    assert Digest.signature(unsafe, [assistant()], policy)["mechanism"] ==
             "wrote_outside_allowlist"

    crashed = evaluation(plan, "c1", "dev-1", 0.0, nil, terminal: false)
    assert Digest.signature(crashed, [], policy)["cause"] == "runtime_failed"
    assert Digest.signature(crashed, [], policy)["causal_status"] == "unknown"

    timed_out = evaluation(plan, "c1", "dev-1", 0.0, ":agent_timeout")
    assert Digest.signature(timed_out, [], policy)["cause"] == "timeout"
  end

  test "a model output limit is distinct from a failed grader or an answer without tools" do
    plan = plan()
    policy = Policy.read(plan)
    limited = evaluation(plan, "c1", "dev-1", 0.0, ":length")

    for entries <- [[], [assistant()], [assistant(), tool_result("read")]] do
      signature = Digest.signature(limited, entries, policy)

      assert signature["cause"] == "output_limit"
      assert signature["causal_status"] == "output_limit"
      assert signature["mechanism"] == "model_output_limit"
    end
  end

  test "build clusters failures by signature, orders by support and tallies candidates and cases" do
    plan = plan()
    policy = Policy.read(plan)
    entries = [assistant(), tool_result("read"), tool_result("write")]
    bytes = JSON.encode!(entries)
    reference = transcript_reference(plan, bytes)

    evaluations = [
      evaluation(plan, "c1", "dev-1", 0.0, ":end_turn", artifacts: [reference]),
      evaluation(plan, "c1", "dev-2", 0.0, ":end_turn", artifacts: [reference]),
      evaluation(plan, "c2", "dev-1", 0.0, ":no_progress"),
      evaluation(plan, "c2", "dev-2", 1.0, ":end_turn"),
      %{evaluation(plan, "c2", "val-1", 0.0, ":end_turn") | split: "validation"}
    ]

    digest = Digest.build(plan, evaluations, %{reference.sha256 => bytes}, policy)

    assert digest["counts"] == %{"evaluations" => 4, "failures" => 3, "clusters" => 2}
    [first, second] = digest["clusters"]
    assert first["count"] == 2
    assert first["signature"]["mechanism"] == "no_verification_after_change"
    assert first["candidate_ids"] == ["c1"]
    assert first["case_ids"] == ["dev-1", "dev-2"]
    assert second["signature"]["mechanism"] == "repeated_tool_wave"

    assert digest["by_candidate"]["c2"] == %{
             "successes" => 1,
             "failures" => 1,
             "mechanisms" => %{"repeated_tool_wave" => 1}
           }

    assert digest["by_case"]["dev-1"]["failures"] == 2
    assert digest["signatures"]["eval_c1_dev-1"]["transcript_available"]
    refute digest["signatures"]["eval_c2_dev-1"]["transcript_available"]
  end

  test "excerpt reuses the bounded reflection projection over decoded entries" do
    entries = [assistant(), tool_result("bash", error: true)]
    excerpt = Digest.excerpt(entries, max_bytes: 4_000)

    assert excerpt["entry_count"] == 2
    assert excerpt["tool_usage"]["bash"]["invocation_errors"] == 1
    assert excerpt["coverage"]["evidence_byte_limit"] == 4_000
    assert Enum.map(excerpt["events"], & &1["type"]) == ["assistant", "tool_result"]
  end

  defp plan do
    scope = %{"id" => "tenant-a/project-a"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-digest",
        "scope" => scope,
        "target_interface" => %{"id" => "profile/v1"},
        "mutation_surface" => [%{"path" => "options.system"}],
        "seeds" => [%{"id" => "seed-1", "content_sha256" => String.duplicate("a", 64)}],
        "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("b", 64)},
        "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("c", 64)},
        "development_case_ids" => ["dev-1", "dev-2"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
        "interface_validator" => %{"id" => "validator", "sha256" => String.duplicate("d", 64)},
        "budget" => %{
          "maximum_candidates" => 5,
          "maximum_tokens" => 1000,
          "maximum_cost_usd" => 1.0,
          "maximum_time_ms" => 1000
        }
      })

    plan
  end

  defp evaluation(plan, candidate_id, case_id, success, finish_reason, opts \\ []) do
    %Evaluation{
      id: "eval_#{candidate_id}_#{case_id}",
      sha256: "",
      created_at: DateTime.utc_now(),
      plan_id: plan.id,
      plan_sha256: plan.sha256,
      candidate_id: candidate_id,
      candidate_content_sha256: String.duplicate("e", 64),
      scope: plan.scope,
      case_id: case_id,
      split: "development",
      objectives: %{"task_success" => success},
      safety:
        if(Keyword.get(opts, :safety, true),
          do: %{"passed" => true, "failures" => []},
          else: %{"passed" => false, "failures" => ["changed_path_outside_allowlist:x"]}
        ),
      completeness: %{"usage" => "complete"},
      usage: %{},
      cost: %{},
      latency: %{},
      artifacts: Keyword.get(opts, :artifacts, []),
      within_budget: true,
      terminal: Keyword.get(opts, :terminal, true),
      observations: %{"finish_reason" => finish_reason},
      extensions: %{}
    }
  end

  defp transcript_reference(plan, bytes) do
    ArtifactReference.from_bytes("transcript", bytes,
      id: "transcript_test",
      media_type: "application/json",
      content_schema: "lemieux.transcript.entries/v2",
      scope: plan.scope
    )
  end

  defp assistant do
    encoded(
      Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => "done"}],
        "tool_calls" => []
      })
    )
  end

  defp tool_result(name, opts \\ []) do
    payload = %{
      "call_id" => "call_" <> Contract.sha256(name <> inspect(opts)),
      "name" => name,
      "arguments" => %{},
      "output" => "",
      "error" => Keyword.get(opts, :error, false),
      "outcome" =>
        Keyword.get(
          opts,
          :outcome,
          if(Keyword.get(opts, :error, false), do: "error", else: "success")
        ),
      "duration_ms" => 1,
      "output_bytes" => 0
    }

    encoded(Entry.new(:tool_result, payload))
  end

  defp encoded(entry), do: entry |> Entry.encode!() |> JSON.decode!()
end
