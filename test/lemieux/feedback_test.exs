defmodule Lemieux.FeedbackTest do
  use ExUnit.Case, async: true

  alias Lemieux.Feedback

  test "requires an anchored run and preserves raw feedback across revisions and JSON" do
    provenance = provenance(%{})

    assert {:error, {:missing_anchor, _fields}} =
             Feedback.new("run the formatter", provenance)

    provenance = put_in(provenance, ["entry_id"], "entry-1")

    assert {:ok, feedback} = Feedback.new("run the formatter", provenance)

    assert {:ok, revised} =
             Feedback.revise(
               feedback,
               %{
                 "created_by" => "human",
                 "confidence" => 1.0,
                 "questions_asked" => 1
               },
               type: :missed_requirement,
               verifiability: %{
                 "class" => "mechanical",
                 "claim" => "formatter succeeds"
               },
               durability: :standing_rule,
               status: :triaged
             )

    assert revised.raw_text == feedback.raw_text
    assert revised.revision == 2
    assert length(revised.interpretations) == 1
    assert Feedback.decode!(Feedback.encode!(revised)) == revised
  end

  test "rejects unknown enum values and more than three clarification questions" do
    assert {:error, {:invalid_scope, :planet}} =
             Feedback.new("feedback", provenance(%{"entry_id" => "entry-1"}), scope: :planet)

    assert {:ok, feedback} =
             Feedback.new("feedback", provenance(%{"entry_id" => "entry-1"}))

    assert {:error, :too_many_questions} =
             Feedback.revise(feedback, %{
               "created_by" => "classifier",
               "confidence" => 0.5,
               "questions_asked" => 4
             })
  end

  defp provenance(extra) do
    Map.merge(
      %{
        "host" => "standalone",
        "tenant_id" => "local",
        "project_id" => "project",
        "session_id" => "session"
      },
      extra
    )
  end
end
