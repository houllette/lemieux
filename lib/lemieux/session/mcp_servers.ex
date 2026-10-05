defmodule Lemieux.Session.MCPServers do
  @moduledoc false

  require Logger

  alias Lemieux.Clock
  alias Lemieux.MCP
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Core
  alias Lemieux.Session.Requests
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Tool

  # The explicit operations — adding, re-enabling, reconnecting — still connect
  # before they answer, because a host that asked for a server is waiting to
  # hear whether it came up. Only startup connects in the background.
  # `overrides` go over the host's connect options. The explicit operations a
  # person asks for pass `interactive_auth: true`: the host's startup options
  # say `false` so a server needing a browser sign-in settles as needs_auth
  # instead of holding up the session, and without the override that server
  # could never be signed in to from `/mcp`.
  def connect_mcp_servers(state, configs, overrides \\ []) do
    opts = Keyword.merge(mcp_connect_options(state), overrides)

    Enum.reduce(configs, {state, %{}, %{}}, fn config, {state, connections, errors} ->
      name = Map.fetch!(config, "name")

      if MapSet.member?(state.mcp_disabled, name) do
        {state, connections, errors}
      else
        result = MCP.connect_server(config, opts)
        {tools, clients, failures} = connection(result)

        {note_mcp_result(state, name, result), Map.put(connections, name, {tools, clients}),
         Map.merge(errors, failures)}
      end
    end)
  end

  # `Lemieux.MCP.connect_server/2`'s answer in the shape the session keeps:
  # tools and clients for the catalog, failures by name for `mcp_status/1`.
  # Consent-needing failures keep their structure in `mcp_needs_auth` too.
  defp connection({:ok, %{client: client, tools: tools}}), do: {tools, [client], %{}}

  defp connection({:error, %{name: name, reason: reason}}),
    do: {[], [], %{name => describe_mcp_failure(reason)}}

  defp describe_mcp_failure({:needs_auth, info}),
    do: "needs authorization: sign in to #{Map.get(info, :url) || Map.get(info, :server)}"

  defp describe_mcp_failure(reason) when is_binary(reason), do: reason
  defp describe_mcp_failure(reason), do: inspect(reason)

  defp note_mcp_result(state, name, {:ok, %{notices: notices}}) do
    %{
      state
      | mcp_needs_auth: Map.delete(state.mcp_needs_auth, name),
        mcp_notices: Map.put(state.mcp_notices, name, notices)
    }
  end

  defp note_mcp_result(state, name, {:error, %{reason: {:needs_auth, info}}}) do
    %{
      state
      | mcp_needs_auth: Map.put(state.mcp_needs_auth, name, info),
        mcp_notices: Map.delete(state.mcp_notices, name)
    }
  end

  defp note_mcp_result(state, name, _failed) do
    %{
      state
      | mcp_needs_auth: Map.delete(state.mcp_needs_auth, name),
        mcp_notices: Map.delete(state.mcp_notices, name)
    }
  end

  # Built in the session so `owner` is the session: a connection task that
  # named itself would leave the clients following a process that exits the
  # moment it has answered.
  defp mcp_connect_options(state) do
    Keyword.merge(
      [
        supervisor: state.supervisor,
        owner: self(),
        auth: state.mcp_auth,
        stdio_launcher: state.mcp_stdio_launcher,
        transports: state.mcp_transports,
        cwd: state.cwd
      ],
      state.mcp_connect_opts
    )
  end

  def start_mcp_connections(state, configs) do
    opts = mcp_connect_options(state)

    configs
    |> Enum.reject(&MapSet.member?(state.mcp_disabled, Map.fetch!(&1, "name")))
    |> Enum.reduce(state, &start_mcp_connection(&2, &1, opts))
  end

  # Not linked: a transport that crashes while connecting costs its own server,
  # as a refused connection always has, and not the session.
  defp start_mcp_connection(state, config, opts) do
    task =
      Task.Supervisor.async_nolink(Sup.task_supervisor(state.supervisor), fn ->
        MCP.connect_server(config, opts)
      end)

    state = %{state | mcp_pending: Map.put(state.mcp_pending, task.ref, {config["name"], task})}

    Core.emit(state, {:mcp_server, mcp_server_status(state, config)})
  end

  def settle_mcp_connection(state, ref, result) do
    {{name, _task}, pending} = Map.pop(state.mcp_pending, ref)
    state = %{state | mcp_pending: pending}
    config = Enum.find(state.mcp_servers, &(&1["name"] == name))
    {tools, clients, failures} = connection(result)

    state =
      if config && not MapSet.member?(state.mcp_disabled, name) do
        state
        |> note_mcp_result(name, result)
        |> Map.update!(:mcp_connections, &Map.put(&1, name, {tools, clients}))
        |> Map.update!(:mcp_errors, &(&1 |> Map.delete(name) |> Map.merge(failures)))
        |> refresh_mcp_tools()
        |> then(&Core.emit(&1, {:mcp_server, mcp_server_status(&1, config)}))
      else
        # Removed or turned off while it was connecting: whatever it started
        # is let go rather than joining a catalog that no longer names it.
        MCP.disconnect(clients, state.supervisor)
        state
      end

    mcp_settled(state)
  end

  # Called by the explicit operations for the servers they are about to
  # connect themselves, so a slower startup attempt cannot land afterwards and
  # replace what they connected.
  def forget_mcp_connecting(state, names) do
    {dropped, kept} =
      Enum.split_with(state.mcp_pending, fn {_ref, {name, _task}} -> name in names end)

    Enum.each(dropped, fn {_ref, {_name, task}} -> Task.shutdown(task, :brutal_kill) end)

    mcp_settled(%{state | mcp_pending: Map.new(kept)})
  end

  defp mcp_settled(%{mcp_pending: pending} = state) when map_size(pending) > 0, do: state

  defp mcp_settled(state) do
    state = answer_mcp_waiters(state)

    state =
      if state.mcp_ready?,
        do: state,
        else: Core.emit(%{state | mcp_ready?: true}, {:ready, %{mcp: mcp_server_statuses(state)}})

    release_mcp_wait(state)
  end

  # Oldest first, each through the clause that would have answered it, now that
  # nothing is pending and none of them will be deferred again.
  defp answer_mcp_waiters(%{mcp_waiters: []} = state), do: state

  defp answer_mcp_waiters(state) do
    state.mcp_waiters
    |> Enum.reverse()
    |> Enum.reduce(%{state | mcp_waiters: []}, fn {request, from}, state ->
      case Lemieux.Session.handle_call(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          state

        {:noreply, state} ->
          state
      end
    end)
  end

  defp release_mcp_wait(%{mcp_wait: nil} = state), do: state

  defp release_mcp_wait(%{mcp_wait: wait} = state) do
    if wait.timer, do: Clock.cancel(state.clock, wait.timer)
    Requests.build_turn(%{state | mcp_wait: nil})
  end

  def mcp_server_statuses(state), do: Enum.map(state.mcp_servers, &mcp_server_status(state, &1))

  def mcp_server_status(state, config) do
    name = config["name"]
    {tools, clients} = Map.get(state.mcp_connections, name, {[], []})
    error = Map.get(state.mcp_errors, name)

    %{
      name: name,
      transport: config["transport"],
      status: mcp_server_state(state, name, clients),
      tool_count: length(tools),
      error: error,
      notices: Map.get(state.mcp_notices, name, []),
      auth: Map.get(state.mcp_needs_auth, name)
    }
  end

  # Connected means a live client, not tools: a server that offers prompts or
  # resources and no tools is connected, and reads as failed otherwise.
  defp mcp_server_state(state, name, clients) do
    cond do
      MapSet.member?(state.mcp_disabled, name) ->
        :disabled

      Enum.any?(state.mcp_pending, fn {_ref, {pending, _task}} -> pending == name end) ->
        :connecting

      clients != [] ->
        :connected

      Map.has_key?(state.mcp_needs_auth, name) ->
        :needs_auth

      true ->
        :failed
    end
  end

  def change_mcp_enabled(state, name, false) do
    state
    |> forget_mcp_connecting([name])
    |> disconnect_mcp_connections(MapSet.new([name]))
    |> Map.update!(:mcp_disabled, &MapSet.put(&1, name))
    |> Map.update!(:mcp_errors, &Map.delete(&1, name))
    |> refresh_mcp_tools()
  end

  def change_mcp_enabled(state, name, true) do
    config = Enum.find(state.mcp_servers, &(Map.fetch!(&1, "name") == name))

    state =
      state
      |> forget_mcp_connecting([name])
      |> disconnect_mcp_connections(MapSet.new([name]))
      |> Map.update!(:mcp_disabled, &MapSet.delete(&1, name))

    {state, connections, errors} = connect_mcp_servers(state, [config])

    state
    |> Map.update!(:mcp_connections, &Map.merge(&1, connections))
    |> Map.update!(:mcp_errors, &Map.merge(&1, errors))
    |> refresh_mcp_tools()
  end

  def disconnect_mcp_connections(state, names) do
    {removed, kept} = Map.split(state.mcp_connections, MapSet.to_list(names))

    removed
    |> Map.values()
    |> Enum.flat_map(fn {_tools, clients} -> clients end)
    |> MCP.disconnect(state.supervisor)

    %{state | mcp_connections: kept}
  end

  def replace_mcp_tools(state, name, tools, clients, change) do
    state =
      state
      |> Map.update!(:mcp_connections, &Map.put(&1, name, {tools, clients}))
      |> Map.update!(:mcp_notices, &Map.put(&1, name, Map.get(change, :notices, [])))
      |> refresh_mcp_tools()

    config = Enum.find(state.mcp_servers, &(&1["name"] == name))
    Core.emit(state, {:mcp_server, mcp_server_status(state, config)})
  end

  def refresh_mcp_tools(state) do
    catalog = state.local_tools ++ Catalog.remote_tools(state)
    tools = Catalog.enabled_tools(catalog, state.disabled_tools, state.tool_profile)

    case Tool.validate_all(tools) do
      :ok ->
        %{state | tools: tools}

      {:error, reason} ->
        Logger.warning("lemieux: ignoring invalid MCP tool catalog: #{inspect(reason)}")

        local_tools =
          Catalog.enabled_tools(state.local_tools, state.disabled_tools, state.tool_profile)

        Core.emit(%{state | tools: local_tools}, {:mcp_error, {:invalid_tool_catalog, reason}})
    end
  end

  # Each enabled server's live client, by name: what `Session.mcp_clients/2`
  # answers and what a prompt's `@server:uri` references are read through.
  def connected_clients(state) do
    clients =
      for {name, {_tools, [client | _rest]}} <- state.mcp_connections,
          not MapSet.member?(state.mcp_disabled, name),
          do: {name, client}

    Enum.sort_by(clients, &elem(&1, 0))
  end

  def mcp_statuses(state) do
    Enum.map(state.mcp_servers, fn config ->
      {tools, _clients} = Map.get(state.mcp_connections, config["name"], {[], []})

      %{
        name: config["name"],
        transport: config["transport"],
        tool_count: length(tools),
        enabled?: not MapSet.member?(state.mcp_disabled, config["name"]),
        error: Map.get(state.mcp_errors, config["name"])
      }
    end)
  end
end
