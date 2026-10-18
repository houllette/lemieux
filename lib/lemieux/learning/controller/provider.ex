defmodule Lemieux.Learning.Controller.Provider do
  @moduledoc false
  @behaviour Lemieux.Provider
  alias Lemieux.Learning.Controller
  alias Lemieux.Provider
  alias Lemieux.Request
  alias Lemieux.Usage

  @spec new(
          controller :: GenServer.server(),
          role :: atom(),
          provider :: Provider.t() | nil,
          opts :: keyword()
        ) :: Provider.t()
  def new(controller, role, provider, opts),
    do:
      {__MODULE__,
       %{
         controller: controller,
         role: role,
         provider: provider,
         token_bound: opts[:token_bound],
         timeout_ms: Keyword.get(opts, :timeout_ms, 5000)
       }}

  @impl true
  def run(%{provider: nil} = state, _request, _emit), do: skipped(state, "provider_unavailable")

  def run(state, request, emit) do
    tokens = if is_function(state.token_bound, 1), do: state.token_bound.(request)

    if is_integer(tokens) and tokens > 0 do
      estimate = %{
        tokens: tokens,
        time_ms: state.timeout_ms,
        cost_usd: Provider.estimate_cost(state.provider, request)
      }

      execute_request(state, request, emit, estimate)
    else
      skipped(state, "token_bound_unavailable")
    end
  end

  defp execute_request(state, request, emit, estimate) do
    case Controller.run(state.controller, Lemieux.ID.generate(), state.role, estimate, fn ->
           stream(state.provider, request, emit)
         end) do
      {:ok, {:error, :controller_work_incomplete}, _receipt} ->
        denied("host_work_interrupted", "controller_work_incomplete")

      {:ok, result, _receipt} ->
        result

      {:skip, receipt} ->
        denied("host_admission_denied", receipt["reason"])
    end
  end

  defp skipped(state, reason) do
    _receipt = Controller.skip(state.controller, state.role, reason)
    denied("host_admission_denied", reason)
  end

  defp denied(code, reason),
    do: {:error, %{provider_code: code, message: "controller: " <> reason}}

  defp stream(provider, request, emit) do
    owner = self()
    ref = make_ref()

    result =
      Provider.run(provider, request, fn event ->
        if match?({:usage, _}, event), do: send(owner, {ref, event})
        emit.(event)
      end)

    {result, reported(ref, nil)}
  end

  defp reported(ref, previous) do
    receive do
      {^ref, {:usage, usage}} -> reported(ref, usage)
    after
      0 -> facts(previous)
    end
  end

  defp facts(nil), do: nil

  defp facts(usage) do
    input = usage["input_tokens"] || usage[:input_tokens]
    output = usage["output_tokens"] || usage[:output_tokens]

    tokens =
      if is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
        do:
          Enum.sum(
            Enum.map(
              ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens),
              &Usage.sum([usage])[&1]
            )
          )

    %{tokens: tokens, cost_usd: Usage.cost_usd(usage)}
  end

  @impl true
  def estimate_cost(%{provider: nil}, _arg0), do: nil

  def estimate_cost(state, %Request{} = request),
    do: Provider.estimate_cost(state.provider, request)

  @impl true
  def context_window(%{provider: nil}, _arg0), do: nil
  def context_window(state, model), do: Provider.context_window(state.provider, model)
  @impl true
  def available_models(%{provider: nil}, _arg0), do: []
  def available_models(state, opts), do: Provider.available_models(state.provider, opts)
  @impl true
  def model_metadata(%{provider: nil}), do: %{}
  def model_metadata(state), do: Provider.model_metadata(state.provider)
  @impl true
  def validate_model(%{provider: nil}, _arg0, _arg1), do: {:error, :provider_unavailable}

  def validate_model(state, model, tools),
    do: Provider.validate_model(state.provider, model, tools)

  @impl true
  def reasoning_efforts(%{provider: nil}, _arg0), do: []
  def reasoning_efforts(state, model), do: Provider.reasoning_efforts(state.provider, model)
  @impl true
  def input_modalities(%{provider: nil}, _arg0), do: :unknown
  def input_modalities(state, model), do: Provider.input_modalities(state.provider, model)
end
