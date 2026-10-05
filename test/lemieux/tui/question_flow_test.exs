defmodule Lemieux.TUI.QuestionFlowTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.CellSession
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Tabs
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.AskUser
  alias Lemieux.TUI

  @frame %Frame{width: 80, height: 24}
  @moduletag :tmp_dir

  defp single do
    %{
      call_id: "ask-1",
      ask_user: true,
      question: "Which database?",
      options: [%{label: "Postgres", description: "Existing service"}, %{label: "SQLite"}]
    }
  end

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

  test "single question takes over the input and waits for explicit review submission" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> type("unsent draft")
    state = info(state, {:question, single()})

    assert state.tools.question_flow
    assert typed(state) == ""
    assert screen(state) =~ "Which database?"
    assert screen(state) =~ "Other · type your own answer"
    assert Enum.any?(TUI.render(state, @frame), fn {widget, _rect} -> match?(%Tabs{}, widget) end)

    state = state |> press("down") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "SQLite"
    refute_received {:answered, "ask-1", _answer}

    state = press(state, "enter")
    assert_receive {:answered, "ask-1", "SQLite"}
    assert state.tools.question_flow == nil
    assert typed(state) == "unsent draft"
  end

  test "batch advances through tabs, accepts Other, and allows editing before submission" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, batch()})
    state = press(state, "enter")
    assert screen(state) =~ "Which region?"

    state = state |> press("down") |> press("down") |> press("enter")
    assert state.tools.question_flow.other?
    state = state |> type("Central") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "Central"
    refute_received {:answered, "ask-2", _answer}

    state = state |> press("up") |> press("enter")
    assert screen(state) =~ "Which region?"
    state = state |> press("up") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "West"
    _state = press(state, "enter")

    assert_receive {:answered, "ask-2",
                    %{"answers" => [%{"selected" => ["pg"]}, %{"selected" => ["west"]}]}}
  end

  test "left and right arrows cycle questions and retain a typed Other draft" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, batch()})
    state = state |> press("down") |> press("down") |> press("enter") |> type("Central")
    state = press(state, "right")
    assert state.tools.question_flow.index == 1
    state = state |> press("right") |> press("right")
    assert state.tools.question_flow.index == 0
    assert state.tools.question_flow.other?
    assert typed(state) == "Central"
    assert screen(state) =~ "Central"
    state = press(state, "left")
    assert state.tools.question_flow.review?
  end

  test "a suggestion accepts a note and sends it with its selected option" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, batch()})
    state = state |> press("n") |> type("Keep the existing service") |> press("enter")
    assert state.tools.question_flow.index == 1

    assert get_in(state.tools.question_flow.answers, ["database", "option_notes", "pg"]) ==
             "Keep the existing service"

    _state = state |> press("enter") |> press("enter")

    assert_receive {:answered, "ask-2",
                    %{"answers" => [%{"selected" => ["pg"], "option_notes" => notes}, _]}}

    assert notes == %{"pg" => "Keep the existing service"}
  end

  test "Escape leaves note editing without cancelling the question panel" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, batch()})
    state = state |> press("n") |> type("Keep this path") |> press("esc")

    assert state.tools.question_flow
    assert state.tools.question_flow.note_option == nil
    refute_received :cancelled
    assert typed(state) == ""

    state = press(state, "n")
    assert typed(state) == "Keep this path"
    state = state |> press("esc") |> press("esc")
    assert state.tools.question_flow == nil
    assert_receive :cancelled
  end

  test "a single question sends the suggested answer together with its note" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, single()})
    state = state |> press("n") |> type("Only for local development") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "Postgres"
    assert screen(state) =~ "Only for local development"
    _state = press(state, "enter")
    assert_receive {:answered, "ask-1", "Postgres | Note: Only for local development"}
  end

  test "Escape and Ctrl-C close the whole questionnaire and restore the draft" do
    for key <- [{"esc", []}, {"c", ["ctrl"]}] do
      state = tui(session: fake_session(snapshot("01SESSION"))) |> type("unsent draft")
      state = info(state, {:question, batch()})
      {code, modifiers} = key

      state =
        if code == "esc",
          do: state |> press("right") |> press("right"),
          else: state |> press("down") |> press("down") |> press("enter") |> type("Central")

      state = press(state, code, modifiers)
      assert state.tools.question_flow == nil
      assert typed(state) == "unsent draft"
      assert_receive :cancelled
    end
  end

  test "multiple selection toggles choices and Other accepts spaces" do
    [first, second] = batch().questions
    first = %{first | multiple: true}
    question = %{batch() | questions: [first, second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    state = state |> press(" ") |> press("down") |> press(" ") |> press("enter")
    assert get_in(state.tools.question_flow.answers, ["database", "selected"]) == ["pg", "sqlite"]
    assert screen(state) =~ "Which region?"

    state = state |> press("down") |> press("down") |> press("enter")
    _state = state |> type("US Central") |> press("enter") |> press("enter")

    assert_receive {:answered, "ask-2",
                    %{
                      "answers" => [
                        %{"selected" => ["pg", "sqlite"]},
                        %{"text" => "US Central"}
                      ]
                    }}
  end

  test "checkbox questions show checked state and submit all selected ids" do
    [first, second] = batch().questions
    question = %{batch() | questions: [Map.put(first, :type, "multi_select"), second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    assert screen(state) =~ "[ ] Postgres"
    state = state |> press(" ") |> press("down") |> press(" ")
    assert screen(state) =~ "[x] Postgres"
    assert screen(state) =~ "[x] SQLite"
    _state = state |> press("enter") |> press("enter") |> press("enter")
    assert_receive {:answered, "ask-2", %{"answers" => [%{"selected" => ["pg", "sqlite"]}, _]}}
  end

  test "ranking requires every priority, preserves it across tabs, and sends ordered ids" do
    [first, second] = batch().questions
    question = %{batch() | questions: [Map.put(first, :type, "ranking"), second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    state = state |> press("2") |> press("enter")
    assert state.tools.question_flow.index == 0
    assert screen(state) =~ "[2] Postgres"

    state = state |> press("down") |> press("1") |> press("right") |> press("left")
    assert screen(state) =~ "[1] SQLite"
    assert get_in(state.tools.question_flow.answers, ["database", "ranked"]) == ["sqlite", "pg"]

    state = state |> press("enter") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "1. SQLite, 2. Postgres"
    _state = press(state, "enter")
    assert_receive {:answered, "ask-2", %{"answers" => [%{"ranked" => ["sqlite", "pg"]}, _]}}
  end

  test "ranking has no Other choice and wraps directly between ranked items" do
    [first, second] = batch().questions
    question = %{batch() | questions: [Map.put(first, :type, "ranking"), second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    refute screen(state) =~ "Other · type your own answer"
    state = state |> press("down") |> press("down")
    assert state.tools.question_flow.selected == 0
    assert state.tools.question_flow.other? == false
  end

  test "the panel stays one height and the transcript ends at its top" do
    [first, second] = batch().questions
    first = Map.put(first, :diagram, "long diagram\nsecond line\nthird line")
    payload = %{batch() | questions: [first, second]}

    state =
      tui(session: fake_session(snapshot("01SESSION")), lines: [{:model, "latest answer"}])
      |> info({:question, payload})

    {transcript, transcript_area} = hd(TUI.render(state, @frame))
    assert inspect(transcript.text) =~ "latest answer"

    panel_area = fn state ->
      Enum.find_value(TUI.render(state, @frame), fn
        {%Block{title: " ask_user · review before sending "}, area} -> area
        _other -> nil
      end)
    end

    first_area = panel_area.(state)
    assert transcript_area.y + transcript_area.height == first_area.y

    second = press(state, "right")
    review = press(second, "right")
    assert panel_area.(second) == first_area
    assert panel_area.(review) == first_area
  end

  test "ranking notes remain visible in review and apply to the whole question" do
    [first, second] = batch().questions
    question = %{batch() | questions: [Map.put(first, :type, "ranking"), second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})
    state = state |> press("n") |> type("Low migration risk") |> press("enter")
    state = state |> press("2") |> press("down") |> press("1") |> press("enter")
    state = state |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "note: Low migration risk"
    _state = press(state, "enter")

    assert_receive {:answered, "ask-2",
                    %{
                      "answers" => [
                        %{"ranked" => ["sqlite", "pg"], "notes" => "Low migration risk"},
                        _
                      ]
                    }}
  end

  test "free text and numeric questions use the editor and retain drafts across tabs" do
    payload = %{
      batch()
      | questions: [
          %{question_id: "reason", question: "Why?", type: "text", options: []},
          %{question_id: "days", question: "How many days?", type: "number", options: []}
        ]
    }

    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, payload})
    assert screen(state) =~ "Type your answer below"
    state = state |> type("Because it helps") |> press("right") |> press("left")
    assert typed(state) == "Because it helps"

    state = state |> press("enter") |> type("soon") |> press("enter")
    assert state.tools.question_flow.index == 1

    state =
      state
      |> press("backspace")
      |> press("backspace")
      |> press("backspace")
      |> press("backspace")

    state = state |> type("2.5") |> press("enter")
    assert state.tools.question_flow.review?
    _state = press(state, "enter")

    assert_receive {:answered, "ask-2",
                    %{"answers" => [%{"text" => "Because it helps"}, %{"number" => "2.5"}]}}
  end

  test "a multi-select note applies to the whole question without choosing an option" do
    [first, second] = batch().questions
    question = %{batch() | questions: [%{first | multiple: true}, second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})
    state = state |> press("n") |> type("Keep the migration path") |> press("enter")
    assert state.tools.question_flow.index == 0
    assert get_in(state.tools.question_flow.answers, ["database"]) == nil
    state = state |> press("down") |> press(" ") |> press("enter") |> press("enter")
    assert state.tools.question_flow.review?
    assert screen(state) =~ "note: Keep the migration path"
    _state = press(state, "enter")

    assert_receive {:answered, "ask-2",
                    %{
                      "answers" => [
                        %{"selected" => ["sqlite"], "notes" => "Keep the migration path"},
                        %{"selected" => ["east"]}
                      ]
                    }}
  end

  test "Escape leaves a question-wide note draft available for later editing" do
    [first, second] = batch().questions
    question = %{batch() | questions: [Map.put(first, :type, "multi_select"), second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    state = state |> press("n") |> type("Keep migration small") |> press("esc")
    assert state.tools.question_flow
    assert state.tools.question_flow.note_option == nil
    refute_received :cancelled

    state = press(state, "n")
    assert typed(state) == "Keep migration small"
  end

  test "a diagram keeps its spacing and leaves the choices visible across tabs" do
    diagram = "  source ──▶ cache\n              │\n              ▼\n           provider"
    [first, second] = batch().questions
    first = Map.put(first, :diagram, diagram)
    question = %{batch() | questions: [first, second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    widgets = TUI.render(state, @frame)
    canvas = CellSession.new(@frame.width, @frame.height)
    :ok = CellSession.draw(canvas, widgets)
    cells = CellSession.take_cells(canvas).cells
    :ok = CellSession.close(canvas)

    painted = Enum.map_join(cells, & &1.symbol)
    assert painted =~ "  source ──▶ cache"
    assert painted =~ "              │"
    assert painted =~ "Other · type your own answer"

    panel_area =
      Enum.find_value(widgets, fn
        {%Block{title: " ask_user · review before sending "}, area} -> area
        _other -> nil
      end)

    other_tab = press(state, "tab")
    assert other_tab.tools.question_flow.index == 1

    other_area =
      Enum.find_value(TUI.render(other_tab, @frame), fn
        {%Block{title: " ask_user · review before sending "}, area} -> area
        _other -> nil
      end)

    assert other_area.height <= panel_area.height
  end

  test "each suggestion shows its own diagram to the right of the question" do
    [first, second] = batch().questions
    [postgres, sqlite] = first.options
    postgres = Map.put(postgres, :diagram, "request → Postgres")
    sqlite = Map.put(sqlite, :diagram, "request → SQLite")
    question = %{batch() | questions: [%{first | options: [postgres, sqlite]}, second]}
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, question})

    widgets = TUI.render(state, @frame)

    {body, body_area} =
      Enum.find(widgets, fn
        {%Paragraph{text: lines, block: nil}, _area} when is_list(lines) ->
          Enum.any?(lines, &(inspect(&1) =~ "Which database?"))

        _other ->
          false
      end)

    assert %Paragraph{} = body

    assert {%Paragraph{block: %Block{title: " Example · Postgres "}}, side_area} =
             Enum.find(widgets, fn
               {%Paragraph{block: %Block{title: " Example · Postgres "}}, _area} -> true
               _other -> false
             end)

    assert side_area.x > body_area.x
    assert screen(state) =~ "request → Postgres"
    state = press(state, "down")
    assert screen(state) =~ "request → SQLite"
    refute screen(state) =~ "request → Postgres"
  end

  test "review answers have indented colored rows and the answer box follows the choices" do
    state = tui(session: fake_session(snapshot("01SESSION"))) |> info({:question, batch()})
    state = state |> press("enter") |> press("enter")
    widgets = TUI.render(state, @frame)

    {%Paragraph{text: lines}, body_area} =
      Enum.find(widgets, fn
        {%Paragraph{text: [first | _]}, _area} -> inspect(first) =~ "Review your answers"
        _other -> false
      end)

    text = Enum.map(lines, fn line -> line.spans |> Enum.map_join(& &1.content) end)

    assert Enum.find_index(text, &String.contains?(&1, "1. Which database?")) + 1 ==
             Enum.find_index(text, &String.contains?(&1, "    Postgres"))

    assert Enum.find_index(text, &String.contains?(&1, "2. Which region?")) + 1 ==
             Enum.find_index(text, &String.contains?(&1, "    East"))

    answer_line = Enum.find(lines, fn line -> hd(line.spans).content =~ "    Postgres" end)
    assert hd(answer_line.spans).style.fg == :green

    {_, footer_area} =
      Enum.find(widgets, fn
        {%Paragraph{block: %Block{title: " Answer "}}, _area} -> true
        _other -> false
      end)

    assert footer_area.y - (body_area.y + body_area.height) == 1
  end

  test "reattaching restores the panel, and an external resolution dismisses it" do
    question = single()
    pending = [%{call_id: "ask-1", kind: :question, payload: question}]
    waiting = snapshot("02WAITING") |> Map.put(:status, :busy) |> Map.put(:pending, pending)
    session = fake_session(waiting)

    assert {:ok, state} =
             TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end, size: {80, 24})

    assert state.tools.question_flow
    assert screen(state) =~ "Which database?"

    entry =
      Entry.new(:tool_result, %{"call_id" => "ask-1", "name" => "ask_user", "output" => "SQLite"})

    state = info(state, {:entry, entry})
    assert state.tools.question_flow == nil
  end

  test "a real parked batch waits for TUI review before the provider receives answers", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    questions = [
      %{
        "id" => "database",
        "question" => "Which database?",
        "options" => [
          %{"id" => "pg", "label" => "Postgres"},
          %{"id" => "sqlite", "label" => "SQLite"}
        ]
      },
      %{
        "id" => "region",
        "question" => "Which region?",
        "options" => [%{"id" => "east", "label" => "East"}, %{"id" => "west", "label" => "West"}]
      }
    ]

    provider =
      Scripted.new([
        [
          {:tool_call, %{id: "ask-3", name: "ask_user", arguments: %{"questions" => questions}}},
          {:done, :tool_calls}
        ],
        [{:text_delta, "received"}, {:done, :stop}]
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(dir),
        model: "test:model",
        subscriber: self(),
        tools: [AskUser]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Ask me")
    assert_receive {:lemieux, ^id, {:question, payload}}
    assert payload.call_id == "ask-3"
    assert length(Scripted.requests(provider)) == 1

    state = tui(session: session, id: id) |> info({:question, payload})
    state = state |> press("enter") |> press("down") |> press("enter")
    assert state.tools.question_flow.review?
    assert length(Scripted.requests(provider)) == 1

    _state = press(state, "enter")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    [_first, second] = Scripted.requests(provider)
    result = Enum.find(second.entries, &(&1.type == :tool_result))

    assert result.payload["structured_content"]["answers"] == [
             %{
               "question_id" => "database",
               "status" => "answered",
               "kind" => "selection",
               "selected" => ["pg"]
             },
             %{
               "question_id" => "region",
               "status" => "answered",
               "kind" => "selection",
               "selected" => ["west"]
             }
           ]
  end
end
