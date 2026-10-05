defmodule Lemieux.TUI.CommandsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Frame
  alias ExRatatui.Style
  alias ExRatatui.Widgets.List
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea
  alias Lemieux.CLI.SessionIndex
  alias Lemieux.Context
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Entry
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.ID.Shorthand
  alias Lemieux.TUI
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Theme
  alias Lemieux.TUITest.HostModel
  alias Lemieux.TUITest.ReadCard
  alias Lemieux.TUITest.Wave

  @frame %Frame{width: 80, height: 24}

  describe "/name and /color" do
    defp said(state, text), do: assert(screen(state) =~ text)

    defp rails(state) do
      {%Paragraph{block: block}, _rect} = Elixir.List.first(TUI.render(state, @frame))

      block.border_style.fg
    end

    test "a bare /name says what the session is called and how to change it" do
      said(command(tui(), "/name") |> press("enter"), "name: #{Shorthand.of("01SESSION")}")
      said(command(tui(), "/name") |> press("enter"), "/name TEXT")
    end

    # The caption changes; the handle does not, and the screen has to say so
    # or the next morning's `--resume` takes a name nothing has ever stored.
    test "a name relabels the header and warns that resume still takes the derived one" do
      state = command(tui(), "/name the refactor")

      assert screen(state) =~ "#{app_label()} · the refactor · test · model"
      refute screen(state) =~ Shorthand.of("01SESSION") <> " · test"
      said(state, "--resume still takes #{Shorthand.of("01SESSION")}")
    end

    test "default gives the derived name back" do
      state = tui() |> command("/name the refactor") |> command("/name default")

      assert screen(state) =~ "#{app_label()} · #{Shorthand.of("01SESSION")} · test · model"
    end

    # No `command/2`: Enter takes a value out of an open completion menu
    # before it sends anything, and `/color`'s menu is never empty — so the
    # bare form is the one a host dispatches,
    # where no menu is open to take from.
    test "a bare /color says what is on screen and what else it can draw" do
      state = %{type(tui(), "/color") | command_menu?: false} |> press("enter")

      said(state, "accent: cyan")
      said(state, "#{length(TUI.accents())} available")
    end

    test "a colour recolours the rails, the cursor and the completion highlight" do
      state = command(tui(), "/color magenta")

      assert rails(state) == :magenta

      assert {%Textarea{cursor_style: cursor}, _rect} =
               state |> TUI.render(@frame) |> Enum.at(2)

      assert cursor.bg == :magenta

      menu = state |> type("/mo") |> suggestions()
      assert menu.highlight_style.fg == :magenta
    end

    test "the composer cursor blinks and typing reveals it immediately" do
      {:ok, state} = TUI.mount(test_mode: {80, 24})
      tick = state.terminal.cursor_blink.tick
      assert is_reference(tick)

      assert {%Textarea{cursor_style: %Style{bg: :cyan}}, _rect} =
               state |> TUI.render(@frame) |> Enum.at(2)

      assert {:noreply, hidden} = TUI.handle_info({:cursor_blink, tick}, state)

      assert {%Textarea{cursor_style: %Style{fg: nil, bg: nil, modifiers: []}}, _rect} =
               hidden |> TUI.render(@frame) |> Enum.at(2)

      assert {:noreply, ^hidden} = TUI.handle_info({:cursor_blink, make_ref()}, hidden)

      visible = hidden |> press("x") |> press("left")
      assert typed(visible) == "x"
      assert caret(visible) == {0, 0}

      assert {%Textarea{cursor_style: %Style{bg: :cyan}}, _rect} =
               visible |> TUI.render(@frame) |> Enum.at(2)

      assert {:noreply, hidden_again} = TUI.handle_info({:cursor_blink, tick}, visible)
      assert hidden_again.terminal.cursor_blink.visible? == false

      painted = painted_cursor(visible)
      unpainted = painted_cursor(hidden_again)
      assert painted.symbol == "x"
      assert unpainted.symbol == "x"
      assert painted.bg == :cyan
      assert unpainted.bg == :reset
    end

    test "the empty composer hint starts in the same cell as typed text" do
      state = tui()
      assert hint(state) == "ask, or say what to change"
      assert painted_cursor(state).symbol == "a"

      hidden = put_in(state.terminal.cursor_blink.visible?, false)
      assert painted_cursor(hidden).symbol == "a"
      assert :dim in painted_cursor(hidden).modifiers

      typed = state |> press("z") |> press("left")
      assert hint(typed) == nil
      assert painted_cursor(typed).symbol == "z"
    end

    # These menus match on substring and Enter takes the highlighted row, so an
    # alphabetical list alone would have `/color gray` set the accent to
    # `dark_gray` — a command doing something other than what it says.
    test "a colour typed in full outranks the longer ones containing it" do
      assert (tui() |> type("/color gray") |> suggestions()).items == ["gray", "dark_gray"]

      assert rails(command(tui(), "/color gray")) == :gray
      assert rails(command(tui(), "/color magenta")) == :magenta

      # A prefix still beats a name that merely contains the query.
      assert (tui() |> type("/color light_m") |> suggestions()).items == ["light_magenta"]
    end

    # Elixir mode paints the rails magenta on its own. An explicit choice is
    # the one thing on the screen somebody asked for by name, so it wins.
    test "an explicit colour outranks the mode's own" do
      assert rails(tui(elixir_mode?: true)) == :magenta
      assert rails(command(tui(elixir_mode?: true), "/color green")) == :green
      assert rails(command(tui(), "/color default")) == :cyan
    end

    test "a six-digit hex colour is accepted and reported as one" do
      state = command(tui(), "/color #FF8800")

      assert rails(state) == {:rgb, 255, 136, 0}
      said(state, "accent: #ff8800")
    end

    test "anything else is refused with what would have worked" do
      state = command(tui(), "/color burgundy")

      assert rails(state) == :cyan
      said(state, "burgundy is not a colour I can draw")
      said(state, "#rrggbb")
    end

    test "the menu offers every colour it accepts, and the way back" do
      offered = tui() |> type("/color ") |> suggestions()

      assert offered.items == Enum.sort(["default" | TUI.accents()])

      # Every name the menu offers has to be one `/color` takes: a list that
      # drifted from the parser would offer a colour that then reports itself
      # as not a colour.
      for name <- TUI.accents() do
        said(command(tui(), "/color " <> name), "accent: #{name}")
      end
    end

    test "the british spelling is the same command" do
      assert rails(command(tui(), "/colour green")) == :green

      assert (tui() |> type("/colour ") |> suggestions()).items ==
               Enum.sort(["default" | TUI.accents()])
    end
  end

  describe "model configuration commands" do
    test "provider, bare model id, and effort selections reach their Session APIs" do
      session = fake_session(snapshot("01SESSION"))

      tui(session: session, providers: ["openai"])
      |> type("/provider openai")
      |> press("enter")

      assert_receive {:set_provider, "openai"}

      tui(session: session, models: ["test:other"])
      |> type("/model other")
      |> press("enter")

      assert_receive {:set_model, "test:other"}

      tui(session: session, efforts: ["high"])
      |> type("/effort high")
      |> press("enter")

      assert_receive {:set_reasoning_effort, "high"}
    end

    test "selecting a provider immediately opens its model completions" do
      session =
        fake_session(snapshot("01SESSION"),
          providers: ["test", "anthropic"],
          models: ["anthropic:claude-opus-5", "anthropic:claude-sonnet-5"]
        )

      state =
        tui(session: session, providers: ["test", "anthropic"])
        |> type("/provider anthropic")
        |> press("enter")

      assert_receive {:set_provider, "anthropic"}
      assert typed(state) == "/model "
      assert suggestions(state).items == ["claude-opus-5", "claude-sonnet-5"]
    end

    test "the model menu leads with current models and leaves deprecated ids selectable" do
      state =
        tui(
          models: ["openai:gpt-4", "openai:gpt-6-sol", "openai:gpt-6-astra"],
          model_now: ~U[2026-09-24 00:00:00Z]
        )
        |> type("/model ")

      assert ["gpt-6-sol", "gpt-6-astra", deprecated] = suggestions(state).items
      assert %ExRatatui.Text.Line{spans: [name, badge]} = deprecated
      assert name.content == "gpt-4 · "
      assert badge.content == "deprecated"
      assert badge.style.fg == :red

      selected =
        tui(models: ["openai:gpt-4"], model_now: ~U[2026-09-24 00:00:00Z])
        |> type("/model gpt-4")
        |> press("tab")

      assert typed(selected) == "/model gpt-4"
    end

    test "Ixway model tabs display Ixway by default and preserve the chosen route" do
      metadata = %{
        "ixway:gpt-5.6-luna" => %{kind: "concrete", route: "Automatic"},
        "ixway:openai:gpt-5.6-luna" => %{kind: "concrete", route: "openai"},
        "ixway:openai_codex:gpt-5.6-luna" => %{kind: "concrete", route: "openai_codex"}
      }

      state =
        tui(
          models: Map.keys(metadata),
          model_metadata: metadata
        )
        |> type("/model ")

      assert state.model_tab == "Automatic"
      assert suggestions(state).items == ["gpt-5.6-luna"]

      assert Enum.any?(TUI.render(state, @frame), fn
               {%ExRatatui.Widgets.Tabs{titles: ["Ixway", "OpenAI", "Codex"], selected: 0}, _rect} ->
                 true

               _other ->
                 false
             end)

      codex = state |> press("back_tab") |> press("back_tab")
      assert codex.model_tab == "openai_codex"
      assert suggestions(codex).items == ["gpt-5.6-luna"]
      filled = press(codex, "tab")
      assert typed(filled) == "/model openai_codex:gpt-5.6-luna"
      assert suggestions(filled) == nil

      searched =
        tui(models: Map.keys(metadata), model_metadata: metadata)
        |> type("/model openai_codex:gpt-5.6-luna")

      assert searched |> press("tab") |> typed() == "/model openai_codex:gpt-5.6-luna"

      session =
        snapshot("01SESSION")
        |> Map.merge(%{model: "ixway:gpt-5.6-luna", provider: "ixway"})
        |> fake_session(model_metadata: metadata, efforts: [])

      selected =
        tui(
          session: session,
          models: Map.keys(metadata),
          model_metadata: metadata,
          conversation: Lemieux.Conversation.new(model: "ixway:gpt-5.6-luna")
        )
        |> type("/model ")
        |> press("back_tab")
        |> press("back_tab")
        |> press("enter")

      assert_receive {:set_model, "ixway:openai_codex:gpt-5.6-luna"}
      assert typed(selected) == ""
      assert suggestions(selected) == nil
      assert selected.model_tab == "Automatic"
    end

    test "Enter selects a model from the default Ixway tab and closes the picker" do
      metadata = %{
        "ixway:gpt-6-luna" => %{kind: "concrete", route: "Automatic"},
        "ixway:openai:gpt-6-luna" => %{kind: "concrete", route: "openai"}
      }

      session =
        snapshot("01SESSION")
        |> Map.merge(%{model: "ixway:other", provider: "ixway"})
        |> fake_session(model_metadata: metadata, efforts: [])

      selected =
        tui(
          session: session,
          models: Map.keys(metadata),
          model_metadata: metadata,
          conversation: Lemieux.Conversation.new(model: "ixway:other")
        )
        |> type("/model ")
        |> press("enter")

      assert_receive {:set_model, "ixway:gpt-6-luna"}
      assert typed(selected) == ""
      assert suggestions(selected) == nil
    end

    test "model route tabs can be clicked without editing the command" do
      metadata = %{
        "ixway:gpt-5.6-luna" => %{kind: "concrete", route: "Automatic"},
        "ixway:openai:gpt-5.6-luna" => %{kind: "concrete", route: "openai"}
      }

      state =
        tui(models: Map.keys(metadata), model_metadata: metadata) |> type("/model ") |> sized()

      {%ExRatatui.Widgets.Tabs{}, area} =
        Enum.find(TUI.render(state, @frame), fn {widget, _rect} ->
          match?(%ExRatatui.Widgets.Tabs{}, widget)
        end)

      {:noreply, clicked} =
        TUI.handle_event(
          %Mouse{kind: "down", button: "left", x: area.x + 12, y: area.y},
          state
        )

      assert clicked.model_tab == "openai"
      assert typed(clicked) == "/model "
      assert clicked |> press("tab") |> typed() == "/model openai:gpt-5.6-luna"
    end

    test "Ixway model tabs keep one menu height when route counts differ" do
      metadata = %{
        "ixway:gpt-6-luna" => %{kind: "concrete", route: "Automatic"},
        "ixway:gpt-5.6-luna" => %{kind: "concrete", route: "Automatic"},
        "ixway:gpt-5" => %{kind: "concrete", route: "Automatic"},
        "ixway:openai_codex:gpt-6-luna" => %{kind: "concrete", route: "openai_codex"}
      }

      ixway = tui(models: Map.keys(metadata), model_metadata: metadata) |> type("/model ")
      codex = press(ixway, "back_tab")

      assert suggestion_rect(ixway).height == suggestion_rect(codex).height
      assert suggestions(ixway).items == ["gpt-6-luna", "gpt-5.6-luna", "gpt-5"]
      assert suggestions(codex).items == ["gpt-6-luna"]
    end

    test "deprecated badge paints red even when its model is selected" do
      state =
        tui(models: ["openai:gpt-4"], model_now: ~U[2026-09-24 00:00:00Z])
        |> type("/model ")

      widgets = TUI.render(state, @frame)
      {%List{}, rect} = Enum.find(widgets, fn {widget, _area} -> match?(%List{}, widget) end)

      session = CellSession.new(@frame.width, @frame.height)
      :ok = CellSession.draw(session, widgets)
      cells = CellSession.take_cells(session).cells
      :ok = CellSession.close(session)

      assert Enum.any?(cells, fn cell ->
               cell.row == rect.y + 1 and cell.symbol == "d" and cell.fg == :red
             end)
    end

    test "the unfiltered model menu leaves a non-selectable gap after personal choices" do
      recent = %SessionIndex{id: "02RECENT", model: "test:alpha"}

      state =
        tui(
          models: ["test:alpha", "test:beta", "test:charlie"],
          preferred_models: %{"test" => "test:beta"},
          sessions: [recent]
        )
        |> type("/model ")

      assert ["beta · preferred", %ExRatatui.Text{lines: [_, blank]}, "charlie"] =
               suggestions(state).items

      assert blank.spans == []
      rect = suggestion_rect(state)
      assert rect.height == 6

      cell_session = CellSession.new(@frame.width, @frame.height)
      :ok = CellSession.draw(cell_session, TUI.render(state, @frame))
      cells = CellSession.take_cells(cell_session).cells
      :ok = CellSession.close(cell_session)

      assert cells
             |> Enum.filter(
               &(&1.row == rect.y + 3 and &1.col > rect.x and &1.col < rect.x + rect.width - 1)
             )
             |> Enum.all?(&(&1.symbol == " "))

      assert state |> press("down") |> press("down") |> press("tab") |> typed() ==
               "/model charlie"
    end

    test "provider switch uses a configured preference instead of the catalog's first model" do
      session =
        fake_session(snapshot("01SESSION"),
          providers: ["test", "openai"],
          models: ["openai:gpt-4", "openai:gpt-6-sol"]
        )

      tui(
        session: session,
        providers: ["test", "openai"],
        preferred_models: %{"openai" => "openai:gpt-6-sol"}
      )
      |> type("/provider openai")
      |> press("enter")

      assert_receive {:set_model, "openai:gpt-6-sol"}
      refute_receive {:set_provider, "openai"}
    end

    test "provider switch applies that provider's configured effort" do
      session =
        fake_session(snapshot("01SESSION"),
          providers: ["test", "openai"],
          models: ["openai:gpt-6-sol"]
        )

      tui(
        session: session,
        providers: ["test", "openai"],
        preferred_models: %{"openai" => "openai:gpt-6-sol"},
        preferred_efforts: %{"openai" => "high"}
      )
      |> type("/provider openai")
      |> press("enter")

      assert_receive {:set_model, "openai:gpt-6-sol"}
      assert_receive {:set_reasoning_effort, "high"}
    end

    test "provider switch reuses a model from a recent session" do
      session =
        fake_session(snapshot("01SESSION"),
          providers: ["test", "openai"],
          models: ["openai:gpt-4", "openai:gpt-6-sol"]
        )

      recent = %SessionIndex{id: "02RECENT", model: "openai:gpt-6-sol"}

      tui(session: session, sessions: [recent], providers: ["test", "openai"])
      |> type("/provider openai")
      |> press("enter")

      assert_receive {:set_model, "openai:gpt-6-sol"}
      refute_receive {:set_provider, "openai"}
    end

    # The flow does not stop at the model, because choosing one is what decides
    # whether there is a third question at all: the levels belong to the model,
    # so a switch both changes which are offered and resets which is current.
    test "selecting a model immediately opens its effort completions" do
      session = fake_session(snapshot("01SESSION"), efforts: ["default", "high"])

      state =
        tui(session: session, models: ["test:model", "test:other"])
        |> type("/model other")
        |> press("enter")

      assert_receive {:set_model, "test:other"}
      assert typed(state) == "/effort "
      assert suggestions(state).items == ["default", "high"]
    end

    # An empty menu under a command is what a broken command looks like from
    # the outside, so a model with no levels ends the flow instead.
    test "a model with no effort levels leaves the box empty" do
      session = fake_session(snapshot("01SESSION"), efforts: [])

      state =
        tui(session: session, models: ["test:model", "test:other"])
        |> type("/model other")
        |> press("enter")

      assert_receive {:set_model, "test:other"}
      assert typed(state) == ""
    end

    # Provider, model, effort: one continuous flow rather than three slash
    # commands, however far into it somebody started.
    test "a provider switch runs through the model to the effort" do
      session =
        fake_session(snapshot("01SESSION"),
          providers: ["test", "anthropic"],
          models: ["anthropic:claude-opus-5"],
          efforts: ["default", "high"]
        )

      chosen =
        tui(session: session, providers: ["test", "anthropic"])
        |> type("/provider anthropic")
        |> press("enter")

      assert_receive {:set_provider, "anthropic"}
      assert typed(chosen) == "/model "

      state = press(chosen, "enter")

      # The menu offers bare ids, so what reaches the session is resolved
      # against whichever provider the snapshot says is current — which this
      # fake never restates. What the flow promises is the third menu.
      assert_receive {:set_model, model}
      assert String.ends_with?(model, ":claude-opus-5")
      assert typed(state) == "/effort "
      assert suggestions(state).items == ["default", "high"]
    end

    test "discovered Ollama tags become provider and model completions" do
      session = fake_session(snapshot("01SESSION"), unavailable_providers: ["ollama"])

      state =
        tui(session: session, providers: ["test"], models: ["test:model"])
        |> then(fn state ->
          assert {:noreply, state} =
                   TUI.handle_info(
                     {:models_discovered, ["ollama:qwen3.8:27b-mxfp8", "ollama:devstral:latest"]},
                     state
                   )

          state
        end)

      provider = type(state, "/provider olla")
      assert provider |> suggestions() |> Map.fetch!(:items) == ["ollama"]

      selected = press(provider, "enter")

      assert_receive {:set_provider, "ollama"}
      assert_receive {:set_model, "ollama:devstral:latest"}

      assert typed(selected) == "/model "

      models = selected |> type("qwen") |> suggestions()
      assert models.items == ["qwen3.8:27b-mxfp8"]
    end

    test "/elixir switches the real tool profile and marks the chat border purple" do
      session = fake_session(snapshot("01SESSION"))

      state =
        tui(
          session: session,
          standard_tools: [Lemieux.Tools.Read],
          commands: Builtin.elixir()
        )
        |> type("/elixir")
        |> press("enter")

      assert_receive {:set_tools, ["elixir", "ask_user"]}
      assert state.elixir_mode?

      {%Paragraph{block: block}, _rect} = Elixir.List.first(TUI.render(state, @frame))
      assert block.border_style.fg == :magenta

      state = state |> type("/elixir") |> press("enter")
      assert_receive {:set_tools, ["read"]}
      refute state.elixir_mode?
    end

    test "/tools lists the catalog and changes several tools through the Session API" do
      statuses = [
        %{name: "read", source: :local, enabled?: true},
        %{name: "github__search", source: {:mcp, "github"}, enabled?: false}
      ]

      session = fake_session(snapshot("01SESSION"), tool_statuses: statuses)

      listed =
        tui(session: session, tool_statuses: statuses)
        |> type("/tools list")
        |> press("enter")

      assert screen(listed) =~ "read · local · enabled"
      assert screen(listed) =~ "github__search · MCP github · disabled"

      tui(session: session, tool_statuses: statuses)
      |> type("/tools disable read github__search")
      |> press("enter")

      assert_receive {:set_tool_access, ["read", "github__search"], false}
    end

    test "Enter applies a highlighted tool name in one press" do
      statuses = [%{name: "read", source: :local, enabled?: false}]
      session = fake_session(snapshot("01SESSION"), tool_statuses: statuses)

      selected =
        tui(session: session, tool_statuses: statuses)
        |> type("/tools enable re")
        |> press("enter")

      assert_receive {:set_tool_access, ["read"], true}
      assert typed(selected) == ""
    end
  end

  describe "themes and renderers a host passes" do
    defp read_call, do: %{id: "read-1", name: "read", arguments: %{"path" => "lib/x.ex"}}

    defp read_result do
      Entry.new(:tool_result, %{
        "call_id" => "read-1",
        "name" => "read",
        "arguments" => %{"path" => "lib/x.ex"},
        "output" => "12345678",
        "error" => false
      })
    end

    # A fresh state for each, as every command test here uses: the input box
    # is a reference into the editor widget, so typing into one state's box
    # is typing into every copy of it.
    test "/theme finds a registered theme, and Tab offers it" do
      offered = tui(themes: %{"sepia" => sepia()}) |> type("/theme se") |> suggestions()
      assert offered.items == ["sepia"]

      switched = command(tui(themes: %{"sepia" => sepia()}), "/theme sepia")

      assert switched.appearance.theme.name == "sepia"
      assert switched.appearance.theme.accent == {:rgb, 192, 128, 64}
      assert rails(switched) == {:rgb, 192, 128, 64}
      said(switched, "theme: sepia")
    end

    test "a bare /theme lists a registered theme with the shipped three" do
      state =
        %{type(tui(themes: %{"sepia" => sepia()}), "/theme") | command_menu?: false}
        |> press("enter")

      said(state, "dark, light, mono, sepia")
    end

    test "a sitting can start in a registered theme" do
      assert tui(themes: %{"sepia" => sepia()}, theme: "sepia").appearance.theme.name == "sepia"
    end

    test "a name nothing registered is still refused, naming what would do" do
      said(command(tui(), "/theme sepia"), "sepia is not a theme I know · dark, light, mono")
    end

    test "a theme that cannot be read raises at start, naming the slot" do
      assert_raise ArgumentError, ~r/sepia: voices.you: "teal" is not a colour/, fn ->
        tui(themes: %{"sepia" => put_in(sepia(), ["voices", "you"], "teal")})
      end
    end

    test "a registered renderer draws a live call, and its result replaces those rows" do
      announced = tui(renderers: %{"read" => ReadCard}) |> info({:tool_call, read_call()})

      assert {:tool_heading, "read-1", :explore, "Opened", "lib/x.ex"} in announced.lines
      refute Enum.any?(announced.lines, &match?({:tool_heading, nil, :explore, _, _}, &1))

      finished = info(announced, {:entry, read_result()})

      assert {:tool_heading, "read-1", :explore, "Opened", "8 bytes"} in finished.lines
      refute {:tool_heading, "read-1", :explore, "Opened", "lib/x.ex"} in finished.lines
      assert screen(finished) =~ "• Opened 8 bytes"
    end

    test "a registered renderer draws a resumed transcript the same way" do
      entries = [
        Entry.new(:assistant, %{
          "content" => [%{"type" => "text", "text" => "looking now"}],
          "tool_calls" => [
            %{"id" => "read-1", "name" => "read", "arguments" => %{"path" => "lib/x.ex"}}
          ]
        }),
        read_result()
      ]

      session = fake_session(snapshot("02CARDED", entries))

      assert {:ok, state} =
               TUI.mount(
                 test_mode: {80, 24},
                 start: fn -> {:ok, session} end,
                 renderers: %{"read" => ReadCard}
               )

      assert screen(state) =~ "• Opened 8 bytes"
      refute screen(state) =~ "Explored"
    end

    test "a renderer that is not one raises at start" do
      assert_raise ArgumentError, ~r/read: :nope does not implement/, fn ->
        tui(renderers: %{"read" => :nope})
      end
    end
  end

  # Everything above calls the callbacks directly, which is the point — they
  # are pure. This drives the actual `ex_ratatui` runtime instead, headless,
  # because `mount/1` and the wiring between a session's broadcasts and
  # `handle_info/2` are the parts that no amount of calling `render/2` proves.
  describe "/context" do
    # `/context` printed the status line again with the numbers stacked
    # vertically, which told a person nothing the footer had not. A window is
    # a proportion, and a proportion is a picture.
    test "draws the window to scale, with a legend for what is in it" do
      said = Entry.new(:user, %{"text" => String.duplicate("please look at the config. ", 20)})

      request =
        Entry.new(:request, %{
          "system" => String.duplicate("you are careful. ", 30),
          "tools" => [%{"name" => "read", "schema" => String.duplicate("x", 400)}],
          "entry_ids" => [said.id]
        })

      answered =
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "ok"}]},
          usage: %{
            "input_tokens" => 9_000,
            "cache_read_tokens" => 8_000,
            "cache_write_tokens" => 600,
            "output_tokens" => 512
          }
        )

      entries = [said, request, answered]
      context = Context.position(entries, window: 200_000)
      session = fake_session(%{snapshot("01SESSION", entries) | context: context})

      state =
        tui(session: session)
        |> info({:context, context})
        |> command("/context")

      rendered = screen(state)

      assert rendered =~ "Context window · 18.1k/200.0k tokens (9%)"
      assert rendered =~ "session · 18.1k tok · 1 request · $0.0000"
      assert rendered =~ "system prompt"
      assert rendered =~ "tools & MCP"
      assert rendered =~ "conversation"
      assert rendered =~ "free"
      assert rendered =~ "█"
      assert rendered =~ "░"

      # The per-request split the status line gave up, with its halves named.
      assert rendered =~ "8.0k cache read"
      assert rendered =~ "600 cache write"
    end

    test "names the delegated share of what the session was billed" do
      context =
        Context.with_delegated_usage(
          Context.position([Entry.new(:assistant, %{}, usage: %{"input_tokens" => 1_000})]),
          %{"input_tokens" => 90_000, "output_tokens" => 600}
        )

      state = tui() |> info({:context, context}) |> command("/context")

      assert screen(state) =~ "90.6k delegated"
    end

    test "says the window is unmeasured rather than drawing an empty one" do
      state = command(tui(), "/context")

      assert screen(state) =~ "context unmeasured"
      refute screen(state) =~ "█"
    end
  end

  describe "/compact" do
    # `Session.compact/2` asks the model for a summary, so it blocks for the
    # length of that round trip. `handle_event/2` runs in the process that
    # draws and polls input, so calling it there is a frozen UI — no repaint,
    # no keystrokes, no way to cancel, nothing on screen saying why.
    #
    # The stand-in session does not reply while the test looks, which is the
    # whole point: if the call were inline this would sit here until the
    # two-minute timeout, and the test would fail on its own timeout rather
    # than on an assertion. It answers once the test is over, so the task
    # that asked ends quietly. It used to be killed instead, and the task's
    # crash on it was logged after the test, where no capture reached.
    test "does not block the loop that draws" do
      test = self()

      silent =
        spawn(fn ->
          receive do
            {:"$gen_call", from, :compact} ->
              send(test, :asked)
              receive do: (:stop -> GenServer.reply(from, {:error, :stopped}))

            :stop ->
              :ok
          end
        end)

      on_exit(fn -> send(silent, :stop) end)

      state = tui(session: silent) |> type("/compact")

      task = Task.async(fn -> TUI.handle_event(key("enter"), state) end)

      assert {:noreply, _state} = Task.await(task)
      # It was asked for all the same, from somewhere else: `:asked` comes
      # only from `Session.compact/2`'s call, not any call to the session.
      assert_receive :asked
    end

    test "the compaction event reports the result once" do
      state = info(tui(), {:compacted, %{entries: Enum.to_list(1..7), sections: nil}})

      assert {:noreply, done} =
               TUI.handle_info({:compaction_result, {:ok, %{entries: 7}}}, state)

      assert Enum.count(done.lines, fn {_who, line} -> line =~ "7 entries" end) == 1
    end

    test "and says so when there was nothing worth summarising" do
      assert {:noreply, done} =
               TUI.handle_info({:compaction_result, {:error, :nothing_to_do}}, tui())

      assert Enum.any?(done.lines, fn {_who, line} -> line =~ "nothing worth summarising" end)
    end
  end

  describe "/theme" do
    test "a bare /theme says which palette is showing and which others exist" do
      state = %{type(tui(), "/theme") | command_menu?: false} |> press("enter")

      said(state, "theme: dark")
      said(state, "dark, light, mono")
    end

    test "light re-paints the rails and reports itself" do
      state = command(tui(), "/theme light")

      assert rails(state) == Theme.light().accent
      refute rails(state) == Theme.dark().accent
      said(state, "theme: light")
    end

    test "mono has no accent to paint the cursor with, so the cursor is reversed" do
      state = command(tui(), "/theme mono")

      assert rails(state) == nil

      assert {%Textarea{cursor_style: cursor}, _rect} =
               state |> TUI.render(@frame) |> Enum.at(2)

      assert cursor.modifiers == [:reversed]
    end

    test "an explicit colour still wins over the theme's accent" do
      assert rails(tui() |> command("/color green") |> command("/theme light")) == :green
    end

    test "an unknown palette is refused with the ones that exist" do
      state = command(tui(), "/theme sepia")

      assert rails(state) == :cyan
      said(state, "sepia is not a theme I know")
      said(state, "dark, light, mono")
    end

    test "the menu offers every palette, and each one it offers is accepted" do
      assert (tui() |> type("/theme ") |> suggestions()).items == Theme.names()

      for name <- Theme.names() do
        said(command(tui(), "/theme " <> name), "theme: #{name}")
      end
    end

    test "a screen can be started in a palette by name, and shrugs at a bad one" do
      assert rails(tui(theme: "light")) == Theme.light().accent
      assert rails(tui(theme: "nonsense")) == :cyan
    end

    test "the palette colours the rows it draws" do
      dark = tui() |> info({:text_delta, "`code`"})
      light = %{dark | appearance: %{dark.appearance | theme: Theme.light()}}

      [dark_line] = RichText.lines(dark.lines, 40, Theme.dark())
      [light_line] = RichText.lines(light.lines, 40, Theme.light())

      assert hd(dark_line.spans).style.fg == Theme.dark().blocks.code
      assert hd(light_line.spans).style.fg == Theme.light().blocks.code
    end
  end

  describe "a host's own slash command" do
    test "is completed with the built-ins, and its argument through its own completions" do
      offered = tui(commands: [Wave]) |> type("/wa") |> suggestions()
      assert offered.items == ["/wave — wave at the room"]

      names = tui(commands: [Wave]) |> type("/wave a") |> suggestions()
      assert names.items == ["alice"]
    end

    test "is listed by /help, parsed, and performed through the dispatcher" do
      session = fake_session(snapshot("01SESSION"))

      # The host's command leads the list, which a 24-row screen has scrolled
      # past by the time the footer of the help is drawn; the rows say it.
      helped = command(tui(session: session, commands: [Wave]), "/help")

      assert Enum.any?(helped.lines, fn
               {:lmx, text} -> text =~ ~r"/wave +wave at the room"
               _row -> false
             end)

      waved = command(tui(session: session, commands: [Wave]), "/wave alice")
      assert screen(waved) =~ "waved at alice"
    end

    test "is subject to the host's command policy, in the menu and by hand" do
      policy = fn
        {:wave, _whom} -> {:deny, "no waving here"}
        _action -> :allow
      end

      # Two states rather than one typed into twice: the input box is a
      # reference into the editor widget, so a second `type/2` on the same
      # state appends to what the first left there.
      assert tui(commands: [Wave], command_policy: policy) |> type("/wa") |> suggestions() ==
               nil

      denied =
        %{
          type(tui(commands: [Wave], command_policy: policy), "/wave alice")
          | command_menu?: false
        }
        |> press("enter")

      assert screen(denied) =~ "no waving here"
      refute screen(denied) =~ "waved at"
    end

    test "one that takes a built-in's name wins" do
      state =
        command(
          tui(session: fake_session(snapshot("01SESSION")), commands: [HostModel]),
          "/model haiku"
        )

      assert screen(state) =~ "the host picked haiku"
      refute_receive {:set_model, _model}
    end

    test "a skill cannot take a command's name" do
      skill = %Skill{
        name: "wave",
        description: "a skill called wave",
        path: "/nowhere/SKILL.md",
        root: "/nowhere",
        source: :project
      }

      offered = tui(commands: [Wave], skills: [skill]) |> type("/wa") |> suggestions()

      assert offered.items == ["/wave — wave at the room"]
    end
  end
end
