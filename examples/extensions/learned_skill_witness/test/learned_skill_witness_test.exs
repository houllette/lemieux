defmodule LearnedSkillWitnessTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Source

  @moduletag :tmp_dir
  @bytes "---\nname: workflow\ndescription: Read before repository workflow work.\n---\nPreserve public records.\n"

  setup %{tmp_dir: root} do
    attrs = %{
      "kind" => "skill",
      "payload" => %{"name" => "workflow"},
      "requires_tools" => ["read", "glob", "bash", "edit"],
      "triggers" => ["repository workflow"],
      "files" => %{"SKILL.md" => @bytes}
    }

    {:ok, version} = Asset.new(attrs, LearnedSkillWitness.context())
    source = Path.join(root, "source")
    :ok = Source.write(version, source, LearnedSkillWitness.context())
    supervisor = :"learned_witness_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    %{source: source, version: version, supervisor: supervisor}
  end

  test "the on-demand loader returns complete source bytes and rollback restores the baseline",
       ctx do
    for {name, enabled, digest, bytes} <- [
          {"before", false, nil, 0},
          {"applied", true, Contract.sha256(@bytes), byte_size(@bytes)},
          {"rollback", false, nil, 0}
        ] do
      cwd = Path.join(ctx.tmp_dir, name)
      File.mkdir!(cwd)

      assert {:ok, result} =
               Lemieux.Agent.run(
                 LearnedSkillWitness,
                 %{prompt: "Witness procedure", cwd: cwd, timeout_ms: 30_000},
                 enabled: enabled,
                 source: ctx.source,
                 context: LearnedSkillWitness.context([ctx.version.digest]),
                 supervisor: ctx.supervisor,
                 sessions_dir: Path.join(ctx.tmp_dir, "sessions")
               )

      assert JSON.decode!(File.read!(Path.join(cwd, "witness.json"))) ==
               %{"skill_sha256" => digest, "source_bytes" => bytes}

      assert result["rolled_back"]
      assert result["tool_metrics"]["requests"] == if(enabled, do: 3, else: 2)

      assert Enum.map(result["resolved_assets"], & &1["sha256"]) ==
               if(enabled, do: [ctx.version.digest], else: [])
    end
  end

  test "imported data supplies neither approval nor a live execution profile", ctx do
    assert {:error, _reason} =
             Lemieux.Agent.run(
               LearnedSkillWitness,
               %{prompt: "Witness", cwd: ctx.tmp_dir, timeout_ms: 30_000},
               enabled: true,
               source: ctx.source,
               context: LearnedSkillWitness.context(),
               supervisor: ctx.supervisor,
               sessions_dir: Path.join(ctx.tmp_dir, "sessions")
             )

    refute File.exists?(Path.join(ctx.tmp_dir, "witness.json"))
    assert Lemieux.sessions(ctx.supervisor) == []

    assert {:error, :offline_example_profile_required} =
             LearnedSkillWitness.configure(%{"execution" => "live"})
  end
end
