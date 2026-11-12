if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.MCPPanel do
    @moduledoc "Draws the compact MCP server list and selected server details."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI.Takeover
    alias Lemieux.TUI.Window

    @doc "Draws the server panel above the transcript and input."
    @spec render(flow :: map(), panes :: map(), accent :: term()) :: [{term(), Rect.t()}]
    def render(%{mode: mode} = flow, panes, accent) when mode in [:tools, :tool] do
      area = Takeover.area(panes, 24)

      body = %Rect{
        x: area.x + 2,
        y: area.y + 2,
        width: max(area.width - 4, 1),
        height: max(area.height - 4, 1)
      }

      rows = inspection_rows(flow, body.width, accent)
      offset = inspection_offset(flow, length(rows), body.height)
      footer = %Rect{x: body.x, y: area.y + area.height - 2, width: body.width, height: 1}

      Takeover.frame(area, " MCP · #{flow.inspection_name} ") ++
        [
          {%Paragraph{text: Enum.slice(rows, offset, body.height)}, body},
          {%Paragraph{
             text:
               if(mode == :tool,
                 do: "↑↓ / PgUp/PgDn scroll · Esc tools",
                 else: "↑↓ tools · Enter inspect · Esc servers"
               )
           }, footer}
        ]
    end

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
             text:
               "↑↓ · Enter tools · r reconnect · o on/off · a add · d remove · Shift+D delete · Esc close"
           }, footer}
        ]
    end

    @doc false
    @spec describe_tool(tool :: map()) :: String.t()
    def describe_tool(tool) do
      [
        "MCP name: #{tool.name}",
        "Model name: #{tool.model_name}",
        "Availability: #{tool.reason || "enabled"}",
        "",
        tool.description,
        "",
        "Input schema:",
        IO.iodata_to_binary(:json.format(tool.input_schema))
      ]
      |> Enum.join("\n")
    end

    @doc false
    @spec scroll(flow :: map(), panes :: map(), by :: integer()) :: map()
    def scroll(flow, panes, by) do
      area = Takeover.area(panes, 24)
      count = length(inspection_rows(flow, max(area.width - 4, 1), :white))
      offset = min(max(flow.detail_scroll + by, 0), max(count - max(area.height - 4, 1), 0))
      %{flow | detail_scroll: offset}
    end

    defp inspection_offset(%{mode: :tool} = flow, count, height),
      do: min(flow.detail_scroll, max(count - height, 0))

    defp inspection_offset(flow, _count, height), do: max(flow.tool_selected - height + 3, 0)

    defp inspection_rows(%{inspection: nil}, _width, _accent),
      do: [Line.new([Span.new("Loading cached tool catalog…")])]

    defp inspection_rows(%{mode: :tool} = flow, width, _accent) do
      case Enum.at(flow.inspection.tools, flow.tool_selected) do
        nil -> text_rows("Tool no longer available; Esc returns to tools.", width)
        tool -> text_rows(tool.detail_text, width)
      end
    end

    defp inspection_rows(flow, width, accent) do
      inspection = flow.inspection
      header = text_rows("#{flow.inspection_name}: #{inspection.server.status}", width)

      tools =
        inspection.tools
        |> Enum.with_index()
        |> Enum.map(fn {tool, index} ->
          selected? = flow.tool_selected == index
          style = if selected?, do: %Style{fg: accent, modifiers: [:bold]}, else: %Style{}

          Line.new([
            Span.new(
              "#{if selected?, do: "›", else: " "} #{tool.name} · #{tool.reason || "enabled"}",
              style: style
            )
          ])
        end)

      empty = if tools == [], do: text_rows(empty_reason(inspection.server), width), else: []
      notices = Enum.flat_map(inspection.notices, &text_rows(&1, width))
      header ++ tools ++ empty ++ notices
    end

    defp empty_reason(%{status: :connecting}),
      do: "Discovery is still connecting. Esc returns to servers; reopen after it settles."

    defp empty_reason(%{status: :disabled}),
      do: "This server is disabled for the session. Esc returns to server management."

    defp empty_reason(%{status: :needs_auth}),
      do: "Sign-in required. Esc returns to servers; r authorizes."

    defp empty_reason(%{error: error}) when is_binary(error),
      do: "Discovery failed: #{error}. Esc returns; r retries."

    defp empty_reason(%{status: :failed}), do: "Server disconnected. Esc returns; r retries."

    defp empty_reason(_server),
      do:
        "Connected; this server exposes no usable tools. Discovery notices follow when available."

    defp text_rows(text, width) do
      text
      |> String.split("\n")
      |> Enum.flat_map(&Window.wrap(&1, width))
      |> Enum.map(&Line.new([Span.new(&1)]))
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
