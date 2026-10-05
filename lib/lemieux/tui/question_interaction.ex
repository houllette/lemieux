# The ask-user modal stages answers until one explicit submission.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.QuestionInteraction do
    @moduledoc "Handles question and questionnaire keyboard input for a TUI state."

    alias Lemieux.Session
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.QuestionFlow

    @doc false
    @spec key(ExRatatui.Event.Key.t(), map(), map()) :: tuple()
    def key(
          %ExRatatui.Event.Key{code: code},
          %{tools: %{question_flow: %{note_option: nil}}} = state,
          _ctx
        )
        when code in ["up", "down"] do
      by = if code == "up", do: -1, else: 1

      flow =
        state.tools.question_flow
        |> QuestionFlow.stash_editor(ExRatatui.textarea_get_value(state.input))

      if QuestionFlow.current(flow) && QuestionFlow.current(flow).type in ~w(text number) do
        {:noreply, state}
      else
        {:noreply, question_update(state, QuestionFlow.move(%{flow | other?: false}, by))}
      end
    end

    def key(%ExRatatui.Event.Key{code: code}, state, _ctx)
        when code in ["left", "right"] do
      by = if code == "left", do: -1, else: 1

      flow =
        state.tools.question_flow
        |> QuestionFlow.stash_editor(ExRatatui.textarea_get_value(state.input))
        |> QuestionFlow.tab(by)

      {:noreply, question_update(state, flow)}
    end

    def key(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, state, _ctx)
        when code in ["tab", "back_tab"] do
      by = if code == "back_tab" or "shift" in modifiers, do: -1, else: 1

      flow =
        state.tools.question_flow
        |> QuestionFlow.stash_editor(ExRatatui.textarea_get_value(state.input))
        |> QuestionFlow.tab(by)

      {:noreply, question_update(state, flow)}
    end

    def key(
          %ExRatatui.Event.Key{code: "esc"},
          %{tools: %{question_flow: %{note_option: note}}} = state,
          _ctx
        )
        when not is_nil(note) do
      flow =
        state.tools.question_flow
        |> QuestionFlow.stash_editor(ExRatatui.textarea_get_value(state.input))
        |> QuestionFlow.cancel_note()

      {:noreply, question_update(state, flow)}
    end

    def key(%ExRatatui.Event.Key{code: "esc"}, state, _ctx), do: cancel_questions(state)

    def key(
          %ExRatatui.Event.Key{code: " ", modifiers: []},
          %{tools: %{question_flow: %{other?: false, note_option: nil}}} = state,
          _ctx
        ) do
      {:noreply, question_update(state, QuestionFlow.toggle(state.tools.question_flow))}
    end

    def key(%ExRatatui.Event.Key{} = event, state, ctx)
        when event.code in ["c", "C"] do
      if Keys.action(state.status.keys, event) == :interrupt,
        do: cancel_questions(state),
        else: question_edit_or_ignore(event, state, ctx)
    end

    def key(
          %ExRatatui.Event.Key{code: "n", modifiers: []},
          %{tools: %{question_flow: %{other?: false, note_option: nil, review?: false}}} = state,
          _ctx
        ) do
      flow = QuestionFlow.edit_note(state.tools.question_flow)
      {:noreply, question_update(state, flow)}
    end

    def key(
          %ExRatatui.Event.Key{code: digit, modifiers: []},
          %{tools: %{question_flow: %{other?: false, note_option: nil, review?: false}}} = state,
          _ctx
        )
        when digit in ~w(1 2 3 4 5 6) do
      flow = QuestionFlow.rank(state.tools.question_flow, String.to_integer(digit))
      {:noreply, question_update(state, flow)}
    end

    def key(
          %ExRatatui.Event.Key{code: "enter", modifiers: modifiers} = event,
          %{tools: %{question_flow: %{note_option: id}}} = state,
          ctx
        )
        when not is_nil(id) do
      if "shift" in modifiers, do: ctx.edit.(event, state), else: save_note_answer(state)
    end

    def key(
          %ExRatatui.Event.Key{code: "enter", modifiers: modifiers} = event,
          %{tools: %{question_flow: %{other?: true}}} = state,
          ctx
        ) do
      if "shift" in modifiers,
        do: ctx.edit.(event, state),
        else: save_other_answer(state)
    end

    def key(%ExRatatui.Event.Key{code: "enter"}, state, ctx),
      do: choose_question_answer(state, QuestionFlow.choose(state.tools.question_flow), ctx)

    def key(event, state, ctx), do: question_edit_or_ignore(event, state, ctx)

    defp save_other_answer(state) do
      case QuestionFlow.custom(
             state.tools.question_flow,
             ExRatatui.textarea_get_value(state.input)
           ) do
        {:staged, next} -> {:noreply, question_update(state, next)}
        {:empty, _same} -> {:noreply, state}
      end
    end

    defp save_note_answer(state) do
      case QuestionFlow.save_note(
             state.tools.question_flow,
             ExRatatui.textarea_get_value(state.input)
           ) do
        {:staged, next} -> {:noreply, question_update(state, next)}
        {:saved, next} -> {:noreply, question_update(state, next)}
        {:empty, _same} -> {:noreply, state}
      end
    end

    defp choose_question_answer(state, {:other, next}, _ctx) do
      {:noreply, question_update(state, next)}
    end

    defp choose_question_answer(state, {:staged, next}, _ctx),
      do: {:noreply, question_update(state, next)}

    defp choose_question_answer(state, {:incomplete, next}, _ctx),
      do: {:noreply, question_update(state, next)}

    defp choose_question_answer(state, {:submit, complete}, ctx),
      do: submit_questions(state, complete, ctx)

    defp question_edit_or_ignore(event, %{tools: %{question_flow: %{other?: true}}} = state, ctx),
      do: ctx.edit.(event, state)

    defp question_edit_or_ignore(
           event,
           %{tools: %{question_flow: %{note_option: id}}} = state,
           ctx
         )
         when not is_nil(id),
         do: ctx.edit.(event, state)

    defp question_edit_or_ignore(_event, state, _ctx), do: {:noreply, state}

    defp question_update(state, flow) do
      value =
        cond do
          flow.review? -> ""
          flow.other? -> QuestionFlow.other_text(flow)
          flow.note_option == :question -> QuestionFlow.note_text(flow)
          is_binary(flow.note_option) -> QuestionFlow.note_text(flow, flow.note_option)
          true -> ""
        end

      :ok = Editor.replace(state.input, value)
      put_in(state.tools.question_flow, flow)
    end

    defp cancel_questions(state) do
      flow = state.tools.question_flow
      :ok = Editor.replace(state.input, flow.draft)
      :ok = Session.cancel(state.session)
      conversation = %{state.conversation | asking: nil, question: nil, approvals: []}

      state =
        state
        |> put_in([Access.key!(:tools), :question_flow], nil)
        |> Map.put(:conversation, conversation)

      {:noreply, %{state | exit_armed: nil}}
    end

    defp submit_questions(state, flow, ctx) do
      :ok = Editor.replace(state.input, flow.draft)
      conversation = %{state.conversation | asking: nil, question: nil}

      state =
        state
        |> put_in([Access.key!(:tools), :question_flow], nil)
        |> Map.put(:conversation, conversation)

      ctx.run.(state, [{:answer, flow.call_id, QuestionFlow.response(flow)}])
    end
  end
end
