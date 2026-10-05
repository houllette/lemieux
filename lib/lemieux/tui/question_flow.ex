defmodule Lemieux.TUI.QuestionFlow do
  @moduledoc """
  Stages `ask_user` answers locally until the person reviews the whole set.

  One parked call contains every question. Moving between tabs changes only
  this state; the session receives a reply once, after explicit submission.
  The final Other choice on choice questions is supplied by the UI, never by
  the model. Ranking has only the items being ranked.
  """

  @type t :: map()

  @doc "Builds a flow from a parked ask_user payload."
  @spec new(payload :: map(), draft :: String.t()) :: t()
  def new(payload, draft) do
    questions =
      case field(payload, :questions) do
        questions when is_list(questions) -> Enum.map(questions, &question/1)
        _single -> [question(payload)]
      end

    %{
      call_id: field(payload, :call_id),
      batch?: field(payload, :questionnaire) == true,
      questions: questions,
      index: 0,
      selected: 0,
      selections: %{},
      answers: %{},
      rankings: %{},
      other_drafts: %{},
      note_drafts: %{},
      option_notes: %{},
      question_notes: %{},
      other?: hd(questions).type in ~w(text number),
      note_option: nil,
      review?: false,
      review_index: length(questions),
      draft: draft
    }
  end

  @doc "Current question, or nil on the review tab."
  @spec current(flow :: t()) :: map() | nil
  def current(%{review?: true}), do: nil
  def current(flow), do: Enum.at(flow.questions, flow.index)

  @doc "Moves the highlighted choice or review action."
  @spec move(flow :: t(), by :: integer()) :: t()
  def move(%{review?: true} = flow, by),
    do: %{flow | review_index: Integer.mod(flow.review_index + by, length(flow.questions) + 1)}

  def move(flow, by) do
    question = current(flow)
    count = max(length(question.options) + if(question.allow_other?, do: 1, else: 0), 1)
    %{flow | selected: Integer.mod(flow.selected + by, count)}
  end

  @doc "Moves to a question tab or the review tab."
  @spec tab(flow :: t(), by :: integer()) :: t()
  def tab(flow, by) do
    flow = remember_selection(flow)
    index = Integer.mod(tab_index(flow) + by, length(flow.questions) + 1)

    case Enum.at(flow.questions, index) do
      nil -> %{flow | index: index, review?: true, other?: false, note_option: nil}
      question -> question_tab(flow, question, index)
    end
  end

  defp question_tab(flow, question, index) do
    selected = Map.get(flow.selections, question.id, answer_index(flow, question))

    %{
      flow
      | index: index,
        review?: false,
        selected: selected,
        other?:
          question.type in ~w(text number) or
            (question.allow_other? and selected == length(question.options)),
        note_option: nil
    }
  end

  defp answer_index(flow, question) do
    case Map.get(flow.answers, question.id) do
      %{"text" => _} -> length(question.options)
      %{"selected" => [id | _]} -> Enum.find_index(question.options, &(&1.id == id)) || 0
      _missing -> 0
    end
  end

  defp remember_selection(%{review?: true} = flow), do: flow

  defp remember_selection(flow) do
    %{flow | selections: Map.put(flow.selections, current(flow).id, flow.selected)}
  end

  @doc "Selects a suggestion; Other is handled by the editor."
  @spec choose(flow :: t()) ::
          {:other, t()} | {:staged, t()} | {:incomplete, t()} | {:submit, t()}
  def choose(%{review?: true} = flow) do
    cond do
      flow.review_index < length(flow.questions) ->
        index = flow.review_index
        {:staged, question_tab(flow, Enum.at(flow.questions, index), index)}

      map_size(flow.answers) == length(flow.questions) ->
        {:submit, flow}

      true ->
        first_missing = Enum.find_index(flow.questions, &(!Map.has_key?(flow.answers, &1.id)))
        {:incomplete, question_tab(flow, Enum.at(flow.questions, first_missing), first_missing)}
    end
  end

  def choose(flow) do
    question = current(flow)

    case question.type do
      "ranking" -> choose_ranking(flow, question)
      type when type in ~w(text number) -> {:other, %{flow | other?: true}}
      _choice -> choose_option(flow, question)
    end
  end

  defp choose_ranking(flow, question) do
    ranks = Map.get(flow.rankings, question.id, %{})

    if map_size(ranks) == length(question.options),
      do: {:staged, stage(flow, ranking_answer(flow, question, ranks))},
      else: {:incomplete, flow}
  end

  defp choose_option(flow, question) do
    case Enum.at(question.options, flow.selected) do
      nil ->
        if question.allow_other?,
          do: {:other, %{flow | other?: true}},
          else: {:incomplete, flow}

      option ->
        selected =
          case Map.get(flow.answers, question.id) do
            %{"selected" => ids} when question.multiple? -> ids
            _other -> []
          end

        ids = if selected == [] and not question.multiple?, do: [option.id], else: selected
        {:staged, stage(flow, selection_answer(flow, question, ids))}
    end
  end

  @doc "Assigns a priority number to the highlighted item; each number belongs to one item."
  @spec rank(flow :: t(), number :: integer()) :: t()
  def rank(flow, number) do
    question = current(flow)
    option = Enum.at(question.options, flow.selected)

    if (question.type == "ranking" and option) && number in 1..length(question.options) do
      ranks = Map.get(flow.rankings, question.id, %{})

      ranks =
        ranks
        |> Enum.reject(fn {id, rank} -> id == option.id or rank == number end)
        |> Map.new()
        |> Map.put(option.id, number)

      answers =
        if map_size(ranks) == length(question.options),
          do: Map.put(flow.answers, question.id, ranking_answer(flow, question, ranks)),
          else: Map.delete(flow.answers, question.id)

      %{flow | rankings: Map.put(flow.rankings, question.id, ranks), answers: answers}
    else
      flow
    end
  end

  @doc "Returns an assigned priority for an option, if any."
  @spec rank_for(flow :: t(), question_id :: String.t(), option_id :: String.t()) ::
          integer() | nil
  def rank_for(flow, question_id, option_id),
    do: get_in(flow.rankings, [question_id, option_id])

  @doc "Toggles the highlighted suggestion for a multiple-choice question."
  @spec toggle(flow :: t()) :: t()
  def toggle(flow) do
    question = current(flow)
    option = Enum.at(question.options, flow.selected)

    if question.multiple? and option do
      existing = get_in(flow.answers, [question.id, "selected"]) || []

      ids =
        if option.id in existing,
          do: List.delete(existing, option.id),
          else: existing ++ [option.id]

      answers =
        if ids == [],
          do: Map.delete(flow.answers, question.id),
          else: Map.put(flow.answers, question.id, selection_answer(flow, question, ids))

      %{flow | answers: answers}
    else
      flow
    end
  end

  @doc "Stages a custom answer when it contains text."
  @spec custom(flow :: t(), text :: String.t()) :: {:staged, t()} | {:empty, t()}
  def custom(flow, text) do
    type = current(flow).type
    note = Map.get(flow.question_notes, current(flow).id)

    if String.trim(text) == "" or (type == "number" and not valid_number?(text)),
      do: {:empty, flow},
      else:
        {:staged,
         stage(
           %{flow | other_drafts: Map.delete(flow.other_drafts, current(flow).id)},
           maybe_note(
             %{
               if(type == "number", do: "number", else: "text") =>
                 if(type == "number", do: String.trim(text), else: text)
             },
             note
           )
         )}
  end

  @doc "Begins a note for the highlighted suggestion."
  @spec edit_note(flow :: t()) :: t()
  def edit_note(flow) do
    question = current(flow)

    if question.type in ~w(multi_select ranking) do
      %{flow | note_option: :question, other?: false}
    else
      case Enum.at(question.options, flow.selected) do
        nil -> flow
        option -> %{flow | note_option: option.id, other?: false}
      end
    end
  end

  @doc "Closes note editing without discarding the question panel."
  @spec cancel_note(flow :: t()) :: t()
  def cancel_note(flow) do
    question = current(flow)

    %{
      flow
      | note_option: nil,
        other?:
          question.type in ~w(text number) or
            (question.allow_other? and flow.selected == length(question.options))
    }
  end

  @doc "Saves a note with its suggested answer."
  @spec save_note(flow :: t(), text :: String.t()) :: {:staged | :saved | :empty, t()}
  def save_note(%{note_option: :question} = flow, text) do
    if String.trim(text) == "" do
      {:empty, flow}
    else
      question = current(flow)
      answer = Map.get(flow.answers, question.id)

      answers =
        if answer,
          do: Map.put(flow.answers, question.id, Map.put(answer, "notes", text)),
          else: flow.answers

      {:saved,
       %{
         flow
         | question_notes: Map.put(flow.question_notes, question.id, text),
           note_drafts: Map.delete(flow.note_drafts, {question.id, :question}),
           answers: answers,
           note_option: nil
       }}
    end
  end

  def save_note(%{note_option: id} = flow, text) when is_binary(id) do
    if String.trim(text) == "" do
      {:empty, flow}
    else
      save_nonempty_note(flow, id, text)
    end
  end

  defp save_nonempty_note(flow, id, text) do
    question = current(flow)
    notes = flow.option_notes |> Map.get(question.id, %{}) |> Map.put(id, text)

    flow = %{
      flow
      | option_notes: Map.put(flow.option_notes, question.id, notes),
        note_drafts: Map.delete(flow.note_drafts, {question.id, id}),
        note_option: nil
    }

    save_note_answer(flow, question, id)
  end

  defp save_note_answer(flow, question, id) do
    ids = get_in(flow.answers, [question.id, "selected"]) || []
    ids = if id in ids, do: ids, else: ids ++ [id]
    answer = selection_answer(flow, question, ids)

    if question.multiple?,
      do: {:saved, %{flow | answers: Map.put(flow.answers, question.id, answer)}},
      else: {:staged, stage(flow, answer)}
  end

  @doc "Retains editor text while moving to another question tab."
  @spec stash_editor(flow :: t(), text :: String.t()) :: t()
  def stash_editor(%{other?: true} = flow, text),
    do: %{flow | other_drafts: Map.put(flow.other_drafts, current(flow).id, text)}

  def stash_editor(%{note_option: id} = flow, text) when not is_nil(id),
    do: %{flow | note_drafts: Map.put(flow.note_drafts, {current(flow).id, id}, text)}

  def stash_editor(flow, _text), do: flow

  @doc "Returns the current Other draft or saved answer for the editor and option row."
  @spec other_text(flow :: t()) :: String.t()
  def other_text(flow) do
    question = current(flow)

    Map.get(flow.other_drafts, question.id) || get_in(flow.answers, [question.id, "text"]) ||
      get_in(flow.answers, [question.id, "number"]) || ""
  end

  @doc "Returns the current suggestion's note draft or saved note."
  @spec note_text(flow :: t(), option_id :: String.t()) :: String.t()
  def note_text(flow, id) do
    question_id = current(flow).id

    Map.get(flow.note_drafts, {question_id, id}) ||
      get_in(flow.option_notes, [question_id, id]) || ""
  end

  @doc "Returns the current question-wide note draft or saved note."
  @spec note_text(flow :: t()) :: String.t()
  def note_text(flow) do
    question_id = current(flow).id

    Map.get(flow.note_drafts, {question_id, :question}) ||
      Map.get(flow.question_notes, question_id, "")
  end

  @doc "Returns the single answer or the complete batch for Session.answer/3."
  @spec response(flow :: t()) :: String.t() | map()
  def response(%{batch?: true} = flow),
    do: %{"answers" => Enum.map(flow.questions, &Map.fetch!(flow.answers, &1.id))}

  def response(flow) do
    question = hd(flow.questions)

    case Map.fetch!(flow.answers, question.id) do
      %{"text" => text} ->
        text

      %{"number" => number} ->
        number

      %{"selected" => [id], "option_notes" => notes} ->
        "#{Enum.find(question.options, &(&1.id == id)).label} | Note: #{notes[id]}"

      %{"selected" => [id]} ->
        Enum.find(question.options, &(&1.id == id)).label
    end
  end

  @doc "Human-readable summary of an answer on the review tab."
  @spec summary(flow :: t(), question :: map()) :: String.t()
  def summary(flow, question) do
    case Map.get(flow.answers, question.id) do
      %{"text" => text} ->
        text

      %{"number" => number} ->
        number

      %{"ranked" => ids} = answer ->
        ranking_summary(question, ids, answer["notes"])

      %{"selected" => ids} = answer ->
        selection_summary(question, ids, answer)

      _missing ->
        "Unanswered"
    end
  end

  defp ranking_summary(question, ids, note) do
    priorities =
      ids
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {id, rank} ->
        option = Enum.find(question.options, &(&1.id == id))
        "#{rank}. #{option.label}"
      end)

    if is_nil(note),
      do: priorities,
      else: priorities <> " · note: " <> note
  end

  defp selection_summary(question, ids, answer) do
    labels =
      question.options
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map_join(", ", & &1.label)

    notes = answer["option_notes"] || %{}
    general_note = answer["notes"]
    choice = if labels == "", do: "None selected", else: labels

    cond do
      is_binary(general_note) -> choice <> " · note: " <> general_note
      map_size(notes) > 0 -> choice <> " · note: " <> named_notes(question, notes)
      true -> choice
    end
  end

  defp named_notes(question, notes) do
    question.options
    |> Enum.filter(&Map.has_key?(notes, &1.id))
    |> Enum.map_join("; ", fn option -> "#{option.label}: #{notes[option.id]}" end)
  end

  defp stage(flow, answer) do
    question_id = current(flow).id
    answers = Map.put(flow.answers, question_id, answer)
    next = flow.index + 1
    next_question = Enum.at(flow.questions, next)

    %{
      flow
      | answers: answers,
        selections: Map.put(flow.selections, question_id, flow.selected),
        index: next,
        review?: next == length(flow.questions),
        review_index: length(flow.questions),
        selected: 0,
        other?: next_question != nil and next_question.type in ~w(text number),
        note_option: nil
    }
  end

  defp selection_answer(flow, question, ids) do
    notes = flow.option_notes |> Map.get(question.id, %{}) |> Map.take(ids)
    answer = %{"selected" => ids}

    if question.multiple?,
      do: maybe_note(answer, Map.get(flow.question_notes, question.id)),
      else: if(map_size(notes) == 0, do: answer, else: Map.put(answer, "option_notes", notes))
  end

  defp ranking_answer(flow, question, ranks) do
    ids = ranks |> Enum.sort_by(fn {_id, rank} -> rank end) |> Enum.map(&elem(&1, 0))
    maybe_note(%{"ranked" => ids}, Map.get(flow.question_notes, question.id))
  end

  defp maybe_note(answer, note) when is_binary(note), do: Map.put(answer, "notes", note)
  defp maybe_note(answer, _note), do: answer

  defp tab_index(%{review?: true, questions: questions}), do: length(questions)
  defp tab_index(flow), do: flow.index

  defp question(payload) do
    options = field(payload, :options) || []

    %{
      id: field(payload, :question_id) || "answer",
      text: field(payload, :question),
      diagram: field(payload, :diagram),
      type:
        field(payload, :type) ||
          if(field(payload, :multiple) == true, do: "multi_select", else: "single_choice"),
      multiple?: field(payload, :type) == "multi_select" or field(payload, :multiple) == true,
      allow_other?:
        Map.get(
          payload,
          :allow_other?,
          Map.get(payload, "allow_other?", field(payload, :type) != "ranking")
        ),
      options:
        options
        |> Enum.with_index(1)
        |> Enum.map(fn {option, index} ->
          %{
            id: field(option, :id) || Integer.to_string(index),
            label: field(option, :label),
            description: field(option, :description),
            preview: field(option, :preview),
            diagram: field(option, :diagram)
          }
        end)
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp valid_number?(number),
    do:
      byte_size(number) <= 100 and
        Regex.match?(~r/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/, String.trim(number))
end
