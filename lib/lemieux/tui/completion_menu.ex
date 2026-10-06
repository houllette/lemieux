# Completion widgets depend on the optional terminal package. Keep this adapter
# absent when an embedding host installs Lemieux without the TUI dependency.
if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.CompletionMenu do
    @moduledoc """
    Draws a bounded suggestion menu from choices the TUI has already prepared.

    The caller owns query matching, selection changes, and the session. This
    module owns only menu geometry, the visible slice, labels, tabs, and the
    counts on its borders. Slicing here, rather than letting Ratatui scroll a
    full list independently, keeps the hidden-option counts equal to the rows
    actually drawn. A model's personal-choice separator occupies an extra row
    but is never a selectable option.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.List, as: CommandList
    alias ExRatatui.Widgets.Tabs
    alias Lemieux.TUI.ModelChoices
    alias Lemieux.TUI.Theme

    @completion_rows 20

    @doc """
    Returns the popup widgets for prepared choices, or none when space is too small.

    `opts` carries what the caller already decided — `:tabs`, `:tab`,
    `:tab_rows`, `:selected`, `:gap_after` and `:accent` — and `:theme`, the
    palette a deprecated model's badge is drawn from: the dark one when
    absent. With tabs, `:tab_label` turns a tab into its title (the model
    picker's route labels by default), `:noun` is what the list holds
    (`"models"`) and `:tab_hint` says how to switch (`"shift-tab routes"`).
    """
    @spec render(matches :: [map()], panes :: map(), opts :: keyword()) :: [{term(), Rect.t()}]
    def render(matches, %{transcript: pane, input: input}, opts) do
      tabs = Keyword.fetch!(opts, :tabs)
      tab_rows = if tabs == [], do: 0, else: 1
      noun = Keyword.get(opts, :noun, "models")

      if (matches == [] and tabs == []) or pane.height < 3 + tab_rows do
        []
      else
        total = length(matches)
        gap_after = Keyword.fetch!(opts, :gap_after)
        gap_rows = if is_integer(gap_after), do: 1, else: 0

        desired_rows =
          if tabs == [], do: total + gap_rows, else: Keyword.fetch!(opts, :tab_rows)

        content_height =
          max(desired_rows, 1)
          |> min(@completion_rows)
          |> min(max(pane.height - 2 - tab_rows, 1))

        height = content_height + 2 + tab_rows
        y = completion_y(pane, input, height)
        selected = if total > 0, do: min(Keyword.fetch!(opts, :selected), total - 1)

        {items, visible_selection, above, below} =
          completion_window(
            matches,
            selected,
            content_height,
            gap_after,
            Keyword.get_lazy(opts, :theme, &Theme.default/0),
            noun
          )

        area = %Rect{x: pane.x, y: y, width: pane.width, height: height}
        list_area = %Rect{area | y: y + tab_rows, height: height - tab_rows}
        accent = Keyword.fetch!(opts, :accent)

        list = %CommandList{
          items: items,
          selected: visible_selection,
          highlight_symbol: "› ",
          # Ratatui applies selected-row foreground after span styles. Leave
          # it unset for a deprecated model so its red badge remains red.
          highlight_style: completion_highlight(accent, Enum.at(matches, selected || 0)),
          scroll_padding: 0,
          block: %Block{
            title:
              completion_title(
                selected,
                length(items),
                total,
                tabs,
                noun,
                Keyword.get(opts, :tab_hint, "shift-tab routes")
              ),
            titles: completion_overflow_titles(above, below),
            borders: [:all],
            border_type: :rounded
          }
        }

        [{%Clear{}, area}] ++
          completion_tabs(
            tabs,
            Keyword.fetch!(opts, :tab),
            Keyword.get(opts, :tab_label, &ModelChoices.tab_label/1),
            accent,
            pane,
            y
          ) ++
          [{list, list_area}]
      end
    end

    defp completion_y(pane, input, height) do
      if pane.y >= input.y + input.height,
        do: pane.y,
        else: pane.y + max(pane.height - height, 0)
    end

    defp completion_items(matches, gap_after, first, theme) do
      matches
      |> Enum.with_index(first)
      |> Enum.map(fn {match, index} -> completion_item(match, index == gap_after, theme) end)
    end

    defp completion_window([], _selected, _rows, _gap_after, _theme, noun),
      do: {["No matching #{noun}"], nil, 0, 0}

    defp completion_window(matches, selected, rows, gap_after, theme, _noun) do
      total = length(matches)

      heights =
        0..(total - 1)
        |> Enum.map(fn index -> if index == gap_after and rows > 1, do: 2, else: 1 end)
        |> List.to_tuple()

      padding = if selected < total - 1 and rows > elem(heights, selected), do: 1, else: 0
      first = completion_first(heights, selected, rows - padding, selected + 1)
      count = completion_count(heights, first, rows, total)

      items = matches |> Enum.slice(first, count) |> completion_items(gap_after, first, theme)
      {items, selected - first, first, total - first - count}
    end

    defp completion_first(_heights, -1, _remaining, first), do: first

    defp completion_first(heights, index, remaining, first) do
      cost = elem(heights, index)

      if cost <= remaining,
        do: completion_first(heights, index - 1, remaining - cost, index),
        else: first
    end

    defp completion_count(_heights, index, _remaining, total) when index >= total, do: 0

    defp completion_count(heights, index, remaining, total) do
      cost = elem(heights, index)

      if cost <= remaining,
        do: 1 + completion_count(heights, index + 1, remaining - cost, total),
        else: 0
    end

    defp completion_overflow_titles(above, below) do
      completion_overflow_title(above, :above) ++ completion_overflow_title(below, :below)
    end

    defp completion_overflow_title(0, _direction), do: []

    defp completion_overflow_title(count, :above) do
      [
        %Block.Title{
          content: " ↑ #{count} more #{option_word(count)} above ",
          position: :top,
          alignment: :right
        }
      ]
    end

    defp completion_overflow_title(count, :below) do
      [
        %Block.Title{
          content: " ↓ #{count} more #{option_word(count)} below ",
          position: :bottom,
          alignment: :right
        }
      ]
    end

    defp option_word(1), do: "option"
    defp option_word(_count), do: "options"

    defp completion_tabs([], _tab, _label, _accent, _pane, _y), do: []

    defp completion_tabs(tabs, tab, label, accent, pane, y) do
      tab_area = %Rect{x: pane.x + 1, y: y, width: max(pane.width - 2, 1), height: 1}

      [
        {%Tabs{
           titles: Enum.map(tabs, label),
           selected: Enum.find_index(tabs, &(&1 == tab)),
           highlight_style: %Style{fg: accent, modifiers: [:bold]},
           divider: "│"
         }, tab_area}
      ]
    end

    defp completion_title(_selected, _shown, 0, _tabs, _noun, _hint), do: " no matches "

    defp completion_title(selected, shown, total, [], _noun, _hint),
      do: completions_title(selected, shown, total)

    defp completion_title(_selected, shown, total, _tabs, noun, hint) when shown >= total,
      do: " #{noun} · #{hint} "

    defp completion_title(selected, _shown, total, _tabs, noun, hint),
      do: " #{noun} #{selected + 1}/#{total} · #{hint} "

    defp completion_item(match, false, theme), do: completion_label(match, theme)

    defp completion_item(match, true, theme) do
      line =
        case completion_label(match, theme) do
          %Line{} = line -> line
          label -> Line.new([Span.new(label)])
        end

      Text.new([line, Line.new([])])
    end

    # The badge is in the alert voice: red in the dark palette, as it always
    # was, and in the light one a red that reads on white (5.4:1), where the
    # named `:red` it used to be is whatever red the terminal's palette holds,
    # which no theme could re-pick and `mono` could not take away.
    defp completion_label(%{label: label, deprecated?: true}, theme) do
      prefix = String.replace_suffix(label, "deprecated", "")

      Line.new([
        Span.new(prefix),
        Span.new("deprecated", style: %Style{fg: theme.voices.alert})
      ])
    end

    defp completion_label(%{label: label}, _theme), do: label
    defp completion_highlight(_accent, %{deprecated?: true}), do: %Style{modifiers: [:bold]}
    defp completion_highlight(accent, _match), do: %Style{fg: accent, modifiers: [:bold]}

    defp completions_title(_selected, shown, total) when shown >= total, do: " completions "

    defp completions_title(selected, _shown, total),
      do: " completions #{selected + 1}/#{total} "
  end
end
