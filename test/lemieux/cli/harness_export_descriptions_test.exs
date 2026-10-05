defmodule Lemieux.CLI.HarnessExportDescriptionsTest do
  # `lmx harness export` writes the repository's `.lmx/harness.json` unless
  # told otherwise, and a repository's overlay may no longer re-describe
  # tools: `lmx` applies its system-prompt text alone. An export that wrote
  # tool descriptions there and said nothing left a person believing a
  # learned improvement was in force while every start dropped it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Harness, as: HarnessCLI
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Overlay
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  @description "Run one shell command in the working directory."

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

    config = [
      id: "export-descriptions-test",
      manifest: manifest,
      seed_profile: seed_profile(),
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

  # The proposer re-describes `bash` and extends the prompt; the case run
  # writes the answer.
  defp turn(1, request) do
    if proposer?(request) do
      edited =
        seed_profile()
        |> put_in(["options", "system"], "Base. Learned line.")
        |> put_in(["options", "tool_descriptions"], %{"bash" => @description})

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
    if proposer?(request) do
      manifest = %{
        "rationale" => "r",
        "hypothesis" => "h",
        "targeted_cluster" => nil,
        "mechanism" => "unknown",
        "changed_paths" => ["options.system", "options.tool_descriptions"],
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

  defp proposer?(request),
    do: String.starts_with?(request.system || "", "You are Lemieux's harness proposer")

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

  defp export(ctx, target) do
    capture_io(:stderr, fn ->
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
    end)
  end

  test "exporting tool descriptions to a repository's overlay says they will not apply", ctx do
    target = Path.join([ctx.tmp_dir, "repository", ".lmx", "harness.json"])
    stderr = export(ctx, target)

    # Written as asked: the file is the person's to review and commit.
    assert {:ok, %Overlay{tool_descriptions: %{"bash" => @description}}} = Overlay.read(target)

    assert stderr =~ "its descriptions of bash do not apply from #{target}"
    assert stderr =~ "Only your own ~/.lmx/harness.json may describe tools"
    assert stderr =~ "--to ~/.lmx/harness.json"
  end

  test "the note says when nothing in the overlay would apply" do
    overlay = %Overlay{tool_descriptions: %{"edit" => "x", "bash" => "y"}}
    note = HarnessCLI.descriptions_note(overlay, ".lmx/harness.json", "/home/someone/.lmx/h.json")

    assert note =~ "nothing in this overlay applies from .lmx/harness.json"
    assert note =~ "It only describes tools (bash, edit)"
  end

  test "nothing is said when the descriptions will apply, or there are none" do
    personal = "/home/someone/.lmx/harness.json"
    described = %Overlay{system_suffix: "s", tool_descriptions: %{"bash" => "y"}}

    assert HarnessCLI.descriptions_note(described, personal, personal) == nil

    assert HarnessCLI.descriptions_note(%Overlay{system_suffix: "s"}, ".lmx/h.json", personal) ==
             nil
  end
end
