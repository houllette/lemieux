defmodule Lemieux.Session.Questions do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Session.Approvals
  alias Lemieux.Session.Core

  # One attention surface per session. A pending receipt answers the provider
  # tool call immediately; the eventual human input is a separate, identified
  # user entry at the next request boundary. Never spin a model to poll, and
  # never start an idle turn merely because an optional answer arrived.
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
        payload = Map.merge(payload, %{call_id: id, tool_call_id: call_id, deferred: true})
        timer = Approvals.park_timer(state, ttl, id)
        question = %{payload: payload, timer: timer, expires_at: expires}

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

  def answer(%{deferred_question: %{id: id} = question} = state, id, answer) do
    if byte_size(JSON.encode!(answer)) > 32_768 do
      {:reply, {:error, :invalid_answer}, state}
    else
      accept_answer(state, id, question, answer)
    end
  end

  defp accept_answer(state, id, question, answer) do
    Approvals.cancel_timer(state, question.timer)

    payload = %{
      "call_id" => id,
      "kind" => "question",
      "status" => "answered",
      "detail" => %{"answer" => answer, "deferred" => true, "session_id" => state.id}
    }

    state =
      %{state | deferred_question: nil, deferred_answers: state.deferred_answers ++ [payload]}
      |> Core.append({:approval, payload, nil})

    {:reply, :ok, state}
  end

  def expire(%{deferred_question: %{id: id}} = state, id) do
    %{state | deferred_question: nil}
    |> Core.append(
      {:approval, %{"call_id" => id, "kind" => "question", "status" => "timed_out"}, nil}
    )
  end

  def expire(state, _stale), do: state

  def cancel(state) do
    state =
      case state.deferred_question do
        nil ->
          state

        %{id: id, timer: timer} ->
          Approvals.cancel_timer(state, timer)

          Core.append(
            state,
            {:approval, %{"call_id" => id, "kind" => "question", "status" => "cancelled"}, nil}
          )
      end

    # Already accepted answers stay durable, but cancellation must not queue
    # an automatic continuation. They are read only on an explicit next run.
    %{state | deferred_question: nil}
  end

  def pending(%{deferred_question: nil}), do: []

  def pending(%{deferred_question: %{id: id, payload: payload}}),
    do: [%{call_id: id, kind: :question, payload: payload}]

  def drain(state) do
    Enum.reduce(state.deferred_answers, %{state | deferred_answers: []}, fn answer, state ->
      data = %{"question_id" => answer["call_id"], "answer" => answer["detail"]["answer"]}

      Core.append(
        state,
        {:user,
         %{
           "source" => "question_answer",
           "question_id" => answer["call_id"],
           "text" =>
             "Human answer to deferred question (not approval of any other action):\n" <>
               JSON.encode!(data)
         }, nil}
      )
    end)
  end

  # A fork cannot inherit the source session's human attention or a queued
  # response. Resume restores data and deadlines, never an execution task.
  def restore(state) do
    {question, answers} =
      Enum.reduce(Core.entries(state), {nil, []}, fn
        %{
          type: :approval,
          payload:
            %{
              "kind" => "question",
              "status" => "pending",
              "detail" => %{"deferred" => true, "session_id" => owner} = detail
            } = p
        },
        {_q, answers}
        when owner == state.id ->
          {p |> Map.put("presentation", detail["presentation"]), answers}

        %{
          type: :approval,
          payload:
            %{
              "kind" => "question",
              "status" => "answered",
              "detail" => %{"deferred" => true, "session_id" => owner}
            } = p
        },
        {_q, answers}
        when owner == state.id ->
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
    %{state | deferred_question: %{id: id, payload: payload, expires_at: expires, timer: timer}}
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
