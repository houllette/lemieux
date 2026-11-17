defmodule Lemieux.Session.Questions do
  @moduledoc false

  alias Lemieux.Clock
  alias Lemieux.Contract
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Core
  alias Lemieux.Session.Prompts

  # One attention surface per session. A pending receipt answers the provider
  # tool call immediately; the eventual human input is a separate, identified
  # user entry at the next request boundary. Only an explicit host-authorized
  # submission can continue an idle task.
  def defer(state, call_id, payload) do
    cond do
      occupied?(state) ->
        {:reply, {:error, "another question is still awaiting an answer"}, state}

      MapSet.size(state.subscribers.pids) == 0 ->
        {:reply, {:error, "no human channel is attached"}, state}

      true ->
        id = "question_" <> Lemieux.ID.generate()
        ttl = state.approval_timeout
        expires = if is_integer(ttl), do: System.system_time(:millisecond) + ttl
        deadline = if is_integer(ttl), do: Clock.now_ms(state.clock) + ttl
        payload = Map.merge(payload, %{call_id: id, tool_call_id: call_id, deferred: true})
        timer = Approvals.park_timer(state, ttl, id)
        question = %{payload: payload, timer: timer, expires_at: expires, deadline: deadline}

        state =
          %{state | deferred_question: Map.put(question, :id, id)}
          |> Core.append({:approval, pending_record(state.id, id, payload, expires), nil})
          |> Core.emit({:question, payload})

        {:reply, {:deferred, id}, state}
    end
  end

  def occupied?(state),
    do:
      state.deferred_question != nil or
        Enum.any?(state.parked, fn {_, w} -> w.kind == :question end)

  def answer(state, id, answer, mode \\ :queue)

  def answer(%{deferred_question: %{id: id} = question} = state, id, answer, mode) do
    cond do
      expired?(question.deadline, state.clock) ->
        {:reply, {:error, :unknown_call}, expire(state, id)}

      byte_size(JSON.encode!(answer)) > 32_768 ->
        {:reply, {:error, :invalid_answer}, state}

      true ->
        state |> accept_answer(id, question, answer) |> after_answer(mode)
    end
  end

  def answer(state, _id, _answer, _mode), do: {:reply, {:error, :unknown_call}, state}

  defp after_answer(state, :queue), do: {:reply, :ok, %{state | deferred_resume: nil}}

  defp after_answer(state, :continue) do
    cond do
      Core.busy?(state) and not is_nil(state.evidence.current_run) ->
        {:reply, {:ok, :queued}, %{state | deferred_resume: :requested}}

      resumable?(state) ->
        {:waiting, used} = state.deferred_resume
        {:reply, {:ok, :continuing}, Prompts.resume_question_answer(%{state | turns_taken: used})}

      true ->
        {:reply, {:ok, :saved}, %{state | deferred_resume: nil}}
    end
  end

  defp resumable?(%{deferred_resume: {:waiting, used}} = state),
    do: used < state.max_turns and not Core.busy?(state)

  defp resumable?(_state), do: false

  def answered?(state), do: Enum.any?(state.deferred_answers, &(&1["status"] == "answered"))

  def continue_at_stop?(state, stop_reason) do
    state.deferred_resume == :requested and stop_reason in [:stop, :ok] and
      is_nil(state.aside) and state.turns_taken < state.max_turns
  end

  def stopped(state, stop_reason) do
    waiting =
      stop_reason in [:stop, :ok] and not is_nil(state.deferred_question) and
        is_nil(state.aside)

    %{state | deferred_resume: if(waiting, do: {:waiting, state.turns_taken})}
  end

  defp expired?(deadline, clock) when is_integer(deadline), do: deadline <= Clock.now_ms(clock)
  defp expired?(_infinite, _clock), do: false

  defp accept_answer(state, id, question, answer) do
    Approvals.cancel_timer(state, question.timer)

    payload = %{
      "call_id" => id,
      "kind" => "question",
      "status" => "answered",
      "detail" => %{"answer" => answer, "deferred" => true, "session_id" => state.id}
    }

    %{state | deferred_question: nil, deferred_answers: state.deferred_answers ++ [payload]}
    |> Core.append({:approval, payload, nil})
  end

  def expire(%{deferred_question: %{id: id}} = state, id), do: close(state, id, "timed_out")

  def expire(state, _stale), do: state

  def cancel(state) do
    state =
      case state.deferred_question do
        nil ->
          state

        %{id: id, timer: timer} ->
          Approvals.cancel_timer(state, timer)

          close(state, id, "cancelled")
      end

    # Already accepted answers stay durable, but cancellation must not queue
    # an automatic continuation. They are read only on an explicit next run.
    %{state | deferred_question: nil, deferred_resume: nil}
  end

  defp close(state, id, status) do
    Approvals.cancel_timer(state, state.deferred_question.timer)

    payload = %{
      "call_id" => id,
      "kind" => "question",
      "status" => status,
      "detail" => %{
        "answer" => %{"status" => status},
        "deferred" => true,
        "session_id" => state.id
      }
    }

    %{
      state
      | deferred_question: nil,
        deferred_resume: nil,
        deferred_answers: state.deferred_answers ++ [payload]
    }
    |> Core.append({:approval, payload, nil})
  end

  def pending(%{deferred_question: nil}), do: []

  def pending(%{deferred_question: %{id: id, payload: payload}}),
    do: [%{call_id: id, kind: :question, payload: payload}]

  def drain(state) do
    Enum.reduce(state.deferred_answers, clear_answers(state), fn answer, state ->
      data = %{"question_id" => answer["call_id"], "answer" => answer["detail"]["answer"]}

      Core.append(
        state,
        {:user,
         %{
           "source" => "question_answer",
           "question_id" => answer["call_id"],
           "question_answer" => data,
           "text" =>
             "Deferred question resolution (not approval of any other action):\n" <>
               JSON.encode!(data)
         }, nil}
      )
    end)
  end

  defp clear_answers(%{deferred_resume: :requested} = state),
    do: %{state | deferred_answers: [], deferred_resume: nil}

  defp clear_answers(state), do: %{state | deferred_answers: []}

  # A fork cannot inherit the source session's human attention or a queued
  # response. Resume restores data and deadlines, never an execution task.
  def restore(state) do
    {question, answers} =
      Enum.reduce(Core.entries(state), {nil, []}, fn
        %{
          type: :approval,
          seq: seq,
          payload:
            %{
              "kind" => "question",
              "status" => "pending",
              "detail" => %{"deferred" => true, "session_id" => owner} = detail
            } = p
        },
        {_q, answers}
        when owner == state.id ->
          {Map.merge(p, %{"presentation" => detail["presentation"], "seq" => seq}), answers}

        %{
          type: :approval,
          payload:
            %{
              "kind" => "question",
              "status" => status,
              "detail" => %{"deferred" => true, "session_id" => owner}
            } = p
        },
        {_q, answers}
        when owner == state.id and status in ~w(answered timed_out cancelled) ->
          {nil, answers ++ [p]}

        %{type: :approval, payload: %{"kind" => "question", "status" => status}}, {_q, answers}
        when status in ~w(cancelled timed_out) ->
          {nil, answers}

        %{type: :user, payload: %{"source" => "question_answer", "question_id" => id}},
        {q, answers} ->
          {q, Enum.reject(answers, &(&1["call_id"] == id))}

        _entry, acc ->
          acc
      end)

    state = %{state | deferred_answers: answers}
    restore_pending(state, question)
  end

  defp restore_pending(state, nil), do: state

  defp restore_pending(state, pending) do
    id = pending["call_id"]
    expires = pending["detail"]["expires_at"]

    remaining =
      if is_integer(expires),
        do: max(expires - System.system_time(:millisecond), 0),
        else: :infinity

    # Only the known presentation keys become atoms; never external atom creation.
    payload = atom_keys(pending["presentation"])
    timer = Approvals.park_timer(state, remaining, id)
    deadline = if is_integer(remaining), do: Clock.now_ms(state.clock) + remaining

    state = %{
      state
      | deferred_question: %{
          id: id,
          payload: payload,
          expires_at: expires,
          deadline: deadline,
          timer: timer
        }
    }

    if remaining == 0, do: expire(state, id), else: restore_continuation(state, pending["seq"])
  end

  # Resume can offer a new authorized continuation only if the transcript
  # establishes a successful stop after the question and its request budget.
  # The intent to continue after an already accepted answer stays in memory.
  defp restore_continuation(state, question_seq) do
    last_stop =
      Enum.find(state.reversed_entries, fn entry ->
        entry.seq > question_seq and entry.type in [:run_evidence, :error, :cancelled]
      end)

    case last_stop do
      %{type: :run_evidence, payload: %{"stop_reason" => reason, "requests" => requests}}
      when reason in ["stop", "ok"] and is_list(requests) ->
        %{state | deferred_resume: {:waiting, length(requests)}}

      _other ->
        state
    end
  end

  defp atom_keys(map) when is_map(map) do
    keys =
      ~w(call_id tool_call_id deferred question questionnaire ask_user questions instructions question_id options type multiple diagram id label description preview)a

    Map.new(map, fn {key, value} ->
      atom = Enum.find(keys, &(Atom.to_string(&1) == key)) || key
      {atom, atom_keys(value)}
    end)
  end

  defp atom_keys(list) when is_list(list), do: Enum.map(list, &atom_keys/1)
  defp atom_keys(value), do: value

  defp pending_record(session_id, id, payload, expires) do
    %{
      "call_id" => id,
      "kind" => "question",
      "status" => "pending",
      "detail" => %{
        "deferred" => true,
        "session_id" => session_id,
        "expires_at" => expires,
        "presentation" => Contract.json(payload)
      }
    }
  end
end
