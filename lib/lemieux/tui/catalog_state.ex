defmodule Lemieux.TUI.CatalogState do
  @moduledoc """
  Keeps the TUI's cached provider and model choices consistent.

  Session calls happen in the TUI callback, which supplies their results here.
  Preparing choices is done when that data changes, so sorting and metadata
  lookups never run in `render/2`.
  """

  alias Lemieux.ModelSpec
  alias Lemieux.TUI.ModelChoices

  @recent_limit 20

  @typedoc """
  One model a host discovered: its spec, or `{:preferred, spec}` for the one
  the host would choose for that spec's provider — for Ollama, the model `lmx`
  would start on by itself (`Lemieux.CLI.TUI.discovered_models/2`).
  """
  @type discovery :: String.t() | {:preferred, String.t()}

  @doc "Prepares picker rows and tab geometry from the current catalog."
  @spec prepare(catalog :: map()) :: map()
  def prepare(catalog) do
    choices =
      ModelChoices.prepare(catalog.models,
        preferred: catalog.preferred_models,
        recent: catalog.recent_models,
        metadata: catalog.model_metadata,
        now: catalog.model_now || DateTime.utc_now()
      )

    %{
      catalog
      | model_choices: choices,
        model_tabs: ModelChoices.tabs(choices),
        model_tab_rows: ModelChoices.tab_rows(choices)
    }
  end

  @doc "Merges session choices with asynchronously discovered models for one provider."
  @spec merge(
          catalog :: map(),
          provider :: String.t() | nil,
          providers :: [String.t()],
          models :: [String.t()]
        ) :: map()
  def merge(catalog, provider, providers, models) do
    %{
      catalog
      | providers: merge_providers(providers, catalog.discovered),
        models: Enum.uniq(models ++ discovered_for(catalog, provider))
    }
    |> prepare()
  end

  @doc """
  Records what a host discovered and refreshes the current provider's choices.

  The order of `discovered` matters beyond the menus, which sort on their own:
  when the session has no model of its own for a provider and nothing the
  person chose is among the discovered ones, `/provider NAME` switches to the
  first of `NAME`'s (`Lemieux.Conversation.Command.Provider`). So a host's
  `{:preferred, spec}` goes first, and the rest follow alphabetically, as they
  always did. Alphabetical alone, the first was whatever tag sorted first:
  for Ollama, an embedding model or a chat model that cannot call tools could
  take the place of the model `lmx` would have started on, and a session's
  first request failed on it.

  The preference lives in that order, not in `preferred_models`, and what an
  earlier discovery found keeps its place rather than being sorted again:
  `discovered` is the one part of the catalog that survives the screen
  starting its session (`Lemieux.TUI.Lifecycle.started/4`), and discovery
  usually answers before the session is ready, so a preference kept anywhere
  else was gone by the time anybody typed `/provider`. It is also not what the
  person configured, which `preferred_models` is and the model menu labels so.
  """
  @spec discover(catalog :: map(), discovered :: [discovery()], provider :: String.t() | nil) ::
          map()
  def discover(catalog, discovered, provider) do
    preferred = for {:preferred, spec} <- discovered, spec?(spec), do: spec
    found = discovered |> Enum.filter(&spec?/1) |> Enum.sort()

    catalog = %{catalog | discovered: Enum.uniq(preferred ++ catalog.discovered ++ found)}

    merge(catalog, provider, catalog.providers, catalog.models)
  end

  @doc "Restores the model and MCP catalog when attaching to a session."
  @spec hydrate(
          catalog :: map(),
          details :: map(),
          model :: String.t(),
          provider :: String.t() | nil
        ) :: map()
  def hydrate(catalog, details, model, provider) do
    %{
      catalog
      | model_metadata: details.model_metadata,
        recent_models: recent(model, catalog.recent_models),
        efforts: details.efforts,
        mcp: server_names(details.mcp)
    }
    |> merge(provider, details.providers, details.models)
  end

  @doc "Promotes a selected model to the recent choices."
  @spec remember(catalog :: map(), model :: String.t()) :: map()
  def remember(catalog, model),
    do: %{catalog | recent_models: recent(model, catalog.recent_models)}

  @doc "Returns the preferred model per provider, with configured choices winning."
  @spec selection_preferences(catalog :: map()) :: map()
  def selection_preferences(catalog) do
    recent =
      Enum.reduce(catalog.recent_models, %{}, fn spec, choices ->
        Map.put_new(choices, ModelSpec.provider(spec), spec)
      end)

    Map.merge(recent, catalog.preferred_models)
  end

  @doc "Extracts configured MCP server names for command completion."
  @spec server_names(statuses :: term()) :: [String.t()]
  def server_names(statuses) when is_list(statuses),
    do: statuses |> Enum.map(& &1.name) |> Enum.filter(&is_binary/1)

  def server_names(_statuses), do: []

  defp recent(model, models), do: Enum.uniq([model | models]) |> Enum.take(@recent_limit)

  defp spec?(spec), do: is_binary(spec) and not is_nil(ModelSpec.provider(spec))

  defp merge_providers(providers, discovered) do
    discovered_providers =
      discovered
      |> Enum.map(&ModelSpec.provider/1)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(providers ++ discovered_providers)
  end

  defp discovered_for(catalog, provider),
    do: Enum.filter(catalog.discovered, &(ModelSpec.provider(&1) == provider))
end
