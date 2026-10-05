defmodule Lemieux.Benchmark.CorpusPromoteTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.Benchmark.Corpus.Promote
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.CLI.Corpus, as: CorpusCLI
  alias Lemieux.Feedback
  alias Lemieux.Feedback.CaseDraft
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "value.txt"), "broken\n")
    File.write!(Path.join(source, "check.sh"), "#!/bin/sh\ntest \"$(cat value.txt)\" = fixed\n")

    manifest_dir = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(manifest_dir)
    manifest = Path.join(manifest_dir, "manifest.json")

    File.write!(
      manifest,
      JSON.encode!(%{
        "version" => 1,
        "tasks" => [
          %{
            "id" => "existing",
            "prompt" => "x",
            "cwd" => ".",
            "grader" => %{"command" => ["true"]}
          }
        ]
      })
    )

    {:ok, feedback} =
      Feedback.new(
        "It finished without fixing value.txt",
        %{
          "host" => "standalone",
          "tenant_id" => "local",
          "project_id" => "p",
          "session_id" => "s",
          "entry_id" => "e1"
        },
        verifiability: %{"class" => "mechanical"}
      )

    {:ok, draft} =
      CaseDraft.create(feedback, source, Path.join(tmp_dir, "drafts"),
        prompt: "Fix value.txt so the check passes.",
        verifier: ["sh", "check.sh"]
      )

    %{
      draft_dir: Path.dirname(draft.record_path),
      manifest: manifest,
      manifest_dir: manifest_dir,
      source: source,
      feedback: feedback
    }
  end

  test "a reviewed draft is copied beside the manifest and appended with its cluster and allowlist",
       ctx do
    assert {:ok, id} =
             Promote.promote(ctx.draft_dir, ctx.manifest,
               cluster_id: "value-repair",
               tags: ["shell"],
               allowed_changed_paths: ["value.txt"]
             )

    assert {:ok, manifest} = Manifest.read(ctx.manifest)
    assert [_existing, task] = manifest.tasks
    assert task.id == id
    assert task.metadata["cluster_id"] == "value-repair"
    assert task.metadata["tags"] == ["promoted", "shell"]
    assert task.metadata["safety"]["allowed_changed_paths"] == ["value.txt"]
    assert task.metadata["feedback_id"] == ctx.feedback.id
    assert task.metadata["status"] == "promoted"
    assert File.exists?(Path.join([ctx.manifest_dir, "repos", id, "check.sh"]))
    assert task.cwd == Path.join([ctx.manifest_dir, "repos", id])

    assert {:error, {:case_exists, ^id}} =
             Promote.promote(ctx.draft_dir, ctx.manifest, cluster_id: "value-repair")
  end

  # Every other test here hands `promote/3` a `tmp_dir` path, which is
  # absolute, and the bug only appeared for a relative one — so promote worked
  # in the suite and failed on its own documented invocation,
  # `lmx corpus promote eval/drafts/case_ID`.
  test "a draft named by a relative path promotes, which is how the CLI names one", ctx do
    relative = Path.relative_to_cwd(ctx.draft_dir)
    refute String.starts_with?(relative, "/")

    assert {:ok, id} = Promote.promote(relative, ctx.manifest, cluster_id: "value-repair")

    assert File.exists?(Path.join([ctx.manifest_dir, "repos", id, "check.sh"]))
  end

  # The draft never copies such a file; one in the fixture was put back by
  # hand, and the manifest's directory is the one that gets committed.
  test "a fixture holding a secret-shaped file is refused unless the reviewer allows it", ctx do
    File.write!(Path.join([ctx.draft_dir, "fixture", ".env"]), "TOKEN=fake\n")
    File.write!(Path.join([ctx.draft_dir, "fixture", "deploy.pem"]), "fake\n")

    assert {:error, {:secret_files, [".env", "deploy.pem"]}} =
             Promote.promote(ctx.draft_dir, ctx.manifest, cluster_id: "value-repair")

    refute File.exists?(Path.join(ctx.manifest_dir, "repos"))
    assert {:ok, manifest} = Manifest.read(ctx.manifest)
    assert [_existing] = manifest.tasks

    assert {:ok, id} =
             Promote.promote(ctx.draft_dir, ctx.manifest,
               cluster_id: "value-repair",
               allow_secret_files: true
             )

    assert File.regular?(Path.join([ctx.manifest_dir, "repos", id, ".env"]))
  end

  # The draft's review checklist tells a CLI user how to proceed, so the CLI
  # has to offer the same choice the function does, in words.
  test "the CLI names the refused files and the flag that accepts them", ctx do
    File.write!(Path.join([ctx.draft_dir, "fixture", ".env"]), "TOKEN=fake\n")
    argv = ["promote", ctx.draft_dir, ctx.manifest, "--cluster", "value-repair"]

    stderr =
      capture_io(:stderr, fn -> assert {:error, 1} = CorpusCLI.run(argv, []) end)

    assert stderr =~ "secret-shaped file"
    assert stderr =~ ".env"
    assert stderr =~ "--allow-secret-files"
    refute stderr =~ ":secret_files"

    promoted =
      capture_io(fn -> assert :ok = CorpusCLI.run(argv ++ ["--allow-secret-files"], []) end)

    assert promoted =~ "promoted case"
  end

  test "a mutation case whose grader already passes is refused; read-only cases opt in", ctx do
    File.write!(Path.join([ctx.draft_dir, "fixture", "value.txt"]), "fixed\n")

    assert {:error, :grader_passes_untouched_fixture} =
             Promote.promote(ctx.draft_dir, ctx.manifest, cluster_id: "value-repair")

    assert {:ok, _id} =
             Promote.promote(ctx.draft_dir, ctx.manifest, cluster_id: "read-only", expect: :pass)

    assert {:error, {:cluster_id, :required}} = Promote.promote(ctx.draft_dir, ctx.manifest, [])
  end

  test "the CLI drafts a case from a stored feedback record after classifying it",
       %{tmp_dir: tmp_dir} = ctx do
    feedback_dir = Path.join(tmp_dir, "feedback")
    store = FeedbackJSONL.new(feedback_dir)

    {:ok, mined} =
      Feedback.new(
        "Mined: never reran the check",
        %{
          "host" => "reflection",
          "tenant_id" => "local",
          "project_id" => "p",
          "session_id" => "s",
          "entry_id" => "e2"
        },
        actor: %{"type" => "model", "id" => "test:model"}
      )

    :ok = FeedbackStore.append(store, mined)
    output_dir = Path.join(tmp_dir, "drafts2")

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Lemieux.CLI.Feedback.run(
                   [
                     "draft-case",
                     mined.id,
                     "--source",
                     ctx.source,
                     "--output",
                     output_dir,
                     "--prompt",
                     "Fix it.",
                     "--verifier",
                     "sh check.sh",
                     "--feedback-dir",
                     feedback_dir
                   ],
                   []
                 )
      end)

    assert stderr =~ "pass --class mechanical"

    output =
      capture_io(fn ->
        assert :ok =
                 Lemieux.CLI.Feedback.run(
                   [
                     "draft-case",
                     mined.id,
                     "--source",
                     ctx.source,
                     "--output",
                     output_dir,
                     "--prompt",
                     "Fix it.",
                     "--verifier",
                     "sh check.sh",
                     "--feedback-dir",
                     feedback_dir,
                     "--class",
                     "mechanical"
                   ],
                   []
                 )
      end)

    assert output =~ "drafted case"
    assert output =~ "lmx corpus promote"
    assert {:ok, revised} = FeedbackStore.latest(store, mined.id)
    assert revised.revision == 2 and revised.status == :triaged
    assert revised.verifiability["class"] == "mechanical"
    [draft_dir] = File.ls!(output_dir) |> Enum.map(&Path.join(output_dir, &1))

    promoted =
      capture_io(fn ->
        assert :ok =
                 CorpusCLI.run(
                   [
                     "promote",
                     draft_dir,
                     ctx.manifest,
                     "--cluster",
                     "repair",
                     "--tag",
                     "mined",
                     "--allow",
                     "value.txt"
                   ],
                   []
                 )
      end)

    assert promoted =~ "promoted case"
    assert {:ok, manifest} = Manifest.read(ctx.manifest)
    assert Enum.any?(manifest.tasks, &(&1.metadata["tags"] == ["promoted", "mined"]))
  end
end
