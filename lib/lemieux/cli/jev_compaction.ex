defmodule Lemieux.CLI.JevCompaction do
  @moduledoc """
  Selects the optional Jev compaction step for the `lmx` host, and the System
  One provider its evaluations go to.

  The library has no SDK dependency. The extension lives in
  `dist/lmx/extensions/jev_compaction`; the installed `lmx` bundles it, and a
  source embedder may add it as a Mix dependency. Only a fixed module name is
  resolved here, never a module from JSON configuration.

  ## Providers are declared; one is selected

  `jev_compaction.provider` chooses where the evaluations go, the way
  `"web_search"` chooses a search backend, and `jev_compaction_providers`
  declares the ones that need declaring. Two are built in:

  - `typesafe`: TypeSafe's hosted service, with a key from `JEV_API_KEY` or
    `jev_compaction.api_key`. It alone has a default model and published
    rates; those live in the extension, next to the vendor.
  - `ixway`: an Ixway gateway implementing `POST /v1/systemone`, with
    `jev_compaction.endpoint` (or the Ixway route `lmx` is using), a pinned
    `jev_compaction.model` and the Ixway key (`IXWAY_API_KEY` or
    `ixway.api_key`).

  Any other name is an entry in `jev_compaction_providers`: a `base_url` that
  speaks `POST /v1/systemone` — a vendor's decision API, a scorer on a machine
  the person controls — with an optional `api_key` or `api_key_env`, extra
  `headers`, a default `model` and its tariff. `jev_compaction.model` and the
  section's rates override the entry's when both are set: the section is where
  a person overrides what a provider declares.

  With no `provider`, the choice is the one `lmx` has always made between the
  two built-in ones: Ixway when its endpoint and a pinned model are set,
  TypeSafe otherwise. A declared provider is never chosen by default. A
  credentials section that is not selected neither switches the step on nor
  sends anything, so a provider can sit in the file before it is wanted, and
  switching back to TypeSafe is one field.

  In `auto` mode the step is on only when the selected provider is complete;
  in `apply` and `shadow` an incomplete provider stops the start, naming the
  missing piece. There is no fallback from one provider to another: a person
  who pointed the step at their own machine chose where the conversation
  excerpts go, and a request to TypeSafe instead would be the failure the
  choice was made to prevent.

  The provider is chosen in the file alone: there is no flag and no `LMX_`
  variable for it, unlike `--web-search`. Where the excerpts go is a
  per-machine decision that belongs beside the credentials it needs, and a
  variable that redirects them is one more thing a launcher's or an agent's
  shell could set without the person noticing. The environment supplies
  credentials only (`JEV_API_KEY`, `IXWAY_API_KEY`, a provider's own
  `api_key_env`), with an empty value switching a saved key off, as
  `BRAVE_SEARCH_API_KEY=` does for search.

  ## Why this stays a bundled extension, under its old name

  Issue #6 asked whether the provider-neutral piece should move into the
  library the way `Lemieux.Tools.WebSearch` did, with vendors as backends. It
  does not: the scorer is reached through `system_one_sdk` and its transport
  stack, and the core takes no such dependency — `test/lemieux/boundary_test.exs`
  would fail the first module that did. What a library behaviour would offer
  already exists at the extension's edge: a host passes `provider:` (this
  module's output) or its own `client:`. Only the selection from a config
  file lives here, and it is JSON data with a fixed module name, never a
  module from the file.

  The issue also asked whether `jev_compaction` should get a vendor-neutral
  name with the old key as an alias. It keeps its name. "Jev compaction" is
  the technique's name in this project, after the fast-jev-compaction work it
  adapts, and the key is also the transcript namespace every recorded
  evaluation carries and the `disabled_extensions` name; a second spelling
  would be two names for one thing in every document and config file, for no
  behaviour. The vendor-neutral part is the provider list, which is where the
  vendors are.
  """

  alias Lemieux.CLI.Config

  @module Module.concat(["LemieuxJevCompaction"])
  @typesafe_base_url "https://api.typesafe.ai"
  @bounds %{
    "max_evaluations" => :max_evaluations,
    "max_cost_usd" => :max_cost_usd,
    "reservation_per_call_usd" => :reservation_per_call_usd
  }
  @rates %{
    "input_per_million" => :input_per_million,
    "output_per_million" => :output_per_million
  }
  @nothing_complete "no provider is complete: the TypeSafe provider needs a Jev key " <>
                      "(JEV_API_KEY, or jev_compaction.api_key in the config file), the Ixway " <>
                      "provider needs an endpoint (jev_compaction.endpoint, or the Ixway route lmx " <>
                      "uses) and a pinned jev_compaction.model beside the Ixway key, and a provider " <>
                      "declared in jev_compaction_providers needs jev_compaction.provider to select it"

  @typedoc """
  The selected provider, as the extension takes it: `type: :typesafe` is
  TypeSafe's hosted service, `type: :endpoint` any other `POST /v1/systemone`
  service. `model` is `nil` only for TypeSafe, whose default the extension
  owns. `api_key_header` names the header the key travels in when the
  service does not take a bearer token; `nil` means `Authorization: Bearer`.
  """
  @type provider :: %{
          name: String.t(),
          type: :typesafe | :endpoint,
          base_url: String.t(),
          api_key: String.t() | nil,
          api_key_header: String.t() | nil,
          headers: %{optional(String.t()) => String.t()},
          model: String.t() | nil
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
    case provider(config, ixway_endpoint) do
      {:ok, provider} ->
        {:ok, {@module, options(settings, mode, provider, config)}}

      {:unavailable, _reason} when mode == "auto" ->
        {:ok, nil}

      {:unavailable, reason} ->
        {:error, "Jev compaction is set to #{mode}, but #{reason}."}
    end
  end

  @doc """
  Resolves the provider the configuration selects, without contacting it.

  `{:unavailable, reason}` says, in a clause that fits after "but", what the
  selected provider is missing; in `auto` mode that means the step stays off.
  """
  @spec provider(config :: Config.t() | nil, ixway_endpoint :: String.t() | nil) ::
          {:ok, provider()} | {:unavailable, String.t()}
  def provider(config, ixway_endpoint) do
    settings = Config.get(config, "jev_compaction", %{})
    declared = Config.get(config, "jev_compaction_providers", %{})

    case Map.get(settings, "provider") || Map.get(settings, "route") || "auto" do
      "auto" -> auto(settings, config, ixway_endpoint)
      "typesafe" -> typesafe(settings)
      "ixway" -> ixway(settings, config, ixway_endpoint)
      name -> declared(name, Map.get(declared, name), settings)
    end
  end

  # The choice `lmx` made before providers could be declared, kept so a file
  # written then selects what it selected: a pinned Ixway route first, the
  # hosted key otherwise. A declared provider takes an explicit `provider`.
  defp auto(settings, config, ixway_endpoint) do
    if present?(ixway_endpoint(settings, config, ixway_endpoint)) and present?(settings["model"]) do
      ixway(settings, config, ixway_endpoint)
    else
      case typesafe(settings) do
        {:ok, provider} -> {:ok, provider}
        {:unavailable, _reason} -> {:unavailable, @nothing_complete}
      end
    end
  end

  defp typesafe(settings) do
    key = System.get_env("JEV_API_KEY") || settings["api_key"]

    if present?(key),
      do:
        {:ok,
         %{
           name: "typesafe",
           type: :typesafe,
           base_url: @typesafe_base_url,
           api_key: key,
           api_key_header: nil,
           headers: %{},
           model: settings["model"]
         }},
      else:
        {:unavailable,
         "the TypeSafe provider has no key: set JEV_API_KEY, or save jev_compaction.api_key in the config file"}
  end

  defp ixway(settings, config, ixway_endpoint) do
    endpoint = ixway_endpoint(settings, config, ixway_endpoint)
    key = System.get_env("IXWAY_API_KEY") || Config.get(config, "ixway", %{})["api_key"]
    model = settings["model"]

    missing =
      for {false, what} <- [
            {present?(endpoint),
             "an endpoint (jev_compaction.endpoint, or the Ixway route lmx uses: --ixway, LMX_IXWAY_URL or ixway.endpoint)"},
            {present?(model), "a pinned jev_compaction.model"},
            {present?(key), "the Ixway key (IXWAY_API_KEY, or ixway.api_key in the config file)"}
          ],
          do: what

    case missing do
      [] ->
        {:ok,
         %{
           name: "ixway",
           type: :endpoint,
           base_url: endpoint,
           api_key: key,
           api_key_header: nil,
           headers: %{},
           model: model
         }}

      what ->
        {:unavailable, "the Ixway provider is missing " <> sentence(what)}
    end
  end

  defp ixway_endpoint(settings, config, ixway_endpoint),
    do: settings["endpoint"] || ixway_endpoint || Config.get(config, "ixway", %{})["endpoint"]

  defp declared(_name, nil, _settings),
    do:
      {:unavailable,
       "jev_compaction.provider names a provider jev_compaction_providers does not declare"}

  defp declared(name, entry, settings) do
    model = settings["model"] || entry["model"]

    with {:ok, key} <- key(name, entry),
         :ok <- modelled(name, model) do
      {:ok,
       %{
         name: name,
         type: :endpoint,
         base_url: entry["base_url"],
         api_key: key,
         api_key_header: entry["api_key_header"],
         headers: Map.get(entry, "headers", %{}),
         model: model
       }}
    end
  end

  # The variable wins when it is set, as JEV_API_KEY wins over the saved key,
  # and an empty one switches the saved key off, as an empty JEV_API_KEY or
  # BRAVE_SEARCH_API_KEY does. A variable named but unset, with no saved key
  # beside it, is a provider the person meant to authenticate to: refused,
  # not sent to unauthenticated.
  defp key(name, %{"api_key_env" => variable} = entry) do
    case System.get_env(variable) do
      nil ->
        if present?(entry["api_key"]),
          do: {:ok, entry["api_key"]},
          else:
            {:unavailable,
             "the #{name} provider reads its key from #{variable}, which is not set"}

      value ->
        if present?(value),
          do: {:ok, value},
          else:
            {:unavailable,
             "the #{name} provider reads its key from #{variable}, which is set but empty"}
    end
  end

  defp key(_name, entry), do: {:ok, if(present?(entry["api_key"]), do: entry["api_key"])}

  defp modelled(name, model) do
    if present?(model),
      do: :ok,
      else:
        {:unavailable,
         "the #{name} provider has no model: set jev_compaction.model, or model in its jev_compaction_providers entry"}
  end

  defp options(settings, mode, provider, config) do
    entry = config |> Config.get("jev_compaction_providers", %{}) |> Map.get(provider.name, %{})

    [
      enabled: if(mode == "auto", do: :auto, else: true),
      mode: if(mode == "shadow", do: :shadow, else: :apply),
      provider: provider
    ]
    |> put_settings(@bounds, settings)
    |> put_settings(@rates, Map.merge(entry, settings))
  end

  defp put_settings(opts, fields, source) do
    Enum.reduce(fields, opts, fn {key, option}, acc ->
      case Map.fetch(source, key) do
        {:ok, value} -> Keyword.put(acc, option, value)
        :error -> acc
      end
    end)
  end

  defp sentence([one]), do: one
  defp sentence([first, second]), do: first <> " and " <> second
  defp sentence([first | rest]), do: first <> ", " <> sentence(rest)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
