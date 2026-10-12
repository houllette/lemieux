defmodule Lemieux.Execution do
  @moduledoc """
  A host's synchronous dispatch journal, separate from policy hooks.

  `:execution` is an optional `{module, state}` session option. The host records
  intent in `c:start/2` before an effect and its result in `c:finish/3` before
  delivery. A failed journal write stops execution; best-effort observer hooks
  cannot provide this guarantee. Neither callback may call the invoking session.

  This is an authority seam: it is never restored from a transcript. Children
  inherit it even when their provider is replaced. A completed record proves
  a returned outcome; a start without a finish proves only uncertainty. Hosts
  choose storage, reconciliation and retry policy, not the loop.
  """

  alias Lemieux.Contract
  alias Lemieux.Provider
  alias Lemieux.Request
  alias Lemieux.Turn
  alias Lemieux.Usage

  @type t :: {module(), term()} | nil
  @callback start(state :: term(), effect :: map()) :: {:ok, term()} | {:error, term()}
  @callback finish(state :: term(), token :: term(), result :: map()) :: :ok

  @doc "Records an effect before dispatch; a refusal has no effect."
  @spec start(execution :: t(), effect :: map()) :: {:ok, term()} | {:error, term()}
  def start(nil, _effect), do: {:ok, nil}
  def start({module, state}, effect), do: module.start(state, effect)

  @doc "Records the returned outcome before it reaches its consumer."
  @spec finish(execution :: t(), token :: term(), result :: map()) :: :ok
  def finish(nil, _token, _result), do: :ok
  def finish({module, state}, token, result), do: module.finish(state, token, result)

  @doc "Runs a provider through the host journal, retaining recoverable terminal entries."
  @spec run_provider(provider :: Provider.t(), request :: Request.t(), emit :: Provider.emit()) ::
          :ok | {:error, term()}
  def run_provider(provider, %Request{context: %{execution: execution}} = request, emit)
      when not is_nil(execution) do
    effect = provider_effect(request)
    request_id = effect["request_id"]

    with {:ok, token} <- start(execution, effect) do
      ref = make_ref()

      try do
        result =
          Provider.run(provider, request, fn event ->
            record_event(execution, token, ref, request, request_id, event)
            emit.(event)
          end)

        finish_return(execution, token, ref, request, request_id, result)
      after
        drain(ref, [])
      end
    end
  end

  def run_provider(provider, request, emit), do: Provider.run(provider, request, emit)

  defp provider_effect(request) do
    %{
      "kind" => "provider",
      "session_id" => request.context[:agent_id] || request.context[:session_id],
      "request_id" => request.context[:request_id] || Lemieux.ID.generate(),
      "purpose" => to_string(request.context[:execution_kind] || :turn),
      "model" => request.model
    }
  end

  defp record_event(execution, token, ref, request, request_id, event) do
    send(self(), {ref, event})

    if terminal?(event) do
      :ok = finish(execution, token, provider_result(drain(ref, []), request.model, request_id))
      send(self(), {ref, :finished})
    end
  end

  defp finish_return(execution, token, ref, request, request_id, result) do
    case drain(ref, []) do
      [:finished] ->
        result

      events ->
        :ok =
          finish(
            execution,
            token,
            provider_result(
              events ++ [{:error, incomplete_reason(result)}],
              request.model,
              request_id
            )
          )

        result
    end
  end

  defp incomplete_reason({:error, reason}), do: reason
  defp incomplete_reason(_result), do: :incomplete_stream

  defp terminal?({kind, _value}) when kind in [:done, :error], do: true
  defp terminal?(_event), do: false

  defp drain(ref, events) do
    receive do
      {^ref, event} -> drain(ref, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp provider_result(events, model, request_id) do
    {turn, entries} =
      Enum.reduce(events, {Turn.new(request_id), []}, fn event, {turn, entries} ->
        {turn, effects} = Turn.step(turn, event)

        appended =
          for {:append, {type, payload, usage}} <- effects,
              do: %{
                "type" => to_string(type),
                "payload" => Map.put(payload, "request_id", request_id),
                "usage" => if(usage, do: Usage.normalize(usage, model))
              }

        {turn, entries ++ appended}
      end)

    %{
      "entries" => Contract.json(entries),
      "stop_reason" => to_string(turn.stop_reason),
      "cost_usd" => if(turn.usage, do: Usage.cost_usd(Usage.normalize(turn.usage, model)))
    }
  end
end
