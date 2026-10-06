defmodule Lemieux.Session.Accounting do
  @moduledoc false

  alias Lemieux.Context
  alias Lemieux.Entry
  alias Lemieux.Messages
  alias Lemieux.ModelSpec
  alias Lemieux.Provider
  alias Lemieux.Provider.Admission
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Request
  alias Lemieux.Session.Compacting
  alias Lemieux.Session.Core
  alias Lemieux.Session.Instrumentation
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.ToolWave
  alias Lemieux.Telemetry
  alias Lemieux.Usage

  def request_budget(state, request) do
    requests = state.request_count

    if is_integer(state.max_requests) and requests >= state.max_requests do
      {:error,
       %{
         kind: :requests,
         spent: requests,
         estimate: 1,
         cap: state.max_requests,
         model: request.model
       }}
    else
      cost_budget(state, request)
    end
  end

  defp cost_budget(%{max_cost_usd: nil}, _request), do: :ok

  # The model rides along so the stop can name it: a session whose first
  # request stops on `estimate: nil` is otherwise told only that its cost
  # cannot be estimated, with nothing to say whether the model is unknown,
  # unpriced, or served by a route that does not estimate.
  defp cost_budget(state, request) do
    spent = state.spent_usd
    estimate = Provider.estimate_cost(state.provider, request)
    payload = %{spent: spent, estimate: estimate, cap: state.max_cost_usd, model: request.model}

    if is_number(spent) and is_number(estimate) and spent + estimate <= state.max_cost_usd,
      do: :ok,
      else: {:error, payload}
  end

  def run_provider(provider, nil, _key, _root_session_id, request, metadata, emit),
    do: run_provider_request(provider, request, metadata, emit)

  def run_provider(provider, limiter, key, root_session_id, request, metadata, emit) do
    limiter_metadata = Map.put(metadata, :root_session_id, root_session_id)
    waiting_at = Telemetry.start([:provider_limiter, :wait], limiter_metadata)

    checkout =
      Admission.checkout(
        limiter,
        key,
        root_session_id,
        Request.estimated_tokens(request)
      )

    case checkout do
      {:ok, lease} ->
        Telemetry.stop(
          [:provider_limiter, :wait],
          waiting_at,
          Map.put(limiter_metadata, :outcome, :granted)
        )

        try do
          result =
            run_provider_request(provider, request, metadata, fn event ->
              penalize_provider(limiter, key, event)
              reconcile_provider_usage(limiter, lease, event)
              emit.(event)
            end)

          penalize_provider(limiter, key, result)
          result
        after
          Admission.release(limiter, lease)
        end

      {:error, reason} ->
        Telemetry.stop(
          [:provider_limiter, :wait],
          waiting_at,
          Map.put(limiter_metadata, :outcome, :rejected)
        )

        {:error, {:provider_admission, reason}}
    end
  end

  defp run_provider_request(provider, request, metadata, emit) do
    context =
      Instrumentation.correlation(metadata)
      |> Map.put(:route_result_sink, request.context[:route_result_sink])
      |> Map.put(:route_task_supervisor, request.context[:route_task_supervisor])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    request = %{request | context: context}
    started_at = Telemetry.start([:provider, :request], metadata)
    terminal_ref = make_ref()

    try do
      result =
        Provider.run(provider, request, fn event ->
          if match?({:error, _reason}, event), do: send(self(), {terminal_ref, event})
          emit.(event)
        end)

      outcome = terminal_error(terminal_ref) || result

      Telemetry.stop(
        [:provider, :request],
        started_at,
        Map.merge(metadata, provider_outcome(outcome))
      )

      result
    catch
      kind, reason ->
        Telemetry.exception([:provider, :request], started_at, metadata, kind)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp provider_outcome(:ok), do: %{outcome: :ok}

  defp provider_outcome({:error, reason}),
    do: %{outcome: :error, reason_category: ProviderError.category(reason)}

  defp provider_outcome(_other), do: %{outcome: :invalid_return}

  defp terminal_error(ref) do
    receive do
      {^ref, {:error, _reason} = error} -> error
    after
      0 -> nil
    end
  end

  defp reconcile_provider_usage(limiter, lease, {:usage, usage}) when is_map(usage) do
    input = nonnegative_tokens(usage, "input_tokens", :input_tokens)
    output = nonnegative_tokens(usage, "output_tokens", :output_tokens)
    Admission.reconcile(limiter, lease, input + output)
  end

  defp reconcile_provider_usage(_limiter, _lease, _event), do: :ok

  defp penalize_provider(limiter, key, {:error, reason}) do
    case ProviderError.retry_after_ms(reason) do
      retry_after_ms when is_integer(retry_after_ms) ->
        Admission.penalize(limiter, key, retry_after_ms)

      nil ->
        :ok
    end
  end

  defp penalize_provider(_limiter, _key, _event_or_result), do: :ok

  defp nonnegative_tokens(usage, string_key, atom_key) do
    case Map.get(usage, string_key) || Map.get(usage, atom_key) do
      value when is_integer(value) and value >= 0 -> value
      _unknown -> 0
    end
  end

  def provider_limit_key(%{provider_limit_key: fun, provider: provider, model: model})
      when is_function(fun, 2),
      do: fun.(provider, model)

  def provider_limit_key(%{provider_limit_key: key}) when key != :default,
    do: key

  def provider_limit_key(%{provider: provider, model: model}),
    do: {elem(provider, 0), ModelSpec.provider(model), model}

  def measured_spend(entries) do
    Enum.reduce_while(entries, 0.0, fn
      %Entry{type: :tool_result, payload: payload}, total ->
        case get_in(payload, ["cost", "usd"]) do
          cost when is_number(cost) and cost >= 0 -> {:cont, total + cost}
          nil -> {:cont, total}
          _invalid -> {:halt, nil}
        end

      %Entry{type: type, usage: nil}, _total when type in [:assistant, :compaction] ->
        {:halt, nil}

      %Entry{type: :error, payload: %{"reason" => "compaction failed"}, usage: nil}, _total ->
        {:halt, nil}

      %Entry{usage: nil}, total ->
        {:cont, total}

      %Entry{usage: usage}, total ->
        case Usage.cost_usd(usage) do
          cost when is_number(cost) -> {:cont, total + cost}
          nil -> {:halt, nil}
        end
    end)
  end

  def account_external_usage(state, usage) do
    spent =
      case {state.spent_usd, Usage.cost_usd(usage)} do
        {current, cost} when is_number(current) and is_number(cost) -> current + cost
        _unknown -> nil
      end

    %{state | spent_usd: spent}
  end

  # Parent and child account independently for admission and budget, but a person
  # watching the root run paid for both. The direct value above keeps the parent
  # budget's established semantics; this is the explicit split for front ends.
  # Which entries carry delegated usage is `Lemieux.Context.delegated_usages/1`'s
  # rule, shared rather than restated.
  def usage_summary(state, context) do
    direct = %{
      "input_tokens" => context.spent.input,
      "output_tokens" => context.spent.output,
      "cache_read_tokens" => context.spent.cached,
      "cache_write_tokens" => context.spent.cache_write,
      "cost_usd" => state.spent_usd
    }

    delegated = state |> Core.entries() |> Context.delegated_usages() |> Usage.sum()

    %{direct: direct, delegated: delegated, total: Usage.add(direct, delegated)}
  end

  def account_usage(state, usage) do
    spent =
      case {state.spent_usd, Usage.cost_usd(usage)} do
        {spent, cost} when is_number(spent) and is_number(cost) -> spent + cost
        _unknown -> nil
      end

    %{state | spent_usd: spent, request_cost_pending?: false}
  end

  def account_tool_cost(state, %{cost: %{"usd" => cost}})
      when is_number(cost) and cost >= 0 do
    spent = if is_number(state.spent_usd), do: state.spent_usd + cost
    %{state | spent_usd: spent}
  end

  def account_tool_cost(state, %{cost: _unknown}), do: %{state | spent_usd: nil}
  def account_tool_cost(state, _result), do: state

  def account_compaction(state, {:crashed, _reason}), do: account_missing_usage(state)

  def account_compaction(state, {_outcome, events}) do
    case Compacting.summary_usage(events) do
      usage when map_size(usage) > 0 ->
        account_usage(
          state,
          Usage.normalize(usage, state.compaction.summary_model || state.model)
        )

      _missing ->
        account_missing_usage(state)
    end
  end

  def account_missing_usage(%{request_cost_pending?: true} = state),
    do: %{state | spent_usd: nil, request_cost_pending?: false}

  def account_missing_usage(state), do: state

  # Preparation can change the estimate after retry admission. If that makes
  # dispatch impossible, finish the failed attempt with its original typed
  # error; replacing it with a budget stop loses the host's retry-after signal.
  def budget_stop(%{retry_failure: {turn, reason}} = state, _payload) do
    Recovery.fold(%{state | turn: turn, retry_failure: nil, retry_note: nil}, {:error, reason})
  end

  def budget_stop(state, payload) do
    state
    |> Map.merge(%{turn: nil, turn_ref: nil, task: nil})
    |> ToolWave.stop(
      {:budget, payload},
      Messages.render(state.messages, :budget_stopped, [payload])
    )
  end
end
