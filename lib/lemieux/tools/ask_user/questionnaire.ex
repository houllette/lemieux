defmodule Lemieux.Tools.AskUser.Questionnaire do
  @moduledoc """
  Renderer-independent batches for `ask_user`.

  A batch parks one call containing all questions, so a host can collect and
  review every answer before releasing the agent. Authored IDs are preserved;
  missing IDs are assigned from their positions before parking. Text hosts
  accept numbers (comma-separated for multiple
  selection), labels, or custom text. `/decline` and `/cancel-question` are
  explicit outcomes.
  A JSON answer can additionally carry `notes`. Missing UI, timeout and refusal
  remain distinct; none supplies a default answer or authorizes an action.
  """

  alias Lemieux.Session
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.AskUser.Diagram

  @doc "The bounded batch input schema."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 4,
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["question"],
        "properties" => %{
          "id" => text_schema(64),
          "question" => text_schema(2000),
          "diagram" => Diagram.schema(),
          "type" => %{
            "type" => "string",
            "enum" => ~w(single_choice multi_select ranking text number)
          },
          "multiple" => %{"type" => "boolean"},
          "options" => %{
            "type" => "array",
            "minItems" => 2,
            "maxItems" => 6,
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["label"],
              "properties" => %{
                "id" => text_schema(64),
                "label" =>
                  Map.put(
                    text_schema(120),
                    "description",
                    "Do not include Other; the UI adds it."
                  ),
                "description" => text_schema(1000),
                "preview" => text_schema(4000),
                "diagram" => Diagram.schema()
              }
            }
          }
        }
      }
    }
  end

  @doc "Validates the whole batch, then parks it as one reviewable request."
  @spec run(questions :: term(), context :: map()) :: {:ok, Result.t()} | {:error, String.t()}
  def run(questions, context) do
    questions = normalize_ids(questions)

    if valid_questions?(questions) do
      response =
        Session.park(
          context.session,
          context.call_id,
          :question,
          presentation(questions, context.call_id),
          timeout_reply: {:ok, %{"status" => "timed_out"}}
        )

      answers = normalize_batch(response, questions)

      status =
        if Enum.all?(answers, &(&1["status"] == "answered")), do: "answered", else: "incomplete"

      data = %{"version" => 1, "status" => status, "answers" => answers}
      {:ok, Result.new(JSON.encode!(data), structured_content: data)}
    else
      {:error, validation_error(questions)}
    end
  end

  defp normalize_ids(questions) when is_list(questions) do
    questions
    |> assign_missing_ids("question")
    |> Enum.map(fn
      %{"options" => options} = question when is_list(options) ->
        Map.put(question, "options", assign_missing_ids(options, "option"))

      question ->
        question
    end)
  end

  defp normalize_ids(questions), do: questions

  defp assign_missing_ids(items, prefix) do
    used =
      items
      |> Enum.filter(&is_map/1)
      |> Enum.map(&Map.get(&1, "id"))
      |> MapSet.new()

    {assigned, _used} =
      items
      |> Enum.with_index(1)
      |> Enum.map_reduce(used, fn
        {item, index}, occupied when is_map(item) ->
          if Map.has_key?(item, "id") do
            {item, occupied}
          else
            id = unused_id("#{prefix}_#{index}", occupied)
            {Map.put(item, "id", id), MapSet.put(occupied, id)}
          end

        {item, _index}, occupied ->
          {item, occupied}
      end)

    assigned
  end

  defp unused_id(base, used, suffix \\ 1) do
    candidate = if suffix == 1, do: base, else: "#{base}_#{suffix}"
    if MapSet.member?(used, candidate), do: unused_id(base, used, suffix + 1), else: candidate
  end

  defp validation_error(questions) when not is_list(questions),
    do: "ask_user.questions must be an array of one to four question objects"

  defp validation_error(questions) when length(questions) not in 1..4,
    do: "ask_user.questions needs one to four questions"

  defp validation_error(questions) do
    Enum.find_value(Enum.with_index(questions, 1), fn {question, index} ->
      if valid_question?(question), do: nil, else: question_error(question, index)
    end) || "ask_user.questions ids must be unique"
  end

  defp question_error(question, index) when not is_map(question),
    do: "ask_user.questions[#{index}] must be an object"

  defp question_error(question, index) do
    type = question_type(question)
    prefix = "ask_user.questions[#{index}]"

    cond do
      not short_text?(question["id"], 64) ->
        "#{prefix}.id is required (nonempty, at most 64 bytes)"

      not short_text?(question["question"], 2000) ->
        "#{prefix}.question is required (nonempty text)"

      type not in ~w(single_choice multi_select ranking text number) ->
        "#{prefix}.type must be single_choice, multi_select, ranking, text, or number"

      true ->
        question_detail_error(question, type, prefix)
    end
  end

  defp question_detail_error(question, type, prefix) do
    options = Map.get(question, "options", [])

    cond do
      type in ~w(text number) and options != [] ->
        "#{prefix}.options must be omitted for text and number questions"

      type in ~w(single_choice multi_select ranking) and not valid_options?(options) ->
        "#{prefix}.options needs 2–6 objects with unique nonempty id and label; omit Other"

      not match?({:ok, _}, Diagram.normalize(question["diagram"])) ->
        "#{prefix}.diagram must be a small valid diagram"

      true ->
        "#{prefix} has invalid fields"
    end
  end

  defp presentation(questions, call_id) do
    [first | _] = presented = Enum.map(questions, &present_question/1)

    Map.merge(first, %{
      call_id: call_id,
      questionnaire: true,
      ask_user: true,
      questions: presented,
      instructions: "Answer each question. The TUI reviews all answers before sending."
    })
  end

  defp present_question(question) do
    {:ok, diagram} = Diagram.normalize(question["diagram"])

    options =
      Enum.map(Map.get(question, "options", []), fn option ->
        {:ok, diagram} = Diagram.normalize(option["diagram"])

        %{
          id: option["id"],
          label: option["label"],
          description: option["description"],
          preview: option["preview"],
          diagram: diagram
        }
      end)

    %{
      question_id: question["id"],
      question: question["question"],
      diagram: diagram,
      options: options,
      type: question_type(question),
      multiple: question_type(question) == "multi_select"
    }
  end

  @doc "Normalizes a complete host response; incomplete answers never imply consent."
  @spec normalize_batch(response :: term(), questions :: [map()]) :: [map()]
  def normalize_batch({:ok, %{"status" => status}}, [first | _])
      when status in ~w(declined cancelled timed_out unavailable),
      do: [%{"question_id" => first["id"], "status" => status}]

  def normalize_batch({:ok, %{"answers" => answers}}, questions) when is_list(answers) do
    if length(answers) == length(questions) do
      Enum.zip_with(answers, questions, fn response, question ->
        response
        |> then(&normalize({:ok, &1}, question))
        |> Map.put("question_id", question["id"])
      end)
    else
      [
        %{
          "question_id" => hd(questions)["id"],
          "status" => "invalid",
          "reason" => "incomplete answers"
        }
      ]
    end
  end

  def normalize_batch(_response, [first | _]),
    do: [
      %{"question_id" => first["id"], "status" => "invalid", "reason" => "invalid host answer"}
    ]

  @doc "Normalizes typed or structured host answers without inferring missing consent."
  @spec normalize(response :: term(), question :: map()) :: map()
  def normalize({:ok, %{"status" => status}}, _question)
      when status in ~w(declined cancelled timed_out unavailable), do: %{"status" => status}

  def normalize({:ok, %{"selected" => ids} = answer}, question) when is_list(ids) do
    allowed = Enum.map(Map.get(question, "options", []), & &1["id"])

    valid =
      question_type(question) in ~w(single_choice multi_select) and
        (question_type(question) == "multi_select" or ids != []) and
        Enum.all?(ids, &(&1 in allowed)) and
        length(ids) == length(Enum.uniq(ids)) and
        (question_type(question) == "multi_select" or length(ids) == 1)

    if valid do
      result = %{"status" => "answered", "kind" => "selection", "selected" => ids}
      result = with_notes(result, answer)

      if question_type(question) == "multi_select",
        do: no_option_notes(result, answer),
        else: with_option_notes(result, answer, ids)
    else
      %{"status" => "invalid", "reason" => "invalid selection"}
    end
  end

  def normalize({:ok, %{"ranked" => ids} = answer}, question) when is_list(ids) do
    allowed = Enum.map(question["options"] || [], & &1["id"])

    if question_type(question) == "ranking" and length(ids) == length(allowed) and
         Enum.sort(ids) == Enum.sort(allowed) do
      %{"status" => "answered", "kind" => "ranking", "ranked" => ids}
      |> with_notes(answer)
      |> no_option_notes(answer)
    else
      %{"status" => "invalid", "reason" => "invalid ranking"}
    end
  end

  def normalize({:ok, %{"number" => number} = answer}, question) when is_binary(number) do
    if question_type(question) == "number" and valid_number?(number),
      do:
        with_notes(
          %{"status" => "answered", "kind" => "number", "number" => String.trim(number)},
          answer
        ),
      else: %{"status" => "invalid", "reason" => "invalid number"}
  end

  def normalize({:ok, %{"text" => text} = answer}, question) when is_binary(text) do
    if question_type(question) not in ~w(number ranking) and String.trim(text) != "" and
         byte_size(text) <= 8000,
       do:
         with_notes(
           %{
             "status" => "answered",
             "kind" => if(question_type(question) == "text", do: "text", else: "custom"),
             "text" => text
           },
           answer
         ),
       else: %{"status" => "invalid", "reason" => "empty or oversized answer"}
  end

  def normalize({:ok, text}, question) when is_binary(text) do
    case String.split(text, "|", parts: 2) do
      [answer, notes] -> typed(String.trim(answer), question, String.trim(notes))
      [answer] -> typed(String.trim(answer), question, nil)
    end
  end

  def normalize(_response, _question),
    do: %{"status" => "invalid", "reason" => "invalid host answer"}

  defp typed("/decline", _question, _notes), do: %{"status" => "declined"}
  defp typed("/cancel-question", _question, _notes), do: %{"status" => "cancelled"}

  defp typed(text, question, notes) do
    case question_type(question) do
      "number" ->
        normalize({:ok, %{"number" => text, "notes" => notes}}, question)

      "text" ->
        normalize({:ok, %{"text" => text, "notes" => notes}}, question)

      "ranking" ->
        typed_ranking(text, question, notes)

      "multi_select" when text == "/none" ->
        normalize({:ok, %{"selected" => [], "notes" => notes}}, question)

      _choice ->
        typed_choice(text, question, notes)
    end
  end

  defp typed_ranking(text, question, notes) do
    ids =
      text
      |> String.split(",", trim: true)
      |> Enum.map(&choice_id(String.trim(&1), question["options"]))

    normalize({:ok, %{"ranked" => ids, "notes" => notes}}, question)
  end

  defp typed_choice(text, question, notes) do
    options = Map.get(question, "options")
    choices = String.split(text, ",", trim: true)
    ids = Enum.map(choices, &choice_id(String.trim(&1), options))

    answer =
      if ids != [] and Enum.all?(ids, &is_binary/1),
        do: %{"selected" => ids, "notes" => notes},
        else: %{"text" => text, "notes" => notes}

    normalize({:ok, answer}, question)
  end

  defp choice_id(text, options) do
    option =
      case Integer.parse(text) do
        {number, ""} when number > 0 -> Enum.at(options, number - 1)
        _other -> Enum.find(options, &(&1["label"] == text or &1["id"] == text))
      end

    if option, do: option["id"]
  end

  defp with_notes(result, %{"notes" => notes}) when is_binary(notes) and byte_size(notes) <= 8000,
    do: Map.put(result, "notes", notes)

  defp with_notes(result, %{"notes" => nil}), do: result
  defp with_notes(result, answer) when not is_map_key(answer, "notes"), do: result
  defp with_notes(_result, _answer), do: %{"status" => "invalid", "reason" => "invalid notes"}

  defp with_option_notes(%{"status" => "invalid"} = result, _answer, _ids), do: result

  defp with_option_notes(result, %{"option_notes" => notes}, ids) when is_map(notes) do
    if map_size(notes) > 0 and
         Enum.all?(notes, fn {id, text} ->
           id in ids and is_binary(text) and byte_size(text) <= 8000 and String.trim(text) != ""
         end),
       do: Map.put(result, "option_notes", notes),
       else: %{"status" => "invalid", "reason" => "invalid option notes"}
  end

  defp with_option_notes(_result, %{"option_notes" => _notes}, _ids),
    do: %{"status" => "invalid", "reason" => "invalid option notes"}

  defp with_option_notes(result, _answer, _ids), do: result

  defp no_option_notes(_result, %{"option_notes" => _notes}),
    do: %{"status" => "invalid", "reason" => "option notes require single choice"}

  defp no_option_notes(result, _answer), do: result

  defp valid_questions?(questions) when is_list(questions) and length(questions) in 1..4,
    do: Enum.all?(questions, &valid_question?/1) and unique?(questions, "id")

  defp valid_questions?(_questions), do: false

  defp valid_question?(%{"id" => id, "question" => text} = question) do
    options = Map.get(question, "options", [])
    type = question_type(question)

    short_text?(id, 64) and short_text?(text, 2000) and
      type in ~w(single_choice multi_select ranking text number) and
      is_boolean(Map.get(question, "multiple", false)) and
      (question["multiple"] != true or type == "multi_select") and
      if(type in ~w(text number), do: options == [], else: valid_options?(options)) and
      match?({:ok, _}, Diagram.normalize(question["diagram"]))
  end

  defp valid_question?(_question), do: false

  defp valid_options?(options) when is_list(options) and length(options) in 2..6,
    do:
      Enum.all?(options, &valid_option?/1) and unique?(options, "id") and
        unique?(options, "label")

  defp valid_options?(_options), do: false

  defp valid_option?(%{"id" => id, "label" => label} = option),
    do:
      short_text?(id, 64) and short_text?(label, 120) and
        String.downcase(String.trim(label)) != "other" and
        optional_text?(option["description"], 1000) and optional_text?(option["preview"], 4000) and
        match?({:ok, _}, Diagram.normalize(option["diagram"]))

  defp valid_option?(_option), do: false

  defp optional_text?(nil, _max), do: true
  defp optional_text?(text, max), do: short_text?(text, max)

  defp short_text?(text, max) when is_binary(text),
    do: byte_size(text) <= max and String.trim(text) != ""

  defp short_text?(_text, _max), do: false
  defp unique?(items, key), do: length(Enum.uniq_by(items, & &1[key])) == length(items)
  defp question_type(%{"type" => type}), do: type
  defp question_type(%{"multiple" => true}), do: "multi_select"
  defp question_type(_question), do: "single_choice"

  defp valid_number?(number),
    do:
      byte_size(number) <= 100 and
        Regex.match?(~r/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/, String.trim(number))

  defp text_schema(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
end
