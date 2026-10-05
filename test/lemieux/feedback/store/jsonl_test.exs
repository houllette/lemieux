defmodule Lemieux.Feedback.Store.JSONLTest do
  use ExUnit.Case, async: true

  alias Lemieux.Feedback
  alias Lemieux.Feedback.Store
  alias Lemieux.Feedback.Store.JSONL

  @moduletag :tmp_dir

  test "appends revisions and reloads them without changing order or raw text", context do
    store = JSONL.new(context.tmp_dir)
    feedback = feedback()

    assert :ok = Store.append(store, feedback)

    assert {:ok, revised} =
             Feedback.revise(
               feedback,
               %{
                 "created_by" => "human",
                 "confidence" => 1.0,
                 "questions_asked" => 0
               },
               status: :triaged
             )

    assert :ok = Store.append(store, revised)
    assert {:ok, [first, second]} = Store.read(store, feedback.id)
    assert [first.revision, second.revision] == [1, 2]
    assert first.raw_text == second.raw_text
    assert {:ok, ^second} = Store.latest(JSONL.new(context.tmp_dir), feedback.id)
    assert {:ok, [id]} = Store.list_feedback(store)
    assert id == feedback.id
  end

  test "rejects a revision that rewrites the immutable raw feedback", context do
    store = JSONL.new(context.tmp_dir)
    feedback = feedback()
    assert :ok = Store.append(store, feedback)

    rewritten = %{feedback | revision: 2, raw_text: "different"}
    assert {:error, :raw_text_changed} = Store.append(store, rewritten)
  end

  defp feedback do
    {:ok, feedback} =
      Feedback.new("run the formatter", %{
        "host" => "standalone",
        "tenant_id" => "local",
        "project_id" => "project",
        "session_id" => "session",
        "entry_id" => "entry"
      })

    feedback
  end
end
