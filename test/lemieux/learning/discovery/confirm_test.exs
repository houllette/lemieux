defmodule Lemieux.Learning.Discovery.ConfirmTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Experiment.Plan, as: ExperimentPlan
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Confirm
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # Candidate sessions: the seed profile fails every "b-" case; a profile
  # carrying the IMPROVED marker passes everything. The model in the request
  # is recorded so the transfer swap can be asserted.
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
    cond do
      String.starts_with?(request.system || "", "You are Lemieux's harness proposer") -> :evolver
      String.starts_with?(request.system || "", "You are Lemieux's proposal critic") -> :critic
      true -> :candidate
    end
  end

  defp turn(1, request, log) do
    case role(request) do
      :critic ->
        Scripted.complete(~s({"verdict":"accept","reason":"ok"}))

      :evolver ->
        seed = seed_profile()

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
        Agent.update(log, &[request.model | &1])
        improved? = String.contains?(request.system || "", "IMPROVED")
        prompt = request.entries |> Enum.filter(&(&1.type == :user)) |> inspect()
        hard? = String.contains?(prompt, "hard case")
        content = if hard? and not improved?, do: "wrong", else: "fixed"
        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => content})
    end
  end

  defp turn(2, request, _log) do
    case role(request) do
      :evolver ->
        manifest = %{
          "rationale" => "r",
          "hypothesis" => "The edit fixes the hard cases.",
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
        Scripted.complete("done")
    end
  end

  defp turn(3, _request, _log), do: Scripted.complete("Proposed.")

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "README.md"), "fixture\n")

    tasks =
      [
        {"dev-1", "easy", "dev-a"},
        {"dev-2", "hard case", "dev-b"},
        {"val-1", "easy", "val"},
        {"hold-a1", "easy", "hold-a"},
        {"hold-a2", "easy", "hold-a"},
        {"hold-b1", "hard case", "hold-b"},
        {"hold-b2", "hard case", "hold-b"},
        {"hold-c1", "hard case", "hold-c"}
      ]
      |> Enum.map(fn {id, kind, cluster} ->
        %{
          "id" => id,
          "prompt" => "Create result.txt containing exactly fixed (#{kind}).",
          "cwd" => "fixture",
          "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
          "metadata" => %{
            "cluster_id" => cluster,
            "tags" => ["discovery"],
            "safety" => %{"allowed_changed_paths" => ["result.txt"]}
          }
        }
      end)

    manifest = Path.join(tmp_dir, "manifest.json")
    File.write!(manifest, JSON.encode!(%{"version" => 1, "tasks" => tasks}))
    {:ok, log} = Agent.start_link(fn -> [] end)

    config = [
      id: "confirm-test",
      manifest: manifest,
      seed_profile: seed_profile(),
      evolver_profile: Proposer.profile("test:model", quota: true),
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
      provider: provider_factory(log),
      output_dir: Path.join(tmp_dir, "campaign"),
      benchmark: [max_concurrency: 1]
    ]

    {:ok, result} = Campaign.run(config)
    [seed, improved] = result.candidates
    %{config: config, log: log, seed: seed, improved: improved}
  end

  test "confirms a frontier member on holdout clusters with both arms on the target model", ctx do
    Agent.update(ctx.log, fn _ -> [] end)

    assert {:ok, result} =
             Confirm.run(ctx.config, ctx.improved.id,
               model: "test:target",
               stopping_rule: %{"minimum_pairs" => 2, "confidence" => 0.9},
               minimum_effect: 0.1
             )

    assert result["verdict"] == "pass"

    assert result["arms"] == %{
             "control" => ctx.seed.id,
             "variant" => ctx.improved.id,
             "model" => "test:target"
           }

    # Three holdout clusters, each a control/variant pair of cluster pass rates.
    assert length(result["pairs"]) == 3
    assert Enum.all?(result["pairs"], &(&1["variant"] == 1.0))
    assert Enum.map(result["pairs"], & &1["control"]) == [1.0, 0.0, 0.0]
    refute Map.has_key?(result["per_case"], "dev-1")
    refute Map.has_key?(result["per_case"], "val-1")

    # Every confirmation session ran on the target model, never the search model.
    models = ctx.log |> Agent.get(& &1) |> Enum.uniq()
    assert models == ["test:target"]

    dir = Path.join([ctx.config[:output_dir], "confirmations", ctx.improved.id])
    assert {:ok, plan} = ExperimentPlan.decode(File.read!(Path.join(dir, "experiment-plan.json")))
    assert plan.variant["digest"] == ctx.improved.content.sha256
    assert plan.control["confirmation_model"] == "test:target"
    assert plan.control["search_model"] == "test:model"
    # A quota search profile stays quota unless the caller declares a metered target.
    assert plan.control["variant"] == ["model"]

    assert plan.sample["holdout_case_ids"] == [
             "hold-a1",
             "hold-a2",
             "hold-b1",
             "hold-b2",
             "hold-c1"
           ]

    assert plan.provenance["discovery"]["candidate_id"] == ctx.improved.id

    assert {:ok, exposure} = Exposure.decode(File.read!(Path.join(dir, "exposure.json")))
    assert exposure.consumer_role == "confirmation_evaluator"
    assert Enum.sort(exposure.direct_case_ids) == plan.sample["holdout_case_ids"]
    assert File.exists?(Path.join(dir, "decision.json"))
    assert File.exists?(Path.join(dir, "report.json"))

    # The directory is single-use.
    assert {:error, {:confirmation_dir_exists, _dir}} =
             Confirm.run(ctx.config, ctx.improved.id, model: "test:target")
  end

  test "the e-process default keeps sampling when three clusters cannot be decisive", ctx do
    assert {:ok, result} = Confirm.run(ctx.config, ctx.improved.id, model: "test:target")
    assert result["verdict"] == "inconclusive"
    assert result["reason"] == "e_process_continue"
    assert result["quality"]["holdout"]["e_process"]["pairs"] == 3
    assert result["quality"]["holdout"]["e_process"]["improvement"] > 1.0
  end

  test "holdout cases must be unseen, clustered, and at least two clusters", ctx do
    assert {:error, {:holdout_case_exposed_to_search, "dev-1"}} =
             Confirm.prepare(ctx.config, ctx.improved.id, holdout_case_ids: ["dev-1", "hold-a1"])

    assert {:error, :fewer_than_two_holdout_clusters} =
             Confirm.prepare(ctx.config, ctx.improved.id,
               holdout_case_ids: ["hold-a1", "hold-a2"]
             )

    assert {:error, {:unknown_candidate, "ghost"}} = Confirm.prepare(ctx.config, "ghost")

    {:ok, metered} =
      Confirm.prepare(ctx.config, ctx.improved.id,
        model: "test:target",
        usage_mode: "metered",
        max_cost_per_attempt_usd: 0.05
      )

    assert "quota_to_metered" in metered.plan.control["variant"]
    assert metered.variant_profile["options"]["max_cost_usd"] == 0.05
    refute Map.has_key?(metered.variant_profile["options"], "max_requests")

    assert {:error, :live_campaign_requires_allow_live} =
             Confirm.run(
               Keyword.put(ctx.config, :provider, {__MODULE__.NotScripted, %{}}),
               ctx.improved.id
             )
  end

  defmodule NotScripted do
    @moduledoc false
    @behaviour Lemieux.Provider
    @impl true
    def run(_state, _request, _emit), do: {:error, :unreachable}
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
