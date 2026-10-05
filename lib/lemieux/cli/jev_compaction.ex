defmodule Lemieux.CLI.JevCompaction do
  @moduledoc """
  Selects the optional Jev compaction route for the `lmx` host: TypeSafe's Jev
  model scores old tool results so they can be shortened before a request.

  The library has no SDK dependency. The extension lives in
  `dist/lmx/extensions/jev_compaction`; the installed `lmx` bundles it, and a
  source embedder may add it as a Mix dependency. Only a fixed
  module name is resolved here, never a module from JSON configuration. An
  explicitly selected Ixway route has no hosted fallback if its credential or
  endpoint is unavailable. `auto` chooses Ixway only with a pinned Jev model;
  otherwise it can use a hosted Jev key.
  """

  alias Lemieux.CLI.Config

  @module Module.concat(["LemieuxJevCompaction"])
  @options %{
    "max_evaluations" => :max_evaluations,
    "max_cost_usd" => :max_cost_usd,
    "reservation_per_call_usd" => :reservation_per_call_usd,
    "input_per_million" => :input_per_million,
    "output_per_million" => :output_per_million
  }

  @doc "Returns the optional extension specification for the current host."
  @spec spec(config :: Config.t() | nil, ixway_endpoint :: String.t() | nil) ::
          {:ok, {module(), keyword()} | nil} | {:error, String.t()}
  def spec(config, ixway_endpoint) do
    settings = Config.get(config, "jev_compaction", %{})
    mode = Map.get(settings, "mode", "auto")

    cond do
      mode == "off" ->
        {:ok, nil}

      not Code.ensure_loaded?(@module) and mode == "auto" and map_size(settings) == 0 ->
        {:ok, nil}

      # The release host in dist/lmx has its own deps directory, which a fresh
      # clone has not fetched: the hint used to say only `cd dist/lmx && mix
      # lmx.tui`, and that stopped on the missing dependencies. `-C ../..` is the
      # checkout the source run opens anyway, spelled out so a copied line says
      # where it works.
      not Code.ensure_loaded?(@module) ->
        {:error,
         "Jev compaction requires the lemieux_jev_compaction extension, which the installed lmx bundles. " <>
           "In a source checkout it lives in dist/lmx/extensions/jev_compaction, and the release host in dist/lmx includes it: " <>
           "run `cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`."}

      true ->
        build_spec(settings, mode, config, ixway_endpoint)
    end
  end

  defp build_spec(settings, mode, config, ixway_endpoint) do
    opts = base_opts(settings, mode, config, ixway_endpoint)

    opts =
      Enum.reduce(@options, opts, fn {key, option}, acc ->
        case Map.fetch(settings, key) do
          {:ok, value} -> Keyword.put(acc, option, value)
          :error -> acc
        end
      end)

    if mode == "auto" and not configured?(opts),
      do: {:ok, nil},
      else: {:ok, {@module, opts}}
  end

  defp base_opts(settings, mode, config, ixway_endpoint) do
    ixway = Config.get(config, "ixway", %{})
    endpoint = settings["endpoint"] || ixway_endpoint || ixway["endpoint"]
    ixway_key = System.get_env("IXWAY_API_KEY") || ixway["api_key"]
    route = route(Map.get(settings, "route", "auto"))

    [
      enabled: if(mode == "auto", do: :auto, else: true),
      mode: if(mode == "shadow", do: :shadow, else: :apply),
      route: route,
      ixway_endpoint: endpoint,
      ixway_api_key: ixway_key,
      api_key: System.get_env("JEV_API_KEY") || settings["api_key"],
      model: settings["model"]
    ]
  end

  defp route("auto"), do: :auto
  defp route("typesafe"), do: :typesafe
  defp route("ixway"), do: :ixway

  defp configured?(opts) do
    case opts[:route] do
      :ixway -> ixway_configured?(opts)
      :typesafe -> present?(opts[:api_key])
      :auto -> auto_configured?(opts)
    end
  end

  defp auto_configured?(opts) do
    if present?(opts[:ixway_endpoint]) and present?(opts[:model]),
      do: ixway_configured?(opts),
      else: present?(opts[:api_key])
  end

  defp ixway_configured?(opts),
    do:
      present?(opts[:ixway_endpoint]) and present?(opts[:ixway_api_key]) and
        present?(opts[:model])

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
