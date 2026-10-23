defmodule PortableProcedureTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Source

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {:ok, version} = Asset.new(attrs(), PortableProcedure.context())
    source = Path.join(root, "source")
    :ok = Source.write(version, source, PortableProcedure.context())
    supervisor = :"portable_example_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    %{source: source, version: version, supervisor: supervisor}
  end

  test "a real session consumes packaged rules; removing the adaptation restores baseline behavior",
       ctx do
    for {mode, expected, requests} <- [
          {"baseline", ["alpha", "beta"], 2},
          {"adapted", ["alpha", "", "beta"], 3},
          {"rollback", ["alpha", "beta"], 2}
        ] do
      cwd = Path.join(ctx.tmp_dir, mode)
      File.mkdir!(cwd)
      File.write!(Path.join(cwd, "records.json"), JSON.encode!([" alpha ", "", " beta "]))
      input = %{prompt: "Normalize the records", cwd: cwd, timeout_ms: 10_000}

      assert {:ok, result} =
               Agent.run(PortableProcedure, input,
                 enabled: mode == "adapted",
                 source: ctx.source,
                 context: PortableProcedure.context([ctx.version.digest]),
                 supervisor: ctx.supervisor,
                 sessions_dir: Path.join(ctx.tmp_dir, "sessions")
               )

      assert JSON.decode!(File.read!(Path.join(cwd, "normalized.json"))) == expected
      assert result["rolled_back"]
      assert result["tool_metrics"]["requests"] == requests

      assert Enum.map(result["resolved_assets"], & &1["sha256"]) ==
               if(mode == "adapted", do: [ctx.version.digest], else: [])
    end
  end

  test "an imported source does not grant permission to use itself", ctx do
    File.write!(Path.join(ctx.tmp_dir, "records.json"), "[]")
    input = %{prompt: "Normalize", cwd: ctx.tmp_dir, timeout_ms: 10_000}

    assert {:error, _} =
             Agent.run(PortableProcedure, input,
               enabled: true,
               source: ctx.source,
               context: PortableProcedure.context(),
               supervisor: ctx.supervisor,
               sessions_dir: Path.join(ctx.tmp_dir, "sessions")
             )

    refute File.exists?(Path.join(ctx.tmp_dir, "normalized.json"))
    assert Lemieux.sessions(ctx.supervisor) == []

    assert {:error, :offline_example_profile_required} =
             PortableProcedure.configure(%{"execution" => "live"})
  end

  defp attrs do
    %{
      "kind" => "skill",
      "payload" => %{"name" => "preserve-records"},
      "requires_tools" => ["write"],
      "triggers" => ["normalize records"],
      "files" => %{
        "SKILL.md" =>
          "---\nname: preserve-records\ndescription: Use to normalize records.\n---\nRead [rules](references/rules.json) before editing.\n",
        "references/rules.json" => JSON.encode!(%{"preserve_empty" => true})
      }
    }
  end
end
