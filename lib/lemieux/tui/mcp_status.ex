if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.MCPStatus do
    @moduledoc """
    What the screen knows about each MCP server, and what it says about them.

    A session connects its MCP servers in tasks of its own and reports each
    one as it goes — `{:mcp_server, status}` — then `{:ready, _}` once they
    have all settled. Asking it for its catalog before then waits for the
    slowest server, which is why the screen used to fail to start behind a
    cold `npx` or an OAuth prompt. So the screen asks nothing: it keeps what
    it was told (`session_view.mcp`), shows the servers still connecting on
    the status line, and says in the notice box (`Lemieux.TUI.Notices`) only
    what a person has to act on — a server that failed, or one waiting for a
    sign-in — and, once everything has settled, one line naming what
    connected. `/mcp` shows every server's state after the box has closed.
    """

    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.Boot
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Notices

    @doc "Starts from what `Session.info/2` reported."
    @spec start(TUI.t(), [map()], boolean()) :: TUI.t()
    def start(state, statuses, ready?) when is_list(statuses) do
      state
      |> put_in([Access.key!(:session_view), :mcp], Map.new(statuses, &{&1.name, &1}))
      |> put_in([Access.key!(:session_view), :mcp_ready?], ready?)
      |> put_in([Access.key!(:session_view), :mcp_announced?], false)
      |> Choices.put_mcp_names(statuses)
      |> boot(ready?, statuses)
    end

    @doc "One server's new status, and the row it earns, if any."
    @spec update(TUI.t(), map()) :: TUI.t()
    def update(state, %{name: name} = status) do
      previous = get_in(state.session_view.mcp, [name, :status])
      state = put_in(state.session_view.mcp[name], status)

      if previous == status.status, do: state, else: announce(state, status)
    end

    def update(state, _status), do: state

    @doc """
    Every server has settled; one line for what connected.

    Said once per session. The same settling can reach the screen twice, as
    the `{:ready, _}` event and as the answer to `watch/1`, and the second
    only reconciles what the first already said. `mcp_ready?` cannot tell the
    two apart, because it starts true on a screen with nothing to wait for;
    `mcp_announced?` is reset when a session is adopted, and set here.
    """
    @spec ready(TUI.t(), [map()]) :: TUI.t()
    def ready(%TUI{session_view: %{mcp_announced?: true}} = state, statuses),
      do: Enum.reduce(statuses, state, &update(&2, &1))

    def ready(state, statuses) do
      state
      |> put_in([Access.key!(:session_view), :mcp_ready?], true)
      |> then(fn state -> Enum.reduce(statuses, state, &update(&2, &1)) end)
      |> refresh()
      |> connected_line(statuses)
      |> announced()
      |> boot(true, statuses)
    end

    defp boot(state, _ready?, []), do: state

    defp boot(state, false, _statuses),
      do: Boot.observe(state, :mcp, "Connecting MCP servers", "busy")

    defp boot(state, true, statuses) do
      failed? = Enum.any?(statuses, &(Map.get(&1, :status, :unknown) != :connected))

      Boot.observe(
        state,
        :mcp,
        "MCP servers settled · /mcp shows details",
        if(failed?, do: "warn", else: "ok")
      )
    end

    @doc """
    Catches up on MCP events the screen could not have seen.

    A session starts connecting its servers the moment it exists, and a refused
    connection settles in milliseconds. That is before a screen that started
    the session from a task has learned the session's id, so the
    `{:mcp_server, _}` and `{:ready, _}` events arrive for an id it doesn't know
    yet, and are dropped. What it kept was the `info/2` read taken while the
    server was still connecting, and the status line said "connecting
    tidewave…" for as long as lmx ran.

    So a screen that adopts a session whose servers have not all settled asks
    for the settled state in a task: `Session.mcp_status/2` waits for the
    connections, then `Session.info/2` says where each one ended up. The
    answer arrives as `{:mcp_settled, session, statuses}` (see `settled/3`).
    A session already settled when adopted has its failures and connections
    announced now, since no event for them is still to come.
    """
    @spec watch(TUI.t()) :: TUI.t()
    def watch(%TUI{session: session, session_view: %{mcp_ready?: false}} = state)
        when is_pid(session) do
      app = self()

      Task.start(fn ->
        _settled = Session.mcp_status(session, :infinity)
        send(app, {:mcp_settled, session, Session.info(session, :infinity).mcp})
      end)

      state
    end

    def watch(%TUI{session_view: %{mcp: servers, mcp_announced?: false}} = state)
        when map_size(servers) > 0 do
      statuses = servers |> Map.values() |> Enum.sort_by(& &1.name)

      statuses
      |> Enum.reduce(state, &announce(&2, &1))
      |> connected_line(statuses)
      |> announced()
    end

    def watch(state), do: state

    @doc "The settled servers `watch/1` asked for; an answer for another session is ignored."
    @spec settled(TUI.t(), pid(), [map()]) :: TUI.t()
    def settled(%TUI{session: session} = state, session, statuses), do: ready(state, statuses)
    def settled(state, _other_session, _statuses), do: state

    defp announced(state), do: put_in(state.session_view.mcp_announced?, true)

    defp connected_line(state, statuses) do
      connected =
        for %{status: :connected, name: name, tool_count: count} <- statuses,
            do: "#{name} (#{count} #{if count == 1, do: "tool", else: "tools"})"

      if connected == [],
        do: state,
        else: Notices.say(state, :info, "MCP connected: " <> Enum.join(connected, ", "))
    end

    @doc "The servers still connecting, by name, for the status line."
    @spec connecting(TUI.t()) :: [String.t()]
    def connecting(%TUI{session_view: %{mcp: servers}}) do
      for {name, %{status: :connecting}} <- servers, do: name
    end

    def connecting(_state), do: []

    @doc """
    The servers as `/mcp` lists them, in the shape `Session.mcp_status/2`
    answers with, from what the screen was told — no call to a session that
    may still be connecting.
    """
    @spec statuses(TUI.t()) :: [map()]
    def statuses(state) do
      state.session_view.mcp
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn status ->
        status
        |> Map.put_new(:enabled?, Map.get(status, :status) != :disabled)
        |> Map.put_new(:tool_count, 0)
        |> Map.put_new(:error, nil)
        |> Map.put_new(:transport, nil)
      end)
    end

    @doc """
    Asks the session for its tools and servers once it has settled, in a
    task; the answer arrives as `{:session_catalog, session, tools, servers}`.
    """
    @spec refresh(TUI.t()) :: TUI.t()
    def refresh(%TUI{session: session} = state) when is_pid(session) do
      app = self()

      Task.start(fn ->
        send(
          app,
          {:session_catalog, session, Session.tool_status(session),
           Session.mcp_status(session, :infinity)}
        )
      end)

      state
    end

    def refresh(state), do: state

    @doc false
    @spec catalog(TUI.t(), pid(), list(), list()) :: TUI.t()
    def catalog(%TUI{session: session} = state, session, tools, servers) do
      state
      |> Choices.put_tool_statuses(tools)
      |> Choices.put_mcp_names(servers)
    end

    def catalog(state, _other_session, _tools, _servers), do: state

    defp announce(state, %{status: :failed, name: name} = status),
      do:
        Notices.say(
          state,
          :error,
          "MCP server #{name} is unavailable: #{status[:error] || "no reason given"}. " <>
            "Its tools are left out; once it is running, /mcp reconnects it."
        )

    defp announce(state, %{status: :needs_auth, name: name}),
      do:
        Notices.say(
          state,
          :warning,
          "MCP server #{name} needs you to sign in; /mcp, select it, and press r to authorize"
        )

    defp announce(state, _status), do: state
  end
end
