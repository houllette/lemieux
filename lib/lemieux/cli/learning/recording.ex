defmodule Lemieux.CLI.Learning.Recording do
  @moduledoc false
  @behaviour Lemieux.Provider
  alias Lemieux.Contract
  alias Lemieux.Provider
  alias Lemieux.Usage

  @spec new(meter :: pid(), provider :: Provider.t()) :: Provider.t()
  def new(meter, provider), do: {__MODULE__, %{meter: meter, provider: provider}}

  @impl true
  def run(state, request, emit) do
    id = Lemieux.ID.generate()
    :ok = Agent.update(state.meter, &Map.put(&1, id, %{"status" => "in_flight", "tokens" => nil}))

    result =
      Provider.run(state.provider, request, fn event ->
        record(state.meter, id, event)

        emit.(event)
      end)

    :ok =
      Agent.update(
        state.meter,
        &Map.update!(&1, id, fn record -> Map.put(record, "terminal", true) end)
      )

    result
  end

  defp record(meter, id, {:usage, usage}) do
    raw = Contract.json(usage)
    facts = Usage.sum([usage])

    tokens =
      if is_integer(raw["input_tokens"]) and is_integer(raw["output_tokens"]),
        do:
          Enum.sum(
            Enum.map(
              ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens),
              &(facts[&1] || 0)
            )
          )

    Agent.update(
      meter,
      &Map.put(&1, id, %{"status" => "reported", "tokens" => tokens, "usage" => facts})
    )
  end

  defp record(_meter, _id, _event), do: :ok

  @impl true
  def model_metadata(state), do: Provider.model_metadata(state.provider)
  @impl true
  def context_window(state, model), do: Provider.context_window(state.provider, model)
  @impl true
  def available_models(state, opts), do: Provider.available_models(state.provider, opts)
  @impl true
  def validate_model(state, model, tools),
    do: Provider.validate_model(state.provider, model, tools)

  @impl true
  def input_modalities(state, model), do: Provider.input_modalities(state.provider, model)

  @impl true
  def estimate_cost(state, request), do: Provider.estimate_cost(state.provider, request)
  @impl true
  def reasoning_efforts(state, model), do: Provider.reasoning_efforts(state.provider, model)
end
