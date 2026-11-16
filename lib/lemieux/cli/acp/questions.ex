defmodule Lemieux.CLI.ACP.Questions do
  @moduledoc false

  @spec request(session_id :: String.t(), question :: map()) :: map()
  def request(session_id, question) do
    fields = fields(question)
    single? = length(fields) == 1

    properties =
      Map.new(fields, fn {id, field} ->
        property = property(field)
        {id, if(single?, do: Map.put(property, "title", "Answer"), else: property)}
      end)

    %{
      "sessionId" => session_id,
      "toolCallId" => question.call_id,
      "mode" => "form",
      "message" => if(single?, do: question.question, else: "Please answer these questions."),
      "requestedSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => Enum.map(fields, &elem(&1, 0))
      }
    }
  end

  @spec answer(question :: map(), result :: term()) :: String.t() | map()
  def answer(question, %{"action" => "accept", "content" => content}) when is_map(content) do
    values = Enum.map(fields(question), fn {id, _field} -> content[id] end)

    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      if Map.get(question, :questionnaire, false),
        do: %{"answers" => values},
        else: hd(values)
    else
      cancelled(question)
    end
  end

  def answer(question, _result), do: cancelled(question)

  defp fields(%{questionnaire: true, questions: questions}),
    do: Enum.map(questions, &{&1.question_id, &1})

  defp fields(question), do: [{"answer", question}]

  defp property(question) do
    choices =
      question
      |> Map.get(:options, [])
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {option, i} -> "#{i}. #{option.label}" end)

    %{
      "type" => "string",
      "title" => question.question,
      "description" =>
        "#{choices}\nEnter an answer; choices accept numbers. Multiple selections use commas."
    }
  end

  defp cancelled(%{questionnaire: true}), do: %{"status" => "cancelled"}
  defp cancelled(_question), do: "Client cancelled the question; no answer was provided."
end
