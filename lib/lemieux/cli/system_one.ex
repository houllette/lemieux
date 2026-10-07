defmodule Lemieux.CLI.SystemOne do
  @moduledoc """
  The System One providers a person declares in the lmx config file, resolved
  for whichever feature asks one.

  A System One model answers typed questions about a state — `noul`,
  `choice` and `score` — with calibrated probabilities over
  `POST /v1/systemone`. More than one feature asks such a model: compaction
  asks which old reads are still needed, the computer-use example asks which
  page element to act on, the research example asks which source to open
  next. They should not each carry a vendor's address and key, so the
  providers are declared once, in `"systemone_providers"`, and each feature
  names the one it uses (`systemone_compaction.provider`, the computer-use
  host's `--systemone-provider`, the research example's `provider:`).
  Different features can use different providers — a small local model for
  compaction, a stronger one for browser actions — and two entries can point
  at one server with different models.

  Two providers are built in, and need an entry only to change what they
  default to:

  - `typesafe`: TypeSafe's hosted service. Its key is `JEV_API_KEY` (the name
    TypeSafe gives its Jev key) or the entry's `api_key`; it alone has a
    default model and published rates, which live with whoever builds its
    client, next to the vendor.
  - `ixway`: an Ixway gateway implementing `POST /v1/systemone`, at the
    entry's `base_url` or the Ixway route `lmx` is using, with the entry's
    `model` and the Ixway key (`IXWAY_API_KEY` or `ixway.api_key`) — the one
    place a gateway key lives.

  Any other name is a provider the person declares: a `base_url` that speaks
  `POST /v1/systemone` — a vendor's decision API, an open model on their own
  machine — with an optional `api_key` or `api_key_env`, `api_key_header`,
  extra `headers`, a `model` and its tariff.

  With no selection (or `"auto"`), the choice is between the two built-in
  ones: Ixway when its endpoint and a model are set, TypeSafe when its key
  is. A declared provider is never chosen that way. An entry nobody selects
  sends nothing, so a provider can sit in the file before it is wanted.
  There is no fallback from one provider to another: a person who pointed a
  feature at their own machine chose where its data goes.

  The environment supplies credentials only (`JEV_API_KEY`, `IXWAY_API_KEY`,
  a provider's own `api_key_env`), with an empty value switching a saved key
  off, as `BRAVE_SEARCH_API_KEY=` does for search. Nothing here contacts a
  provider; this is data in, a provider description out. The library has no
  System One SDK dependency: whoever asks the questions builds the client.
  """

  alias Lemieux.CLI.Config

  @typesafe_base_url "https://api.typesafe.ai"

  @typedoc """
  A resolved provider, as every consumer takes it: `type: :typesafe` is
  TypeSafe's hosted service, `type: :endpoint` any other `POST /v1/systemone`
  service. `model` is `nil` only for TypeSafe, whose default the client's
  builder owns. `api_key_header` names the header the key travels in when
  the service does not take a bearer token; `nil` means
  `Authorization: Bearer`.
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

  @doc """
  Resolves the provider `selection` names, without contacting it.

  `selection` is a provider's name, `"auto"` or `nil`. `opts` takes
  `ixway_endpoint:` (the Ixway route `lmx` is using, which the `ixway`
  provider falls back to) and `selected_by:` (the field or flag that named
  the provider, so a refusal can say where to change it).

  `{:unavailable, reason}` says, in a clause that fits after "but", what is
  missing; a feature that is optional then stays off, and one that was asked
  for stops with that sentence.
  """
  @spec provider(config :: Config.t() | nil, selection :: String.t() | nil, opts :: keyword()) ::
          {:ok, provider()} | {:unavailable, String.t()}
  def provider(config, selection, opts \\ []) do
    entries = Config.get(config, "systemone_providers", %{})
    ixway_endpoint = Keyword.get(opts, :ixway_endpoint)
    selected_by = Keyword.get(opts, :selected_by, "the provider setting")

    case selection || "auto" do
      "auto" -> auto(entries, config, ixway_endpoint, selected_by)
      "typesafe" -> typesafe(Map.get(entries, "typesafe", %{}))
      "ixway" -> ixway(Map.get(entries, "ixway", %{}), config, ixway_endpoint)
      name -> declared(name, Map.get(entries, name), selected_by)
    end
  end

  @doc """
  The declared tariff for a provider, as `input_per_million:` and
  `output_per_million:` options; empty when the entry declares none.
  """
  @spec rates(config :: Config.t() | nil, name :: String.t()) :: keyword()
  def rates(config, name) do
    entry = config |> Config.get("systemone_providers", %{}) |> Map.get(name, %{})

    for {key, option} <- [
          {"input_per_million", :input_per_million},
          {"output_per_million", :output_per_million}
        ],
        Map.has_key?(entry, key),
        do: {option, entry[key]}
  end

  # Ixway when its endpoint and a model are both set, TypeSafe when its key
  # is: a gateway someone pinned a model on is the more deliberate choice. A
  # declared provider takes an explicit selection.
  defp auto(entries, config, ixway_endpoint, selected_by) do
    entry = Map.get(entries, "ixway", %{})

    if present?(ixway_endpoint(entry, config, ixway_endpoint)) and present?(entry["model"]) do
      ixway(entry, config, ixway_endpoint)
    else
      case typesafe(Map.get(entries, "typesafe", %{})) do
        {:ok, provider} -> {:ok, provider}
        {:unavailable, _reason} -> {:unavailable, nothing_complete(selected_by)}
      end
    end
  end

  defp nothing_complete(selected_by),
    do:
      "no provider is complete: the typesafe provider needs a key (JEV_API_KEY, or " <>
        "systemone_providers.typesafe.api_key), the ixway provider needs an endpoint " <>
        "(systemone_providers.ixway.base_url, or the Ixway route lmx uses) and a model beside " <>
        "the Ixway key, and any other provider in systemone_providers needs #{selected_by} " <>
        "to select it"

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
           "systemone_providers.typesafe.api_key in the config file"}
  end

  defp ixway(entry, config, ixway_endpoint) do
    endpoint = ixway_endpoint(entry, config, ixway_endpoint)
    key = System.get_env("IXWAY_API_KEY") || Config.get(config, "ixway", %{})["api_key"]
    model = entry["model"]

    missing =
      for {false, what} <- [
            {present?(endpoint),
             "an endpoint (systemone_providers.ixway.base_url, or the Ixway route lmx uses: " <>
               "--ixway, LMX_IXWAY_URL or ixway.endpoint)"},
            {present?(model), "a model (systemone_providers.ixway.model)"},
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

  # The name is not echoed: it may have come from a flag, and what sits in
  # a name's place in a mistyped command line may be a key.
  defp declared(_name, nil, selected_by),
    do: {:unavailable, "#{selected_by} names a provider systemone_providers does not declare"}

  defp declared(name, entry, _selected_by) do
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
  # and an empty one switches the saved key off. A variable named but unset,
  # with no saved key beside it, is a provider the person meant to
  # authenticate to: refused, not sent to unauthenticated.
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
         "the #{name} provider has no model: set model in its systemone_providers entry"}
  end

  defp sentence([one]), do: one
  defp sentence([first, second]), do: first <> " and " <> second
  defp sentence([first | rest]), do: first <> ", " <> sentence(rest)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
