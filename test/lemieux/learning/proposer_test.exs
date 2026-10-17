defmodule Lemieux.Learning.ProposerTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Learning.Experience.Retrieval
  alias Lemieux.Learning.Proposer
  alias Lemieux.Learning.Proposer.Workspace
  alias Lemieux.Providers.Scripted
  alias LemieuxTest.LessonFixtures, as: F

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    evolver = Proposer.profile("test:model", quota: true)
    seed_profile = seed_profile()
    seed_bytes = Contract.encode!(seed_profile)
    plan = plan(evolver, seed_bytes)
    {:ok, state} = plan |> State.new() |> State.start()

    base_context = %{
      candidates: [],
      evaluations: [],
      artifacts: %{Contract.sha256(seed_bytes) => seed_bytes},
      ordinal: 1,
      workspace_root: Path.join(tmp_dir, "proposals"),
      sessions_dir: Path.join(tmp_dir, "sessions"),
      evolver_profile: evolver,
      timeout_ms: 30_000
    }

    %{
      plan: plan,
      state: state,
      seed_profile: seed_profile,
      seed_bytes: seed_bytes,
      context: base_context
    }
  end

  test "the seed operator records the parent unchanged without a model call", ctx do
    retained = self()

    context =
      Map.merge(ctx.context, %{
        parent: {:seed, hd(ctx.plan.seeds)},
        operator: "seed",
        provider: Scripted.new([]),
        retain: fn sha, bytes -> send(retained, {:retained, sha, byte_size(bytes)}) end
      })

    assert {:ok, %Candidate{} = candidate, accounting} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert candidate.mutation_kind == "seed"
    assert candidate.interface_validation["status"] == "passed"
    assert Candidate.content_sha256(candidate) == Contract.sha256(ctx.seed_bytes)
    assert [%{"id" => "seed-1"}] = candidate.parents
    assert candidate.extensions["prediction"] == %{"fixes" => [], "at_risk" => []}
    assert %{"tokens" => 0, "cost_usd" => +0.0, "requests" => 0} = accounting
    assert_received {:retained, _sha, _size}
    assert Scripted.requests(context.provider) == []
  end

  test "the evolver's proposal becomes a validated, predicted, critic-reviewed candidate", ctx do
    seed = seed_candidate(ctx)

    evaluations = [
      failed(ctx.plan, seed, "dev-1"),
      failed(ctx.plan, seed, "dev-2"),
      passed(ctx.plan, seed, "dev-3")
    ]

    edited =
      put_in(ctx.seed_profile, ["options", "tool_descriptions"], %{
        "bash" => "Run a shell command. Always rerun the failing check after editing."
      })

    manifest = %{
      "rationale" => "Both failures ended without re-running the check after an edit.",
      "hypothesis" => "Telling the agent to rerun the check after editing fixes dev-1 and dev-2.",
      "targeted_cluster" => %{
        "cause" => "grader_failed",
        "causal_status" => "end_turn",
        "mechanism" => "no_verification_after_change"
      },
      "mechanism" => "no_verification_after_change",
      "changed_paths" => ["options.tool_descriptions.bash"],
      "predicted_fixes" => ["dev-2", "dev-1"],
      "predicted_at_risk" => ["dev-3"]
    }

    evolver =
      Scripted.new([
        Scripted.tool_call(
          "w1",
          "write",
          %{"path" => "proposal/profile.json", "content" => JSON.encode!(edited)},
          usage: %{"input_tokens" => 100, "output_tokens" => 50}
        ),
        Scripted.tool_call(
          "w2",
          "write",
          %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
          usage: %{"input_tokens" => 120, "output_tokens" => 40}
        ),
        Scripted.complete("Proposed a bash description edit.",
          usage: %{"input_tokens" => 130, "output_tokens" => 10}
        )
      ])

    critic =
      Scripted.new([
        Scripted.complete(
          ~s(Verdict: {"verdict": "accept", "reason": "The excerpts show no rerun."}),
          usage: %{"input_tokens" => 40, "output_tokens" => 20}
        )
      ])

    # Two providers, one context: the critic session gets the critic profile
    # and the evolver session the evolver profile through a provider that
    # dispatches on the system prompt.
    provider = {__MODULE__.Router, %{evolver: evolver, critic: critic}}

    context =
      Map.merge(ctx.context, %{
        parent: {:candidate, seed.id},
        operator: "clonal",
        candidates: [seed],
        evaluations: evaluations,
        artifacts:
          Map.put(ctx.context.artifacts, Contract.sha256(transcript_bytes()), transcript_bytes()),
        evidence: %{
          "operator" => "clonal",
          "candidate_id" => seed.id,
          "failed_case_ids" => ["dev-1", "dev-2"],
          "evaluation_ids" => Enum.map(Enum.take(evaluations, 2), & &1.id)
        },
        provider: provider,
        critic_profile: Proposer.critic_profile("test:model", quota: true),
        ordinal: 2
      })

    assert {:ok, %Candidate{} = candidate, accounting} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert candidate.mutation_kind == "clonal"
    assert candidate.interface_validation["status"] == "passed"

    assert candidate.interface_validation["detail"]["changed_paths"] == [
             "options.tool_descriptions.bash"
           ]

    assert [%{"id" => parent_id}] = candidate.parents
    assert parent_id == seed.id

    assert candidate.extensions["prediction"] == %{
             "fixes" => ["dev-1", "dev-2"],
             "at_risk" => ["dev-3"]
           }

    assert candidate.extensions["critic"]["verdict"] == "accept"
    assert candidate.extensions["hypothesis"] =~ "rerun the check"
    assert candidate.extensions["changed_paths"] == ["options.tool_descriptions.bash"]
    assert candidate.exposures == [%{"source_case_ids" => ["dev-1", "dev-2", "dev-3"]}]
    assert Candidate.content_sha256(candidate) == Contract.sha256(Contract.encode!(edited))
    assert accounting["tokens"] == 100 + 50 + 120 + 40 + 130 + 10 + 40 + 20
    assert accounting["requests"] == 4

    workspace = Path.join(ctx.context.workspace_root, "proposal-002")
    assert File.exists?(Path.join(workspace, "evidence/summary.md"))
    assert File.exists?(Path.join(workspace, "parent/profile.json"))
    assert {:ok, landscape} = File.read(Path.join(workspace, "evidence/landscape.json"))

    assert %{"candidates" => [%{"id" => seed_id, "successes" => 1, "evaluated" => 3}]} =
             JSON.decode!(landscape)

    assert seed_id == seed.id
    assert File.ls!(Path.join(workspace, "evidence/transcripts")) != []
    # Evidence was unsealed after the sessions so the directory can be cleaned up.
    assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(workspace, "evidence"))
    assert Bitwise.band(mode, 0o200) != 0
  end

  test "an edit outside the surface or a grader reference yields a failed-interface candidate",
       ctx do
    seed = seed_candidate(ctx)

    outside = put_in(ctx.seed_profile, ["model"], "test:other")

    manifest = %{
      "rationale" => "swap model",
      "changed_paths" => ["model"],
      "predicted_fixes" => [],
      "predicted_at_risk" => []
    }

    evolver =
      Scripted.new([
        Scripted.tool_call("w1", "write", %{
          "path" => "proposal/profile.json",
          "content" => JSON.encode!(outside)
        }),
        Scripted.tool_call("w2", "write", %{
          "path" => "proposal/manifest.json",
          "content" => JSON.encode!(manifest)
        }),
        Scripted.complete("done")
      ])

    context =
      Map.merge(ctx.context, %{
        parent: {:candidate, seed.id},
        operator: "clonal",
        candidates: [seed],
        evaluations: [failed(ctx.plan, seed, "dev-1")],
        provider: evolver,
        ordinal: 2
      })

    assert {:ok, %Candidate{} = candidate, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert candidate.interface_validation["status"] == "failed"
    assert candidate.interface_validation["detail"]["error"] == ["outside_surface", ["model"]]
    assert candidate.extensions["critic"]["verdict"] == "not_applicable"
    assert candidate.extensions["changed_paths"] == ["model"]
  end

  test "a session that writes nothing still yields a recorded, failed candidate", ctx do
    seed = seed_candidate(ctx)
    evolver = Scripted.new([Scripted.complete("I could not decide.")])

    context =
      Map.merge(ctx.context, %{
        parent: {:candidate, seed.id},
        operator: "reaction_norm",
        candidates: [seed],
        evaluations: [failed(ctx.plan, seed, "dev-1"), failed(ctx.plan, seed, "dev-2")],
        provider: evolver,
        ordinal: 3
      })

    assert {:ok, %Candidate{} = candidate, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert candidate.mutation_kind == "reaction_norm"
    assert candidate.interface_validation["status"] == "failed"
    assert candidate.interface_validation["detail"]["error"] == "no_profile_written"
  end

  # A proposer killed during its session never reaches the `after` that
  # unseals: an ExUnit timeout, a supervisor's brutal kill, a halted VM. Its
  # read-only evidence then made `rm -rf` of the campaign directory fail, and
  # a test's tmp_dir impossible to recreate on every later run.
  test "the next proposal gives a killed attempt's sealed trees their write permission back",
       ctx do
    seed = seed_candidate(ctx)
    root = ctx.context.workspace_root
    killed = sealed_attempt(ctx, root, 3)

    assert {:ok, %Candidate{}, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, retry(ctx, seed, root, 3))

    # The retry got a directory of its own, and the killed one is kept, as
    # evidence, but no longer read-only.
    assert File.dir?(Path.join(root, "proposal-003-r1"))
    refute Enum.any?(killed.sealed, &read_only?/1)
    assert {:ok, _removed} = File.rm_rf(root)
  end

  # Only an earlier attempt at the ordinal being proposed is known to be over.
  # Another ordinal's sealed tree under the same root can belong to a session
  # still running, and unsealing it would make that evidence writable under it.
  test "leaves another ordinal's sealed trees as they are", ctx do
    seed = seed_candidate(ctx)
    root = ctx.context.workspace_root
    running = sealed_attempt(ctx, root, 2)
    killed = sealed_attempt(ctx, root, 3)

    assert {:ok, %Candidate{}, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, retry(ctx, seed, root, 3))

    refute Enum.any?(killed.sealed, &read_only?/1)
    assert Enum.all?(running.sealed, &read_only?/1)
  end

  # The root is the host's choice, and `[1]` in a wildcard pattern is a
  # character class: matched as one, this root found the other campaign's
  # trees and not its own.
  test "finds its own attempts under a root a wildcard would misread", ctx do
    seed = seed_candidate(ctx)
    root = Path.join([ctx.tmp_dir, "run[1]", "proposals"])
    other_campaign = sealed_attempt(ctx, Path.join([ctx.tmp_dir, "run1", "proposals"]), 3)
    killed = sealed_attempt(ctx, root, 3)

    assert {:ok, %Candidate{}, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, retry(ctx, seed, root, 3))

    refute Enum.any?(killed.sealed, &read_only?/1)
    assert Enum.all?(other_campaign.sealed, &read_only?/1)
  end

  test "a critic veto is recorded on the candidate rather than discarded", ctx do
    seed = seed_candidate(ctx)

    edited =
      put_in(
        ctx.seed_profile,
        ["options", "system"],
        "Be careful. Verify every edit by rerunning the check."
      )

    manifest = %{
      "rationale" => "verify",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => ["dev-1"],
      "predicted_at_risk" => []
    }

    evolver =
      Scripted.new([
        Scripted.tool_call("w1", "write", %{
          "path" => "proposal/profile.json",
          "content" => JSON.encode!(edited)
        }),
        Scripted.tool_call("w2", "write", %{
          "path" => "proposal/manifest.json",
          "content" => JSON.encode!(manifest)
        }),
        Scripted.complete("done")
      ])

    critic =
      Scripted.new([
        Scripted.complete(
          ~s({"verdict":"veto","reason":"The excerpt shows the check was rerun."})
        )
      ])

    provider = {__MODULE__.Router, %{evolver: evolver, critic: critic}}

    context =
      Map.merge(ctx.context, %{
        parent: {:candidate, seed.id},
        operator: "clonal",
        candidates: [seed],
        evaluations: [failed(ctx.plan, seed, "dev-1")],
        provider: provider,
        critic_profile: Proposer.critic_profile("test:model", quota: true),
        ordinal: 2
      })

    assert {:ok, %Candidate{} = candidate, _accounting} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert candidate.interface_validation["status"] == "passed"

    assert candidate.extensions["critic"] == %{
             "verdict" => "veto",
             "reason" => "The excerpt shows the check was rerun."
           }
  end

  test "missing parent content is an infrastructure error, not a candidate", ctx do
    context =
      Map.merge(ctx.context, %{
        parent: {:candidate, "ghost"},
        operator: "clonal",
        provider: Scripted.new([])
      })

    assert {:error, {:unknown_parent, "ghost"}} = Proposer.propose(ctx.plan, ctx.state, context)

    context =
      Map.merge(ctx.context, %{
        parent: {:seed, hd(ctx.plan.seeds)},
        operator: "seed",
        provider: Scripted.new([]),
        artifacts: %{}
      })

    assert {:error, {:parent_content_missing, _digest}} =
             Proposer.propose(ctx.plan, ctx.state, context)
  end

  test "identity pins the module and the evolver profile digest" do
    profile = Proposer.profile("test:model")
    assert %{"id" => "Lemieux.Learning.Proposer", "sha256" => sha} = Proposer.identity(profile)
    assert sha == Contract.digest(profile)
    refute sha == Contract.digest(Proposer.profile("test:model", temperature: 0.9))
    refute sha == Contract.digest(Proposer.profile("test:model", experience: true))
  end

  test "a second task reads the first task's rejected lesson; frozen and updating controls differ",
       ctx do
    evolver = Proposer.profile("test:model", quota: true, experience: true)
    plan = plan(evolver, ctx.seed_bytes)
    {:ok, state} = plan |> State.new() |> State.start()

    ctx = %{
      ctx
      | plan: plan,
        state: state,
        context: Map.put(ctx.context, :evolver_profile, evolver)
    }

    experience = first_task(ctx)
    assert {:ok, frozen} = Retrieval.freeze(experience.store, ctx.plan.scope)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, updated} = Retrieval.freeze(experience.store, ctx.plan.scope)

    improved =
      put_in(ctx.seed_profile, ["options", "system"], "Rerun the parser test after editing.")

    results =
      for {name, library, expected} <- [
            {"frozen", frozen, experience.profile},
            {"updating", updated, improved}
          ] do
        provider =
          Scripted.new([
            Scripted.tool_call("read-lessons", "read", %{"path" => "evidence/lessons/index.json"}),
            fn request ->
              assert request.system =~ "Scoped prior experience"

              observed =
                request.entries
                |> Enum.filter(&(&1.type == :tool_result))
                |> Enum.map(& &1.payload)
                |> inspect()

              profile =
                if String.contains?(observed, experience.lesson.id),
                  do: improved,
                  else: experience.profile

              Scripted.tool_call("write-profile", "write", %{
                "path" => "proposal/profile.json",
                "content" => JSON.encode!(profile)
              })
            end,
            Scripted.tool_call("write-manifest", "write", %{
              "path" => "proposal/manifest.json",
              "content" => JSON.encode!(manifest())
            }),
            Scripted.complete("done")
          ])

        context =
          proposal_context(ctx, experience, provider, library)
          |> Map.put(:workspace_root, Path.join(ctx.tmp_dir, name))

        assert {:ok, candidate, _accounting} = Proposer.propose(ctx.plan, ctx.state, context)
        assert candidate.interface_validation["status"] == "passed"
        assert candidate.content.sha256 == Contract.digest(expected)
        assert length(Scripted.requests(provider)) == 4
        assert candidate.extensions["experience"]["library_sha256"] == library["sha256"]

        assert {:ok, index} =
                 File.read(
                   Path.join([
                     context.workspace_root,
                     "proposal-002",
                     "evidence/lessons/index.json"
                   ])
                 )

        assert index =~ library["sha256"]
        candidate
      end

    [control, updating] = results
    refute control.content.sha256 == updating.content.sha256

    assert updating.extensions["experience"]["selected"] == [
             %{"id" => experience.lesson.id, "sha256" => experience.lesson.sha256}
           ]

    assert_received {:lesson_committed, exposure}
    assert exposure.source_case_ids == experience.lesson.source_case_ids
    assert exposure.derived_artifact_ids == [experience.lesson.id]
  end

  test "a known rejected edit cannot be repeated without genuinely new evidence", ctx do
    experience = first_task(ctx)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)
    old = experience.evaluation

    for reconsiderations <- [
          nil,
          [
            %{
              "lesson_id" => experience.lesson.id,
              "rationale" => "try again",
              "evaluation_refs" => []
            }
          ],
          [
            %{
              "lesson_id" => experience.lesson.id,
              "rationale" => "same evidence",
              "evaluation_refs" => [%{"id" => old.id, "sha256" => old.sha256}]
            }
          ]
        ] do
      provider =
        proposal_provider(
          experience.profile,
          Map.put(manifest(), "reconsiderations", reconsiderations)
        )

      context =
        proposal_context(ctx, experience, provider, library) |> Map.put(:evaluations, [old])

      assert {:ok, candidate, _} = Proposer.propose(ctx.plan, ctx.state, context)
      assert candidate.interface_validation["status"] == "failed"

      assert candidate.interface_validation["detail"]["error"] == [
               "rejected_edit_requires_new_evidence",
               [experience.lesson.id]
             ]

      assert candidate.extensions["critic"]["verdict"] == "not_applicable"
    end
  end

  test "a rejected edit may be reconsidered with a recorded rationale and a fresh development observation",
       ctx do
    experience = first_task(ctx)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)
    fresh = passed(ctx.plan, experience.seed, "dev-2")

    rationale = [
      %{
        "lesson_id" => experience.lesson.id,
        "rationale" =>
          "The new development observation contradicts the original diagnosis; repeat only to measure that hypothesis.",
        "evaluation_refs" => [%{"id" => fresh.id, "sha256" => fresh.sha256}]
      }
    ]

    provider =
      proposal_provider(experience.profile, Map.put(manifest(), "reconsiderations", rationale))

    context =
      proposal_context(ctx, experience, provider, library) |> Map.put(:evaluations, [fresh])

    config = context.experience

    context =
      Map.put(context, :experience, fn current ->
        assert current.ordinal == 2
        {:ok, config}
      end)

    assert {:ok, candidate, _} = Proposer.propose(ctx.plan, ctx.state, context)
    assert candidate.interface_validation["status"] == "passed"
    assert candidate.extensions["reconsiderations"] == rationale
    assert candidate.extensions["experience"]["selected"] != []
  end

  test "adding an unrelated allowed edit cannot hide a repeated rejected field", ctx do
    experience = first_task(ctx)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)

    disguised =
      put_in(experience.profile, ["options", "tool_descriptions"], %{"read" => "Read source"})

    provider = proposal_provider(disguised, manifest())
    context = proposal_context(ctx, experience, provider, library)

    assert {:ok, candidate, _} = Proposer.propose(ctx.plan, ctx.state, context)
    refute candidate.content.sha256 == Contract.digest(experience.profile)
    assert candidate.interface_validation["status"] == "failed"

    assert hd(candidate.interface_validation["detail"]["error"]) ==
             "rejected_edit_requires_new_evidence"
  end

  test "provider failures and fabricated digests cannot justify retrying a rejected edit", ctx do
    experience = first_task(ctx)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)
    fresh = passed(ctx.plan, experience.seed, "dev-2")

    {:ok, unavailable} =
      Evaluation.new(
        ctx.plan,
        experience.seed,
        fresh
        |> Evaluation.to_map()
        |> Map.delete("sha256")
        |> Map.put("observations", %{
          "finish_reason" => ":error",
          "provider_error" => %{"category" => "timeout"}
        })
      )

    for {observation, sha} <- [
          {fresh, Contract.sha256("fabricated")},
          {unavailable, unavailable.sha256}
        ] do
      reconsiderations = [
        %{
          "lesson_id" => experience.lesson.id,
          "rationale" => "try with new evidence",
          "evaluation_refs" => [%{"id" => observation.id, "sha256" => sha}]
        }
      ]

      provider =
        proposal_provider(
          experience.profile,
          Map.put(manifest(), "reconsiderations", reconsiderations)
        )

      context =
        proposal_context(ctx, experience, provider, library)
        |> Map.put(:evaluations, [observation])

      assert {:ok, candidate, _} = Proposer.propose(ctx.plan, ctx.state, context)
      assert candidate.interface_validation["status"] == "failed"
    end
  end

  test "retrieved comparative evidence exposes an ineffective edit and a missed prediction",
       ctx do
    ctx = comparison_context(ctx)
    experience = first_task(ctx, parent_score: 0.0)
    assessment = retrieve_assessment(ctx, experience)
    assert assessment["state"] == "comparative"

    assert assessment["candidates"][experience.evaluation.candidate_id]["state"] ==
             "no_observed_fix"

    calibration = assessment["calibration"]["candidates"][experience.evaluation.candidate_id]
    assert calibration["fix_precision"] == 0.0
    assert calibration["brier"] == 1.0
  end

  test "retrieved comparative evidence distinguishes regression from provider failure", ctx do
    ctx = comparison_context(ctx)
    experience = first_task(ctx, parent_score: 1.0)
    assessment = retrieve_assessment(ctx, experience)

    assert assessment["candidates"][experience.evaluation.candidate_id]["state"] ==
             "observed_regression"
  end

  test "retrieved infrastructure failures establish no harness edit effect", ctx do
    ctx = comparison_context(ctx)

    experience =
      first_task(ctx,
        parent_score: 1.0,
        observations: %{
          "finish_reason" => ":error",
          "provider_error" => %{"category" => "timeout"}
        }
      )

    assessment = retrieve_assessment(ctx, experience)

    assert assessment["candidates"][experience.evaluation.candidate_id] == %{
             "state" => "infrastructure_failure",
             "attribution" => "no_edit_effect_established",
             "causes" => ["provider_timeout"]
           }

    assert assessment["calibration"]["aggregate"]["mean_brier"] == nil
  end

  test "retrieval failure starts no proposer session or hidden reflection", ctx do
    experience = first_task(ctx)
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)
    provider = Scripted.new([])

    context =
      proposal_context(ctx, experience, provider, library)
      |> put_in([:experience, :commit], fn _, _ -> {:error, :storage_unavailable} end)

    assert {:error, {:exposure_not_committed, :storage_unavailable}} =
             Proposer.propose(ctx.plan, ctx.state, context)

    assert Scripted.requests(provider) == []
    refute File.exists?(Path.join(context.workspace_root, "proposal-002"))
  end

  defp comparison_context(ctx) do
    attrs =
      ctx.plan
      |> Plan.to_map()
      |> Map.delete("sha256")
      |> Map.put("hard_constraints", [%{"id" => "safe", "kind" => "mechanical"}])

    {:ok, plan} = Plan.new(attrs)
    {:ok, state} = plan |> State.new() |> State.start()
    %{ctx | plan: plan, state: state}
  end

  defp retrieve_assessment(ctx, experience) do
    assert :ok = Lessons.append(experience.store, experience.lesson)
    assert {:ok, library} = Retrieval.freeze(experience.store, ctx.plan.scope)

    assert {:ok, result} =
             Retrieval.retrieve(
               experience.store,
               library,
               %{"task" => "repair failing parser"},
               F.context(),
               F.consumer(),
               fn _, _ -> :ok end,
               now: ~U[2026-10-17 01:00:00Z]
             )

    result.evidence[experience.lesson.id <> ".json"]["assessment"]
  end

  defp first_task(ctx, opts \\ []) do
    retained = start_supervised!({Agent, fn -> ctx.context.artifacts end})

    context =
      Map.put(ctx.context, :retain, fn sha, bytes ->
        Agent.update(retained, &Map.put(&1, sha, bytes))
      end)

    ctx = %{ctx | context: context}
    seed = seed_candidate(ctx)

    profile =
      put_in(ctx.seed_profile, ["options", "system"], "Skip parser verification after editing.")

    context =
      Map.merge(context, %{
        parent: {:candidate, seed.id},
        operator: "clonal",
        candidates: [seed],
        provider: proposal_provider(profile, manifest()),
        ordinal: 1
      })

    assert {:ok, rejected, _} = Proposer.propose(ctx.plan, ctx.state, context)
    evaluation = failed(ctx.plan, rejected, "dev-1")

    {:ok, evaluation} =
      Evaluation.new(
        ctx.plan,
        rejected,
        evaluation
        |> Evaluation.to_map()
        |> Map.delete("sha256")
        |> Map.put("observations", Keyword.get(opts, :observations, evaluation.observations))
      )

    evaluations =
      case Keyword.fetch(opts, :parent_score) do
        {:ok, score} -> [evaluation(ctx.plan, seed, "dev-1", score), evaluation]
        :error -> [evaluation]
      end

    artifacts =
      Agent.get(retained, &Map.put(&1, Contract.sha256(transcript_bytes()), transcript_bytes()))

    references =
      [seed.content, seed.rationale, rejected.content, rejected.rationale] ++
        Enum.flat_map(evaluations, & &1.artifacts)

    descriptors =
      references
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn ref ->
        %{
          "id" => ref.id,
          "scope" => ctx.plan.scope,
          "path" => "artifacts/" <> ref.sha256,
          "reference" => ArtifactReference.to_map(ref)
        }
      end)

    assert {:ok, bundle} =
             Bundle.new(%{
               "id" => "task-one",
               "scope" => ctx.plan.scope,
               "plan" =>
                 if(Keyword.has_key?(opts, :parent_score),
                   do: Plan.to_map(ctx.plan),
                   else: Map.take(Plan.to_map(ctx.plan), ~w(id sha256 scope))
                 ),
               "seeds" => ctx.plan.seeds,
               "candidates" => Enum.map([seed, rejected], &Candidate.to_map/1),
               "evaluations" => Enum.map(evaluations, &Evaluation.to_map/1),
               "raw" => [],
               "derived" => [],
               "artifacts" => descriptors,
               "exposures" => rejected.exposures
             })

    artifacts = Map.take(artifacts, Enum.map(references, & &1.sha256))

    attrs =
      F.attrs()
      |> Map.merge(%{
        "key" => "parser-check",
        "outcome" => "rejected",
        "qualification" => "unconfirmed",
        "applicability" => ["failing parser"],
        "mechanism" => "Skipping parser verification did not fix the failing parser.",
        "supporting" => [evaluation.id],
        "candidate_ids" => [rejected.id]
      })

    assert {:ok, lesson} = Lesson.new(bundle, artifacts, attrs)

    %{
      store: LessonFiles.new(Path.join(ctx.tmp_dir, "lessons"), ctx.plan.scope),
      lesson: lesson,
      seed: seed,
      profile: profile,
      evaluation: evaluation
    }
  end

  defp proposal_context(ctx, experience, provider, library) do
    owner = self()

    Map.merge(ctx.context, %{
      parent: {:candidate, experience.seed.id},
      operator: "clonal",
      candidates: [experience.seed],
      provider: provider,
      ordinal: 2,
      experience: %{
        store: experience.store,
        library: library,
        query: %{"task" => "repair failing parser"},
        binding: F.context(),
        consumer: F.consumer(),
        options: [now: ~U[2026-10-17 01:00:00Z]],
        commit: fn _, exposure ->
          send(owner, {:lesson_committed, exposure})
          :ok
        end
      }
    })
  end

  defp manifest do
    %{
      "rationale" => "Measure parser verification behavior",
      "hypothesis" => "Verification distinguishes the parser failure",
      "mechanism" => "parser verification",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => ["dev-1"],
      "predicted_at_risk" => []
    }
  end

  defp proposal_provider(profile, manifest) do
    Scripted.new([
      Scripted.tool_call("profile", "write", %{
        "path" => "proposal/profile.json",
        "content" => JSON.encode!(profile)
      }),
      Scripted.tool_call("manifest", "write", %{
        "path" => "proposal/manifest.json",
        "content" => JSON.encode!(manifest)
      }),
      Scripted.complete("done")
    ])
  end

  defmodule Router do
    @moduledoc false
    @behaviour Lemieux.Provider

    @impl true
    def run(%{evolver: evolver, critic: critic}, request, emit) do
      provider =
        if String.starts_with?(request.system || "", "You are Lemieux's proposal critic"),
          do: critic,
          else: evolver

      Lemieux.Provider.run(provider, request, emit)
    end
  end

  # What an attempt at `ordinal` leaves under `root` when it is killed during
  # its session. Unsealed again when the test ends, whatever it did, unless
  # the test removed it: a tree left read-only stops ExUnit from emptying the
  # test's tmp_dir on the next run.
  defp sealed_attempt(ctx, root, ordinal) do
    {:ok, attempt} =
      Workspace.materialize(root, ordinal, %{plan: ctx.plan, parent_bytes: ctx.seed_bytes})

    %Workspace{sealed: [_ | _] = trees} = sealed = Workspace.seal(attempt)
    on_exit(fn -> Workspace.unseal(%{sealed | sealed: Enum.filter(trees, &File.dir?/1)}) end)
    assert Enum.all?(trees, &read_only?/1)
    sealed
  end

  # The ordinal proposed again under `root`, as a resumed campaign does after
  # an attempt that never returned.
  defp retry(ctx, seed, root, ordinal) do
    Map.merge(ctx.context, %{
      parent: {:candidate, seed.id},
      operator: "reaction_norm",
      candidates: [seed],
      evaluations: [failed(ctx.plan, seed, "dev-1")],
      provider: Scripted.new([Scripted.complete("I could not decide.")]),
      workspace_root: root,
      ordinal: ordinal
    })
  end

  # Whether anything in the tree lacks its owner's write permission: a
  # directory that does stops `rm -rf` from emptying it.
  defp read_only?(path) do
    %File.Stat{type: type, mode: mode} = File.stat!(path)

    Bitwise.band(mode, 0o200) == 0 or
      (type == :directory and Enum.any?(File.ls!(path), &read_only?(Path.join(path, &1))))
  end

  defp seed_candidate(ctx) do
    context =
      Map.merge(ctx.context, %{
        parent: {:seed, hd(ctx.plan.seeds)},
        operator: "seed",
        provider: Scripted.new([])
      })

    {:ok, candidate, _accounting} = Proposer.propose(ctx.plan, ctx.state, context)
    candidate
  end

  defp seed_profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "You are a careful coding agent.",
          "max_turns" => 8,
          "max_tokens" => 1024,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0,
          "tool_descriptions" => %{}
        }
      },
      8
    )
  end

  defp plan(evolver_profile, seed_bytes) do
    scope = %{"id" => "tenant-a/project-a"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-proposer",
        "scope" => scope,
        "target_interface" => %{"id" => "lemieux.session-profile/v1"},
        "mutation_surface" => [
          %{"path" => "options.system"},
          %{"path" => "options.tool_descriptions"}
        ],
        "seeds" => [
          %{"id" => "seed-1", "content_sha256" => Contract.sha256(seed_bytes), "scope" => scope}
        ],
        "proposer" => Proposer.identity(evolver_profile),
        "base_model" => %{"id" => "test:model", "sha256" => Contract.sha256("test:model")},
        "development_case_ids" => ["dev-1", "dev-2", "dev-3"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => [
          %{"id" => "safe", "kind" => "mechanical"},
          %{
            "id" => "graders",
            "kind" => "forbidden_references",
            "patterns" => ["check.sh", "grader"]
          }
        ],
        "interface_validator" => Surface.validator(),
        "budget" => %{
          "maximum_candidates" => 10,
          "maximum_tokens" => 1_000_000,
          "maximum_cost_usd" => 10.0,
          "maximum_time_ms" => 600_000,
          "unknown_cost" => "allow"
        }
      })

    plan
  end

  defp failed(plan, candidate, case_id), do: evaluation(plan, candidate, case_id, 0.0)
  defp passed(plan, candidate, case_id), do: evaluation(plan, candidate, case_id, 1.0)

  # Every fixture evaluation references the same two-entry transcript, so a
  # test can retain the bytes once, the way the shadow loop does.
  defp transcript_bytes, do: JSON.encode!(transcript_entries())

  defp transcript_entries do
    [
      %{
        "v" => 2,
        "id" => "e1",
        "seq" => 1,
        "type" => "user",
        "payload" => %{"content" => "task"},
        "at" => "2026-09-16T00:00:00Z"
      },
      %{
        "v" => 2,
        "id" => "e2",
        "seq" => 2,
        "type" => "tool_result",
        "payload" => %{"name" => "write", "outcome" => "success", "error" => false},
        "at" => "2026-09-16T00:00:01Z"
      }
    ]
  end

  defp evaluation(plan, candidate, case_id, success) do
    bytes = transcript_bytes()

    reference =
      ArtifactReference.from_bytes("transcript", bytes,
        id: "transcript_#{candidate.id}_#{case_id}",
        media_type: "application/json",
        content_schema: "lemieux.transcript.entries/v2",
        scope: plan.scope
      )

    {:ok, evaluation} =
      Evaluation.new(plan, candidate, %{
        "id" => "eval_#{candidate.id}_#{case_id}",
        "scope" => plan.scope,
        "case_id" => case_id,
        "split" => "development",
        "objectives" => %{"task_success" => success},
        "safety" => %{"passed" => true, "failures" => []},
        "completeness" => %{
          "usage" => "complete",
          "cost" => "not_applicable",
          "sandbox" => "not_applicable"
        },
        "usage" => %{"total_tokens" => 10},
        "cost" => %{"usd" => nil},
        "latency" => %{"milliseconds" => 5},
        "artifacts" => [ArtifactReference.to_map(reference)],
        "within_budget" => true,
        "terminal" => true,
        "observations" => %{"finish_reason" => ":end_turn"}
      })

    evaluation
  end
end
