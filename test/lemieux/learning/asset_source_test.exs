defmodule Lemieux.Learning.AssetSourceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Extensions.Workspace.SkillTool
  alias Lemieux.Harness
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Extension
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Tools.Read

  @moduletag :tmp_dir

  setup do
    context = %{
      scope: %{"id" => "source-test"},
      binding: %{"runtime_sha256" => Contract.sha256("runtime")},
      trust: "repository",
      tools: ["read"],
      description_tools: [],
      settings_allowlist: [],
      approved_digests: []
    }

    attrs = %{
      "kind" => "skill",
      "payload" => %{"name" => "check-records"},
      "requires_tools" => ["read"],
      "triggers" => ["quoted records"],
      "files" => %{
        "SKILL.md" =>
          "---\nname: check-records\ndescription: Use for quoted records.\n---\nRead [checks](references/checks.md).\n",
        "references/checks.md" => "Preserve empty fields.\n"
      }
    }

    assert {:ok, version} = Asset.new(attrs, context)
    %{context: context, version: version}
  end

  test "source survives the existing Mix export and requires fresh digest approval", ctx do
    project = Path.join(ctx.tmp_dir, "project")
    source = Path.join(project, "priv/learned")
    File.mkdir_p!(Path.dirname(source))
    assert :ok = Source.write(ctx.version, source, ctx.context)
    assert {:ok, version, files} = Source.read(source, ctx.context)
    assert version == ctx.version
    assert files == Path.join(source, "files")

    File.mkdir!(Path.join(project, "lib"))
    File.write!(Path.join(project, "mix.exs"), "# owner-supplied Mix project\n")
    File.write!(Path.join(project, "lib/example.ex"), "defmodule SourceExample do\nend\n")

    paths =
      ~w(mix.exs lib/example.ex priv/learned/asset.json priv/learned/files/SKILL.md priv/learned/files/references/checks.md)

    File.write!(
      Path.join(project, "lemieux-extension.json"),
      JSON.encode!(%{"schema_version" => 1, "module" => "SourceExample", "files" => paths})
    )

    package = Path.join(ctx.tmp_dir, "export")
    assert {:ok, receipt} = Export.export(project, package)
    assert receipt["qualification"] == "unassessed"
    assert :ok = Export.verify(package)
    portable = Path.join(package, "priv/learned")
    assert {:ok, ^version, _files} = Source.read(portable, ctx.context)
    assert {:error, _} = Extension.init(source: portable, context: ctx.context)

    approved = %{ctx.context | approved_digests: [version.digest]}
    base = Harness.new(system: "Original", tools: [Read])

    assert {:ok, loaded} =
             Harness.assemble(base, [{Extension, [source: portable, context: approved]}])

    assert [%{"id" => id, "sha256" => digest, "qualification" => "unconfirmed"}] =
             loaded.harness_context["resolved_assets"]

    assert id == version.id
    assert digest == version.digest
    assert loaded.system =~ "read SKILL.md with the skill tool"
    assert [loader] = loaded.host_tools

    assert {:ok, "Skill: check-records\nFile: references/checks.md\n\nPreserve empty fields.\n"} =
             SkillTool.run(
               loader,
               %{"name" => "check-records", "file" => "references/checks.md"},
               %{
                 cwd: ctx.tmp_dir,
                 environment: Lemieux.Environment.local()
               }
             )

    assert {:ok, ^base} = Harness.assemble(base, [])
    assert {:error, _} = Extension.init(source: portable, context: ctx.context)

    assert {:error, _} =
             Extension.init(source: portable, version: version, root: files, context: approved)
  end

  test "changed or missing dependencies, symlinks and undeclared source files refuse loading",
       ctx do
    for mutation <- [:changed, :missing, :symlink, :extra, :manifest_symlink, :root_symlink] do
      root = Path.join(ctx.tmp_dir, to_string(mutation))
      assert :ok = Source.write(ctx.version, root, ctx.context)
      file = Path.join(root, "files/references/checks.md")

      case mutation do
        :changed ->
          File.write!(file, "altered")

        :missing ->
          File.rm!(file)

        :symlink ->
          File.write!(Path.join(ctx.tmp_dir, "outside"), "Preserve empty fields.\n")
          File.rm!(file)
          File.ln_s!(Path.join(ctx.tmp_dir, "outside"), file)

        :extra ->
          File.write!(Path.join(root, "secret.txt"), "undeclared")

        :manifest_symlink ->
          File.cp!(Path.join(root, "asset.json"), Path.join(ctx.tmp_dir, "outside"))
          File.rm!(Path.join(root, "asset.json"))
          File.ln_s!(Path.join(ctx.tmp_dir, "outside"), Path.join(root, "asset.json"))

        :root_symlink ->
          File.rename!(root, root <> ".real")
          File.ln_s!(root <> ".real", root)
      end

      assert {:error, _} = Source.read(root, ctx.context)
    end
  end

  test "scope, runtime and host policy are validated again at the receiving host", ctx do
    root = Path.join(ctx.tmp_dir, "source")
    assert :ok = Source.write(ctx.version, root, ctx.context)

    for context <- [
          %{ctx.context | scope: %{"id" => "other-project"}},
          %{ctx.context | binding: %{"runtime_sha256" => Contract.sha256("changed")}},
          %{ctx.context | tools: []}
        ] do
      assert {:error, _} = Source.read(root, context)
    end

    assert {:error, :eexist} = Source.write(ctx.version, root, ctx.context)
    assert {:ok, _, _} = Source.read(root, ctx.context)
  end

  test "forged qualification, incompatible runtime and broken loader metadata are rejected",
       ctx do
    root = Path.join(ctx.tmp_dir, "source")
    assert :ok = Source.write(ctx.version, root, ctx.context)
    path = Path.join(root, "asset.json")
    original = JSON.decode!(File.read!(path))

    for changed <- [
          Map.put(original, "qualification", "confirmed"),
          put_in(original, ["content", "qualification"], "confirmed"),
          put_in(original, ["runtime", "elixir"], "0.0.0"),
          Map.put(original, "asset_sha256", Contract.sha256("other"))
        ] do
      changed = Map.put(changed, "sha256", Contract.digest(changed, ["sha256"]))
      File.write!(path, JSON.encode!(changed))
      assert {:error, _} = Source.read(root, ctx.context)
    end

    bad = put_in(ctx.version.content, ["triggers"], ["absent"])

    assert {:ok, version} =
             Asset.new(Map.take(bad, ~w(kind payload files requires_tools triggers)), ctx.context)

    destination = Path.join(ctx.tmp_dir, "bad-loader")
    assert {:error, _} = Source.write(version, destination, ctx.context)
    refute File.exists?(destination)
  end

  test "unsupported registry metadata is not silently dropped and oversized documents refuse reads",
       ctx do
    root = Path.join(ctx.tmp_dir, "source")

    assert {:error, :unsupported_asset_source_metadata} =
             Source.write(%{ctx.version | parent_id: "prior-registry-version"}, root, ctx.context)

    refute File.exists?(root)
    assert :ok = Source.write(ctx.version, root, ctx.context)
    File.write!(Path.join(root, "asset.json"), String.duplicate(" ", 131_073))
    assert {:error, :invalid_asset_source_layout} = Source.read(root, ctx.context)
  end

  test "configuration-only source preserves empty file trees and current allowlists", ctx do
    context = %{ctx.context | settings_allowlist: ["search.glob_after_requests"]}

    attrs = %{
      "kind" => "configuration",
      "payload" => %{"extension" => "search", "glob_after_requests" => 0},
      "files" => %{},
      "requires_tools" => [],
      "triggers" => []
    }

    assert {:ok, version} = Asset.new(attrs, context)
    root = Path.join(ctx.tmp_dir, "configuration")
    assert :ok = Source.write(version, root, context)
    assert {:ok, ^version, _files} = Source.read(root, context)
    assert {:error, _} = Source.read(root, ctx.context)
  end
end
