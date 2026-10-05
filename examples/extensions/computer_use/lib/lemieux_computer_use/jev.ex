defmodule LemieuxComputerUse.Jev do
  @moduledoc """
  System One adapter for the experimental computer-use extension.

  SystemOneSDK owns the TypeSafe HTTP client and response decoding. The default
  client pins the hosted endpoint and Jev model; a host can supply an explicit
  SystemOneSDK client for a compatible endpoint or native provider. The raw
  System One call preserves single-option target questions, which the SDK's
  stricter semantic API rejects. Browser target validation stays in Decision.

  One request is allowed per browser step. Errors are reduced to fixed strings
  before entering evidence, because SDK errors may contain provider bodies.
  """

  alias LemieuxComputerUse.Jev.Transport
  alias SystemOneSDK.{Client, Error, SystemOneResponse}
  alias SystemOneSDK.Providers.TypeSafe

  @default_model "jev-1.13.0"
  @default_timeout_ms 15_000

  @spec evaluate(request :: map(), opts :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def evaluate(request, opts \\ [])

  def evaluate(%{"state" => state, "questions" => questions}, opts)
      when is_map(questions) and is_list(opts) do
    with {:ok, client} <- client(opts),
         {:ok, %SystemOneResponse{raw: raw}} <-
           SystemOneSDK.system_one(client, state, questions,
             model: Keyword.get(opts, :model) || client.default_model,
             retry: false,
             timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
           ),
         %{"answers" => answers, "model" => model} = raw
         when is_map(answers) and is_binary(model) <- raw do
      {:ok, Map.take(raw, ~w(answers model usage))}
    else
      {:error, :missing_key} -> {:error, "JEV_API_KEY is required"}
      {:error, :invalid_client} -> {:error, "Jev client is invalid"}
      {:error, %Error{} = error} -> diagnostic(error)
      {:error, _} -> {:error, "Jev transport failed"}
      _ -> {:error, "Jev returned an invalid response"}
    end
  rescue
    error in Error -> diagnostic(error)
  end

  def evaluate(_request, _opts), do: {:error, "Jev request is invalid"}

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, %Client{} = client} -> {:ok, client}
      {:ok, _} -> {:error, :invalid_client}
      :error -> hosted_client(opts)
    end
  end

  defp hosted_client(opts) do
    key = Keyword.get(opts, :api_key) || System.get_env("JEV_API_KEY")

    if is_binary(key) and String.trim(key) != "" do
      {:ok,
       SystemOneSDK.new_client(
         provider: TypeSafe,
         api_key: key,
         base_url: "https://api.typesafe.ai",
         model: @default_model,
         retry: false,
         timeout_ms: @default_timeout_ms,
         headers: %{},
         transport: Transport,
         transport_opts: []
       )}
    else
      {:error, :missing_key}
    end
  end

  defp diagnostic(%Error{type: :response_validation}),
    do: {:error, "Jev returned an invalid response"}

  defp diagnostic(%Error{type: :invalid_request}), do: {:error, "Jev request is invalid"}

  defp diagnostic(%Error{status: status}) when is_integer(status) and status in 100..599,
    do: {:error, "Jev returned HTTP #{status}"}

  defp diagnostic(%Error{}), do: {:error, "Jev transport failed"}
end
