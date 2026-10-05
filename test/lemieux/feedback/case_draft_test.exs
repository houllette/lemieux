defmodule Lemieux.Feedback.CaseDraftTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command
  alias Lemieux.Feedback
  alias Lemieux.Feedback.CaseDraft

  @moduletag :tmp_dir

  test "freezes a reviewable benchmark task whose grader reproduces the failure", context do
    source = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "unformatted.ex"), "defmodule Bad,do: nil\n")

    feedback = mechanical_feedback()
    output = Path.join(context.tmp_dir, "drafts")

    assert {:ok, draft} =
             CaseDraft.create(feedback, source, output,
               prompt: "Format the project before finishing.",
               verifier: ["sh", "-c", "test -f formatter-ran"]
             )

    assert draft.feedback_id == feedback.id
    assert File.regular?(Path.join(draft.task.cwd, "unformatted.ex"))
    assert File.regular?(draft.record_path)
    assert {:ok, result} = Command.grade(draft.task.grader, draft.task, "")
    refute result["passed"]
    assert "review fixture for secrets" in draft.review_checklist
  end

  test "leaves secret-shaped files out of the fixture and records each one", context do
    source = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(Path.join(source, "config"))
    File.write!(Path.join(source, "unformatted.ex"), "defmodule Bad,do: nil\n")
    File.write!(Path.join(source, ".env"), "OPENAI_API_KEY=not-a-real-key\n")
    File.write!(Path.join(source, ".env.example"), "OPENAI_API_KEY=\n")
    File.write!(Path.join(source, "config/prod.secret.exs"), "import Config\n")

    assert {:ok, draft} =
             CaseDraft.create(mechanical_feedback(), source, Path.join(context.tmp_dir, "drafts"),
               prompt: "Format the project before finishing.",
               verifier: ["true"]
             )

    assert draft.skipped_files == [".env", "config/prod.secret.exs"]
    refute File.exists?(Path.join(draft.task.cwd, ".env"))
    refute File.exists?(Path.join(draft.task.cwd, "config/prod.secret.exs"))
    assert File.regular?(Path.join(draft.task.cwd, ".env.example"))
    assert File.regular?(Path.join(draft.task.cwd, "unformatted.ex"))
    assert [first | _rest] = draft.review_checklist
    assert first =~ "left out secret-shaped files (.env, config/prod.secret.exs)"
    # `lmx feedback draft-case` prints this list, so it names the CLI flag too.
    assert first =~ "--allow-secret-files"
    assert first =~ "allow_secret_files: true"

    record = draft.record_path |> File.read!() |> JSON.decode!()

    assert record["skipped"] == [
             %{"path" => ".env", "reason" => "secret"},
             %{"path" => "config/prod.secret.exs", "reason" => "secret"}
           ]

    refute File.read!(draft.record_path) =~ "not-a-real-key"
  end

  test "a workspace without secret-shaped files records an empty skip list", context do
    source = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "unformatted.ex"), "defmodule Bad,do: nil\n")

    assert {:ok, draft} =
             CaseDraft.create(mechanical_feedback(), source, Path.join(context.tmp_dir, "drafts"),
               prompt: "Format the project before finishing.",
               verifier: ["true"]
             )

    assert draft.skipped_files == []
    refute Enum.any?(draft.review_checklist, &(&1 =~ "secret-shaped"))
    assert (draft.record_path |> File.read!() |> JSON.decode!())["skipped"] == []
  end

  test "subjective feedback cannot enter the mechanical case path", context do
    {:ok, feedback} =
      Feedback.new("I dislike the tone", provenance(),
        verifiability: %{"class" => "human_review"}
      )

    assert {:error, {:not_case_eligible, :human_review}} =
             CaseDraft.create(feedback, context.tmp_dir, Path.join(context.tmp_dir, "drafts"),
               prompt: "change tone",
               verifier: ["true"]
             )
  end

  test "refuses to place a recursive draft inside its source fixture", context do
    source = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(source)

    assert {:error, :draft_inside_source} =
             CaseDraft.create(
               mechanical_feedback(),
               source,
               Path.join(source, "drafts"),
               prompt: "format it",
               verifier: ["true"]
             )
  end

  defp mechanical_feedback do
    {:ok, feedback} =
      Feedback.new("run formatter", provenance(),
        verifiability: %{"class" => "mechanical", "claim" => "formatter ran"},
        durability: :standing_rule
      )

    feedback
  end

  defp provenance do
    %{
      "host" => "standalone",
      "tenant_id" => "local",
      "project_id" => "project",
      "session_id" => "session",
      "entry_id" => "entry"
    }
  end
end
