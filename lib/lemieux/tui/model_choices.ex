defmodule Lemieux.TUI.ModelChoices do
  @moduledoc """
  Orders the model menu after the session has determined which models are usable.

  Availability remains the provider's decision. The bundled LLMDB catalog
  supplies dates and lifecycle labels where it can, but gateway and local
  models may have no catalog entry. Those stay selectable. Preferred and recent
  choices lead the unfiltered menu; search promotes an exact id so a person
  typing an older model still gets precisely that model on Enter.

  Ixway's optional route metadata places bare IDs, intents, and aliases in
  the Ixway tab and qualified IDs in their own route tabs. A tab changes only
  presentation: completions retain the exact catalog ID, so choosing a
  qualified route cannot accidentally send the bare ID instead.

  Ixway currently publishes placeholder creation timestamps. For concrete
  model ordering, an optional `ixway_release_date` wins; otherwise an exact
  model-id match in bundled LLMDB supplies an advisory date. Neither asserts
  which backend the gateway chooses. Unknown IDs retain alphabetical order.

  Preparing the metadata once per catalog change keeps LLMDB lookups and
  sorting out of the TUI's render path.
  """

  alias Lemieux.ModelSpec

  @dated_snapshot ~r/^(.*?)(?:-|@)\d{4}-?\d{2}-?\d{2}$/

  @type choice :: %{
          spec: String.t(),
          id: String.t(),
          label: String.t(),
          deprecated?: boolean(),
          personal?: boolean(),
          route: String.t() | nil,
          search_id: String.t()
        }

  @doc "Prepares model choices in menu order, using catalog metadata when available."
  @spec prepare(models :: [String.t()], opts :: keyword()) :: [choice()]
  def prepare(models, opts \\ []) when is_list(models) and is_list(opts) do
    preferred = Keyword.get(opts, :preferred, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    recent =
      opts
      |> Keyword.get(:recent, [])
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    models =
      models
      |> Enum.uniq()
      |> Enum.filter(&(is_binary(&1) and not is_nil(ModelSpec.model_id(&1))))

    dates = ixway_dates(models, metadata)

    models
    |> Enum.map(&choice(&1, Map.get(metadata, &1, %{}), preferred, recent, now, dates))
    |> Enum.sort_by(& &1.order)
    |> Enum.map(&Map.delete(&1, :order))
  end

  @doc "Lists Ixway route tabs. An empty list means the ordinary flat picker."
  @spec tabs(choices :: [choice()]) :: [String.t()]
  def tabs(choices) when is_list(choices) do
    routes =
      choices
      |> Enum.map(& &1.route)
      |> Enum.reject(&(&1 in [nil, "Automatic"]))
      |> Enum.uniq()
      |> Enum.sort()

    if routes == [], do: [], else: ["Automatic" | routes]
  end

  @doc "The tallest unfiltered Ixway route list, including its personal-choice gap."
  @spec tab_rows(choices :: [choice()]) :: non_neg_integer()
  def tab_rows(choices) when is_list(choices) do
    choices
    |> tabs()
    |> Enum.map(fn tab ->
      members = Enum.filter(choices, &(&1.route == tab))
      personal? = Enum.any?(members, & &1.personal?)
      general? = Enum.any?(members, &(not &1.personal?))
      length(members) + if(personal? and general?, do: 1, else: 0)
    end)
    |> Enum.max(fn -> 0 end)
  end

  @doc "A short title for one route tab without altering its exact route ID."
  @spec tab_label(route :: String.t()) :: String.t()
  def tab_label("Automatic"), do: "Ixway"
  def tab_label("openai_codex"), do: "Codex"
  def tab_label("openai"), do: "OpenAI"
  def tab_label(route), do: route |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)

  @doc "Filters one tab; typing a qualified ID searches every route."
  @spec completions(choices :: [choice()], value :: String.t(), tab :: String.t()) :: [map()]
  def completions(choices, value, tab \\ "Automatic")
      when is_list(choices) and is_binary(value) and is_binary(tab) do
    query = value |> String.replace_prefix("/model ", "") |> String.trim() |> String.downcase()

    cross_route? = qualified_query?(choices, query)

    choices
    |> Enum.filter(&visible_in_tab?(&1, tab, cross_route?))
    |> Enum.with_index()
    |> Enum.filter(fn {choice, _index} -> matches_query?(choice, query) end)
    |> Enum.sort_by(&match_order(&1, query))
    |> Enum.map(&completion(&1, cross_route?))
  end

  defp qualified_query?(choices, query) do
    Enum.any?(choices, fn choice ->
      choice.route not in [nil, "Automatic"] and
        String.starts_with?(query, String.downcase(choice.route) <> ":")
    end)
  end

  defp visible_in_tab?(choice, tab, cross_route?),
    do: choice.route == nil or choice.route == tab or cross_route?

  defp matches_query?(choice, query),
    do:
      String.contains?(String.downcase(choice.search_id), query) or
        String.contains?(String.downcase(choice.id), query)

  defp match_order({choice, index}, query) do
    id = String.downcase(choice.search_id)
    full_id = String.downcase(choice.id)

    rank =
      cond do
        id == query or full_id == query -> 0
        String.starts_with?(id, query) or String.starts_with?(full_id, query) -> 1
        true -> 2
      end

    {rank, index}
  end

  defp completion({choice, _index}, cross_route?) do
    %{
      label: if(cross_route?, do: qualified_label(choice), else: choice.label),
      value: "/model " <> choice.id,
      deprecated?: choice.deprecated?,
      personal?: choice.personal?
    }
  end

  defp qualified_label(%{route: route, id: id, label: label})
       when route not in [nil, "Automatic"] do
    String.replace_prefix(label, String.replace_prefix(id, route <> ":", ""), id)
  end

  defp qualified_label(choice), do: choice.label

  defp choice(spec, metadata, preferred, recent, now, dates) do
    id = ModelSpec.model_id(spec)
    provider = ModelSpec.provider(spec)
    route = Map.get(metadata, :route)

    search_id = display_id(id, route)

    kind = Map.get(metadata, :kind)
    preferred? = Map.get(preferred, provider) == spec
    recent_index = Map.get(recent, spec)

    {status, family_date, own_date} =
      metadata(spec, now, dates, search_id, Map.get(metadata, :release_date))

    priority = priority(preferred?, recent_index)
    label = choice_label(search_id, preferred?, recent_index, status)

    %{
      spec: spec,
      id: id,
      route: route,
      search_id: search_id,
      label: label,
      deprecated?: status == :deprecated,
      personal?: preferred? or is_integer(recent_index),
      order:
        {priority, kind_rank(kind), status_rank(status, family_date), -family_date, snapshot?(id),
         -own_date, id}
    }
  end

  defp display_id(id, route) when route in [nil, "Automatic"], do: id
  defp display_id(id, route), do: String.replace_prefix(id, route <> ":", "")

  defp ixway_dates(models, metadata) do
    wanted =
      models
      |> Enum.filter(&(ModelSpec.provider(&1) == "ixway"))
      |> Enum.reject(&(Map.get(Map.get(metadata, &1, %{}), :kind) in ["intent", "alias"]))
      |> MapSet.new(fn spec ->
        route = metadata |> Map.get(spec, %{}) |> Map.get(:route)
        display_id(ModelSpec.model_id(spec), route)
      end)

    if MapSet.size(wanted) == 0 do
      %{}
    else
      LLMDB.models()
      |> Enum.filter(&MapSet.member?(wanted, &1.id))
      |> Enum.reduce(%{}, &put_known_date/2)
    end
  end

  defp put_known_date(model, dates) do
    case date_value(model.release_date) do
      0 -> dates
      date -> Map.update(dates, model.id, date, &max(&1, date))
    end
  end

  defp priority(true, _recent_index), do: {0, 0}
  defp priority(false, recent_index) when is_integer(recent_index), do: {1, recent_index}
  defp priority(false, _recent_index), do: {2, 0}

  defp choice_label(search_id, preferred?, recent_index, status) do
    [
      search_id,
      if(preferred?, do: "preferred"),
      if(is_integer(recent_index) and not preferred?, do: "recent"),
      if(status in [:deprecated, :retired], do: Atom.to_string(status))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp kind_rank("intent"), do: 0
  defp kind_rank("alias"), do: 1
  defp kind_rank(_kind), do: 2

  defp metadata(spec, now, dates, search_id, ixway_release_date) do
    case LLMDB.model(spec) do
      {:ok, model} ->
        own_date = date_value(model.release_date)
        {status(model, now), family_date(spec, own_date), own_date}

      {:error, _reason} ->
        date = ixway_date(spec, dates, search_id, ixway_release_date)
        {:unknown, date, date}
    end
  end

  defp ixway_date(spec, dates, search_id, declared_date) do
    if ModelSpec.provider(spec) == "ixway" do
      case date_value(declared_date) do
        0 -> Map.get(dates, search_id, 0)
        date -> date
      end
    else
      0
    end
  end

  defp family_date(spec, own_date) do
    case Regex.run(@dated_snapshot, ModelSpec.model_id(spec)) do
      [_snapshot, canonical_id] ->
        canonical = ModelSpec.join(ModelSpec.provider(spec), canonical_id)

        case LLMDB.model(canonical) do
          {:ok, model} -> canonical_date(model, own_date)
          {:error, _reason} -> own_date
        end

      nil ->
        own_date
    end
  end

  defp canonical_date(model, own_date) do
    case date_value(model.release_date) do
      0 -> own_date
      date -> date
    end
  end

  defp status(model, now) do
    case LLMDB.Model.effective_status(model, now) do
      "active" -> :active
      "deprecated" -> :deprecated
      "retired" -> :retired
    end
  end

  defp status_rank(:active, date) when date > 0, do: 0
  defp status_rank(:active, _date), do: 1
  defp status_rank(:unknown, _date), do: 2
  defp status_rank(:deprecated, _date), do: 3
  defp status_rank(:retired, _date), do: 4

  defp date_value(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.to_gregorian_days(parsed)
      {:error, _reason} -> 0
    end
  end

  defp date_value(_date), do: 0

  defp snapshot?(id), do: Regex.match?(@dated_snapshot, id)
end
