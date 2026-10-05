defmodule Lemieux.Learning.Discovery.MetaTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Meta
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # One three-turn script serves every session at both levels. Roles: the
  # outer evolver (its task prompt carries "Meta level"), the inner evolver,
  # the critic, and the coding-agent candidate sessions of the inner runs.
  defp provider_factory(log) do
    fn ->
      Scripted.new([
        fn request -> turn(1, request, log) end,
        fn request -> turn(2, request, log) end,
        fn request -> turn(3, request, log) end
      ])
    end
  end

  defp role(request) do
    user = request.entries |> Enum.filter(&(&1.type == :user)) |> inspect()

    cond do
      String.starts_with?(request.system || "", "You are Lemieux's proposal critic") ->
        :critic

      String.starts_with?(request.system || "", "You are Lemieux's harness proposer") and
          String.contains?(user, "Meta level") ->
        :outer_evolver

      String.starts_with?(request.system || "", "You are Lemieux's harness proposer") ->
        :inner_evolver

      true ->
        :candidate
    end
  end

  defp turn(1, request, log) do
    role = role(request)
    Agent.update(log, &[role | &1])

    case role do
      :critic ->
        Scripted.complete(~s({"verdict":"accept","reason":"ok"}))

      :outer_evolver ->
        # Edit the inner proposer's instructions; the seed is the module default.
        inner = Proposer.profile("test:model", quota: true)

        edited =
          put_in(
            inner,
            ["options", "system"],
            inner["options"]["system"] <> "\nMETA: always predict at least one fix."
          )

        Scripted.tool_call("w1", "write", %{
          "path" => "proposal/profile.json",
          "content" => JSON.encode!(edited)
        })

      :inner_evolver ->
        seed = coding_seed()

        edited =
          put_in(
            seed,
            ["options", "system"],
            seed["options"]["system"] <> " IMPROVED #{System.unique_integer([:positive])}"
          )

        Scripted.tool_call("w1", "write", %{
          "path" => "proposal/profile.json",
          "content" => JSON.encode!(edited)
        })

      :candidate ->
        improved? = String.contains?(request.system || "", "IMPROVED")
        prompt = request.entries |> Enum.filter(&(&1.type == :user)) |> inspect()
        hard? = String.contains?(prompt, "hard")
        content = if hard? and not improved?, do: "wrong", else: "fixed"

        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => content},
          usage: usage()
        )
    end
  end

  defp turn(2, request, _log) do
    case role(request) do
      :outer_evolver ->
        manifest = %{
          "rationale" => "The inner proposer never predicted fixes.",
          "hypothesis" => "Requiring a predicted fix improves calibration.",
          "targeted_cluster" => nil,
          "mechanism" => "unknown",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => ["inner-a"],
          "predicted_at_risk" => []
        }

        Scripted.tool_call("w2", "write", %{
          "path" => "proposal/manifest.json",
          "content" => JSON.encode!(manifest)
        })

      :inner_evolver ->
        manifest = %{
          "rationale" => "r",
          "hypothesis" => "h",
          "targeted_cluster" => nil,
          "mechanism" => "unknown",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => ["dev-2"],
          "predicted_at_risk" => []
        }

        Scripted.tool_call("w2", "write", %{
          "path" => "proposal/manifest.json",
          "content" => JSON.encode!(manifest)
        })

      _other ->
        Scripted.complete("done", usage: usage())
    end
  end

  defp turn(3, _request, _log), do: Scripted.complete("Proposed.", usage: usage())

  # Usage on every turn: a provider that reports none leaves every evaluation
  # "partial", and partial evidence is ineligible by design.
  defp usage, do: %{"input_tokens" => 20, "output_tokens" => 5}

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "README.md"), "fixture\n")
    manifest = Path.join(tmp_dir, "manifest.json")

    tasks =
      [{"dev-1", "easy"}, {"dev-2", "hard"}, {"val-1", "easy"}]
      |> Enum.map(fn {id, kind} ->
        %{
          "id" => id,
          "prompt" => "Create result.txt containing exactly fixed (#{kind}).",
          "cwd" => "fixture",
          "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
          "metadata" => %{
            "cluster_id" => id,
            "safety" => %{"allowed_changed_paths" => ["result.txt"]}
          }
        }
      end)

    File.write!(manifest, JSON.encode!(%{"version" => 1, "tasks" => tasks}))
    {:ok, log} = Agent.start_link(fn -> [] end)

    inner_template = [
      manifest: manifest,
      seed_profile: coding_seed(),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      development_case_ids: ["dev-1", "dev-2"],
      validation_case_ids: ["val-1"],
      search: %{"seed" => 3, "fidelity_tiers" => [2]},
      budget: %{
        "maximum_candidates" => 2,
        "maximum_tokens" => 1_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      },
      benchmark: [max_concurrency: 1]
    ]

    config = [
      id: "meta-test",
      output_dir: Path.join(tmp_dir, "meta"),
      provider: provider_factory(log),
      seed_evolver_profile: Proposer.profile("test:model", quota: true),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      inner: [inner_a: inner_template, inner_b: inner_template],
      validation_inner: [:inner_b],
      search: %{"seed" => 5, "fidelity_tiers" => [1]},
      budget: %{
        "maximum_candidates" => 2,
        "maximum_tokens" => 10_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      }
    ]

    %{config: config, log: log}
  end

  test "the outer campaign edits the proposer profile and scores it by inner yield and calibration",
       ctx do
    assert {:ok, result} = Meta.run(ctx.config)

    assert result.state.status == :completed
    assert [seed, edited] = result.candidates
    assert seed.mutation_kind == "seed"
    assert edited.interface_validation["status"] == "passed", inspect(edited.interface_validation)
    assert edited.extensions["changed_paths"] == ["options.system"]

    # The outer candidate is a valid proposer profile carrying the meta edit.
    {:ok, profile} = JSON.decode(Map.fetch!(result.artifacts, edited.content.sha256))
    assert :ok = Profile.validate(profile)
    assert profile["options"]["system"] =~ "META: always predict"

    # Each outer evaluation is one inner campaign on the development template only.
    assert Enum.all?(result.evaluations, &(&1.case_id == "inner_a" and &1.split == "development"))
    assert length(result.evaluations) == 2

    for evaluation <- result.evaluations do
      assert Map.keys(evaluation.objectives) |> Enum.sort() == ["brier", "frontier_yield"]

      assert evaluation.objectives["frontier_yield"] == 1.0
      assert evaluation.objectives["brier"] < 1.0
      # Spend is measured and kept as an observation, not ranked by default.
      refute Map.has_key?(evaluation.objectives, "proposer_tokens")
      assert is_float(evaluation.observations["proposer_tokens"])
      assert evaluation.observations["proposer_tokens"] > 0
      assert evaluation.safety["passed"]
      assert evaluation.within_budget
      assert [%{kind: "meta_report"}] = evaluation.artifacts
      assert evaluation.observations["inner_status"] == "completed"
    end

    roles = ctx.log |> Agent.get(& &1) |> Enum.frequencies()
    assert roles[:outer_evolver] == 1
    assert roles[:inner_evolver] == 2
    assert roles[:candidate] >= 8

    dir = ctx.config[:output_dir]
    assert {:ok, plan} = Plan.decode(File.read!(Path.join(dir, "plan.json")))
    assert plan.target_interface == %{"id" => "lemieux.proposer-profile/v1"}
    assert plan.development_case_ids == ["inner_a"] and plan.validation_case_ids == ["inner_b"]
    assert File.exists?(Path.join([dir, "inner", seed.id, "inner_a", "report.md"]))
    assert File.exists?(Path.join([dir, "inner", edited.id, "inner_a", "report.md"]))
    assert File.exists?(Path.join(dir, "report.md"))
    refute File.exists?(Path.join([dir, "inner", seed.id, "inner_b"]))

    # The outer proposer's workspace received the inner report as evidence.
    proposal = Path.join([dir, "proposals", "proposal-002", "evidence", "transcripts"])
    assert Enum.any?(File.ls!(proposal), &String.ends_with?(&1, "-meta_report.md"))
  end

  test "the confirmation lane pairs a proposer profile against the seed on the validation inner campaigns",
       ctx do
    assert {:ok, run} = Meta.run(ctx.config)
    assert [seed, edited] = run.candidates
    dir = ctx.config[:output_dir]

    assert {:ok, result} = Meta.confirm(ctx.config, edited.id)

    # Both arms are scripted identically, so the paired objectives tie and the
    # lane must say so rather than pass a no-op edit.
    assert result["verdict"] == "inconclusive"
    assert result["reason"] == "identical_objectives"
    assert result["arms"] == %{"control" => seed.id, "variant" => edited.id}
    assert result["sample"] == %{"validation_campaigns" => 1, "grade" => "development"}
    assert result["minimum_effect"] == %{"frontier_yield" => 0.1, "brier" => 0.05}

    assert [pair] = result["pairs"]
    assert pair["case_id"] == "inner_b"
    assert Map.keys(pair["control"]) |> Enum.sort() == ["brier", "frontier_yield"]
    assert Map.keys(pair["variant"]) |> Enum.sort() == ["brier", "frontier_yield"]
    assert pair["control"]["frontier_yield"] == 1.0 and pair["control"]["brier"] < 1.0
    assert pair["improvement"] == %{"frontier_yield" => 0.0, "brier" => 0.0}
    assert pair["gamed"] == []
    assert pair["runs"]["control"]["status"] == "completed"
    assert pair["runs"]["variant"]["status"] == "completed"

    assert result["resources"]["inner_campaigns"] == 2
    assert result["resources"]["tokens"] > 0
    assert is_integer(result["timing"]["elapsed_ms"])
    assert result["plan_id"] == "meta-test"

    # One inner campaign per arm per validation template, in single-use directories.
    confirmation = Path.join([dir, "confirmations", edited.id])
    assert File.exists?(Path.join([confirmation, "inner_b", "control", "report.md"]))
    assert File.exists?(Path.join([confirmation, "inner_b", "variant", "report.md"]))
    refute File.exists?(Path.join(confirmation, "inner_a"))

    {:ok, control_plan} =
      Plan.decode(File.read!(Path.join([confirmation, "inner_b", "control", "plan.json"])))

    {:ok, variant_plan} =
      Plan.decode(File.read!(Path.join([confirmation, "inner_b", "variant", "plan.json"])))

    assert control_plan.proposer == Proposer.identity(ctx.config[:seed_evolver_profile])

    {:ok, variant_profile} =
      JSON.decode(File.read!(Path.join([dir, "artifacts", edited.content.sha256])))

    assert variant_plan.proposer == Proposer.identity(variant_profile)
    refute variant_plan.proposer == control_plan.proposer

    assert {:ok, persisted} = JSON.decode(File.read!(Path.join(confirmation, "result.json")))
    assert persisted["verdict"] == "inconclusive"
    assert persisted["pairs"] == result["pairs"]

    report = File.read!(Path.join(confirmation, "report.md"))
    assert report =~ "**inconclusive**"
    assert report =~ "n=1"
    assert report =~ "development-grade"
    assert report =~ "inner_b"

    # The directory is single-use, and the lane refuses what it cannot judge.
    assert {:error, {:confirmation_dir_exists, ^confirmation}} =
             Meta.confirm(ctx.config, edited.id)

    assert {:error, {:unknown_candidate, "ghost"}} = Meta.confirm(ctx.config, "ghost")
    assert {:error, :invalid_control} = Meta.confirm(ctx.config, seed.id)

    assert {:error, :live_campaign_requires_allow_live} =
             Meta.confirm(
               Keyword.put(ctx.config, :provider, {__MODULE__.NotScripted, %{}}),
               edited.id,
               suffix: "live"
             )

    refute File.exists?(confirmation <> "-live")
  end

  describe "verdict/2" do
    @minimum_effect %{"frontier_yield" => 0.1, "brier" => 0.05}

    test "passes when no validation campaign is worse and one is better by the minimum effect" do
      pairs = [
        pair("inner_b", %{"frontier_yield" => 0.1, "brier" => 0.0}),
        pair("inner_c", %{"frontier_yield" => 0.0, "brier" => 0.0})
      ]

      assert Meta.verdict(pairs, @minimum_effect) == {"pass", "improved_beyond_minimum_effect"}
    end

    test "fails when any campaign regresses by the minimum effect on either objective" do
      pairs = [
        pair("inner_b", %{"frontier_yield" => 0.5, "brier" => 0.2}),
        pair("inner_c", %{"frontier_yield" => 0.0, "brier" => -0.05})
      ]

      assert Meta.verdict(pairs, @minimum_effect) == {"fail", "regressed_beyond_minimum_effect"}
    end

    test "is inconclusive when every difference is inside the minimum effect" do
      pairs = [pair("inner_b", %{"frontier_yield" => 0.05, "brier" => -0.01})]
      assert Meta.verdict(pairs, @minimum_effect) == {"inconclusive", "within_minimum_effect"}

      identical = [pair("inner_b", %{"frontier_yield" => 0.0, "brier" => 0.0})]
      assert Meta.verdict(identical, @minimum_effect) == {"inconclusive", "identical_objectives"}
      assert Meta.verdict([], @minimum_effect) == {"inconclusive", "no_validation_campaigns"}
    end

    test "a gamed inner candidate in the variant arm is a safety failure whatever the scores" do
      pairs = [
        %{pair("inner_b", %{"frontier_yield" => 1.0, "brier" => 0.5}) | "gamed" => ["cand_003"]}
      ]

      assert Meta.verdict(pairs, @minimum_effect) ==
               {"safety_failure", "variant_inner_candidate_referenced_grader"}
    end

    test "a judged objective missing from a pair cannot count as no worse" do
      pairs = [pair("inner_b", %{"frontier_yield" => 0.5})]
      assert Meta.verdict(pairs, @minimum_effect) == {"inconclusive", "objective_missing:brier"}
    end

    defp pair(case_id, improvement) do
      %{
        "case_id" => case_id,
        "control" => %{"frontier_yield" => 0.5, "brier" => 0.3},
        "variant" => %{"frontier_yield" => 0.5, "brier" => 0.3},
        "improvement" => improvement,
        "gamed" => []
      }
    end
  end

  defmodule NotScripted do
    @moduledoc false
    @behaviour Lemieux.Provider
    @impl true
    def run(_state, _request, _emit), do: {:error, :unreachable}
  end

  test "objectives score an inner run with no calibrated candidate as maximally uncalibrated" do
    frontier = %Lemieux.Learning.Discovery.Frontier{
      id: "f",
      sha256: "",
      plan_id: "p",
      plan_sha256: "",
      objectives: [],
      members: [%{"candidate_id" => "cand_002"}],
      excluded: []
    }

    result = %{
      candidates: [
        candidate_stub("cand_001", "seed", 0),
        candidate_stub("cand_002", "clonal", 120),
        candidate_stub("cand_003", "clonal", 80)
      ],
      frontier: frontier,
      calibration: %{"aggregate" => %{"mean_brier" => nil}}
    }

    assert Meta.objectives(result) == %{
             "frontier_yield" => 0.5,
             "brier" => 1.0,
             "proposer_tokens" => 200.0
           }

    assert Meta.objectives(%{result | candidates: [candidate_stub("cand_001", "seed", 0)]})[
             "frontier_yield"
           ] == 0.0
  end

  test "the plan requires development and validation inner campaigns", ctx do
    assert {:error, :validation_inner_required} =
             Meta.plan(Keyword.put(ctx.config, :validation_inner, []))

    assert {:error, :development_inner_required} =
             Meta.plan(Keyword.put(ctx.config, :validation_inner, [:inner_a, :inner_b]))

    assert {:error, :unknown_validation_inner} =
             Meta.plan(Keyword.put(ctx.config, :validation_inner, [:ghost]))
  end

  defp candidate_stub(id, kind, tokens) do
    %Lemieux.Learning.Discovery.Candidate{
      id: id,
      sha256: "",
      created_at: DateTime.utc_now(),
      plan_id: "p",
      plan_sha256: "",
      scope: %{},
      parents: [],
      content: nil,
      proposer: %{},
      rationale: nil,
      interface_validation: %{},
      exposures: [],
      mutation_kind: kind,
      extensions: %{"proposer_usage" => %{"tokens" => tokens}}
    }
  end

  defp coding_seed do
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
