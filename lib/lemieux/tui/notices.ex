if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Notices do
    @moduledoc """
    Temporary setup and update notices, boxed inside the scrolling transcript.

    Reserving a strip above the transcript made its top and height jump when
    the startup box disappeared. This box is a display row instead: arrival,
    wrapping, selection and expiry use the conversation's viewport arithmetic.
    It is not a session entry and never becomes model context or saved history.

    The box closes five seconds after its newest item, or on Esc. A panel
    holding the keyboard pauses expiry; closing it starts five seconds again.
    Only the newest token can close it. Items are deduplicated and capped at
    twelve. A later notification brings the current box to the recent end,
    except during a streamed model block, which must stay contiguous.

    Warnings and errors retain their finding/remedy shape and semantic colours.
    HTTP(S) links remain clickable even when they wrap or the box is scrolled.
    A command's result, a start that failed, or a session that stopped remains
    ordinary transcript text; expiry removes only this temporary display row.
    """
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias Lemieux.TUI
    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Transcript
    alias Lemieux.TUI.Width
    alias Lemieux.TUI.Window

    @visible_ms 5_000
    @max_items 12
    @kinds [:info, :warning, :error]
    @markdown_link ~r/\[[^\]\n]+\]\(<?(https?:\/\/[^\s)>]+)>?\)/
    @bare_url ~r/https?:\/\/[^\s<>()\[\]]+/
    @type kind :: :info | :warning | :error
    @type item :: %{kind: kind(), text: String.t()}
    @type t :: %{
            items: [item()],
            id: reference() | nil,
            token: reference() | nil,
            timer: reference() | nil
          }

    @doc "An empty box, with no display row or running timer."
    @spec new() :: t()
    def new, do: %{items: [], id: nil, token: nil, timer: nil}

    @doc "Adds a nonblank, distinct item and restarts the box's five seconds."
    @spec say(state :: TUI.t(), kind :: kind(), text :: String.t()) :: TUI.t()
    def say(%TUI{} = state, kind, text) when kind in @kinds and is_binary(text) do
      item = %{kind: kind, text: String.trim(text)}
      notices = state.terminal.notices

      if item.text == "" or item in notices.items do
        state
      else
        notices = %{
          notices
          | items: Enum.take(notices.items ++ [item], -@max_items),
            id: notices.id || make_ref()
        }

        state |> publish(notices) |> restart_clock(notices)
      end
    end

    @doc "Adds each text as `say/3` does."
    @spec say_all(state :: TUI.t(), kind :: kind(), texts :: [String.t()] | nil) :: TUI.t()
    def say_all(state, kind, texts) when is_list(texts),
      do: Enum.reduce(texts, state, &say(&2, kind, &1))

    def say_all(state, _kind, nil), do: state

    defp publish(state, notices) do
      state = remove_box(state, state.terminal.notices.id)
      # A notification must not split an open Markdown/A2UI fence or the text
      # delta that will extend its head. Insert before that model segment.
      {newer, older} =
        if state.conversation.busy?,
          do: Enum.split_while(state.lines, &Blocks.model_row?/1),
          else: {[], state.lines}

      Transcript.splice(state, newer, [], [{:notice_box, notices.id, notices.items}], older)
    end

    defp restart_clock(state, notices) do
      cancel_timer(state.terminal.notices.timer)
      token = make_ref()
      timer = Process.send_after(self(), {:notices_expired, token}, @visible_ms)
      put_in(state.terminal.notices, %{notices | token: token, timer: timer})
    end

    defp cancel_timer(nil), do: :ok

    defp cancel_timer(timer) do
      Process.cancel_timer(timer)
      :ok
    end

    @doc false
    @spec expire(state :: TUI.t(), token :: reference()) :: {:noreply, TUI.t()}
    def expire(%TUI{modal: nil, terminal: %{notices: %{token: token}}} = state, token),
      do: {:noreply, dismiss(state)}

    def expire(state, _token), do: {:noreply, state}

    @doc "Restarts five seconds when a panel that held the keyboard closes."
    @spec resume(state :: TUI.t()) :: TUI.t()
    def resume(%TUI{terminal: %{notices: %{items: [_ | _]} = notices}} = state),
      do: restart_clock(state, notices)

    def resume(state), do: state

    @doc "Removes only the temporary display row, leaving the transcript pane fixed."
    @spec dismiss(state :: TUI.t()) :: TUI.t()
    def dismiss(state) do
      cancel_timer(state.terminal.notices.timer)

      state
      |> remove_box(state.terminal.notices.id)
      |> put_in([Access.key!(:terminal), :notices], new())
    end

    defp remove_box(state, nil), do: state

    defp remove_box(state, id) do
      {newer, rest} = Enum.split_while(state.lines, &(not match?({:notice_box, ^id, _items}, &1)))

      case rest do
        [row | older] -> Transcript.splice(state, newer, [row], [], older)
        [] -> state
      end
    end

    @doc "Items in the current box, oldest first."
    @spec items(state :: TUI.t()) :: [item()]
    def items(%TUI{terminal: %{notices: %{items: items}}}), do: items

    @doc "Width-only projection, shared by drawing, scroll accounting and link hit-testing."
    @spec lines(items :: [item()], width :: pos_integer(), theme :: Theme.t()) :: [Line.t()]
    def lines(items, width, theme),
      do: items |> tagged_lines(width, theme) |> Enum.map(&elem(&1, 0))

    defp tagged_lines(items, width, theme) do
      inner = if width >= 8, do: width - 4, else: width

      body =
        Enum.flat_map(items, fn item -> Enum.map(item_lines(item, inner, theme), &{&1, item}) end)

      frame(body, width, theme)
    end

    defp frame(body, width, _theme) when width < 8, do: body

    defp frame(body, width, theme) do
      muted = %Style{fg: theme.text.muted}
      title = %Style{fg: theme.accent, modifiers: [:bold]}

      top =
        Line.new([
          Span.new("╭─", style: muted),
          Span.new(" lmx ", style: title),
          Span.new(String.duplicate("─", width - 8) <> "╮", style: muted)
        ])

      bottom_label = if width >= 16, do: " esc closes ", else: ""

      bottom =
        Line.new([
          Span.new(
            "╰" <>
              String.duplicate("─", width - 2 - String.length(bottom_label)) <>
              bottom_label <> "╯",
            style: muted
          )
        ])

      [{top, nil}] ++ Enum.map(body, &framed_item(&1, width, muted)) ++ [{bottom, nil}]
    end

    defp framed_item({line, item}, width, style) do
      used = Enum.sum(Enum.map(line.spans, &Width.of(&1.content)))

      spans =
        [Span.new("│ ", style: style)] ++
          line.spans ++
          [Span.new(String.duplicate(" ", max(width - used - 3, 1)) <> "│", style: style)]

      {Line.new(spans), item}
    end

    @doc "A notice's HTTP(S) link at transcript depth, or :outside for ordinary transcript text."
    @spec link_at(state :: TUI.t(), depth :: non_neg_integer(), width :: pos_integer()) ::
            {:notice, String.t() | nil} | :outside
    def link_at(state, depth, width) do
      renderer = Screen.row_renderer(state, width)

      found =
        Enum.reduce_while(
          state.lines,
          depth,
          &find_link(&1, &2, renderer, width, Screen.theme(state))
        )

      case found do
        {:link, target} -> target
        _past_history -> :outside
      end
    end

    defp find_link(row, depth, renderer, width, theme) do
      height = length(renderer.(row, width))

      if depth < height,
        do: {:halt, {:link, row_link(row, height - 1 - depth, width, theme)}},
        else: {:cont, depth - height}
    end

    defp row_link({:notice_box, _id, items}, index, width, theme) do
      case Enum.at(tagged_lines(items, width, theme), index) do
        {_line, %{text: text}} -> {:notice, link(text)}
        _border -> {:notice, nil}
      end
    end

    defp row_link(_row, _index, _width, _theme), do: :outside

    defp item_lines(%{kind: :info, text: text}, width, theme),
      do: RichText.lines([{:model, text}], width, theme)

    defp item_lines(%{kind: :warning, text: text}, width, theme),
      do: marked(text, "⚠ ", theme.voices.notice, width)

    defp item_lines(%{kind: :error, text: text}, width, theme),
      do: marked(text, "✗ ", theme.voices.alert, width)

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
