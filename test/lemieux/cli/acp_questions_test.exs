defmodule Lemieux.CLI.ACP.QuestionsTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.Questions

  test "a single question appears once with a separate answer label" do
    question = %{call_id: "q", question: "Which file?", options: []}
    request = Questions.request("session", question)
    assert request["message"] == "Which file?"
    assert request["requestedSchema"]["properties"]["answer"]["title"] == "Answer"
  end

  test "batched questions use each field's title without repeating the first question" do
    question = %{
      call_id: "q",
      questionnaire: true,
      question: "Which file?",
      questions: [
        %{question_id: "file", question: "Which file?", options: []},
        %{question_id: "format", question: "Which format?", options: []}
      ]
    }

    request = Questions.request("session", question)
    assert request["message"] == "Please answer these questions."
    assert request["requestedSchema"]["properties"]["file"]["title"] == "Which file?"
    assert request["requestedSchema"]["properties"]["format"]["title"] == "Which format?"

    assert Questions.answer(question, %{"action" => "accept", "content" => %{"file" => "src.ex"}}) ==
             %{"status" => "cancelled"}
  end
end
