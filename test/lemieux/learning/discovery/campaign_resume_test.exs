defmodule Lemieux.Learning.Discovery.CampaignResumeTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Workspace
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # Every candidate session succeeds on its one case; the interesting part is
  # which sessions run before and after the interruption.
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
        marker = " EDIT #{System.unique_integer([:positive])}"
        seed = seed_profile()
        edited = put_in(seed, ["options", "system"], seed["options"]["system"] <> marker)

        Scripted.tool_call("w1", "write", %{
          "path" => "proposal/profile.json",
          "content" => JSON.encode!(edited)
        })

      :candidate ->
        Agent.update(log, &[request.system | &1])
        Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "fixed"})
    end
  end

  defp turn(2, request, _log) do
    case role(request) do
      :evolver ->
        manifest = %{
          "rationale" => "r",
          "hypothesis" => "h",
          "targeted_cluster" => nil,
          "mechanism" => "unknown",
          "changed_paths" => ["options.system"],
          "predicted_fixes" => [],
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
    manifest = Path.join(tmp_dir, "manifest.json")

    File.write!(
      manifest,
      JSON.encode!(%{
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
      })
    )

    {:ok, log} = Agent.start_link(fn -> [] end)
    {:ok, crash} = Agent.start_link(fn -> true end)
    %{manifest: manifest, output: Path.join(tmp_dir, "campaign"), log: log, crash: crash}
  end

  defp config(ctx) do
    seed_id_prefix = "cand_001_"

    # The workspace callback stands in for a process interruption: it raises
    # while preparing the first evaluation of any non-seed candidate, but only
    # while the crash flag is set.
    workspace = fn task, context ->
      if Agent.get(ctx.crash, & &1) and not String.starts_with?(context.runtime, seed_id_prefix) do
        raise "interrupted while evaluating #{context.runtime}"
      else
        Workspace.copy(task, context)
      end
    end

    [
      id: "resume-test",
      manifest: ctx.manifest,
      seed_profile: seed_profile(),
      evolver_profile: Proposer.profile("test:model", quota: true),
      critic_profile: Proposer.critic_profile("test:model", quota: true),
      development_case_ids: ["dev-1"],
      validation_case_ids: ["val-1"],
      search: %{"seed" => 5, "fidelity_tiers" => [1]},
      budget: %{
        "maximum_candidates" => 3,
        "maximum_tokens" => 1_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      },
      provider: provider_factory(ctx.log),
      output_dir: ctx.output,
      benchmark: [max_concurrency: 1, workspace: workspace]
    ]
  end

  test "an interrupted campaign resumes from its archive without repeating recorded work", ctx do
    config = config(ctx)

    assert_raise RuntimeError, ~r/interrupted while evaluating cand_00[23]/, fn ->
      Campaign.run(config)
    end

    {:ok, plan} = Plan.decode(File.read!(Path.join(ctx.output, "plan.json")))
    {:ok, interrupted} = State.decode(plan, File.read!(Path.join(ctx.output, "state.json")))
    assert interrupted.status == :running
    # The widening rule may expand twice before the first non-seed evaluation.
    assert length(interrupted.candidates) in [2, 3]
    assert length(interrupted.evaluations) == 1
    sessions_before = Agent.get(ctx.log, &length/1)
    assert sessions_before == 1

    Agent.update(ctx.crash, fn _flag -> false end)
    assert {:ok, result} = Campaign.resume(config)

    assert result.state.status == :completed
    assert length(result.candidates) == 3

    assert Enum.map(Enum.take(result.candidates, length(interrupted.candidates)), & &1.id) ==
             Enum.map(interrupted.candidates, & &1["id"])

    # The seed's evaluation was loaded, not rerun: only the two later candidates ran sessions.
    seed_system = seed_profile()["options"]["system"]
    systems_after = ctx.log |> Agent.get(& &1) |> Enum.reverse() |> Enum.drop(sessions_before)
    assert length(systems_after) == 2
    refute seed_system in systems_after
    assert Enum.all?(systems_after, &String.contains?(&1, "EDIT"))

    # The resumed state keeps the interrupted history and adds the new work.
    assert Enum.take(result.state.events, length(interrupted.events)) == interrupted.events
    assert length(result.evaluations) == 3
    assert Enum.count(File.ls!(Path.join(ctx.output, "evaluations"))) == 3
    assert File.exists?(Path.join(ctx.output, "report.md"))
  end

  test "resume refuses a completed campaign, a different evolver profile and a missing archive",
       ctx do
    config = config(ctx)
    Agent.update(ctx.crash, fn _flag -> false end)
    assert {:ok, _result} = Campaign.run(config)
    assert {:error, {:not_resumable, :completed}, %State{}} = Campaign.resume(config)

    other =
      Keyword.put(
        config,
        :evolver_profile,
        Proposer.profile("test:model", quota: true, temperature: 0.9)
      )

    assert {:error, :resume_evolver_profile_mismatch} = Campaign.resume(other)

    assert {:error, :enoent} =
             Campaign.resume(Keyword.put(config, :output_dir, Path.join(ctx.output, "missing")))
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
