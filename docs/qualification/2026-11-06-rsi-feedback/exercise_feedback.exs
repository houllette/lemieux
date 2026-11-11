# Private development exercise, not a model trial. Arguments: curated repository
# manifest and fresh output directory. LEMIEUX_RSI_PRIOR names the retained packet.
alias Lemieux.Benchmark.Manifest
alias Lemieux.CLI.Corpus
alias Lemieux.CLI.Feedback, as: FeedbackCLI
alias Lemieux.CLI.Learning.Repositories
alias Lemieux.Contract
alias Lemieux.Environment.Sandbox
alias Lemieux.Feedback
alias Lemieux.Feedback.Store
alias Lemieux.Feedback.Store.JSONL

[manifest_path, root] = System.argv()
:ok = File.mkdir(root)
prior = System.fetch_env!("LEMIEUX_RSI_PRIOR")
read = fn path -> path |> File.read!() |> JSON.decode!() end
packet = Path.dirname(__ENV__.file)
audit = read.(Path.join(packet, "public-audit.json"))
ancestry = audit["captured_artifact_ancestry"]

evidence =
  prior
  |> Path.join("tmp/selective-pint-calibration-live/*/evidence.json")
  |> Path.wildcard()
  |> Enum.find(&(Contract.sha256(File.read!(&1)) == ancestry["source_evidence_bytes_sha256"]))
  |> read.()

original = evidence["original"]
"completed" = original["status"]
anchor = Enum.find(Enum.reverse(original["transcript"]), &(&1["type"] == "assistant"))
{[fixture], _metadata} = Repositories.materialize(manifest_path, Path.join(root, "input"))
artifact = Path.join(prior, "tmp/selective-public-feedback-v2/model-artifact/pint/definitions.py")
bytes = File.read!(artifact)
true = Contract.sha256(bytes) == ancestry["restored_changed_file_sha256"]
:ok = File.write(Path.join(fixture.task.cwd, "pint/definitions.py"), bytes)
public = %{fixture | cases: fixture.probe_cases}
grade = Repositories.grade(public, fixture.task.cwd, fixture.environment)
false = grade["passed"]
14 = grade["checks"]
11 = grade["correct"]
[] = grade["safety_failures"]

provenance = %{
  "host" => "qualification-curator",
  "tenant_id" => "development",
  "project_id" => fixture.cluster,
  "session_id" => original["session_id"],
  "entry_id" => anchor["id"],
  "source_evidence_sha256" => ancestry["source_evidence_bytes_sha256"],
  "source_case_ids" => ["hgrecco-pint-948", fixture.id],
  "exposure" => "developer_exposed_private_control_informed"
}

{:ok, feedback} =
  Feedback.new(
    "The retained artifact fails reviewed public numeric-definition checks.",
    provenance,
    actor: %{"type" => "model", "id" => "codex-curator"},
    verifiability: %{
      "class" => "mechanical",
      "claim" => "Public checks fail on the retained artifact."
    }
  )

store = JSONL.new(Path.join(root, "feedback"))
:ok = Store.append(store, feedback)
benchmark = read.(Path.join(packet, "public-audit.json"))
image = benchmark["image"]

bootstrap =
  "import os,sys; import pytest; sys.path.insert(0,os.getcwd()); raise SystemExit(pytest.main(['-q','-p','no:cacheprovider','-c','qualification_pytest.ini','test_qualification_public.py','test_definition_contract.py']))"

argv = [
  "docker",
  "run",
  "--rm",
  "--network",
  "none",
  "--read-only",
  "--user",
  "1000:1000",
  "--cap-drop",
  "ALL",
  "--security-opt",
  "no-new-privileges",
  "--memory",
  "1g",
  "--cpus",
  "2",
  "--pids-limit",
  "128",
  "--tmpfs",
  "/tmp:rw,nosuid,size=128m",
  "--mount",
  "type=bind,src={cwd},dst=/app",
  "--workdir",
  "/app",
  "--entrypoint",
  "python3",
  image,
  "-I",
  "-B",
  "-c",
  bootstrap
]

verifier = Enum.map_join(argv, " ", &Sandbox.quote_shell/1)
true = OptionParser.split(verifier) == argv
drafts = Path.join(root, "drafts")

:ok =
  FeedbackCLI.run(
    [
      "draft-case",
      feedback.id,
      "--source",
      fixture.task.cwd,
      "--output",
      drafts,
      "--prompt",
      fixture.task.prompt,
      "--verifier",
      verifier
    ], feedback_store: store)

[draft_name] = File.ls!(drafts)
draft = Path.join(drafts, draft_name)
reference = Path.join(root, "reference")
{:ok, _files} = File.cp_r(fixture.task.cwd, reference)
manifest = read.(manifest_path)
[item] = manifest["tasks"]
oracle = Path.join(Path.dirname(item["source"]), "oracle/pint/definitions.py")
:ok = File.write(Path.join(reference, "pint/definitions.py"), File.read!(oracle))

:ok =
  Corpus.run(["review", draft, "--reference", reference, "--allow", "pint/definitions.py"], [])

# Extend an owned copy of an existing approved development manifest. Its thirty
# existing fixtures remain read-only references; no placeholder case is invented.
repository = Path.expand("../../..", packet)
basis = Path.join(repository, "eval/corpus/investigators-v2/manifest.json")
existing = read.(basis)

tasks =
  Enum.map(existing["tasks"], &Map.put(&1, "cwd", Path.expand(&1["cwd"], Path.dirname(basis))))

development =
  existing
  |> Map.put("tasks", tasks)
  |> Map.put("metadata", %{
    "exposure" => "developer_exposed",
    "source_case_ancestry" => provenance["source_case_ids"]
  })

destination = Path.join(root, "development.json")
:ok = File.write(destination, JSON.encode!(development))

:ok =
  Corpus.run(
    [
      "promote",
      draft,
      destination,
      "--cluster",
      fixture.cluster,
      "--tag",
      "developer_exposed",
      "--tag",
      "public-feedback",
      "--allow",
      "pint/definitions.py",
      "--reference",
      reference
    ],
    []
  )

{:ok, promoted} = Manifest.read(destination)
task = List.last(promoted.tasks)
true = length(promoted.tasks) == length(tasks) + 1
"passed" = task.metadata["verification_review"]["status"]

report = %{
  "schema_version" => 1,
  "kind" => "development_feedback_case_workflow/v1",
  "hosted_requests" => 0,
  "actor" => %{"type" => "model", "id" => "codex-curator"},
  "source_case_ids" => provenance["source_case_ids"],
  "source_evidence_sha256" => ancestry["source_evidence_bytes_sha256"],
  "feedback_id" => feedback.id,
  "promoted_case_id" => task.id,
  "retained_artifact_public_grade" => grade,
  "verification_review" => task.metadata["verification_review"],
  "existing_development_cases" => length(tasks),
  "cases_added" => 1,
  "ordinary_use_items_reviewed" => 0,
  "independent_peer_review" => false,
  "independent_confirmation" => false,
  "qualified_improvements" => 0,
  "manifest_bytes_sha256" => Contract.sha256(File.read!(destination)),
  "interpretation" =>
    "Agent-reviewed development curation exercises product commands; no independent efficacy or asset activation authority."
}

:ok =
  File.write(
    Path.join(root, "report.json"),
    JSON.encode!(Map.put(report, "sha256", Contract.digest(report)))
  )

IO.puts(JSON.encode!(report))
