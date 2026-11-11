defmodule Lemieux.CLI.Mtplx do
  @moduledoc "Discovers the chat models served by a local MTPLX daemon."

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.ModelCatalog
  alias Lemieux.ModelSpec

  @doc "Lists MTPLX models on its default loopback endpoint."
  @spec models(options :: Options.t(), opts :: keyword()) :: [String.t()]
  def models(%Options{base_url: nil, ixway: nil, host: %{route: nil}} = options, opts) do
    get = Keyword.get(opts, :get, &Req.get/2)
    key = System.get_env("MTPLX_API_KEY") || Config.api_keys(options.config)["mtplx"]
    headers = if key, do: [{"authorization", "Bearer " <> key}], else: []

    case get.(ModelCatalog.mtplx_url() <> "/models",
           headers: headers,
           retry: false,
           redirect: false,
           connect_options: [timeout: 350],
           receive_timeout: 350
         ) do
      {:ok, %{status: 200, body: %{"data" => entries}}} when is_list(entries) ->
        entries
        |> Enum.flat_map(&model/1)
        |> Enum.uniq()

      _unavailable ->
        []
    end
  end

  def models(%Options{}, _opts), do: []

  defp model(%{"owned_by" => "mtplx", "id" => id}) when is_binary(id) and id != "",
    do: [ModelSpec.join("mtplx", id)]

  defp model(_entry), do: []
end
