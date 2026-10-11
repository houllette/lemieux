defmodule Lemieux.TUI.CompletionMenuTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.List, as: Menu
  alias Lemieux.TUI.Colour
  alias Lemieux.TUI.CompletionMenu
  alias Lemieux.TUI.Theme

  defp menu(theme, selected \\ 0, gap \\ nil) do
    matches = for i <- 0..29, do: %{label: "Choice #{i}"}
    panes = %{transcript: %Rect{width: 80, height: 12}, input: %Rect{y: 12, height: 3}}

    [{%ExRatatui.Widgets.Clear{}, _}, {%Menu{} = menu, _}] =
      CompletionMenu.render(matches, panes,
        tabs: [],
        tab: nil,
        selected: selected,
        gap_after: gap,
        theme: theme,
        accent: theme.accent
      )

    menu
  end

  test "all choices cycle pale tints while selection retains its bold accent" do
    menu = menu(Theme.dark())
    colours = Enum.map(menu.items, fn %Line{spans: [span]} -> span.style.fg end)
    assert length(Enum.uniq(Enum.take(colours, 3))) == 3
    assert Enum.at(colours, 0) == Enum.at(colours, 3)
    assert Enum.all?(colours, &(Colour.contrast(Colour.rgb(&1), {0, 0, 0}) >= 4.5))
    assert menu.highlight_style.fg == Theme.dark().accent
    assert menu.highlight_style.modifiers == [:bold]
  end

  test "a choice keeps its tint when the visible window scrolls or has a separator" do
    initial = menu(Theme.dark())
    scrolled = menu(Theme.dark(), 12)

    assert Enum.find(initial.items, &(&1.spans |> hd() |> Map.fetch!(:content) == "Choice 5")) ==
             Enum.find(scrolled.items, &(&1.spans |> hd() |> Map.fetch!(:content) == "Choice 5"))

    separated = menu(Theme.dark(), 0, 1)
    assert Enum.at(initial.items, 2) == Enum.at(separated.items, 2)
  end

  test "light tints remain readable and mono remains uncoloured" do
    assert length(menu(Theme.light()).items) == 10
    assert length(menu(Theme.mono()).items) == 10

    for %Line{spans: [span]} <- menu(Theme.light()).items do
      assert Colour.contrast(Colour.rgb(span.style.fg), {255, 255, 255}) >= 4.5
    end

    for %Line{spans: [span]} <- menu(Theme.mono()).items, do: assert(span.style.fg == nil)
  end
end
