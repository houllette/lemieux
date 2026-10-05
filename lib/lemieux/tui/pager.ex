if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Pager do
    @moduledoc """
    Ctrl-O: a tool call's whole output, over the screen, with scrolling.

    A transcript row keeps the first and last two lines of what a command
    printed, which is right for reading along and wrong for reading the test
    failure in the middle. The durable transcript has all of it, but reading
    that meant leaving the screen. So the screen keeps the full text of the
    last few results (`Lemieux.TUI`'s `session_view.outputs`, bounded), and
    this draws one of them over the transcript until `q` or `Esc`.

    The newest output opens first; `←` and `→` step to older and newer ones.
    Scrolling is by rows of the wrapped text, the same unit the transcript
    scrolls in.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Screen

    # Enough outputs to go back through a turn's worth of commands, few
    # enough that holding them is not holding the transcript twice.
    @kept 20
    @max_bytes 2_000_000

    @doc """
    Remembers a finished tool call's output for the pager: newest first,
    `#{@kept}` at most, each cut at #{div(@max_bytes, 1_000_000)} MB.
    """
    @spec remember(TUI.t(), String.t(), String.t(), String.t()) :: TUI.t()
    def remember(state, _id, _name, ""), do: state

    def remember(state, id, name, text) when is_binary(text) do
      entry = %{id: id, name: name, text: bounded(text)}
      outputs = [entry | Enum.reject(state.session_view.outputs, &(&1.id == id))]
      put_in(state.session_view.outputs, Enum.take(outputs, @kept))
    end

    def remember(state, _id, _name, _text), do: state

    # Cut on a character boundary: half a UTF-8 sequence is not something a
    # span can draw.
    defp bounded(text) when byte_size(text) <= @max_bytes, do: text
    defp bounded(text), do: String.slice(text, 0, div(@max_bytes, 4)) <> "\n… cut for the pager"

    @doc false
    @spec open(TUI.t()) :: TUI.t()
    def open(%TUI{session_view: %{outputs: []}} = state),
      do: Flash.show(state, "no tool output to page through yet")

    def open(state), do: %{state | modal: %{kind: :pager, index: 0, offset: 0}}

    # The keys `less` taught everybody, and the ones the screen's own map
    # binds to closing things.
    @moves %{
      "q" => :close,
      "esc" => :close,
      "up" => :line_up,
      "k" => :line_up,
      "down" => :line_down,
      "j" => :line_down,
      "enter" => :line_down,
      "page_up" => :page_up,
      "page_down" => :page_down,
      " " => :page_down,
      "home" => :top,
      "g" => :top,
      "end" => :bottom,
      "G" => :bottom,
      "left" => :older,
      "[" => :older,
      "right" => :newer,
      "]" => :newer
    }

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(%ExRatatui.Event.Key{code: code} = event, state) do
      move =
        if Keys.action(state.status.keys, event) in [:pager, :interrupt, :dismiss],
          do: :close,
          else: Map.get(@moves, code)

      {:noreply, move(state, move)}
    end

    defp move(state, :close), do: Modal.close(state)
    defp move(state, :line_up), do: scroll(state, -1)
    defp move(state, :line_down), do: scroll(state, 1)
    defp move(state, :page_up), do: scroll(state, -page(state))
    defp move(state, :page_down), do: scroll(state, page(state))
    defp move(state, :top), do: put_in(state.modal.offset, 0)
    defp move(state, :bottom), do: scroll(state, :end)
    defp move(state, :older), do: step(state, 1)
    defp move(state, :newer), do: step(state, -1)
    defp move(state, nil), do: state

    @doc false
    @spec paste(term(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec render(TUI.t(), map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      area = area(panes)
      %{name: name, text: text} = current(state)
      count = length(state.session_view.outputs)
      position = "#{state.modal.index + 1}/#{count}"

      body = %Paragraph{
        text: text,
        wrap: true,
        scroll: {state.modal.offset, 0},
        block: %Block{
          title: " #{name} · output #{position} ",
          titles: [
            %Block.Title{
              content: " ↑↓ PgUp PgDn scroll · ←→ other outputs · q close ",
              position: :bottom,
              alignment: :center
            }
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: Screen.accent(state)},
          padding: {1, 1, 0, 0}
        }
      }

      [{%Clear{}, area}, {body, area}]
    end

    defp current(state), do: Enum.at(state.session_view.outputs, state.modal.index)

    # Everything the transcript and the input box cover: the pager is read,
    # not typed into, and a full-height page is the point of opening it.
    defp area(panes) do
      top = panes.transcript.y
      bottom = panes.input.y + panes.input.height

      %Rect{
        x: panes.transcript.x,
        y: top,
        width: panes.transcript.width,
        height: max(bottom - top, 3)
      }
    end

    defp page(state), do: max(area(Screen.panes(state)).height - 4, 1)

    defp scroll(state, :end), do: put_in(state.modal.offset, last_offset(state))

    defp scroll(state, by) do
      offset = (state.modal.offset + by) |> max(0) |> min(last_offset(state))
      put_in(state.modal.offset, offset)
    end

    # The rows the text wraps to at the panel's inner width, less one page:
    # scrolling stops when the last row reaches the bottom of the panel.
    defp last_offset(state) do
      area = area(Screen.panes(state))
      width = max(area.width - 4, 1)

      rows =
        current(state).text
        |> String.split("\n")
        |> Enum.map(&max(div(String.length(&1) + width - 1, width), 1))
        |> Enum.sum()

      max(rows - max(area.height - 2, 1), 0)
    end

    defp step(state, by) do
      index = (state.modal.index + by) |> max(0) |> min(length(state.session_view.outputs) - 1)
      %{state | modal: %{state.modal | index: index, offset: 0}}
    end
  end
end
