# Explicit offline review of a complete archived learned skill:
# mix run examples/learned_skill_export.exs --source ARCHIVE --output NEW_DIRECTORY
Code.require_file("extensions/learned_skill_witness/lib/learned_skill_witness.ex", __DIR__)

defmodule LearnedSkillExportDemo do
  @moduledoc false
  alias Lemieux.Benchmark.Command
  alias Lemieux.Contract
  alias Lemieux.Experiment.CodeGate
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Tree

  @spec run(source :: Path.t(), output :: Path.t()) :: :ok
  def run(source, output) do
    # This context validates archival integrity only. It is never used to
    # activate an asset. Receiving authority comes from context/1 below.
    {:ok, document} = Tree.read(Path.join(source, "asset.json"))

    archival_context = %{
      scope: document["content"]["scope"],
      binding: document["content"]["binding"],
      trust: "repository",
      tools: ~w(read write edit bash glob),
      description_tools: [],
      settings_allowlist: [],
      helper_extensions: [],
      approved_digests: []
    }

    {:ok, original, _files} = Source.read(source, archival_context)
    "skill" = original.content["kind"]

    true =
      Enum.all?(original.content["files"], fn {file, _bytes} ->
        Path.extname(file) in ~w(.md .txt .json)
      end)

    {:error, _changed_scope} = Source.read(source, LearnedSkillWitness.context())

    attrs = Map.take(original.content, ~w(kind payload files requires_tools triggers))
    {:ok, derived} = Asset.new(attrs, LearnedSkillWitness.context())
    true = derived.content["files"] == original.content["files"]
    true = derived.id != original.id and derived.digest != original.digest
    "unconfirmed" = derived.content["qualification"]

    root = Path.expand(output)
    File.mkdir_p!(Path.dirname(root))
    File.mkdir!(root)
    :ok = File.chmod(root, 0o700)
    project = Path.join(root, "project")
    template = Path.expand("extensions/learned_skill_witness", __DIR__)
    File.mkdir!(project)

    for file <- ~w(mix.exs LICENSE lib/learned_skill_witness.ex) do
      target = Path.join(project, file)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(template, file), target)
    end

    File.mkdir!(Path.join(project, "priv"))
    :ok = Source.write(original, Path.join(project, "priv/original"), archival_context)
    :ok = Source.write(derived, Path.join(project, "priv/learned"), LearnedSkillWitness.context())

    provenance = %{
      "kind" => "explicit_unconfirmed_receiving_scope_derivation/v1",
      "original_asset_id" => original.id,
      "original_asset_sha256" => original.digest,
      "original_created_at" => DateTime.to_iso8601(original.created_at),
      "derived_asset_id" => derived.id,
      "derived_asset_sha256" => derived.digest,
      "complete_file_bytes_preserved" => true,
      "qualification_inherited" => false,
      "host_authority_exported" => false,
      "file_sha256" =>
        Map.new(original.content["files"], fn {path, bytes} -> {path, Contract.sha256(bytes)} end)
    }

    :ok = Tree.write(Path.join(project, "priv/provenance.json"), provenance)
    manifest(project, original.content["files"])
    package = Path.join(root, "package")
    {:ok, inventory} = Export.export(project, package)
    :ok = Export.verify(package)
    "unassessed" = inventory["qualification"]

    profile = %{
      "execution" => "scripted",
      "model" => "test:learned-skill-witness",
      "tools" => ~w(read write edit bash glob),
      "options" => %{"enabled" => false, "asset_sha256" => derived.digest}
    }

    {:ok, baseline} = Build.freeze(package, Path.join(root, "baseline-build"), profile)

    {:ok, adapted} =
      Build.freeze(
        package,
        Path.join(root, "adapted-build"),
        put_in(profile, ["options", "enabled"], true)
      )

    before = episode(root, "before", baseline)
    applied = episode(root, "applied", adapted)
    undo = episode(root, "after-undo", baseline)
    empty = %{"skill_sha256" => nil, "source_bytes" => 0}
    true = before["witness"] == empty and undo["witness"] == empty

    expected = %{
      "skill_sha256" => Contract.sha256(original.content["files"]["SKILL.md"]),
      "source_bytes" => byte_size(original.content["files"]["SKILL.md"])
    }

    true = applied["witness"] == expected
    true = before["assets"] == [] and undo["assets"] == []
    [%{"id" => id, "sha256" => digest}] = applied["assets"]
    true = id == derived.id and digest == derived.digest
    installed = install(root, template, package, inventory, derived)
    true = installed["witness"] == expected and installed["resolved_assets"] == applied["assets"]
    true = installed["rolled_back"]
    {:error, {:missing_evidence, missing}} = CodeGate.evaluate(%{})

    report = %{
      "kind" => "actual_learned_skill_native_export_mechanism/v1",
      "driver_sha256" => Contract.sha256(File.read!(__ENV__.file)),
      "qualification" => "unassessed",
      "benefit" => "not_tested_by_scripted_witness",
      "independent_confirmation" => "not_run",
      "hosted_requests" => 0,
      "production_active" => false,
      "package_sha256" => inventory["sha256"],
      "provenance" => provenance,
      "baseline_build_sha256" => baseline.sha256,
      "adapted_build_sha256" => adapted.sha256,
      "before" => before,
      "applied" => applied,
      "after_undo" => undo,
      "installed_consumer" => installed,
      "missing_code_gate_evidence" => missing
    }

    :ok =
      Tree.write(
        Path.join(root, "review.json"),
        Map.put(report, "sha256", Contract.digest(report))
      )

    IO.puts("Learned skill native review: " <> Path.join(root, "review.json"))
    IO.puts("Unassessed source export, fresh Mix consumer, actual skill read and exact rollback.")
  end

  defp manifest(project, skill_files) do
    files =
      ~w(mix.exs LICENSE lib/learned_skill_witness.ex priv/provenance.json) ++
        Enum.flat_map(~w(original learned), fn kind ->
          [
            "priv/#{kind}/asset.json"
            | Enum.map(Map.keys(skill_files), &("priv/#{kind}/files/" <> &1))
          ]
        end)

    graph = Map.new(files, &{&1, []})
    graph = Map.put(graph, "lib/learned_skill_witness.ex", ["priv/learned/asset.json"])

    graph =
      Enum.reduce(~w(original learned), graph, fn kind, acc ->
        Map.put(
          acc,
          "priv/#{kind}/asset.json",
          Enum.map(Map.keys(skill_files), &("priv/#{kind}/files/" <> &1))
        )
      end)

    :ok =
      Tree.write(Path.join(project, "lemieux-extension.json"), %{
        "schema_version" => 1,
        "module" => "LearnedSkillWitness",
        "files" => Enum.sort(files),
        "dependencies" => graph,
        "capabilities" => ["workspace_read", "workspace_write", "workspace_shell"]
      })
  end

  defp episode(root, name, build) do
    cwd = Path.join(root, name)
    File.mkdir!(cwd)

    {:ok, result} =
      Build.run(build, %{prompt: "Witness the packaged skill", cwd: cwd, timeout_ms: 30_000})

    true = result["rolled_back"]

    %{
      "witness" => JSON.decode!(File.read!(Path.join(cwd, "witness.json"))),
      "assets" => result["resolved_assets"],
      "requests" => result["tool_metrics"]["requests"],
      "harness_restored" => result["rolled_back"],
      "frozen_build_sha256" => result["frozen_build_sha256"]
    }
  end

  defp install(root, template, package, inventory, version) do
    consumer = Path.join(root, "consumer")
    File.mkdir!(consumer)
    File.cp!(Path.join(template, "consumer.exs"), Path.join(consumer, "consumer.exs"))
    checkout = Path.expand("..", __DIR__)
    File.cp!(Path.join(checkout, "mix.lock"), Path.join(consumer, "mix.lock"))

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule LearnedSkillConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :learned_skill_consumer, version: "0.1.0", deps: [{:learned_skill_witness, path: #{inspect(package)}}]]
    end
    """)

    options = [
      cwd: consumer,
      timeout: 120_000,
      max_output_bytes: 128_000,
      env: %{
        "LEMIEUX_EXTENSION_BASE" => checkout,
        "LMX_CONFIG" => "none",
        "MIX_ENV" => "test",
        "MIX_BUILD_PATH" => Path.join(consumer, "_build"),
        "MIX_DEPS_PATH" => Path.join(checkout, "deps")
      }
    ]

    for {name, args} <- [
          {"deps", ["mix", "deps.get"]},
          {"run", ["mix", "run", "consumer.exs", version.digest, inventory["sha256"], package]}
        ] do
      {:ok, result} = Command.run(args, options)
      File.write!(Path.join(consumer, name <> ".log"), result["output"])

      if result["exit_status"] != 0 or result["timed_out"],
        do: raise("consumer #{name} failed; inspect #{consumer}")
    end

    consumer
    |> Path.join("installed.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.put("mix_lock_sha256", Contract.sha256(File.read!(Path.join(consumer, "mix.lock"))))
  end
end

case OptionParser.parse(System.argv(), strict: [source: :string, output: :string]) do
  {opts, [], []} when length(opts) == 2 ->
    LearnedSkillExportDemo.run(Keyword.fetch!(opts, :source), Keyword.fetch!(opts, :output))

  _invalid ->
    raise ArgumentError,
          "usage: mix run examples/learned_skill_export.exs --source ARCHIVE --output NEW_DIRECTORY"
end
