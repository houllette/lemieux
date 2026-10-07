defmodule ResearchExtension.Jev do
  @moduledoc """
  Default hosted source classifier for the research host.

  This small native typed-question request uses the existing Req dependency;
  ordinary synthesis providers still go through ReqLLM. Requiring the browser
  example's SDK would make a configured key insufficient for standalone research.
  The wire contract is documented at https://docs.typesafe.ai/api. Model and
  endpoint are pinned to the live-qualified route. Redirects and retries are
  disabled so one choice cannot forward a credential or spend multiple requests.

  An explicit `:api_key` wins, then nonempty `JEV_API_KEY`, then the validated
  personal configuration's `systemone_compaction_providers.typesafe.api_key`,
  the TypeSafe key `lmx` itself uses. `LMX_CONFIG=none` disables
  personal lookup; other values select that config path. No file is created or
  modified. Callers can bypass this host default with their own classifier.
  Credentials live only in the returned function's private runtime state.
  """

  alias Lemieux.CLI.Config

  @spec classifier(opts :: keyword()) ::
          {:ok, (map() -> {:ok, map()} | {:error, String.t()})}
          | :unavailable
          | {:error, String.t()}
  def classifier(opts) when is_list(opts) do
    with {:ok, key} <- key(opts) do
      if present?(key) do
        request = Keyword.get(opts, :request, &Req.post/1)
        {:ok, fn question -> evaluate(question, key, request) end}
      else
        :unavailable
      end
    end
  end

  defp key(opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, key} -> {:ok, key}
      :error -> environment_key()
    end
  end

  defp environment_key do
    key = System.get_env("JEV_API_KEY")
    if present?(key), do: {:ok, key}, else: saved_key()
  end

  defp saved_key do
    case System.get_env("LMX_CONFIG") do
      "none" -> {:ok, nil}
      nil -> saved_key(Config.default_path(), optional: true)
      path -> saved_key(Path.expand(path), [])
    end
  end

  defp saved_key(path, options) do
    with {:ok, config} <- Config.load(path, options) do
      {:ok,
       get_in(Config.get(config, "systemone_compaction_providers", %{}), ["typesafe", "api_key"])}
    end
  end

  defp present?(key) when is_binary(key), do: String.trim(key) != ""
  defp present?(_), do: false

  defp evaluate(%{"state" => state, "questions" => questions}, key, request)
       when is_map(questions) do
    request.(
      url: "https://api.typesafe.ai/v1/systemone",
      auth: {:bearer, key},
      json: %{"state" => state, "questions" => questions, "model" => "jev-1.13.0"},
      redirect: false,
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 5_000]
    )
    |> response()
  end

  defp evaluate(_, _, _), do: {:error, "Jev request is invalid"}

  defp response({:ok, %Req.Response{status: 200, body: body}}) do
    case body do
      %{"answers" => answers, "model" => model} when is_map(answers) and is_binary(model) ->
        {:ok, Map.take(body, ~w(answers model usage))}

      _ ->
        {:error, "Jev returned an invalid response"}
    end
  end

  defp response({:ok, %Req.Response{status: status}}) when status in 100..599,
    do: {:error, "Jev returned HTTP #{status}"}

  defp response(_), do: {:error, "Jev transport failed"}
end
