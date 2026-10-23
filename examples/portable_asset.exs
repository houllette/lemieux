# Offline, from the repository root:
# mix run examples/portable_asset.exs --output tmp/portable-asset-review
# The output must be new; failures retain their evidence for inspection.
Code.require_file("extensions/portable_procedure/lib/portable_procedure.ex", __DIR__)

defmodule PortableAssetDemo do
  @moduledoc false
  alias Lemieux.Benchmark.Command
  alias Lemieux.Contract
  alias Lemieux.Experiment.CodeGate
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Tree

  @spec run(output :: Path.t()) :: :ok
  def run(output) do
    root = Path.expand(output)
    File.mkdir_p!(Path.dirname(root))
    File.mkdir!(root)
    :ok = File.chmod(root, 0o700)
    project = Path.join(root, "project")
    template = Path.expand("extensions/portable_procedure", __DIR__)
    :ok = File.mkdir(project)

    # Preserve owner-supplied code verbatim. Only data is materialized.
    for file <- ~w(mix.exs LICENSE lib/portable_procedure.ex lemieux-extension.json) do
      target = Path.join(project, file)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(template, file), target)
    end

    File.mkdir!(Path.join(project, "priv"))

    attrs = %{
      "kind" => "skill",
      "payload" => %{"name" => "preserve-records"},
      "requires_tools" => ["write"],
      "triggers" => ["normalize records"],
      "files" =>
        Map.new(~w(SKILL.md references/rules.json), fn file ->
          {file, File.read!(Path.join([template, "procedure", file]))}
        end)
    }

    {:ok, version} = Asset.new(attrs, PortableProcedure.context())
    :ok = Source.write(version, Path.join(project, "priv/learned"), PortableProcedure.context())
    package = Path.join(root, "package")
    {:ok, inventory} = Export.export(project, package)
    :ok = Export.verify(package)
    "unassessed" = inventory["qualification"]

    profile = %{
      "execution" => "scripted",
      "model" => "test:portable-procedure",
      "tools" => ["read", "write"],
      "options" => %{"enabled" => false, "asset_sha256" => version.digest}
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
    after_undo = episode(root, "after-undo", baseline)
    ["alpha", "beta"] = before["records"]
    ["alpha", "", "beta"] = applied["records"]
    true = before["records"] == after_undo["records"]
    [] = before["assets"]
    [] = after_undo["assets"]
    [%{"id" => id, "sha256" => digest}] = applied["assets"]
    true = id == version.id and digest == version.digest
    [2, 3, 2] = Enum.map([before, applied, after_undo], & &1["requests"])
    installed = install(root, template, package, inventory, version)
    true = installed["records"] == applied["records"]
    true = installed["resolved_assets"] == applied["assets"]
    true = installed["rolled_back"]
    {:error, {:missing_evidence, missing}} = CodeGate.evaluate(%{})

    report = %{
      "schema_version" => 1,
      "kind" => "portable_asset_mechanism",
      "driver_sha256" => Contract.sha256(File.read!(__ENV__.file)),
      "qualification" => "unassessed",
      "independent_confirmation" => "not_run",
      "hosted_requests" => 0,
      "production_active" => false,
      "package_sha256" => inventory["sha256"],
      "asset_sha256" => version.digest,
      "baseline_build_sha256" => baseline.sha256,
      "adapted_build_sha256" => adapted.sha256,
      "before" => before,
      "applied" => applied,
      "after_undo" => after_undo,
      "installed_consumer" => installed,
      "missing_code_gate_evidence" => missing
    }

    report = Map.put(report, "sha256", Contract.digest(report))
    :ok = Tree.write(Path.join(root, "review.json"), report)
    IO.puts("Portable asset review: " <> Path.join(root, "review.json"))

    IO.puts(
      "Export → fresh session → on-demand skill → artifact → exact harness rollback passed."
    )

    IO.puts(
      "Unassessed; independent confirmation and reviewed CodeGate evidence remain required."
    )
  end

  defp install(root, template, package, inventory, version) do
    consumer = Path.join(root, "consumer")
    File.mkdir!(consumer)
    File.cp!(Path.join(template, "consumer.exs"), Path.join(consumer, "consumer.exs"))
    checkout = Path.expand("..", __DIR__)
    File.cp!(Path.join(checkout, "mix.lock"), Path.join(consumer, "mix.lock"))

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule PortableConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :portable_consumer, version: "0.1.0", deps: [{:portable_procedure, path: #{inspect(package)}}]]
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

  defp episode(root, name, build) do
    cwd = Path.join(root, name)
    File.mkdir!(cwd)
    File.write!(Path.join(cwd, "records.json"), JSON.encode!([" alpha ", "", " beta "]))

    input = %{
      prompt: "Normalize records while preserving meaningful entries",
      cwd: cwd,
      timeout_ms: 30_000
    }

    {:ok, result} = Build.run(build, input)
    true = result["rolled_back"]

    %{
      "records" => JSON.decode!(File.read!(Path.join(cwd, "normalized.json"))),
      "assets" => result["resolved_assets"],
      "requests" => result["tool_metrics"]["requests"],
      "harness_restored" => result["rolled_back"],
      "frozen_build_sha256" => result["frozen_build_sha256"]
    }
  end
end

case OptionParser.parse(System.argv(), strict: [output: :string]) do
  {[output: output], [], []} ->
    PortableAssetDemo.run(output)

  _invalid ->
    raise ArgumentError, "usage: mix run examples/portable_asset.exs --output NEW_DIRECTORY"
end
