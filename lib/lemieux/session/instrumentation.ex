defmodule Lemieux.Session.Instrumentation do
  @moduledoc false

  alias Lemieux.ModelSpec
  alias Lemieux.Telemetry

  def start_prompt_telemetry(state) do
    started_at = Telemetry.start([:session, :prompt], telemetry_metadata(state))
    %{state | prompt_started_at: started_at}
  end

  def finish_prompt_telemetry(%{prompt_started_at: nil} = state, _stop_reason), do: state

  def finish_prompt_telemetry(state, stop_reason) do
    Telemetry.stop(
      [:session, :prompt],
      state.prompt_started_at,
      telemetry_metadata(state, %{
        stop_reason: telemetry_stop_reason(stop_reason),
        outcome: prompt_outcome(stop_reason)
      })
    )

    %{state | prompt_started_at: nil}
  end

  def finish_turn_telemetry(%{turn_started_at: nil} = state, _stop_reason), do: state

  def finish_turn_telemetry(state, stop_reason) do
    Telemetry.stop(
      [:turn],
      state.turn_started_at,
      telemetry_metadata(state, %{
        stop_reason: telemetry_stop_reason(stop_reason),
        outcome: prompt_outcome(stop_reason)
      })
    )

    %{state | turn_started_at: nil}
  end

  defp prompt_outcome(:error), do: :error
  defp prompt_outcome(:cancelled), do: :cancelled
  defp prompt_outcome(:hook_failed), do: :error
  defp prompt_outcome({:budget, _payload}), do: :budget
  defp prompt_outcome(:no_progress), do: :stopped
  defp prompt_outcome(:max_turns), do: :stopped
  defp prompt_outcome(_stop_reason), do: :ok

  def telemetry_stop_reason({reason, _payload}) when is_atom(reason), do: reason
  def telemetry_stop_reason(reason) when is_atom(reason), do: reason
  def telemetry_stop_reason(_reason), do: :other

  # What a gateway needs to see two actors in one conversation rather than one
  # actor making more requests. A subagent is an actor *inside* a conversation, so
  # the conversation id it reports is the root's and never its own. The root names
  # itself as an agent too, because an edge pointing at an actor nobody declared is
  # worse than no edge. Delegation is depth one (see `Lemieux.Subagent`); if it
  # ever nests, `:parent_agent_id` is the field that has to carry the immediate
  # spawner rather than the root.
  def correlation(metadata) do
    root = metadata[:root_session_id]
    self_id = metadata[:session_id]

    %{session_id: root || self_id, agent_id: self_id, request_id: metadata[:request_id]}
    |> put_parent(root, self_id)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_parent(correlation, root, self_id) when is_binary(root) and root != self_id,
    do: Map.put(correlation, :parent_agent_id, root)

  defp put_parent(correlation, _root, _self_id), do: correlation

  def telemetry_metadata(state, extra \\ %{}) do
    Map.merge(
      %{
        session_id: state.id,
        root_session_id: state.root_session_id,
        request_id: state.current_request_id,
        provider: ModelSpec.provider(state.model),
        model: state.model
      },
      extra
    )
  end

  def recovery_kind(nil), do: :threshold
  def recovery_kind(_reason), do: :provider_context_limit
end
