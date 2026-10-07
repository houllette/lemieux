defmodule ResearchBench.LiveSetup do
  @moduledoc """
  What every live research bench runs on: the personal settings its keys may
  come from, one model, effort and provider for all of its arms, and the
  System One provider of a guided-discovery arm, chosen here so that a
  comparison changes model in one place and its arms always match. A bench
  loads it with `Code.require_file("live_setup.exs", __DIR__)`.

    * `RESEARCH_MODEL` — `provider:model`; default `ixway:gpt-6-luna`, the
      model the recorded campaigns used. An `ixway:` model goes through Ixway,
      configured by the `"ixway"` object in `~/.lmx/config.json` or by
      `IXWAY_API_KEY` and `LMX_IXWAY_URL`. Any other model goes straight to
      its provider through ReqLLM, with that provider's key in the
      environment, for example `RESEARCH_MODEL=openai:gpt-5-mini` with
      `OPENAI_API_KEY`.
    * `RESEARCH_EFFORT` — the reasoning effort for every arm; default `max`
      on Ixway, otherwise `default` (the provider's own). Anything else must
      be an effort the model offers.
    * `RESEARCH_SYSTEMONE_PROVIDER` — the System One provider a guided arm
      asks which source to open: a name from `"systemone_providers"` in
      `~/.lmx/config.json`, or unset for the automatic choice (TypeSafe with
      `JEV_API_KEY` or a saved key, which the recorded campaigns used).

  The benches bound their spend in requests, not dollars: an Ixway route
  cannot price a request before it is routed.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.SystemOne
  alias Lemieux.Ixway

  @default_model "ixway:gpt-6-luna"

  @doc """
  The personal settings in `path` (`~/.lmx/config.json` by default), or
  empty settings when the file does not exist, so that keys in the
  environment are enough. A file that exists but cannot be used stops the
  bench with the reason.

  `LMX_CONFIG` does not change which file this reads. The documented v5
  command sets `LMX_CONFIG=none`, which turns off the pipeline's own lookup
  of a System One provider (`ResearchExtension.SystemOne`), and still
  expects the bench's keys and provider to come from this file; honouring
  `LMX_CONFIG=none` here would leave that run without them.
  """
  @spec config(path :: Path.t()) :: Config.t()
  def config(path \\ Config.default_path()) do
    case Config.load(path, optional: true) do
      {:ok, config} -> config
      {:error, message} -> raise "#{path}: #{message}"
    end
  end

  @doc """
  The model, effort and provider for a live bench, as
  `%{model: model, effort: effort, provider: provider, secrets: secrets}`.

  `provider_options` are the provider's own, such as `:receive_timeout`; each
  bench passes the ones it was recorded with. `secrets` lists the model
  credential in play, which a bench checks never reaches a written report.
  """
  @spec model(config :: Config.t() | nil, provider_options :: keyword()) :: map()
  def model(config, provider_options) when is_list(provider_options) do
    case System.get_env("RESEARCH_MODEL", @default_model) do
      "ixway:" <> _ = model -> ixway(model, config, provider_options)
      model -> direct(model, provider_options)
    end
  end

  @doc """
  The System One provider `RESEARCH_SYSTEMONE_PROVIDER` selects from
  `config` (`Lemieux.CLI.SystemOne.provider/3`), for a bench to pass as
  `discovery: [provider: provider]`. Handing the pipeline the resolved
  provider keeps its own lookup, which `LMX_CONFIG=none` switches off, out of
  the run. A provider that cannot be used stops the bench with the reason
  rather than running the arm without guidance.
  """
  @spec system_one(config :: Config.t() | nil) :: SystemOne.provider()
  def system_one(config) do
    selection = System.get_env("RESEARCH_SYSTEMONE_PROVIDER")

    case SystemOne.provider(config, selection,
           selected_by: "RESEARCH_SYSTEMONE_PROVIDER",
           ixway_endpoint: System.get_env("LMX_IXWAY_URL")
         ) do
      {:ok, provider} -> provider
      {:unavailable, reason} -> raise "the guided arm needs a System One provider, but #{reason}"
    end
  end

  defp ixway(model, config, provider_options) do
    ixway = Config.get(config, "ixway", %{})
    key = System.get_env("IXWAY_API_KEY") || ixway["api_key"]
    endpoint = System.get_env("LMX_IXWAY_URL") || ixway["endpoint"]

    unless is_binary(key) and key != "" do
      raise "#{model} needs an Ixway key (IXWAY_API_KEY or ~/.lmx/config.json); " <>
              "set RESEARCH_MODEL to use another provider"
    end

    effort = System.get_env("RESEARCH_EFFORT", "max")
    {:ok, connection} = [endpoint: endpoint, api_key: key] |> Ixway.new() |> Ixway.discover()
    {:ok, ^model} = Ixway.select_model(connection, model)

    unless effort in Ixway.reasoning_efforts(connection, model),
      do: raise("#{model} does not offer reasoning effort #{inspect(effort)}")

    %{
      model: model,
      effort: effort,
      provider: Ixway.provider(connection, provider_options),
      secrets: [key]
    }
  end

  defp direct(model, provider_options) do
    effort = System.get_env("RESEARCH_EFFORT", "default")
    provider = Lemieux.Providers.ReqLLM.new(provider_options)

    case Lemieux.Provider.validate_model(provider, model, []) do
      :ok -> :ok
      {:error, reason} -> raise "cannot use RESEARCH_MODEL=#{model}: #{inspect(reason)}"
    end

    # "default" leaves the effort to the provider, which every model accepts.
    unless effort == "default" or effort in Lemieux.Provider.reasoning_efforts(provider, model),
      do: raise("#{model} does not offer reasoning effort #{inspect(effort)}")

    %{model: model, effort: effort, provider: provider, secrets: provider_key(model)}
  end

  # The key ReqLLM sends for this model, from the environment or the
  # application configuration, where `validate_model/3` found it.
  defp provider_key(model) do
    with {:ok, spec} <- ReqLLM.model(model),
         {:ok, key, _source} <- ReqLLM.Keys.get(spec, []) do
      [key]
    else
      _missing -> []
    end
  end
end
