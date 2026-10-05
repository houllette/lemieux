defmodule Lemieux.Learning.Discovery.MetaResumeTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Workspace
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Meta
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # The same three-turn script the meta tests use: one script serves the outer
  # proposer, the inner proposers, the critic and every coding candidate.
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
        inner = Proposer.profile("test:model", quota: true)

        edited =
          put_in(
            inner,
            ["options", "system"],
            inner["options"]["system"] <> "\nMETA #{System.unique_integer([:positive])}"
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
        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "fixed"},
          usage: usage()
        )
    end
  end

  defp turn(2, request, _log) do
    case role(request) do
      role when role in [:outer_evolver, :inner_evolver] ->
        manifest = %{
          "rationale" => "r",
          "hypothesis" => "h",
          "targeted_cluster" => nil,
          "mechanism" => "unknown",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => ["dev-1"],
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

  defp usage, do: %{"input_tokens" => 20, "output_tokens" => 5}

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "README.md"), "fixture\n")
    manifest = Path.join(tmp_dir, "manifest.json")

    tasks =
      Enum.map(["dev-1", "val-1"], fn id ->
        %{
          "id" => id,
          "prompt" => "Create result.txt containing exactly fixed.",
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
    # Set while the first attempt runs; cleared before the resume.
    {:ok, crash} = Agent.start_link(fn -> true end)

    %{manifest: manifest, log: log, crash: crash, output: Path.join(tmp_dir, "meta")}
  end

  defp config(ctx) do
    # The interruption: the inner `beta` campaign raises while preparing any
    # workspace, so `alpha` finishes and `beta` dies part way. That is exactly
    # the shape resume has to survive — one candidate with one bought inner
    # campaign and one lost one.
    workspace = fn task, context ->
      if Agent.get(ctx.crash, & &1) and String.contains?(context.workspace_root, "beta") do
        raise "interrupted while evaluating #{context.runtime}"
      else
        Workspace.copy(task, context)
      end
    end

    inner_template = [
      manifest: ctx.manifest,
      seed_profile: coding_seed(),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      development_case_ids: ["dev-1"],
      validation_case_ids: ["val-1"],
      search: %{"seed" => 3, "fidelity_tiers" => [1]},
      budget: %{
        # Two candidates, so every inner campaign runs exactly one inner
        # proposer session. Counting those is what distinguishes a reused
        # archive from a rerun one.
        "maximum_candidates" => 2,
        "maximum_tokens" => 1_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      },
      benchmark: [max_concurrency: 1, workspace: workspace]
    ]

    [
      id: "meta-resume",
      output_dir: ctx.output,
      provider: provider_factory(ctx.log),
      seed_evolver_profile: Proposer.profile("test:model", quota: true),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      inner: [alpha: inner_template, beta: inner_template, gamma: inner_template],
      validation_inner: [:gamma],
      search: %{"seed" => 5, "fidelity_tiers" => [2]},
      budget: %{
        "maximum_candidates" => 1,
        "maximum_tokens" => 10_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      }
    ]
  end

  test "an interrupted meta campaign resumes without paying for a finished inner campaign twice",
       ctx do
    config = config(ctx)

    assert_raise RuntimeError, ~r/interrupted while evaluating/, fn -> Meta.run(config) end

    assert [seed_dir] = File.ls!(Path.join(ctx.output, "inner"))
    alpha = Path.join([ctx.output, "inner", seed_dir, "alpha"])
    beta = Path.join([ctx.output, "inner", seed_dir, "beta"])

    assert Campaign.finished?(alpha), "the first inner campaign should have run to a frontier"
    refute Campaign.finished?(beta)

    before = %{
      report: File.read!(Path.join(alpha, "report.md")),
      frontier: File.read!(Path.join(alpha, "frontier.json")),
      sessions: Agent.get(ctx.log, &length/1)
    }

    {:ok, plan} = Campaign.read_plan(ctx.output)
    {:ok, interrupted} = State.decode(plan, File.read!(Path.join(ctx.output, "state.json")))
    assert interrupted.status == :running
    assert interrupted.evaluations == []

    Agent.update(ctx.crash, fn _flag -> false end)
    assert {:ok, result} = Meta.resume(config)

    assert result.state.status == :completed

    # The outer evaluations cover both development templates, and the seed's
    # `alpha` archive is byte-for-byte the one the interrupted run bought: a
    # rerun would have minted fresh candidate ids and a different frontier.
    assert result.evaluations |> Enum.map(& &1.case_id) |> Enum.sort() == ["alpha", "beta"]
    assert File.read!(Path.join(alpha, "report.md")) == before.report
    assert File.read!(Path.join(alpha, "frontier.json")) == before.frontier
    assert Campaign.finished?(beta)

    # And the resume paid only for what was missing. Every inner campaign runs
    # exactly one inner proposer session, so two inner campaigns ran in total
    # across both attempts — three would mean `alpha` was bought twice.
    roles = ctx.log |> Agent.get(& &1) |> Enum.frequencies()
    assert roles[:inner_evolver] == 2
    assert Agent.get(ctx.log, &length/1) > before.sessions

    # The reused result is real evidence, not a placeholder.
    for evaluation <- result.evaluations do
      assert Map.keys(evaluation.objectives) |> Enum.sort() == ["brier", "frontier_yield"]
      assert evaluation.observations["inner_status"] == "completed"
      assert [%{kind: "meta_report"}] = evaluation.artifacts
    end
  end

  test "resume refuses an archive the configuration no longer describes", ctx do
    config = config(ctx)
    Agent.update(ctx.crash, fn _flag -> false end)
    assert {:ok, _result} = Meta.run(config)

    other_proposer =
      Keyword.put(
        config,
        :evolver_profile,
        Proposer.profile("test:model", quota: true, temperature: 0.9)
      )

    assert {:error, :resume_evolver_profile_mismatch} = Meta.resume(other_proposer)

    renamed = Keyword.update!(config, :inner, &Keyword.drop(&1, [:beta]))
    assert {:error, :resume_inner_campaigns_mismatch} = Meta.resume(renamed)

    assert {:error, :enoent} =
             Meta.resume(Keyword.put(config, :output_dir, Path.join(ctx.output, "missing")))

    # A campaign that already finished is not resumable, and says so rather
    # than starting a second search over the same archive.
    assert {:error, {:not_resumable, :completed}, %State{}} = Meta.resume(config)
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
