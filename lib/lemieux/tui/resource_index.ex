# Like `Lemieux.TUI.FileIndex`: the ranking is pure and unguarded, and the
# listing is a task the screen starts.
defmodule Lemieux.TUI.ResourceIndex do
  @moduledoc """
  The resources connected MCP servers offer, for the `@` picker.

  A resource is typed `@server:uri` (see `Lemieux.Reference`). The picker
  offers them beside files once something is typed after the `@`, ranked the
  way `Lemieux.TUI.FileIndex` ranks paths, over `server:uri`.

  ## When the list is fetched

  Asking means asking every server that declared resources, over its own
  connection (`Lemieux.Session.mcp_resources/2`), so it is a task and the
  screen never waits on it:

    * the first time an `@` query is typed, when nothing was listed yet;
    * when the session reports it is ready, since servers connect in the
      background and there may have been nothing to list before;
    * when a server says its resources changed.

  `render/2` only ever reads what is kept. While a listing is being fetched
  again the previous one stays, so the menu does not empty mid-word.
  """

  alias Lemieux.Reference
  alias Lemieux.Session
  alias Lemieux.TUI.FileIndex

  @shown 20

  @typedoc """
  One resource the picker can offer: `label` is shown and matched, `reference`
  is what goes on the line, `name` is what the server calls it.
  """
  @type item :: %{label: String.t(), reference: String.t(), name: String.t() | nil}

  @doc "Starts a listing when there has never been one. See `refresh/2`."
  @spec ensure(references :: map(), session :: pid() | nil) :: map()
  def ensure(references, session) do
    case Map.get(references, :resources) do
      nil -> refresh(references, session)
      _listed_or_listing -> references
    end
  end

  @doc """
  Lists the session's resources again, in a task that answers
  `{:mcp_resources, session, items}`. Without a session there is nothing to
  ask.
  """
  @spec refresh(references :: map(), session :: pid() | nil) :: map()
  def refresh(references, session) when is_pid(session) do
    app = self()
    Task.start(fn -> send(app, {:mcp_resources, session, listed(session)}) end)
    Map.put(references, :resources, %{items: items(references), loading?: true})
  end

  def refresh(references, _no_session), do: references

  @doc """
  Keeps a finished listing when it answers for the session still being
  shown; one from a session since replaced by `/new` or `/resume` is dropped.
  """
  @spec loaded(references :: map(), current :: pid() | nil, session :: pid(), items :: [item()]) ::
          map()
  def loaded(references, session, session, items),
    do: Map.put(references, :resources, %{items: items, loading?: false})

  def loaded(references, _current, _stale, _items), do: references

  @doc "The resources whose `server:uri` fits `query`, best first."
  @spec match(references :: map(), query :: String.t()) :: [item()]
  def match(references, query) do
    items = items(references)
    by_label = Map.new(items, &{&1.label, &1})

    items
    |> Enum.map(& &1.label)
    |> FileIndex.match(query, @shown)
    |> Enum.map(&Map.fetch!(by_label, &1))
  end

  @doc """
  What of a session's resources the picker can offer: only what
  `Lemieux.Reference.render_resource/2` can put on the line, since a
  reference the session would read back as something else is worse than
  none. One entry per `server:uri`.
  """
  @spec offerable(resources :: [map()]) :: [item()]
  def offerable(resources) when is_list(resources) do
    resources
    |> Enum.flat_map(&item/1)
    |> Enum.uniq_by(& &1.label)
  end

  defp item(%{server: server, uri: uri} = resource) when is_binary(server) and is_binary(uri) do
    case Reference.render_resource(server, uri) do
      nil -> []
      reference -> [%{label: server <> ":" <> uri, reference: reference, name: resource[:name]}]
    end
  end

  defp item(_resource), do: []

  defp items(references) do
    case Map.get(references, :resources) do
      %{items: items} -> items
      _none -> []
    end
  end

  # A session that has gone, or one that cannot list resources, leaves the
  # picker without them rather than crashing the task that asked.
  defp listed(session) do
    session |> Session.mcp_resources() |> offerable()
  catch
    :exit, _reason -> []
  end
end
