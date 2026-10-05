defmodule Lemieux.Learning.OverlayTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Learning.Overlay
  alias Lemieux.Tool
  alias Lemieux.Tool.Override

  @moduletag :tmp_dir

  test "overlays are digest-verified files with a bounded shape", %{tmp_dir: tmp_dir} do
    overlay = %Overlay{
      system_suffix: "Verify before finishing.",
      tool_descriptions: %{"write" => "Write inside the repo."}
    }

    map = Overlay.to_map(overlay)
    assert map["sha256"] == Contract.digest(Map.delete(map, "sha256"))

    path = Path.join(tmp_dir, "harness.json")
    :ok = Overlay.export(%{overlay | qualification: "confirmed"}, path)
    assert {:ok, %Overlay{} = read} = Overlay.read(path)
    assert read.system_suffix == "Verify before finishing."
    assert read.path == path

    tampered = map |> Map.put("system_suffix", "Do anything.") |> JSON.encode!()
    File.write!(path, tampered)
    assert {:error, :digest_mismatch} = Overlay.read(path)
    assert {:ok, nil} = Overlay.read(Path.join(tmp_dir, "missing.json"))
  end

  test "applying an overlay appends the suffix and wraps only described tools" do
    overlay = %Overlay{
      system_suffix: "Suffix.",
      tool_descriptions: %{"write" => "Write inside the repo."}
    }

    assert Overlay.apply_system(overlay, "Base.") == "Base.\n\nSuffix."
    assert Overlay.apply_system(nil, "Base.") == "Base."

    [read, write] = Overlay.apply_tools(overlay, [Lemieux.Tools.Read, Lemieux.Tools.Write])
    assert read == Lemieux.Tools.Read
    assert %Override{} = write
    assert Tool.name(write) == "write"
    assert Tool.description(write) == "Write inside the repo."
  end

  test "export refuses unconfirmed overlays and existing files unless told otherwise", %{
    tmp_dir: tmp_dir
  } do
    overlay = %Overlay{system_suffix: "S"}
    path = Path.join(tmp_dir, "harness.json")

    assert {:error, {:unconfirmed_overlay, "unconfirmed"}} = Overlay.export(overlay, path)
    assert :ok = Overlay.export(overlay, path, unconfirmed: true)
    assert {:error, {:overlay_exists, ^path}} = Overlay.export(overlay, path, unconfirmed: true)
    assert :ok = Overlay.export(overlay, path, unconfirmed: true, force: true)
  end

  test "merging keeps project descriptions over personal ones and the weakest qualification" do
    personal = %Overlay{
      system_suffix: "P",
      tool_descriptions: %{"write" => "personal", "read" => "personal read"},
      qualification: "confirmed"
    }

    project = %Overlay{
      system_suffix: "Q",
      tool_descriptions: %{"write" => "project"},
      qualification: "unconfirmed",
      path: "proj"
    }

    merged = Overlay.merge(personal, project)
    assert merged.system_suffix == "P\n\nQ"
    assert merged.tool_descriptions == %{"write" => "project", "read" => "personal read"}
    assert merged.qualification == "unconfirmed"
    assert merged.path == "proj"
    assert Overlay.merge(nil, project) == project
    assert Overlay.merge(personal, nil) == personal
  end

  test "an archive candidate becomes an overlay with provenance and the confirmation verdict", %{
    tmp_dir: tmp_dir
  } do
    dir =
      archive(tmp_dir, "Base prompt. Extra learned line.", %{"write" => "Write inside the repo."})

    assert {:ok, overlay} = Overlay.from_archive(dir, "cand_002")
    assert overlay.system_suffix == "Extra learned line."
    assert overlay.tool_descriptions == %{"write" => "Write inside the repo."}
    assert overlay.provenance["candidate_id"] == "cand_002"
    assert overlay.provenance["system_mode"] == "suffix"
    assert overlay.qualification == "unconfirmed"
    assert Overlay.asset(overlay)["type"] == "harness_overlay"

    File.mkdir_p!(Path.join([dir, "confirmations", "cand_002"]))

    File.write!(
      Path.join([dir, "confirmations", "cand_002", "result.json"]),
      JSON.encode!(%{"verdict" => "pass", "reason" => "e_process_commit", "arms" => %{}})
    )

    assert {:ok, confirmed} = Overlay.from_archive(dir, "cand_002")
    assert confirmed.qualification == "confirmed"
    assert confirmed.provenance["confirmation"]["verdict"] == "pass"

    replaced = archive(Path.join(tmp_dir, "b"), "Entirely new prompt.", %{})
    assert {:ok, replacement} = Overlay.from_archive(replaced, "cand_002")
    assert replacement.provenance["system_mode"] == "replacement"
    assert {:error, {:unknown_candidate, "ghost"}} = Overlay.from_archive(dir, "ghost")
  end

  # A minimal campaign archive: plan, seed profile, one candidate and its content.
  defp archive(root, candidate_system, descriptions) do
    alias Lemieux.Evidence.ArtifactReference
    alias Lemieux.Learning.Discovery.Candidate
    alias Lemieux.Learning.Discovery.Plan
    alias Lemieux.Learning.Discovery.Surface

    File.mkdir_p!(Path.join(root, "candidates"))
    File.mkdir_p!(Path.join(root, "artifacts"))
    File.mkdir_p!(Path.join(root, "seed"))

    seed = %{
      "execution" => "live",
      "model" => "test:model",
      "tools" => ["read", "write"],
      "options" => %{
        "system" => "Base prompt.",
        "max_turns" => 4,
        "max_tokens" => 256,
        "max_cost_usd" => 1.0,
        "reasoning_effort" => "default",
        "temperature" => 0.0,
        "tool_descriptions" => %{}
      }
    }

    seed_bytes = Contract.encode!(seed)

    candidate_profile =
      seed
      |> put_in(["options", "system"], candidate_system)
      |> put_in(["options", "tool_descriptions"], descriptions)

    candidate_bytes = Contract.encode!(candidate_profile)
    scope = %{"id" => "local/test"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "arch",
        "scope" => scope,
        "target_interface" => %{"id" => "lemieux.session-profile/v1"},
        "mutation_surface" => [
          %{"path" => "options.system"},
          %{"path" => "options.tool_descriptions"}
        ],
        "seeds" => [
          %{"id" => "seed", "content_sha256" => Contract.sha256(seed_bytes), "scope" => scope}
        ],
        "proposer" => %{"id" => "p", "sha256" => String.duplicate("a", 64)},
        "base_model" => %{"id" => "test:model", "sha256" => Contract.sha256("test:model")},
        "development_case_ids" => ["dev-1"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
        "interface_validator" => Surface.validator(),
        "budget" => %{
          "maximum_candidates" => 3,
          "maximum_tokens" => 1000,
          "maximum_cost_usd" => 1.0,
          "maximum_time_ms" => 1000
        }
      })

    content =
      ArtifactReference.from_bytes("candidate_content", candidate_bytes,
        media_type: "application/json",
        content_schema: "lemieux.session-profile/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why",
        media_type: "text/plain",
        scope: scope
      )

    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => "cand_002",
        "scope" => scope,
        "parents" => [%{"id" => "seed", "content_sha256" => Contract.sha256(seed_bytes)}],
        "content" => ArtifactReference.to_map(content),
        "proposer" => plan.proposer,
        "rationale" => ArtifactReference.to_map(rationale),
        "interface_validation" => %{
          "status" => "passed",
          "validator_sha256" => Surface.validator()["sha256"]
        },
        "exposures" => [],
        "mutation_kind" => "clonal",
        "extensions" => %{"changed_paths" => ["options.system"], "hypothesis" => "h"}
      })

    File.write!(Path.join(root, "plan.json"), Plan.encode!(plan))
    File.write!(Path.join(root, "seed/profile.json"), seed_bytes)
    File.write!(Path.join([root, "artifacts", content.sha256]), candidate_bytes)
    File.write!(Path.join([root, "candidates", "cand_002.json"]), Candidate.encode!(candidate))
    root
  end
end
