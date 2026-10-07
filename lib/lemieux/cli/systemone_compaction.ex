defmodule Lemieux.CLI.SystemOneCompaction do
  @moduledoc """
  Selects the optional System One compaction step for the `lmx` host, and the
  System One provider its evaluations go to.

  The library has no SDK dependency. The extension lives in
  `dist/lmx/extensions/systemone_compaction`; the installed `lmx` bundles it,
  and a source embedder may add it as a Mix dependency. Only a fixed module
  name is resolved here, never a module from JSON configuration.

  ## Choosing a provider is separate from configuring one

  `"systemone_compaction"` holds the choice and the budget: `mode`,
  `provider`, `max_evaluations`, `max_cost_usd` and
  `reservation_per_call_usd`. `"systemone_compaction_providers"` holds what
  each provider needs, the way `"web_search"` and `"web_search_providers"`
  divide search. Two providers are built in, and each may have an entry:

  - `typesafe`: TypeSafe's hosted service. Its key is `JEV_API_KEY` (the name
    TypeSafe gives its Jev key) or the entry's `api_key`; it alone has a
    default model and published rates, which live in the extension, next to
    the vendor.
  - `ixway`: an Ixway gateway implementing `POST /v1/systemone`, at the
    entry's `base_url` or the Ixway route `lmx` is using, with the entry's
    `model` and the Ixway key (`IXWAY_API_KEY` or `ixway.api_key`) — the one
    place a gateway key lives.

  Any other name is a provider the person declares: a `base_url` that speaks
  `POST /v1/systemone` — a vendor's decision API, an open model on their own
  machine — with an optional `api_key` or `api_key_env`, `api_key_header`,
  extra `headers`, a `model` and its tariff.

  With no `provider`, the choice is between the two built-in ones: Ixway when
  its endpoint and a model are set, TypeSafe when its key is. A declared
  provider is never chosen that way. An entry that is not selected neither
  switches the step on nor sends anything, so a provider can sit in the file
  before it is wanted, and switching is one field.

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

  ## Why a bundled extension, and why this name

  Issue #6 asked whether the provider-neutral piece should move into the
  library the way `Lemieux.Tools.WebSearch` did, with vendors as backends. It
  does not: the scorer is reached through `system_one_sdk` and its transport
  stack, and the core takes no such dependency — `test/lemieux/boundary_test.exs`
  would fail the first module that did. What a library behaviour would offer
  already exists at the extension's edge: a host passes `provider:` (this
  module's output) or its own `client:`. Only the selection from a config
  file lives here, and it is JSON data with a fixed module name, never a
  module from the file.

  The step was called Jev compaction, after TypeSafe's model. Once any System
  One provider could score, the vendor's model name described one provider
  rather than the step, so the extension, its config keys, its transcript
  namespace and its `disabled_extensions` name became `systemone_compaction`
  together, with no alias: two spellings would be two names for one thing in
  every file and transcript. A file that still says `jev_compaction` is
  refused with a sentence naming the new keys, rather than ignored, because
  ignoring it would silently switch the step off or change where it sends.
  """

  alias Lemieux.CLI.Config

  @module Module.concat(["LemieuxSystemOneCompaction"])
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
  @nothing_complete "no provider is complete: the typesafe provider needs a key " <>
                      "(JEV_API_KEY, or systemone_compaction_providers.typesafe.api_key), the ixway " <>
                      "provider needs an endpoint (systemone_compaction_providers.ixway.base_url, or " <>
                      "the Ixway route lmx uses) and a model beside the Ixway key, and any other " <>
                      "provider needs systemone_compaction.provider to select it"

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
    settings = Config.get(config, "systemone_compaction", %{})
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
         "System One compaction requires the lemieux_systemone_compaction extension, which the installed lmx bundles. " <>
           "In a source checkout it lives in dist/lmx/extensions/systemone_compaction, and the release host in dist/lmx includes it: " <>
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
        {:error, "System One compaction is set to #{mode}, but #{reason}."}
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
    settings = Config.get(config, "systemone_compaction", %{})
    entries = Config.get(config, "systemone_compaction_providers", %{})

    case Map.get(settings, "provider", "auto") do
      "auto" -> auto(entries, config, ixway_endpoint)
      "typesafe" -> typesafe(Map.get(entries, "typesafe", %{}))
      "ixway" -> ixway(Map.get(entries, "ixway", %{}), config, ixway_endpoint)
      name -> declared(name, Map.get(entries, name))
    end
  end

  # Ixway when its endpoint and a model are both set, TypeSafe when its key
  # is: a gateway someone pinned a scorer on is the more deliberate choice. A
  # declared provider takes an explicit `provider`.
  defp auto(entries, config, ixway_endpoint) do
    entry = Map.get(entries, "ixway", %{})

    if present?(ixway_endpoint(entry, config, ixway_endpoint)) and present?(entry["model"]) do
      ixway(entry, config, ixway_endpoint)
    else
      case typesafe(Map.get(entries, "typesafe", %{})) do
        {:ok, provider} -> {:ok, provider}
        {:unavailable, _reason} -> {:unavailable, @nothing_complete}
      end
    end
  end

  # An empty JEV_API_KEY is a choice, as an empty BRAVE_SEARCH_API_KEY is:
  # it switches the saved key off rather than falling through to it.
  defp typesafe(entry) do
    key = System.get_env("JEV_API_KEY") || entry["api_key"]

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
           model: entry["model"]
         }},
      else:
        {:unavailable,
         "the typesafe provider has no key: set JEV_API_KEY, or save " <>
           "systemone_compaction_providers.typesafe.api_key in the config file"}
  end

  defp ixway(entry, config, ixway_endpoint) do
    endpoint = ixway_endpoint(entry, config, ixway_endpoint)
    key = System.get_env("IXWAY_API_KEY") || Config.get(config, "ixway", %{})["api_key"]
    model = entry["model"]

    missing =
      for {false, what} <- [
            {present?(endpoint),
             "an endpoint (systemone_compaction_providers.ixway.base_url, or the Ixway route lmx uses: " <>
               "--ixway, LMX_IXWAY_URL or ixway.endpoint)"},
            {present?(model), "a model (systemone_compaction_providers.ixway.model)"},
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
        {:unavailable, "the ixway provider is missing " <> sentence(what)}
    end
  end

  defp ixway_endpoint(entry, config, ixway_endpoint),
    do: entry["base_url"] || ixway_endpoint || Config.get(config, "ixway", %{})["endpoint"]

  defp declared(_name, nil),
    do:
      {:unavailable,
       "systemone_compaction.provider names a provider systemone_compaction_providers does not declare"}

  defp declared(name, entry) do
    with {:ok, key} <- key(name, entry),
         :ok <- modelled(name, entry["model"]) do
      {:ok,
       %{
         name: name,
         type: :endpoint,
         base_url: entry["base_url"],
         api_key: key,
         api_key_header: entry["api_key_header"],
         headers: Map.get(entry, "headers", %{}),
         model: entry["model"]
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
         "the #{name} provider has no model: set model in its systemone_compaction_providers entry"}
  end

  defp options(settings, mode, provider, config) do
    entry =
      config
      |> Config.get("systemone_compaction_providers", %{})
      |> Map.get(provider.name, %{})

    [
      enabled: if(mode == "auto", do: :auto, else: true),
      mode: if(mode == "shadow", do: :shadow, else: :apply),
      provider: provider
    ]
    |> put_settings(@bounds, settings)
    |> put_settings(@rates, entry)
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
