defmodule Lemieux.Learning.AssetTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.Workspace.SkillTool
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Extension
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Read
  @moduletag :tmp_dir

  defp context do
    %{
      scope: %{"id" => "project/test"},
      binding: %{"runtime_sha256" => String.duplicate("a", 64)},
      trust: "repository",
      tools: ["read", "bash", "grep", "glob"],
      description_tools: ["read"],
      settings_allowlist: ["search.glob_after_requests"],
      approved_digests: []
    }
  end

  defp skill do
    %{
      "kind" => "skill",
      "payload" => %{"name" => "check-records"},
      "requires_tools" => ["read"],
      "triggers" => ["quoted records"],
      "files" => %{
        "SKILL.md" =>
          "---\nname: check-records\ndescription: Use when repairing quoted records.\n---\nRead [the procedure](references/checks.md).\n",
        "references/checks.md" => "Inspect quoted fields before editing. Preserve empty fields.\n"
      }
    }
  end

  test "a recurring procedure uses the real on-demand loader and snapshot identity", %{
    tmp_dir: dir
  } do
    context = context()
    assert {:ok, version} = Asset.new(skill(), context)
    root = Path.join(dir, "asset")
    assert {:ok, discovered} = Asset.materialize(version, root, context)
    assert discovered.name == "check-records"
    base = %Harness{system: "Original", tools: Lemieux.Tools.default()}

    spec =
      {Extension,
       [version: version, root: root, context: %{context | approved_digests: [version.digest]}]}

    personal = SkillTool.new([%{discovered | source: :personal}])

    assert_raise ArgumentError, ~r/already loaded skill/, fn ->
      Harness.assemble(%{base | host_tools: [personal]}, [spec])
    end

    custom_loader = Override.new!(Read, name: "skill")

    assert_raise ArgumentError, ~r/host skill loader/, fn ->
      Harness.assemble(%{base | host_tools: [custom_loader]}, [spec])
    end

    assert {:ok, applied} = Harness.assemble(base, [spec])
    assert applied.system =~ "quoted records"
    refute applied.system =~ "Preserve empty fields"
    assert [loader] = applied.host_tools
    assert Tool.name(loader) == "skill"

    assert {:ok, body} =
             SkillTool.run(
               loader,
               %{"name" => "check-records", "file" => "references/checks.md"},
               %{cwd: dir, environment: Lemieux.Environment.local()}
             )

    assert body =~ "Preserve empty fields"
    assert hd(applied.harness_context["resolved_assets"])["sha256"] == version.digest
    assert {:ok, ^base} = Harness.assemble(base, [])
    File.write!(Path.join(root, "references/checks.md"), "changed")
    refute match?({:ok, _}, Asset.installed(version, root, context))

    assert {:error, _} =
             SkillTool.run(
               loader,
               %{"name" => "check-records", "file" => "references/checks.md"},
               %{cwd: dir, environment: Lemieux.Environment.local()}
             )
  end

  test "missing transitive helpers, broken triggers, unavailable tools and unsafe files refuse candidates",
       %{tmp_dir: dir} do
    context = context()

    for attrs <- [
          update_in(skill()["files"], &Map.delete(&1, "references/checks.md")),
          put_in(skill()["files"]["references/checks.md"], "Read [missing](missing.md)."),
          put_in(skill()["files"]["../escape.md"], "escape"),
          put_in(skill()["files"]["scripts/run.sh"], "echo executable"),
          %{skill() | "requires_tools" => ["new_authority"]},
          %{skill() | "kind" => "native_module"}
        ],
        do: assert({:error, _} = Asset.new(attrs, context))

    assert {:ok, version} = Asset.new(%{skill() | "triggers" => ["absent trigger"]}, context)
    assert {:error, _} = Asset.materialize(version, Path.join(dir, "bad-trigger"), context)
  end

  test "trusted descriptions and shipped settings cannot change host authority", %{tmp_dir: dir} do
    attrs = %{
      "kind" => "tool_description",
      "payload" => %{"read" => "Read current bytes before editing."},
      "files" => %{},
      "requires_tools" => ["read"],
      "triggers" => []
    }

    assert {:error, _} = Asset.new(attrs, context())
    assert {:error, _} = Asset.new(skill(), %{context() | binding: %{}})

    assert {:error, _} =
             Asset.new(skill(), %{
               context()
               | binding: Map.put(context().binding, "api_key", "must not serialize")
             })

    personal = %{context() | trust: "personal"}
    assert {:ok, version} = Asset.new(attrs, personal)
    root = Path.join(dir, "description")
    assert {:ok, nil} = Asset.materialize(version, root, personal)
    assert {:error, _} = Extension.init(version: version, root: root, context: personal)

    assert {:ok, state} =
             Extension.init(
               version: version,
               root: root,
               context: %{personal | approved_digests: [version.digest]}
             )

    base = %Harness{tools: Lemieux.Tools.default()}
    applied = Extension.apply(base, state)
    assert Enum.map(applied.tools, &Tool.name/1) == Enum.map(base.tools, &Tool.name/1)
    assert Tool.description(hd(applied.tools)) == "Read current bytes before editing."
    refute match?(:ok, Asset.verify(version, %{personal | binding: %{}}))

    assert {:error, _} =
             Asset.new(put_in(attrs["payload"]["read"], String.duplicate("x", 3000)), personal)

    settings = %{
      attrs
      | "kind" => "configuration",
        "payload" => %{"extension" => "search", "glob_after_requests" => 0}
    }

    assert {:ok, _} = Asset.new(settings, context())

    for field <- ["module", "model", "permission_mode", "api_key", "environment", "command"],
        do:
          assert(
            {:error, _} = Asset.new(put_in(settings["payload"][field], "injected"), context())
          )
  end
end
