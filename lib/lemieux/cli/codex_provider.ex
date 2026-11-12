defmodule Lemieux.CLI.CodexProvider do
  @moduledoc """
  Host credential decorator for ReqLLM's Codex subscription transport.

  Only access tokens are read, immediately before a Codex request; Codex
  keeps refresh ownership. Injection happens below session request auditing,
  so credentials never become config, transcript or harness parameters.
  Switching to another provider forwards the original request unchanged.
  """
  @behaviour Lemieux.Provider
  alias Lemieux.CLI.Learning.CodexAuth
  alias Lemieux.Provider

  @doc "Wraps a provider with read-only local Codex credential lookup."
  @spec wrap(provider :: Provider.t(), opts :: keyword()) :: Provider.t()
  def wrap(provider, opts \\ []), do: {__MODULE__, {provider, opts}}

  @impl true
  def run({provider, opts}, %{model: "openai_codex:" <> _} = request, emit) do
    if explicit_auth?(request.params) do
      Provider.run(provider, request, emit)
    else
      run_local(provider, opts, request, emit)
    end
  end

  def run({provider, _opts}, request, emit), do: Provider.run(provider, request, emit)

  defp run_local(provider, opts, request, emit) do
    case CodexAuth.credential(opts) do
      {:ok, credential} ->
        options = credential_options(request.params, credential)

        Provider.run(
          provider,
          %{request | params: Keyword.put(request.params, :provider_options, options)},
          emit
        )

      {:error, _reason} ->
        {:error,
         "Local Codex sign-in is missing, unreadable or expired. Run codex login in your own terminal, then retry; Lemieux never refreshes Codex credentials."}
    end
  end

  defp explicit_auth?(params) do
    all = Keyword.get(params, :provider_options, [])

    nested =
      Keyword.merge(Keyword.delete(all, :openai_codex), Keyword.get(all, :openai_codex, []))

    Enum.any?(
      [:access_token, :oauth_file, :auth_file],
      &(Keyword.has_key?(params, &1) or Keyword.has_key?(nested, &1))
    ) or
      Application.get_env(:req_llm, :oauth_file) != nil or
      Application.get_env(:req_llm, :auth_file) != nil or
      System.get_env("REQ_LLM_OAUTH_FILE") != nil or
      System.get_env("REQ_LLM_AUTH_FILE") != nil
  end

  @doc false
  @spec local_auth?(params :: keyword()) :: boolean()
  def local_auth?(params), do: not explicit_auth?(params)

  defp credential_options(params, credential) do
    params
    |> Keyword.get(:provider_options, [])
    |> Keyword.put(:access_token, credential.access)
    |> put_account(credential.account_id)
  end

  defp put_account(options, nil), do: options
  defp put_account(options, account), do: Keyword.put(options, :chatgpt_account_id, account)

  @impl true
  def available_models({provider, _opts}, query),
    do: Provider.available_models(provider, query)

  @impl true
  def model_metadata({provider, _opts}), do: Provider.model_metadata(provider)
  @impl true
  def context_window({provider, _opts}, model), do: Provider.context_window(provider, model)
  @impl true
  def validate_model({provider, _opts}, model, tools),
    do: Provider.validate_model(provider, model, tools)

  @impl true
  def reasoning_efforts({provider, _opts}, model), do: Provider.reasoning_efforts(provider, model)
  @impl true
  def fast_modes({provider, _opts}, model), do: Provider.fast_modes(provider, model)
  @impl true
  def estimate_cost({provider, _opts}, request), do: Provider.estimate_cost(provider, request)
  @impl true
  def input_modalities({provider, _opts}, model), do: Provider.input_modalities(provider, model)
end
