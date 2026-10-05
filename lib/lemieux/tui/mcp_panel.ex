if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.MCPPanel do
    @moduledoc "Draws the compact MCP server list and selected server details."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI.Takeover

    @doc "Draws the server panel above the transcript and input."
    @spec render(flow :: map(), panes :: map(), accent :: term()) :: [{term(), Rect.t()}]
    def render(flow, panes, accent) do
      height = min(max(length(flow.statuses) + 11, 15), 18)
      area = Takeover.area(panes, height)

      body = %Rect{
        x: area.x + 2,
        y: area.y + 2,
        width: max(area.width - 4, 1),
        height: max(area.height - 5, 1)
      }

      footer = %Rect{x: area.x + 2, y: area.y + area.height - 2, width: body.width, height: 1}

      Takeover.frame(area, " MCP servers ") ++
        [
          {%Paragraph{text: body(flow, accent, body.height), wrap: true}, body},
          {%Paragraph{
             text: "↑↓ · r reconnect · o on/off · a add · d remove · Shift+D delete · Esc close"
           }, footer}
        ]
    end

    defp body(%{statuses: []} = flow, _accent, _height),
      do: "No MCP servers configured.\n\nPress a to add a server.#{notice(flow)}"

    defp body(flow, accent, height) do
      heading = [Line.new([Span.new("Configured servers")]), Line.new([])]
      visible_count = max(height - 6, 1)
      offset = max(flow.selected - visible_count + 1, 0)
      visible = Enum.slice(flow.statuses, offset, visible_count)

      servers =
        visible
        |> Enum.with_index(offset)
        |> Enum.map(fn {status, index} ->
          selected? = flow.selected == index
          marker = if(selected?, do: "›", else: " ")
          style = if(selected?, do: %Style{fg: accent, modifiers: [:bold]}, else: %Style{})
          state = condition(status)

          Line.new([
            Span.new("#{marker} #{status.name}", style: style),
            Span.new("  ·  #{status.transport}  ·  #{status.tool_count} tools#{state}")
          ])
        end)

      heading ++ servers ++ status_lines(flow)
    end

    # What the session last said about the server: a connection still
    # running, one waiting for somebody to sign in, one that failed, or off.
    defp condition(%{status: :connecting}), do: " · connecting…"
    defp condition(%{status: :needs_auth}), do: " · needs sign-in (r)"
    defp condition(%{status: :failed}), do: " · failed"
    defp condition(%{enabled?: false}), do: " · off"
    defp condition(_status), do: ""

    defp status_lines(flow) do
      selected = Enum.at(flow.statuses, flow.selected)

      details =
        case selected do
          nil ->
            []

          %{enabled?: false} ->
            [Line.new([]), Line.new([Span.new("Off for this session")])]

          %{status: :needs_auth} ->
            [
              Line.new([]),
              Line.new([
                Span.new("Waiting for you to sign in. Press r to open the authorization page.")
              ])
            ]

          %{error: error} when is_binary(error) ->
            [Line.new([]), Line.new([Span.new("Connection error: #{error}")])]

          _server ->
            []
        end

      if flow.notice,
        do: details ++ [Line.new([]), Line.new([Span.new(flow.notice)])],
        else: details
    end

    defp notice(%{notice: nil}), do: ""
    defp notice(%{notice: text}), do: "\n\n#{text}"
  end
end
