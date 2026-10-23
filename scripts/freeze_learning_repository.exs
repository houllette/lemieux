# Provider-free finalization of curator-owned fixture bytes and control counts.
alias Lemieux.CLI.Learning.Leases
alias Lemieux.CLI.Learning.Repositories
alias Lemieux.Contract
{opts, [], []} = OptionParser.parse(System.argv(), strict: [template: :string])
path = Keyword.fetch!(opts, :template)
root = Path.dirname(path)
manifest = path |> File.read!() |> JSON.decode!()
[item] = manifest["tasks"]
{:ok, source_sha} = Leases.source_digest(item["source"])
{:ok, private_sha} = Leases.source_digest(item["private_tests"])

item =
  item |> Map.put("source_sha256", source_sha) |> Map.put("private_tests_sha256", private_sha)

manifest = Map.put(manifest, "tasks", [item])
controls_path = Path.join(root, "controls.json")
manifest_path = Path.join(root, "manifest.json")
File.write!(manifest_path, Contract.encode!(manifest))
{[fixture], metadata} = Repositories.materialize(manifest_path, Path.join(root, "control-import"))
public = %{fixture | cases: fixture.probe_cases}
oracle = Path.join(root, "oracle")
negative_public = Repositories.grade(public, fixture.task.cwd, fixture.environment)
negative_private = Repositories.grade(fixture, fixture.task.cwd, fixture.environment)
positive_public = Repositories.grade(public, oracle, fixture.environment)
positive_private = Repositories.grade(fixture, oracle, fixture.environment)

controls = %{
  "metadata" => Map.delete(metadata, "manifest_sha256"),
  "inputs_sha256" =>
    Contract.digest(
      Map.take(item, [
        "source_sha256",
        "private_tests_sha256",
        "image",
        "immutable_paths",
        "public_pytest_args"
      ])
    ),
  "hosted_requests" => 0,
  "negative_public" => negative_public,
  "negative_private" => negative_private,
  "positive_public" => positive_public,
  "positive_private" => positive_private
}

File.write!(controls_path, Contract.encode!(controls))
true = positive_public["passed"] and positive_private["passed"]
false = negative_public["passed"] or negative_private["passed"]
# Counts are frozen before any model is authorized. A candidate cannot pass by
# skipping the failing check and reporting the remaining tests as all green.
item =
  Map.put(item, "minimum_checks", %{
    "public" => positive_public["checks"],
    "private" => positive_private["checks"]
  })

manifest =
  manifest
  |> Map.put("tasks", [item])
  |> put_in(["metadata", "controls_sha256"], Contract.sha256(File.read!(controls_path)))

File.write!(manifest_path, Contract.encode!(manifest))

IO.puts(
  JSON.encode!(%{
    "manifest" => manifest_path,
    "hosted_requests" => 0,
    "source_sha256" => source_sha,
    "private_tests_sha256" => private_sha
  })
)
