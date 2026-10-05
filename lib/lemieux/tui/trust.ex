if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Trust do
    @moduledoc """
    The question a repository's `.mcp.json` asks before anything in it runs.

    `Lemieux.Extensions.MCP` holds back a project's servers that nobody has
    reviewed (see `Lemieux.MCP.Trust`), and says so in a notice. This is the
    other half: when the host names a trust store (`:mcp_trust`, `%{store:,
    cwd:}`), the screen asks — once the session is up, in a task, because
    reading the file is I/O — and, if there is something to decide, shows
    each server with what it runs or where it connects and the environment
    variables it reads, by name. `:except` names the servers the host's own
    configuration claims; they are left out of the question, as the
    extension leaves them out of the session.

    Three answers. **Trust** records the decision and starts the servers in
    this session; they are marked `"trusted"` rather than `"project"`, because
    the variables they read are exactly the ones just shown and agreed to, as
    `Lemieux.MCP.Trust.allowed_env/3` allows on the next start. **Don't start
    them** records a no, so the question is not asked again until the file
    changes. **Not now** records nothing and asks next time.

    Every name, command, argument and URL in the question came from the
    file, and is shown as `lmx mcp trust` shows it: each argument
    shell-quoted and every control character written out
    (`Lemieux.CLI.MCPCommands.command_line/1`,
    `Lemieux.CLI.Sanitize.visible/1`). The cells never pass a control
    character to the terminal — ratatui drops them — but dropped is hidden:
    a carriage return and an erase-line inside an argument, there to make
    the line read as a harmless command, vanished along with the sign that
    anything was wrong.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.CLI.MCPCommands
    alias Lemieux.CLI.Sanitize
    alias Lemieux.Extensions.MCP, as: MCPExtension
    alias Lemieux.MCP.Trust, as: TrustStore
    alias Lemieux.Session
    alias Lemieux.TUI
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Transcript

    @choices [
      {:trusted, "Trust them and start them"},
      {:denied, "Don't start them"},
      {:later, "Not now — ask next time"}
    ]

    @doc """
    Asks, off the render loop, whether the project's servers need a decision.
    A no-op when the host named no store.

    The staged queue waits for the answer, and for the decision when there
    is one to make (`Lemieux.TUI.History.hold/2`), so a prompt staged before
    the session was up runs with the servers the person chose to start.
    """
    @spec check(TUI.t()) :: TUI.t()
    def check(%TUI{session_view: %{mcp_trust: %{store: store, cwd: cwd} = trust}} = state)
        when is_binary(store) and is_binary(cwd) do
      app = self()
      # A decision is one digest over the servers asked about. Asked over
      # more servers than the extension gates, it would record a digest the
      # extension never matches: the servers stay held as "changed" on every
      # start, while this question, finding its own set trusted, never
      # comes back to fix it.
      except = Map.get(trust, :except, [])

      Task.start(fn ->
        send(app, {:mcp_trust_check, MCPExtension.project_trust(cwd, store, except: except)})
      end)

      History.hold(state, :trust)
    end

    def check(state), do: state

    @doc false
    @spec checked(TUI.t(), map() | nil) :: TUI.t()
    def checked(state, nil), do: History.answered(state, :trust)

    def checked(%TUI{modal: nil} = state, pending),
      do: %{state | modal: %{kind: :trust, pending: pending, choice: 0}}

    # Something else holds the keyboard; the question waits for the next start
    # rather than stacking on top of it.
    def checked(state, _pending), do: History.answered(state, :trust)

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(%ExRatatui.Event.Key{code: code} = event, state) do
      case {code, Keys.action(state.status.keys, event)} do
        {_code, :previous} ->
          {:noreply, move(state, -1)}

        {_code, :next} ->
          {:noreply, move(state, 1)}

        {digit, _action} when digit in ["1", "2", "3"] ->
          {:noreply, decide(state, String.to_integer(digit) - 1)}

        {_code, :submit} ->
          {:noreply, decide(state, state.modal.choice)}

        {_code, action} when action in [:dismiss, :interrupt] ->
          {:noreply, decide(state, 2)}

        _other ->
          {:noreply, state}
      end
    end

    @doc false
    @spec paste(term(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(_event, state), do: {:noreply, state}

    # The decision is recorded, and trusted servers have started, before
    # the staged queue goes.
    @doc false
    @spec result(TUI.t(), atom(), term(), String.t()) :: TUI.t()
    def result(state, decision, result, file),
      do: state |> said(decision, result, file) |> History.answered(:trust)

    defp said(state, :trusted, :ok, file),
      do:
        Transcript.say(
          state,
          :lmx,
          "trusted the MCP servers in #{Sanitize.visible(file)} · starting them"
        )

    defp said(state, :trusted, {:error, :busy}, file),
      do:
        Transcript.say(
          state,
          :notice,
          "trusted the MCP servers in #{Sanitize.visible(file)}; they start with the next session because this one is busy"
        )

    defp said(state, :denied, :ok, file),
      do:
        Transcript.say(
          state,
          :lmx,
          "the MCP servers in #{Sanitize.visible(file)} will not be started"
        )

    defp said(state, _decision, {:error, reason}, file),
      do:
        Transcript.say(
          state,
          :notice,
          "could not record the decision about #{Sanitize.visible(file)}: #{inspect(reason)}"
        )

    defp said(state, _decision, _result, _file), do: state

    defp move(state, by),
      do: put_in(state.modal.choice, Integer.mod(state.modal.choice + by, length(@choices)))

    defp decide(state, index) do
      {decision, _label} = Enum.at(@choices, index)
      pending = state.modal.pending
      state = Modal.close(state)

      case decision do
        :later ->
          state
          |> Transcript.say(
            :lmx,
            "MCP servers in #{Sanitize.visible(pending.file)} stay off for now · lmx asks again next time"
          )
          |> History.answered(:trust)

        decision ->
          record(state, pending, decision)
      end
    end

    defp record(state, pending, decision) do
      app = self()
      session = state.session
      store = state.session_view.mcp_trust.store

      Task.start(fn ->
        result =
          with :ok <- TrustStore.record(store, pending.workspace, pending.servers, decision),
               do: start(decision, session, pending.servers)

        send(app, {:mcp_trust_result, decision, result, pending.file})
      end)

      state
    end

    # Trusted servers start now, marked as trusted: the variables they read
    # were the ones the question listed. See the moduledoc.
    defp start(:trusted, session, servers),
      do: Session.add_mcp_servers(session, Enum.map(servers, &Map.put(&1, "source", "trusted")))

    defp start(_denied, _session, _servers), do: :ok

    @doc false
    @spec render(TUI.t(), map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      pending = state.modal.pending
      theme = Screen.theme(state)
      muted = %Style{fg: theme.text.muted}

      # `Lemieux.MCP.Trust.describe/1` is one description per server, in
      # order; the server itself is what the command line is quoted from.
      servers =
        pending.servers
        |> Enum.zip(pending.description)
        |> Enum.flat_map(fn {config, server} ->
          what =
            if server.url,
              do: "connects to #{Sanitize.visible(to_string(server.url))}",
              else: "runs #{MCPCommands.command_line(config)}"

          env =
            if server.env == [],
              do: [],
              else: [
                Line.new([
                  Span.new("    reads " <> Enum.map_join(server.env, ", ", &Sanitize.visible/1),
                    style: muted
                  )
                ])
              ]

          [
            Line.new([
              Span.new("  • #{Sanitize.visible(server.name)}",
                style: %Style{fg: theme.text.plain, modifiers: [:bold]}
              ),
              Span.new(" · #{Sanitize.visible(server.transport)} · #{what}")
            ])
            | env
          ]
        end)

      file = Sanitize.visible(pending.file)

      why =
        case pending.status do
          :changed -> "#{file} changed since you last decided about it."
          :denied -> "#{file} was declined before."
          _untrusted -> "#{file} declares MCP servers nobody has reviewed yet."
        end

      choices =
        @choices
        |> Enum.with_index()
        |> Enum.map(fn {{_decision, label}, index} ->
          selected? = index == state.modal.choice

          style =
            if selected?, do: %Style{fg: Screen.accent(state), modifiers: [:bold]}, else: %Style{}

          Line.new([
            Span.new("#{if selected?, do: "›", else: " "} #{index + 1}. #{label}", style: style)
          ])
        end)

      lines =
        [
          Line.new([Span.new(why)]),
          Line.new([
            Span.new("Starting them runs these commands and connects to these servers:",
              style: muted
            )
          ]),
          Line.new([])
        ] ++
          servers ++ [Line.new([])] ++ choices

      height =
        min(length(lines) + 4, max(panes.input.y + panes.input.height - panes.transcript.y, 6))

      bottom = panes.input.y + panes.input.height
      area = %Rect{x: panes.input.x, y: bottom - height, width: panes.input.width, height: height}

      panel = %Paragraph{
        text: lines,
        wrap: true,
        block: %Block{
          title: " Start this repository's MCP servers? ",
          titles: [
            %Block.Title{
              content: " ↑↓ choose · Enter confirm · Esc not now ",
              position: :bottom,
              alignment: :right
            }
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: theme.voices.notice},
          padding: {1, 1, 0, 0}
        }
      }

      [{%Clear{}, area}, {panel, area}]
    end
  end
end
