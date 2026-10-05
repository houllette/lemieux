defmodule Lemieux.TUI.LightPaletteTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Frame
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI
  alias Lemieux.TUI.Colour
  alias Lemieux.TUI.Theme

  # The colours the ask_user panel and the model menu drew by name, read
  # through the theme instead, so the palette a pale terminal gets can
  # re-pick them. Everything is drawn through `TUI.render/2`, the way the
  # screen draws it, rather than by calling the panel on its own.

  @frame %Frame{width: 80, height: 24}
  @white {255, 255, 255}

  defp batch do
    %{
      call_id: "ask-2",
      ask_user: true,
      questionnaire: true,
      question: "Which database?",
      options: [],
      questions: [
        %{
          question_id: "database",
          question: "Which database?",
          options: [%{id: "pg", label: "Postgres"}, %{id: "sqlite", label: "SQLite"}],
          multiple: false
        },
        %{
          question_id: "region",
          question: "Which region?",
          options: [%{id: "east", label: "East"}, %{id: "west", label: "West"}],
          multiple: false
        }
      ]
    }
  end

  defp asked(fields),
    do: [session: fake_session(snapshot("01SESSION"))] |> Keyword.merge(fields) |> tui()

  # Both questions answered with their first option, and the review showing.
  defp review(state), do: state |> info({:question, batch()}) |> press("enter") |> press("enter")

  defp span(state, content) do
    state
    |> TUI.render(@frame)
    |> Enum.flat_map(fn
      {%Paragraph{text: [%Line{} | _rest] = lines}, _rect} -> lines
      _widget -> []
    end)
    |> Enum.flat_map(& &1.spans)
    |> Enum.find(&(&1.content == content)) ||
      flunk("nothing on the screen reads #{inspect(content)}")
  end

  defp deprecated_badge(state) do
    assert [%Line{spans: [_name, badge]}] = suggestions(state).items
    badge
  end

  defp model_menu(fields) do
    [models: ["openai:gpt-4"], model_now: ~U[2026-09-24 00:00:00Z]]
    |> Keyword.merge(fields)
    |> tui()
    |> type("/model ")
  end

  defp on_white(colour), do: Colour.contrast(Colour.rgb(colour), @white)

  describe "the ask_user panel" do
    test "draws answers in the light palette in a colour that reads on white" do
      answer = asked(theme: "light") |> review() |> span("    Postgres")

      assert answer.style.fg == Theme.light().children.ok
      assert on_white(answer.style.fg) >= 4.5
    end

    test "draws a note under its option the same way" do
      note =
        asked(theme: "light")
        |> info({:question, batch()})
        |> press("n")
        |> type("Keep the existing service")
        |> press("enter")
        |> press("left")
        |> span("      ↳ Keep the existing service")

      assert note.style.fg == Theme.light().children.ok
    end

    # The answer stays apart from the accent on the row being chosen: a
    # palette whose accent is its `children.ok` gets the question's voice.
    test "an accent in the answers' colour turns them to the question's voice" do
      light = Theme.light()
      forest = %{light | name: "forest", accent: light.children.ok}

      answer =
        asked(theme: "forest", themes: %{"forest" => forest})
        |> review()
        |> span("    Postgres")

      assert answer.style.fg == light.voices.question
    end

    test "draws answers without colour in mono" do
      assert (asked(theme: "mono") |> review() |> span("    Postgres")).style.fg == nil
    end
  end

  describe "the model menu" do
    test "marks a deprecated model in the light palette's alert colour, legible on white" do
      badge = deprecated_badge(model_menu(theme: "light"))

      assert badge.content == "deprecated"
      assert badge.style.fg == Theme.light().voices.alert
      assert on_white(badge.style.fg) >= 4.5
    end

    test "marks it without colour in mono" do
      assert deprecated_badge(model_menu(theme: "mono")).style.fg == nil
    end
  end
end
