defmodule Lemieux.Learning.Discovery.CampaignTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # One three-turn script serves every session; each turn dispatches on the
  # role the request's system prompt reveals and, for candidate sessions, on
  # the case named in the task prompt. The seed profile fails the second
  # case; a profile carrying the proposer's edit passes both.
  defp provider_factory do
    fn ->
      Scripted.new([
        fn request -> turn(1, request) end,
        fn request -> turn(2, request) end,
        fn request -> turn(3, request) end
      ])
    end
  end

  defp role(request) do
    cond do
      String.starts_with?(request.system || "", "You are Lemieux's harness proposer") -> :evolver
      String.starts_with?(request.system || "", "You are Lemieux's proposal critic") -> :critic
      true -> :candidate
    end
  end

  defp turn(1, request) do
    case role(request) do
      :critic ->
        Scripted.complete(~s({"verdict":"accept","reason":"supported"}), usage: usage())

      :evolver ->
        # Each proposal appends a unique marker so no two candidates share a
        # document; the seed is known to the test, so no workspace read is needed.
        marker = " IMPROVED: verify the second file (#{System.unique_integer([:positive])})"
        seed = seed_profile()
        edited = put_in(seed, ["options", "system"], seed["options"]["system"] <> marker)

        Scripted.tool_call(
          "w1",
          "write",
          %{"path" => "proposal/profile.json", "content" => JSON.encode!(edited)},
          usage: usage()
        )

      :candidate ->
        improved? = String.contains?(request.system || "", "IMPROVED")

        # Only the user turns name the task; the session entry would also
        # carry the system prompt, which must not steer this branch.
        prompt = request.entries |> Enum.filter(&(&1.type == :user)) |> inspect()

        {path, content} =
          cond do
            String.contains?(prompt, "other.txt") and improved? -> {"other.txt", "ok"}
            String.contains?(prompt, "other.txt") -> {"other.txt", "wrong"}
            true -> {"result.txt", "fixed"}
          end

        Scripted.tool_call("c1", "write", %{"path" => path, "content" => content}, usage: usage())
    end
  end

  defp turn(2, request) do
    case role(request) do
      :evolver ->
        manifest = %{
          "rationale" => "The seed never verifies the second file.",
          "hypothesis" => "Naming the verification step fixes dev-2.",
          "targeted_cluster" => nil,
          "mechanism" => "no_verification_after_change",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => ["dev-2"],
          "predicted_at_risk" => []
        }

        Scripted.tool_call(
          "w2",
          "write",
          %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
          usage: usage()
        )

      _other ->
        Scripted.complete("done", usage: usage())
    end
  end

  defp turn(3, _request), do: Scripted.complete("Proposed.", usage: usage())

  defp usage, do: %{"input_tokens" => 20, "output_tokens" => 5}

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "README.md"), "fixture\n")

    manifest_path = Path.join(tmp_dir, "manifest.json")

    File.write!(
      manifest_path,
      JSON.encode!(%{
        "version" => 1,
        "tasks" => [
          task(
            "dev-1",
            "Create result.txt containing exactly fixed.",
            "test \"$(cat result.txt)\" = fixed",
            ["result.txt"]
          ),
          task(
            "dev-2",
            "Create other.txt containing exactly ok.",
            "test \"$(cat other.txt)\" = ok",
            ["other.txt"]
          ),
          task(
            "val-1",
            "Create result.txt containing exactly fixed.",
            "test \"$(cat result.txt)\" = fixed",
            ["result.txt"]
          )
        ]
      })
    )

    %{manifest: manifest_path, output: Path.join(tmp_dir, "campaign")}
  end

  defp task(id, prompt, check, allowed) do
    %{
      "id" => id,
      "prompt" => prompt,
      "cwd" => "fixture",
      "grader" => %{"command" => ["sh", "-c", check]},
      "metadata" => %{
        "cluster_id" => id,
        "tags" => ["discovery"],
        "safety" => %{"allowed_changed_paths" => allowed}
      }
    }
  end

  defp config(ctx, overrides) do
    Keyword.merge(
      [
        id: "campaign-test",
        manifest: ctx.manifest,
        seed_profile: seed_profile(),
        evolver_profile: Proposer.profile("test:model", quota: true),
        critic_profile: Proposer.critic_profile("test:model", quota: true),
        development_case_ids: ["dev-1", "dev-2"],
        validation_case_ids: ["val-1"],
        search: %{"seed" => 3, "fidelity_tiers" => [2]},
        budget: %{
          "maximum_candidates" => 3,
          "maximum_tokens" => 1_000_000,
          "maximum_cost_usd" => 0.0,
          "maximum_time_ms" => 600_000,
          "unknown_cost" => "allow"
        },
        provider: provider_factory(),
        output_dir: ctx.output,
        benchmark: [max_concurrency: 1]
      ],
      overrides
    )
  end

  test "a scripted campaign searches, persists its archive and reports a frontier", ctx do
    assert {:ok, result} = Campaign.run(config(ctx, []))

    assert result.state.status == :completed
    assert length(result.candidates) == 3
    [seed | rest] = result.candidates
    assert seed.mutation_kind == "seed"
    assert Enum.all?(rest, &(&1.mutation_kind in ["clonal", "reaction_norm", "cross_lineage"]))
    assert Enum.all?(rest, &(&1.interface_validation["status"] == "passed"))
    assert Enum.all?(rest, &(&1.extensions["critic"]["verdict"] == "accept"))
    assert Enum.all?(rest, &(&1.extensions["prediction"]["fixes"] == ["dev-2"]))

    # The seed fails dev-2; every improved candidate passes both, so the seed is dominated.
    members = Enum.map(result.frontier.members, & &1["candidate_id"])
    refute seed.id in members
    assert members != []
    assert result.calibration["status"] == "calibrated"

    # A candidate whose parent is the seed predicted the dev-2 fix correctly; a
    # candidate proposed from an already-improved parent predicted a fix its
    # parent had made, which calibration scores as imprecise on purpose.
    seed_children = Enum.filter(rest, &(hd(&1.parents)["id"] == seed.id))
    assert seed_children != []

    for child <- seed_children do
      assert result.calibration["candidates"][child.id]["fix_precision"] == 1.0
    end

    dir = ctx.output
    assert File.exists?(Path.join(dir, "plan.json"))
    assert File.exists?(Path.join(dir, "exposure.json"))
    assert File.exists?(Path.join(dir, "seed/profile.json"))
    assert length(File.ls!(Path.join(dir, "candidates"))) == 3
    assert length(File.ls!(Path.join(dir, "evaluations"))) == length(result.evaluations)
    assert File.exists?(Path.join(dir, "frontier.json"))
    assert File.exists?(Path.join(dir, "report.md"))
    assert {:ok, plan} = Plan.decode(File.read!(Path.join(dir, "plan.json")))
    assert {:ok, state} = State.decode(plan, File.read!(Path.join(dir, "state.json")))
    assert state.status == :completed
    assert plan.proposer == Proposer.identity(Proposer.profile("test:model", quota: true))
    assert Enum.any?(plan.hard_constraints, &(&1["kind"] == "no_solved_regression"))

    # Every candidate's content and every transcript is retained by digest.
    for candidate <- result.candidates do
      assert File.exists?(Path.join([dir, "artifacts", Candidate.content_sha256(candidate)]))
    end

    report = File.read!(Path.join(dir, "report.md"))
    assert report =~ "# Discovery campaign campaign-test"
    assert report =~ "frontier"
  end

  test "the report counts development cases solved on every attempt, not evaluations", ctx do
    config = config(ctx, search: %{"always_case_ids" => ["dev-2"], "always_attempts" => 2})
    assert {:ok, plan, _seed_bytes} = Campaign.plan(config, String.duplicate("a", 64))
    candidate = candidate(plan, "cand_001")

    # dev-1 is solved; dev-2 passed once and failed once, so it is not.
    evaluations = [
      evaluation(plan, candidate, "dev-1", 1, 1.0),
      evaluation(plan, candidate, "dev-2", 1, 1.0),
      evaluation(plan, candidate, "dev-2", 2, 0.0)
    ]

    {:ok, state} = plan |> State.new() |> State.start()
    {:ok, frontier} = Frontier.compute(plan, [candidate], evaluations)

    report =
      Campaign.report(plan, %{
        state: state,
        candidates: [candidate],
        evaluations: evaluations,
        frontier: frontier,
        artifacts: %{},
        incomplete: [],
        calibration: nil,
        digest: nil,
        selection: nil,
        acceptance: nil
      })

    assert report =~ "| cand_001 | seed | seed |"
    assert report =~ "| 1/2 |"
    refute report =~ "| 2/3 |"
  end

  test "a live provider is refused without allow_live and an occupied directory is refused",
       ctx do
    live = config(ctx, provider: {__MODULE__.NotScripted, %{}})
    assert {:error, :live_campaign_requires_allow_live} = Campaign.run(live)

    File.mkdir_p!(ctx.output)
    File.write!(Path.join(ctx.output, "plan.json"), "{}")
    assert {:error, {:output_dir_not_empty, _dir}} = Campaign.run(config(ctx, []))
  end

  test "the plan refuses cases the manifest does not contain and invalid seeds", ctx do
    assert {:error, {:case_not_in_manifest, "ghost"}} =
             Campaign.run(config(ctx, development_case_ids: ["dev-1", "ghost"]))

    assert {:error, :invalid_session_profile} =
             Campaign.run(config(ctx, seed_profile: %{"nope" => true}))
  end

  test "grader references are derived from argv script names only" do
    {:ok, manifest} =
      Manifest.from_map(
        %{
          "version" => 1,
          "tasks" => [
            %{
              "id" => "a",
              "prompt" => "x",
              "cwd" => ".",
              "grader" => %{"command" => ["sh", "check.sh"]}
            },
            %{
              "id" => "b",
              "prompt" => "x",
              "cwd" => ".",
              "grader" => %{"command" => ["sh", "-c", "test -f result.txt"]}
            },
            %{
              "id" => "c",
              "prompt" => "x",
              "cwd" => ".",
              "grader" => %{"command" => ["elixir", "scripts/check.exs"]}
            }
          ]
        },
        File.cwd!()
      )

    assert Campaign.grader_references(manifest) == ["check.exs", "check.sh"]
  end

  defmodule NotScripted do
    @moduledoc false
    @behaviour Lemieux.Provider
    @impl true
    def run(_state, _request, _emit), do: {:error, :unreachable}
  end

  defp candidate(plan, id) do
    scope = plan.scope
    seed = hd(plan.seeds)

    content =
      ArtifactReference.from_bytes("candidate_content", "{}",
        id: id <> "-content",
        media_type: "application/json",
        content_schema: "profile/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why",
        id: id <> "-rationale",
        media_type: "text/plain",
        content_schema: "rationale/v1",
        scope: scope
      )

    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => id,
        "scope" => scope,
        "parents" => [%{"id" => seed["id"], "content_sha256" => seed["content_sha256"]}],
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

  defp evaluation(plan, candidate, case_id, attempt, success) do
    {:ok, evaluation} =
      Evaluation.new(plan, candidate, %{
        "id" => "eval_#{candidate.id}_#{case_id}_#{attempt}",
        "scope" => plan.scope,
        "case_id" => case_id,
        "split" => "development",
        "objectives" => %{"task_success" => success, "requests" => 2.0},
        "safety" => %{"passed" => true, "failures" => []},
        "completeness" => %{
          "usage" => "complete",
          "cost" => "not_applicable",
          "sandbox" => "not_applicable"
        },
        "usage" => %{"total_tokens" => 10},
        "cost" => %{"usd" => nil},
        "latency" => %{"milliseconds" => 5},
        "artifacts" => [],
        "within_budget" => true,
        "terminal" => true,
        "observations" => %{"finish_reason" => ":end_turn", "attempt" => attempt}
      })

    evaluation
  end

  defp seed_profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "You are a careful coding agent.",
          "max_turns" => 6,
          "max_tokens" => 512,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0,
          "tool_descriptions" => %{}
        }
      },
      6
    )
  end
end
