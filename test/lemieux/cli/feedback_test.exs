defmodule Lemieux.CLI.FeedbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Entry
  alias Lemieux.Feedback.Store, as: FeedbackStore
  alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "anchors feedback to a session entry without appending a conversation entry", context do
    transcript_store = JSONL.new(Path.join(context.tmp_dir, "sessions"))
    feedback_store = FeedbackJSONL.new(Path.join(context.tmp_dir, "feedback"))
    session_id = "session-1"
    entry = Entry.new(:user, %{"text" => "change it"})

    assert :ok = Store.append(transcript_store, session_id, [entry])

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(
                   [
                     "feedback",
                     session_id,
                     "--text",
                     "run the formatter",
                     "--scope",
                     "project",
                     "--standing-rule"
                   ],
                   store: transcript_store,
                   feedback_store: feedback_store,
                   project_id: "project-1",
                   tenant_id: "local"
                 )
      end)

    assert output =~ "feedback fb_"
    assert {:ok, [^entry]} = Store.read(transcript_store, session_id)
    assert {:ok, [feedback_id]} = FeedbackStore.list_feedback(feedback_store)
    assert {:ok, feedback} = FeedbackStore.latest(feedback_store, feedback_id)
    assert feedback.provenance["entry_id"] == entry.id
    assert feedback.raw_text == "run the formatter"
    assert feedback.durability == :standing_rule
  end

  test "refuses an entry that is not in the anchored transcript", context do
    transcript_store = JSONL.new(Path.join(context.tmp_dir, "sessions"))
    feedback_store = FeedbackJSONL.new(Path.join(context.tmp_dir, "feedback"))
    assert :ok = Store.append(transcript_store, "session-1", [Entry.new(:user, %{"text" => "x"})])

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 CLI.run(
                   ["feedback", "session-1", "--entry", "missing", "--text", "bad"],
                   store: transcript_store,
                   feedback_store: feedback_store
                 )
      end)

    assert stderr =~ "no entry missing"
    assert {:ok, []} = FeedbackStore.list_feedback(feedback_store)
  end
end
