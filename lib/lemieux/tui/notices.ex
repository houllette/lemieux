if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Notices do
    @moduledoc """
    What the screen has to say about its own setup, in a box at the top of
    the screen that closes itself.

    Startup used to write these as transcript rows: the permission banner,
    the workspace and configuration notices, which MCP servers connected and
    which could not, update and version notices. A row stays for the whole
    sitting and scrolls with the conversation, so the same lines about `lmx`
    itself sat between the person's own work every time the screen opened.
    They are true of the start, not of the conversation.

    So they go here instead. The box is drawn above the transcript while it
    has something to say, and closes ten seconds after its newest item
    arrived — a server that connects late gets its own ten seconds — or at
    once on Esc (`:dismiss`). Those ten seconds are only counted while
    nothing else holds the keyboard: a box whose time runs out behind a
    panel (`Lemieux.TUI.Modal`) stays, and gets ten seconds more once the
    panel closes (`resume/1`). Startup says the most important things it has
    — that tools run without asking, that commands are not sandboxed — at
    the moment a newcomer is busy with the first-run provider panel, and the
    box used to close while that panel was still open, before anybody could
    have read it. An item is info, a warning or an error: a
    warning is drawn as the transcript draws a notice (`⚠`, with what to do
    about it on a `↳` line), an error the same way in the alert colour, and
    info as plain text, so a Markdown link in it (`[changelog](https://…)`)
    is drawn the way links in answers are and a click on its item opens it.
    An item the box is already showing is not added twice.

    What answers something the person did stays in the transcript: a
    command's result, a start that failed, a session that stopped. Those are
    part of the sitting and have to be findable afterwards.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Window

    @visible_ms 10_000
    # Startup says a handful of things. A cap keeps a host that sends a notice
    # in a loop from growing the box, and the state, without bound.
    @max_items 12
    @kinds [:info, :warning, :error]
    @markdown_link ~r/\[[^\]\n]+\]\(<?(https?:\/\/[^\s)>]+)>?\)/
    @bare_url ~r/https?:\/\/[^\s<>()\[\]]+/

    @type kind :: :info | :warning | :error
    @type item :: %{kind: kind(), text: String.t()}
    @type t :: %{items: [item()], token: reference() | nil}

    @doc "An empty box: nothing to show and no timer running."
    @spec new() :: t()
    def new, do: %{items: [], token: nil}

    @doc """
    Adds `text` to the box and starts its ten seconds again. A blank text, or
    one the box is already showing, changes nothing.
    """
    @spec say(TUI.t(), kind(), String.t()) :: TUI.t()
    def say(%TUI{} = state, kind, text) when kind in @kinds and is_binary(text) do
      item = %{kind: kind, text: String.trim(text)}
      %{items: items} = notices = state.terminal.notices

      if item.text == "" or item in items,
        do: state,
        else: shown(state, %{notices | items: Enum.take(items ++ [item], -@max_items)})
    end

    @doc "Adds each of `texts` as `say/3` does."
    @spec say_all(TUI.t(), kind(), [String.t()] | nil) :: TUI.t()
    def say_all(state, kind, texts) when is_list(texts),
      do: Enum.reduce(texts, state, &say(&2, kind, &1))

    def say_all(state, _kind, nil), do: state

    # Only the newest item's timer closes the box: an older one expiring must
    # not take down what arrived after it.
    defp shown(state, notices) do
      token = make_ref()
      Process.send_after(self(), {:notices_expired, token}, @visible_ms)
      put_in(state.terminal.notices, %{notices | token: token})
    end

    # A panel holding the keyboard keeps the box open: its time is counted
    # again from when the panel closes (`resume/1`).
    @doc false
    @spec expire(TUI.t(), reference()) :: {:noreply, TUI.t()}
    def expire(%TUI{modal: nil, terminal: %{notices: %{token: token}}} = state, token),
      do: {:noreply, dismiss(state)}

    def expire(state, _token), do: {:noreply, state}

    @doc """
    Starts the box's ten seconds again, if it has anything to say: what
    closing a panel that held the keyboard does (`Lemieux.TUI.Modal.close/1`),
    so whatever was said while the panel was open is still there to read
    once it is gone.
    """
    @spec resume(state :: TUI.t()) :: TUI.t()
    def resume(%TUI{terminal: %{notices: %{items: [_ | _]} = notices}} = state),
      do: shown(state, notices)

    def resume(state), do: state

    @doc "Closes the box now. Its timer, still running, finds nothing to close."
    @spec dismiss(TUI.t()) :: TUI.t()
    def dismiss(state), do: put_in(state.terminal.notices, new())

    @doc "The items the box is showing, oldest first."
    @spec items(TUI.t()) :: [item()]
    def items(%TUI{terminal: %{notices: %{items: items}}}), do: items

    @doc """
    How many rows the box wants on a pane `width` wide with `available` rows:
    `0` when it has nothing to show, and never more than half of `available`.
    """
    @spec rows(TUI.t(), pos_integer(), non_neg_integer()) :: non_neg_integer()
    def rows(state, width, available) do
      case items(state) do
        [] -> 0
        _items -> min(length(laid_out(state, width)) + 2, max(div(available, 2), 3))
      end
    end

    @doc false
    @spec render(TUI.t(), Rect.t()) :: [{term(), Rect.t()}]
    def render(state, %Rect{height: height} = area) when height >= 3 do
      theme = Screen.theme(state)
      muted = %Style{fg: theme.text.muted}

      box = %Paragraph{
        text: state |> visible(area) |> Enum.map(&elem(&1, 0)),
        wrap: false,
        block: %Block{
          title: " lmx ",
          title_style: %Style{fg: Screen.accent(state), modifiers: [:bold]},
          titles: [
            %Block.Title{
              content: " esc closes ",
              position: :bottom,
              alignment: :right,
              style: muted
            }
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: muted,
          padding: {1, 1, 0, 0}
        }
      }

      [{box, area}]
    end

    def render(_state, _area), do: []

    @doc """
    The link of the item under `{x, y}`, when the point is inside the box
    drawn at `area` and that item has one; `nil` otherwise. Only HTTP(S)
    addresses: a notice's text can quote a server's error, and a scheme in
    that must not become a local command.
    """
    @spec link_at(TUI.t(), Rect.t() | nil, {integer(), integer()}) :: String.t() | nil
    def link_at(_state, nil, _point), do: nil

    def link_at(state, %Rect{} = area, {x, y}) do
      if inside?(area, x, y) do
        case Enum.at(visible(state, area), y - area.y - 1) do
          {_line, item} -> link(item.text)
          nil -> nil
        end
      end
    end

    @doc "Whether `{x, y}` is inside the box drawn at `area`, border included."
    @spec inside?(Rect.t() | nil, integer(), integer()) :: boolean()
    def inside?(nil, _x, _y), do: false

    def inside?(%Rect{} = area, x, y),
      do: x >= area.x and x < area.x + area.width and y >= area.y and y < area.y + area.height

    # The rows that fit, newest kept: what arrived last is what the person is
    # most likely looking for when the box cannot hold everything.
    defp visible(state, %Rect{} = area),
      do: state |> laid_out(area.width) |> Enum.take(-max(area.height - 2, 0))

    # Every row of every item, each with the item it belongs to, wrapped to
    # the box's inner width: the border and the padding take two columns on
    # each side.
    defp laid_out(state, width) do
      theme = Screen.theme(state)
      inner = max(width - 4, 1)

      Enum.flat_map(items(state), fn item ->
        item |> lines(inner, theme) |> Enum.map(&{&1, item})
      end)
    end

    defp lines(%{kind: :info, text: text}, width, theme),
      do: RichText.lines([{:model, text}], width, theme)

    defp lines(%{kind: :warning, text: text}, width, theme),
      do: marked(text, "⚠ ", theme.voices.notice, width)

    # In the alert colour, because an error drawn in the warning's amber
    # reads as one more thing to skip.
    defp lines(%{kind: :error, text: text}, width, theme),
      do: marked(text, "✗ ", theme.voices.alert, width)

    # A notice's shape, as the transcript draws one: what was found, then
    # what to do about it on a `↳` line of its own. Continuations hang under
    # the text rather than the mark, so each item reads as one block.
    defp marked(text, mark, colour, width) do
      style = %Style{fg: colour}

      case String.split(text, "; ", parts: 2) do
        [found, remedy] ->
          guttered(mark, found, width, %{style | modifiers: [:bold]}, style) ++
            guttered("↳ ", remedy, width, %{style | modifiers: [:dim]}, style)

        [found] ->
          guttered(mark, found, width, %{style | modifiers: [:bold]}, style)
      end
    end

    defp guttered(gutter, text, width, gutter_style, style) do
      text
      |> Window.wrap(max(width - 2, 1))
      |> Enum.with_index()
      |> Enum.map(fn
        {row, 0} -> Line.new([Span.new(gutter, style: gutter_style), Span.new(row, style: style)])
        {row, _continued} -> Line.new([Span.new("  "), Span.new(row, style: style)])
      end)
    end

    defp link(text) do
      case Regex.run(@markdown_link, text, capture: :all_but_first) || Regex.run(@bare_url, text) do
        [target | _rest] -> target
        nil -> nil
      end
    end
  end
end
