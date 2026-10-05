defmodule Lemieux.CLI.HarnessExportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Harness, as: HarnessCLI
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Overlay
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture")
    File.mkdir_p!(fixture)
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
            "metadata" => %{
              "cluster_id" => "a",
              "safety" => %{"allowed_changed_paths" => ["result.txt"]}
            }
          },
          %{
            "id" => "val-1",
            "prompt" => "unused",
            "cwd" => "fixture",
            "grader" => %{"command" => ["sh", "-c", "false"]},
            "metadata" => %{"cluster_id" => "b"}
          }
        ]
      })
    )

    provider = fn ->
      Scripted.new([
        fn request -> turn(1, request) end,
        fn request -> turn(2, request) end,
        fn _request -> Scripted.complete("done", usage: usage()) end
      ])
    end

    seed = seed_profile()

    config = [
      id: "export-test",
      manifest: manifest,
      seed_profile: seed,
      evolver_profile: Proposer.profile("test:model", quota: true),
      critic_profile: false,
      development_case_ids: ["dev-1"],
      validation_case_ids: ["val-1"],
      search: %{"seed" => 1, "fidelity_tiers" => [1]},
      budget: %{
        "maximum_candidates" => 2,
        "maximum_tokens" => 1_000_000,
        "maximum_cost_usd" => 0.0,
        "maximum_time_ms" => 600_000,
        "unknown_cost" => "allow"
      },
      provider: provider,
      output_dir: Path.join(tmp_dir, "campaign")
    ]

    {:ok, result} = Campaign.run(config)
    [_seed, candidate] = result.candidates
    %{archive: config[:output_dir], candidate: candidate, tmp_dir: tmp_dir}
  end

  defp turn(1, request) do
    if String.starts_with?(request.system || "", "You are Lemieux's harness proposer") do
      edited = put_in(seed_profile(), ["options", "system"], "Base. Learned line.")

      Scripted.tool_call(
        "w1",
        "write",
        %{"path" => "proposal/profile.json", "content" => JSON.encode!(edited)},
        usage: usage()
      )
    else
      Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "fixed"},
        usage: usage()
      )
    end
  end

  defp turn(2, request) do
    if String.starts_with?(request.system || "", "You are Lemieux's harness proposer") do
      manifest = %{
        "rationale" => "r",
        "hypothesis" => "h",
        "targeted_cluster" => nil,
        "mechanism" => "unknown",
        "changed_paths" => ["options.system"],
        "predicted_fixes" => [],
        "predicted_at_risk" => []
      }

      Scripted.tool_call(
        "w2",
        "write",
        %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
        usage: usage()
      )
    else
      Scripted.complete("done", usage: usage())
    end
  end

  defp seed_profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "Base.",
          "max_turns" => 4,
          "max_tokens" => 256,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0,
          "tool_descriptions" => %{}
        }
      },
      4
    )
  end

  defp usage, do: %{"input_tokens" => 5, "output_tokens" => 2}

  test "export refuses an unconfirmed candidate unless asked, then writes a labeled overlay",
       ctx do
    target = Path.join(ctx.tmp_dir, "out/harness.json")

    output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 HarnessCLI.run(["export", ctx.archive, ctx.candidate.id, "--to", target])
      end)

    assert output =~ "unconfirmed"
    refute File.exists?(target)

    output =
      capture_io(fn ->
        assert :ok =
                 HarnessCLI.run([
                   "export",
                   ctx.archive,
                   ctx.candidate.id,
                   "--to",
                   target,
                   "--unconfirmed"
                 ])
      end)

    assert output =~ "exported unconfirmed overlay"
    assert {:ok, overlay} = Overlay.read(target)
    assert overlay.system_suffix == "Learned line."
    assert overlay.provenance["candidate_id"] == ctx.candidate.id
    assert overlay.qualification == "unconfirmed"

    output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 HarnessCLI.run([
                   "export",
                   ctx.archive,
                   ctx.candidate.id,
                   "--to",
                   target,
                   "--unconfirmed"
                 ])
      end)

    assert output =~ "overlay_exists"
  end
end
