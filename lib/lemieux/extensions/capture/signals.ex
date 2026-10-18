defmodule Lemieux.Extensions.Capture.Signals do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Transcript
  @verification ~r/(?:\b(?:mix|npm|cargo|go|make)\s+(?:test|check)\b|\bpytest\b|tests\/run\.sh)/
  @correction ~r/\A\s*(?:no|wrong|that's not|undo|revert|not what I asked|you broke)(?![\w])/i

  @spec detect(entries :: [Entry.t()], commands :: [String.t()]) :: [map()]
  def detect(entries, commands) do
    initial = %{
      prompt: nil,
      assistant: false,
      pending: %{},
      errors: %{},
      completed: [],
      commands: commands
    }

    state = Enum.reduce(entries, initial, &observe/2)

    (state.completed ++ Map.values(state.pending) ++ repeated(state.errors))
    |> Enum.sort_by(& &1["entry_ids"])
    |> Enum.take(32)
  end

  defp observe(%Entry{type: :user, id: id, payload: %{"text" => text}} = entry, state) do
    if Transcript.stop_hook?(entry) do
      state
    else
      state =
        if state.assistant and Regex.match?(@correction, text),
          do: %{state | completed: [signal("correction", id, [id], nil, []) | state.completed]},
          else: state

      %{state | prompt: id}
    end
  end

  defp observe(%Entry{type: :assistant}, state), do: %{state | assistant: true}

  defp observe(%Entry{type: :tool_result, id: id, payload: payload}, state) do
    args = payload["arguments"] || %{}
    command = args["command"]
    result = payload["structured_content"] || %{}

    if payload["name"] == "bash" and is_binary(command) and
         (command in state.commands or Regex.match?(@verification, command)) and
         result["status"] == "exited" and is_integer(result["exit_status"]) do
      verification(state, id, command, result["exit_status"])
    else
      tool(state, id, payload)
    end
  end

  defp observe(
         %Entry{
           type: :extension_state,
           id: id,
           payload: %{"namespace" => "lemieux.verify", "value" => %{"last" => last}}
         },
         state
       ) do
    if last["status"] in ~w(passed failed) and is_binary(last["command"]) and
         is_integer(last["exit_status"]),
       do: verification(state, id, last["command"], last["exit_status"]),
       else: state
  end

  defp observe(_entry, state), do: state

  defp verification(state, id, command, status) when status != 0 do
    observation = %{"entry_id" => id, "exit_status" => status}
    value = signal("verification_failure", state.prompt, [id], command, [observation])
    %{state | pending: Map.put_new(state.pending, command, value)}
  end

  defp verification(state, id, command, 0) do
    case Map.pop(state.pending, command) do
      {nil, _pending} ->
        state

      {failure, pending} ->
        recovered =
          failure
          |> Map.put("kind", "verification_recovery")
          |> Map.update!("entry_ids", &(&1 ++ [id]))
          |> Map.update!("observations", &(&1 ++ [%{"entry_id" => id, "exit_status" => 0}]))

        %{state | pending: pending, completed: [recovered | state.completed]}
    end
  end

  defp tool(state, id, payload) do
    key = Contract.digest(Map.take(payload, ~w(name arguments)))

    case {payload["error"], Map.get(state.errors, key, [])} do
      {true, errors} ->
        %{
          state
          | errors:
              Map.put(
                state.errors,
                key,
                Enum.take([%{"id" => id, "prompt" => state.prompt} | errors], 8)
              )
        }

      {false, [_a, _b | _] = errors} ->
        signal =
          signal(
            "tool_recovery",
            hd(errors)["prompt"],
            Enum.map(Enum.reverse(errors), & &1["id"]) ++ [id],
            nil,
            []
          )

        %{state | errors: Map.delete(state.errors, key), completed: [signal | state.completed]}

      {false, _errors} ->
        %{state | errors: Map.delete(state.errors, key)}

      _unknown ->
        state
    end
  end

  defp repeated(errors) do
    errors
    |> Map.values()
    |> Enum.filter(&(length(&1) >= 2))
    |> Enum.map(fn errors ->
      signal(
        "repeated_tool_failure",
        hd(errors)["prompt"],
        Enum.map(Enum.reverse(errors), & &1["id"]),
        nil,
        []
      )
    end)
  end

  defp signal(kind, prompt, ids, command, observations),
    do: %{
      "kind" => kind,
      "prompt_id" => prompt,
      "entry_ids" => ids,
      "command" => command,
      "observations" => observations
    }
end
