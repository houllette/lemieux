defmodule Lemieux.TUI.ViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea
  alias Lemieux.Context
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  alias Lemieux.TUI.Blocks
  alias Lemieux.TUI.Processing
  alias Lemieux.TUITest.HostFollowup
  alias Lemieux.TUITest.HostStatus
  alias Lemieux.TUITest.OddKeys
  alias Lemieux.TUITest.Overlapping
  alias Lemieux.TUITest.TallStatus
  alias Lemieux.TUITest.UpsideDown
  alias Lemieux.TUITest.ViKeys

  @frame %Frame{width: 80, height: 24}

  describe "a host's own status line" do
    test "draws the row instead of the shipped one" do
      rendered = screen(sized(tui(status_line: HostStatus)))

      assert rendered =~ "host line · Processing · 80 wide"
      refute rendered =~ "session 0 tok"
    end

    test "is given the turn's label, elapsed time and phase" do
      session = fake_session(snapshot("01SESSION"))

      state =
        tui(session: session, processing: ["Deking"], status_line: HostStatus)

      assert {:noreply, started} = TUI.handle_info({:retry_result, :ok}, state)

      assert screen(sized(started)) =~ "host line · Deking · 80 wide"
    end

    # The row is handed over; the rest of the screen is not.
    test "cannot paint outside the row it was given" do
      widgets = TUI.render(sized(tui(status_line: TallStatus)), @frame)

      assert [_transcript, {_status, status_rect}, {%Textarea{}, input_rect}, _hint] =
               widgets

      assert status_rect.width == @frame.width
      assert status_rect.height == 2
      assert input_rect.y + input_rect.height == status_rect.y
      assert status_rect.y + status_rect.height <= @frame.height
    end

    # A second row has to come from somewhere, and the transcript is the only
    # pane with rows to give.
    test "a taller row takes its rows from the transcript" do
      one = TUI.render(sized(tui()), @frame)
      two = TUI.render(sized(tui(status_line: TallStatus)), @frame)

      [{_widget, short}, _status, _input, _hint] = two
      [{_widget, tall}, _status, _input, _hint] = one

      assert tall.height - short.height == 1
    end
  end

  test "Ixway estimate updates the status line without adding a transcript message" do
    observation = %{
      "kind" => "ixway_api_equivalent",
      "request_id" => "receipt-one",
      "data" => %{
        "state" => "estimated",
        "amount" => "0.0011273",
        "reference_provider" => "openai",
        "reference_source" => "llm_db/gpt-6-luna",
        "excludes" => ["subscription_fee"]
      },
      "text" => "API equivalent estimate: $0.0011273 USD"
    }

    state =
      tui()
      |> info({:usage, %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => nil}})
      |> info({:route_observation, observation})

    assert status_row(state) =~ "estimated cost: $0.0011273"
    assert String.starts_with?(status_row(state), " estimated cost:")
    refute Enum.any?(state.lines, &(inspect(&1) =~ "API equivalent estimate"))
  end

  test "/compact uses a timed placeholder, then one report and an unknown context position" do
    session = fake_session(snapshot("01SESSION"), compact_result: {:ok, %{entries: 14}})
    started = tui(session: session, clock: fn -> 0 end) |> command("/compact")
    assert {:compacting, tick, "Compacting...(0s)"} = Enum.at(started.lines, 1)

    assert [{:compact_space, ^tick}, {:compacting, ^tick, _}, {:compact_space, ^tick} | _] =
             started.lines

    refute screen(started) =~ "› /compact"

    timed = %{started | clock: fn -> 2_100 end}
    assert {:noreply, timed} = TUI.handle_info({:compact_tick, tick}, timed)
    assert Enum.at(timed.lines, 1) == {:compacting, tick, "Compacting...(2s)"}

    compacted =
      info(timed, {
        :compacted,
        %{entries: Enum.to_list(1..14), tokens: %{before: 13_000, after: 3_100}}
      })

    assert {:compact_result, report} = Enum.at(compacted.lines, 1)
    assert report =~ "Compacted · summarised the earlier conversation (14 entries)"
    assert report =~ "last request 13.0k tok"
    refute report =~ "next request"
    refute report =~ "Jev"
    assert status_row(compacted) =~ "context ?"

    assert {:noreply, settled} =
             TUI.handle_info({:compaction_result, {:ok, %{entries: 14}}}, compacted)

    assert Enum.count(settled.lines, &match?({:compact_result, _}, &1)) == 1
    next = command(settled, "hey")
    assert_receive {:prompted, "hey"}
    assert [{:you, "hey"}, {:compact_space, ^tick}, {:compact_result, _} | _] = next.lines
  end

  test "the compact result names actual Jev projection evidence when enabled" do
    harness = %Lemieux.Harness{
      applied: [
        %{
          "module" => "LemieuxJevCompaction",
          "options" => %{"enabled" => true, "mode" => "apply"}
        }
      ]
    }

    session = fake_session(snapshot("01SESSION"), compact_result: {:ok, %{entries: 14}})
    state = tui(session: session, harness: harness, clock: fn -> 0 end)
    started = command(state, "/compact")

    pending = info(started, {:compacted, %{entries: Enum.to_list(1..14)}})
    assert Enum.at(pending.lines, 1) |> elem(1) =~ "Jev active, no projection recorded yet"

    state = command(state, "/compact")

    state =
      info(
        state,
        {:entry,
         %{
           type: :extension_state,
           payload: %{
             "namespace" => "jev_compaction",
             "value" => %{"last_outcome" => "applied", "last_saved_tokens_estimate" => 1_250}
           }
         }}
      )

    compacted = info(state, {:compacted, %{entries: Enum.to_list(1..14)}})

    assert Enum.at(compacted.lines, 1) |> elem(1) =~
             "last Jev projection kept ≈1.3k tok out of context"
  end

  describe "keys a host rebinds" do
    # `/name` is the command every rebinding test submits: it needs no
    # session, and the header shows whether it was sent.
    defp named?(state, name), do: screen(state) =~ "#{app_label()} · #{name} · test"

    test "a map moves submit to ctrl-j and releases enter to the editor" do
      keys = %{"ctrl-j" => "submit", "enter" => "forward"}

      sent = tui(keys: keys) |> type("/name bob") |> press("j", ["ctrl"]) |> press("j", ["ctrl"])
      assert named?(sent, "bob")

      kept = tui(keys: keys) |> type("/name bob") |> press("enter") |> press("enter")
      refute named?(kept, "bob")
      assert typed(kept) =~ "/name bob"
    end

    test "a map that binds shift-up to page_up pages, and page_up still does" do
      state = sized(tui(keys: %{"shift-up" => "page_up"}, lines: said(100)))

      assert press(state, "up", ["shift"]).scroll == press(state, "page_up").scroll
      assert press(state, "up", ["shift"]).scroll > 3
    end

    test "a key the map does not mention keeps its default" do
      state = sized(tui(keys: %{"ctrl-j" => "submit"}, lines: said(100)))

      assert press(state, "up", ["shift"]).scroll == 3
      assert {:noreply, armed} = TUI.handle_event(key("c", ["ctrl"]), state)
      assert armed.exit_armed
    end

    test "a module key map is asked, and its answers are acted on" do
      state = sized(tui(keys: ViKeys, lines: said(100)))

      assert press(state, "k", ["ctrl"]).scroll == 3
      assert state |> press("k", ["ctrl"]) |> press("j", ["ctrl"]) |> Map.fetch!(:scroll) == 0
      assert press(state, "page_up").scroll > 3
    end

    test "an answer outside the vocabulary goes to the editor, and the transcript says so" do
      state = tui(keys: OddKeys) |> press("x")

      assert typed(state) == "x"
      assert screen(state) =~ "keys: Lemieux.TUITest.OddKeys answered :launch for x"
    end

    test "a map that cannot be read, or a module that is not a key map, is refused" do
      assert_raise ArgumentError, ~r/keys: .*ctl-x/, fn -> tui(keys: %{"ctl-x" => "submit"}) end

      assert_raise ArgumentError, ~r/keys: .*interrupt/, fn ->
        tui(keys: %{"ctrl-c" => "submit"})
      end

      assert_raise ArgumentError, ~r/keys: Lemieux.TUITest.HostStatus does not implement/, fn ->
        tui(keys: HostStatus)
      end
    end
  end

  describe "panes a host rearranges" do
    test "the input on top puts the transcript rows at the bottom" do
      state = sized(tui(layout: UpsideDown, lines: [{:lmx, "the only line"}]))

      [
        {%Textarea{}, input},
        {%Paragraph{wrap: true}, _hint},
        {%Paragraph{block: nil}, status},
        {%Paragraph{}, transcript}
      ] =
        state |> TUI.render(@frame) |> Enum.sort_by(fn {_widget, rect} -> rect.y end)

      assert input == %ExRatatui.Layout.Rect{x: 0, y: 0, width: 80, height: 3}
      assert status.y == 3
      assert transcript == %ExRatatui.Layout.Rect{x: 0, y: 4, width: 80, height: 20}
      assert screen(state) =~ "the only line"
      refute screen(state) =~ "layout:"
    end

    test "mouse selection still picks the clicked row" do
      owner = self()

      clipboard = fn text ->
        send(owner, {:copied, text})
        :ok
      end

      state =
        sized(
          tui(layout: UpsideDown, clipboard: clipboard, lines: [{:lmx, "lib/lemieux/session.ex"}])
        )

      # The pane's first content row is screen row 5: three rows of input, one
      # of status, and the pane's own top rail.
      selected = events(state, [{"down", 1, 5}, {"drag", 11, 5}, {"up", 11, 5}])
      assert_receive {:copied, "lib/lemieux"}
      assert selected.selection

      # Screen row 1 is inside the input box now, so a drag there selects nothing.
      untouched = events(state, [{"down", 1, 1}, {"drag", 11, 1}, {"up", 11, 1}])
      refute untouched.selection
      refute_receive {:copied, _text}
    end

    test "the completion menu opens at the edge of the transcript nearest the input" do
      rect = tui(layout: UpsideDown) |> type("/th") |> suggestion_rect()

      assert rect.y == 4
      assert rect.x == 0
      assert rect.width == 80
    end

    test "paging measures the pane where the layout put it" do
      state = sized(tui(layout: UpsideDown, lines: said(100)))

      assert press(state, "page_up").scroll ==
               press(sized(tui(lines: said(100))), "page_up").scroll
    end

    test "overlapping panes are refused, the shipped arrangement drawn, and the reason shown" do
      state = sized(tui(layout: Overlapping, lines: [{:lmx, "still here"}]))

      assert TUI.render(state, @frame) |> Enum.map(&elem(&1, 1)) ==
               TUI.render(sized(tui()), @frame) |> Enum.map(&elem(&1, 1))

      assert screen(state) =~
               "layout: Lemieux.TUITest.Overlapping let the transcript and the status overlap · drawn as shipped"

      assert screen(state) =~ "still here"
    end

    test "something that is not a layout is refused" do
      assert_raise ArgumentError, ~r/layout: Lemieux.TUITest.HostStatus does not implement/, fn ->
        tui(layout: HostStatus)
      end

      assert_raise ArgumentError, ~r/layout: "nope"/, fn -> tui(layout: "nope") end
    end
  end

  describe "a host's own follow-up guess" do
    test "is offered in place of the shipped one, and Tab takes it" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      finished =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end, followups: HostFollowup)
        |> info({:tool_call, %{id: "edit-1", name: "edit", arguments: %{"path" => "a.ex"}}})
        |> info({:finished, :stop})

      assert hint(finished) == "open a pull request · tab"
      assert typed(press(finished, "tab")) == "open a pull request"
    end

    # The shipped rules would have hinted here; the host's one rule does not.
    test "gets the last word when it declines" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      finished =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end, followups: HostFollowup)
        |> info({:tool_call, %{id: "read-1", name: "read", arguments: %{"path" => "a.ex"}}})
        |> info({:finished, :stop})

      assert hint(finished) == "ask, or say what to change"
    end
  end

  describe "the status line and the live row above it" do
    # Three numbers, each answering a different question. The per-request
    # split that used to be here — `cache 9.0k/0`, which said which half was
    # which to nobody — is `/context`'s job now.
    test "is present and zeroed before the first response" do
      rendered = screen(tui())

      assert rendered =~ "context 0"
      assert rendered =~ "session 0 tok"
      assert rendered =~ "$0.0000"
      refute rendered =~ "cache 0/0"
    end

    test "counts delegated tokens in the session total as the children report them" do
      state =
        info(tui(), {:subagent, ["root", "child"], {:usage, %{"input_tokens" => 9_000}}})

      assert screen(state) =~ "session 9.0k tok"
    end

    test "reports where the session stands once there is anything to report" do
      context = %Context{
        measured?: true,
        tokens: 6_000,
        window: 10_000,
        fraction: 0.6,
        spent: %{input: 6_000, output: 0, cached: 0, requests: 1}
      }

      state = info(tui(), {:context, context})

      assert screen(state) =~ "context 6.0k/10.0k tokens (60%)"

      # A `spent` map with a key missing is a host's struct or an older
      # transcript's, and an accounting number is not worth a crashed status
      # line. This one has no `:cache_write`.
      assert screen(state) =~ "session 6.0k tok"
    end

    # A session on 2026-09-18 spent two and a half minutes composing one
    # 35 KB write behind a bare `Processing` label, and before that its
    # parent read three investigation results in a silence that looked the
    # same. The phase is what tells working from hung.
    test "says what the session is doing beside the elapsed time" do
      busy = %{Lemieux.Conversation.new() | busy?: true}
      state = tui(conversation: busy, started_at: 0, frame: 2, clock: fn -> 12_000 end)

      fed = fn state, event ->
        {:noreply, state} = TUI.handle_info({:lemieux, "01SESSION", event}, state)
        state
      end

      waiting =
        fed.(
          state,
          {:entry, %Lemieux.Entry{id: "r1", type: :request, payload: %{}, at: DateTime.utc_now()}}
        )

      assert unwrapped(%{waiting | clock: fn -> 18_000 end}) =~ "waiting for the model (6s)"

      thinking = fed.(waiting, {:thinking_delta, %{id: "a1", text: "hmm"}})
      assert unwrapped(%{thinking | clock: fn -> 52_000 end}) =~ "thinking (40s)"

      composing =
        fed.(
          thinking,
          {:tool_call_delta,
           %{
             id: "a1",
             name: "write",
             bytes: 18_636,
             head: ~s({"path": "tmp/analysis.md", "content": "# Plan)
           }}
        )

      assert unwrapped(composing) =~ "composing write tmp/analysis.md (18.2 KB)"

      running =
        fed.(
          composing,
          {:tool_call, %{id: "c1", name: "bash", arguments: %{"command" => "mix test"}}}
        )

      assert unwrapped(%{running | clock: fn -> 132_000 end}) =~ "running bash (2m)"

      retrying =
        fed.(
          running,
          {:provider_retry,
           %{attempt: 2, max: 2, delay_ms: 8_000, category: :server, reason: "x"}}
        )

      assert unwrapped(%{retrying | clock: fn -> 14_000 end}) =~
               "provider error, retrying in 6s (2/2)"

      delegating =
        fed.(state, {:subagent, ["01SESSION"], {:child_started, %{"child_id" => "01C1"}}})

      delegating =
        fed.(delegating, {:subagent, ["01SESSION"], {:child_started, %{"child_id" => "01C2"}}})

      assert unwrapped(delegating) =~ "2 read-only investigations running"

      closed =
        fed.(
          delegating,
          {:subagent, ["01SESSION"],
           {:group_finished,
            %{
              "status" => "ok",
              "results" => [%{"answer" => String.duplicate("a", 20_480)}, %{"answer" => "b"}]
            }}}
        )

      waiting_again =
        fed.(
          closed,
          {:entry, %Lemieux.Entry{id: "r2", type: :request, payload: %{}, at: DateTime.utc_now()}}
        )

      assert unwrapped(waiting_again) =~
               "reading 2 read-only investigations (20.0 KB) · waiting for the model"

      # The first delta ends the reading note.
      answering = fed.(waiting_again, {:text_delta, %{id: "a2", text: "So"}})
      assert unwrapped(answering) =~ "answering"
      refute unwrapped(answering) =~ "reading 2"
    end

    test "an accepted retry starts the turn's spinner" do
      state = tui()
      refute state.conversation.busy?

      {:noreply, retried} = TUI.handle_info({:retry_result, :ok}, state)
      assert retried.conversation.busy?
      assert is_integer(retried.turn.started_at)

      {:noreply, refused} = TUI.handle_info({:retry_result, {:error, :nothing_to_retry}}, state)
      refute refused.conversation.busy?
      assert screen(refused) =~ "nothing failed, so there is nothing to retry"
    end

    test "animates processing and formats elapsed seconds, minutes, and hours" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      state =
        tui(
          conversation: busy,
          started_at: 0,
          frame: 2,
          clock: fn -> 12_000 end
        )

      assert screen(state) =~ "Processing (12s)"

      assert screen(%{state | turn: %{state.turn | frame: 0}, clock: fn -> 125_000 end}) =~
               "Processing (2m)"

      assert screen(%{state | clock: fn -> 7_560_000 end}) =~ "(2hr 6m)"
    end

    # The animation is a glyph in a gutter of its own rather than dots on the
    # end of the label, which is what the label used to wear and what had to be
    # padded so the elapsed time beside it did not shuffle three times a second.
    test "the spinner turns without moving the text beside it" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      turning =
        for frame <- 0..3 do
          tui(conversation: busy, started_at: 0, frame: frame, clock: fn -> 12_000 end)
          |> screen()
          |> String.split("\n")
          |> Enum.find(&(&1 =~ "Processing"))
        end

      glyphs = Enum.map(turning, &String.first/1)
      assert length(Enum.uniq(glyphs)) == 4

      rest = Enum.map(turning, &String.slice(&1, 1..-1//1))
      assert Enum.uniq(rest) == [" Processing (12s)"]
    end

    # The row above the input box is what is permanently true about the
    # session. What the turn is doing is neither permanent nor true for long,
    # and it belongs beside the tool calls it describes.
    test "the turn's activity is in the transcript, not on the status line" do
      busy = %{Lemieux.Conversation.new() | busy?: true}
      state = tui(conversation: busy, started_at: 0, frame: 2, clock: fn -> 12_000 end)

      assert screen(state) =~ "Processing (12s)"
      refute status_row(state) =~ "Processing"
      assert status_row(state) =~ "session 0 tok"
    end

    # A finished turn has its summary rule instead; two ways of saying the turn
    # is over, one of them stale, is the bug a live row invites.
    test "the live row is gone once the turn ends" do
      busy = %{Lemieux.Conversation.new() | busy?: true}
      state = tui(conversation: busy, started_at: 0, frame: 2, clock: fn -> 12_000 end)

      assert screen(state) =~ "Processing (12s)"

      {:noreply, finished} =
        TUI.handle_info({:lemieux, "01SESSION", {:finished, :ok}}, state)

      refute screen(finished) =~ "Processing (12s)"
      assert screen(finished) =~ "── 12s · "
    end

    # A resume and an armed ctrl-c are the screen's own work rather than the
    # conversation's, so they stay on the row that is always there.
    test "the screen's own work stays on the status line" do
      state = tui()

      assert status_row(%{state | resume: %{state.resume | busy?: true}}) =~ "resuming…"

      {:noreply, armed} = TUI.handle_event(key("c", ["ctrl"]), state)
      assert status_row(armed) =~ "ctrl-c again to leave"
    end

    # One word per turn, drawn when the turn starts. A fixed label told nobody
    # anything the elapsed seconds beside it had not already said.
    test "each turn is labelled with a word from the list" do
      session = fake_session(snapshot("01SESSION"))

      labels =
        for _attempt <- 1..40 do
          state = tui(session: session, clock: fn -> 0 end)
          assert {:noreply, started} = TUI.handle_info({:retry_result, :ok}, state)

          started.turn.label
        end

      assert Enum.all?(labels, &(&1 in Processing.words()))

      # Forty draws from a list this long landing on one word is a fixed
      # label wearing a random one's clothes.
      assert length(Enum.uniq(labels)) > 1
    end

    test "a configured word list replaces the shipped one" do
      session = fake_session(snapshot("01SESSION"))
      state = tui(session: session, processing: ["Pucking"], clock: fn -> 0 end)

      assert {:noreply, started} = TUI.handle_info({:retry_result, :ok}, state)
      assert started.turn.label == "Pucking"
      assert screen(%{started | clock: fn -> 12_000 end}) =~ "Pucking (12s)"
    end

    test "finishing adds a width-aware divider with per-prompt work and usage" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      state =
        tui(conversation: busy, started_at: 0, clock: fn -> 12_000 end)
        |> info(
          {:usage,
           %{
             "input_tokens" => 1_100,
             "cache_read_tokens" => 100,
             "cache_write_tokens" => 20,
             "output_tokens" => 200,
             "cost_usd" => 0.0123
           }}
        )
        |> info({:tool_call, %{id: "read-1", name: "read", arguments: %{"path" => "a"}}})
        |> info(
          {:usage,
           %{
             "input_tokens" => 80,
             "cache_read_tokens" => 0,
             "cache_write_tokens" => 0,
             "output_tokens" => 20,
             "cost_usd" => 0.0007
           }}
        )
        |> info({:tool_call, %{id: "read-2", name: "read", arguments: %{"path" => "b"}}})
        |> info({:finished, :stop})

      rendered = screen(state)

      assert rendered =~ "── 12s · 2 reqs · 1.5k total tokens"
      assert rendered =~ "1.2k in · 100/20 cache · 220 out"
      assert unwrapped(state) =~ "2 tool calls ─"
      assert rendered =~ "$0.0130"
      assert rendered =~ "── 12s"
      refute state.conversation.busy?
      assert is_nil(state.turn.started_at)
    end

    test "per-prompt summary includes delegated work while cost stays in the status line" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      state =
        tui(conversation: busy, started_at: 0, clock: fn -> 2_000 end)
        |> info(
          {:subagent, ["root", "child"],
           {:usage,
            %{
              "input_tokens" => 1_000,
              "cache_read_tokens" => 200,
              "cache_write_tokens" => 0,
              "output_tokens" => 100,
              "cost_usd" => 0.02
            }}}
        )
        |> info(
          {:subagent, ["root", "child"],
           {:tool_call, %{id: "read-1", name: "read", arguments: %{"path" => "mix.exs"}}}}
        )
        |> info({:finished, :stop})

      assert {:summary, summary} = Elixir.List.first(state.lines)
      assert summary =~ "1 req · 1.3k total tokens"
      assert summary =~ "1 tool call"
      refute summary =~ "$0.0200"
      assert Lemieux.Conversation.status(state.conversation) =~ "$0.0200 delegated"
    end

    test "a finished turn offers a follow-up hint that tab accepts" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      running =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end)
        |> info({:tool_call, %{id: "edit-1", name: "edit", arguments: %{"path" => "a.ex"}}})

      refute hint(running) =~ "run the tests"

      finished = info(running, {:finished, :stop})

      assert hint(finished) == "run the tests · tab"
      assert typed(press(finished, "tab")) == "run the tests"
    end

    test "a hint is offered only into an empty box, and only when there is one" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      quiet =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end)
        |> info({:finished, :stop})

      assert hint(quiet) == "ask, or say what to change"

      typing =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end)
        |> info({:tool_call, %{id: "edit-1", name: "edit", arguments: %{"path" => "a.ex"}}})
        |> info({:finished, :stop})
        |> type("no")

      # Tab over typed text is a tab, not an offer being taken.
      assert typed(press(typing, "tab")) =~ "no"
      refute typed(press(typing, "tab")) == "run the tests"
    end

    test "a failed call turns the hint towards the failure" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      state =
        tui(conversation: busy, started_at: 0, clock: fn -> 1_000 end)
        |> info(
          {:tool_call, %{id: "bash-1", name: "bash", arguments: %{"command" => "mix test"}}}
        )
        |> info(
          {:entry,
           %{
             type: :tool_result,
             payload: %{
               "call_id" => "bash-1",
               "name" => "bash",
               "error" => true,
               "output" => "boom"
             }
           }}
        )
        |> info({:finished, :stop})

      assert hint(state) == "fix what failed and try again · tab"
    end

    test "a finished prompt without usage does not present zero as measured" do
      busy = %{Lemieux.Conversation.new() | busy?: true}

      state =
        tui(conversation: busy, started_at: 0, clock: fn -> 500 end)
        |> info({:finished, :stop})

      assert {:summary, summary} = Elixir.List.first(state.lines)

      assert summary == "0s · 0 reqs · tokens unmeasured · 0 tool calls"

      refute summary =~ "$0.0000"
    end
  end

  describe "markdown blocks in an answer" do
    defp streamed(state, fragments),
      do: Enum.reduce(fragments, state, &info(&2, {:text_delta, &1}))

    # The fragments stop in the middle of the fence on purpose: no line can
    # be classified until the next one has begun, and the test is that the
    # block is nonetheless a block by the time anybody looks at it.
    test "a fenced block is code from its first character and closes on the next line" do
      state = streamed(tui(started_at: 0), ["Here:\n``", "`elixir\ndef f, do", ": 1\n"])

      assert [
               {:model_code, "elixir", "", nil},
               {:model_code, "elixir", "def f, do: 1", spans},
               {:model_fence, :open, "elixir", "```"},
               {:model, "Here:"}
             ] = state.lines

      assert is_list(spans)

      state = info(state, {:text_delta, "```\nafter"})

      assert [
               {:model, "after"},
               {:model_fence, :close, "elixir", "```"},
               {:model_code, "elixir", "def f, do: 1", _spans},
               {:model_fence, :open, "elixir", "```"},
               {:model, "Here:"}
             ] = state.lines

      assert screen(state) =~ "╭─ elixir ─"
      assert screen(state) =~ "def f, do: 1\n╰───"
    end

    test "a code row starts in the first column, so a copied block is the block" do
      state = streamed(tui(started_at: 0), ["```\nmix test --failed\n```\n"])

      assert screen(state) =~ "\nmix test --failed\n"
    end

    test "the end of the turn closes what the model left open" do
      state = tui(started_at: 0) |> streamed(["```\ncode"]) |> info({:finished, :stop})

      assert Enum.any?(
               state.lines,
               &match?({:model_code, nil, "code", spans} when is_list(spans), &1)
             )
    end

    test "a table is one row per row, header first, aligned as its delimiter says" do
      state =
        streamed(tui(started_at: 0), ["| name | age |\n|---|---:|\n| ann | 3 |\n| bo | 12 |\n"])

      assert [
               {:model, ""},
               {:model_table,
                %{
                  header: ["name", "age"],
                  aligns: [:left, :right],
                  rows: [["ann", "3"], ["bo", "12"]]
                }}
             ] = state.lines

      assert screen(state) =~ "name  age\n────  ───\nann     3\nbo     12"
    end

    test "headings, quotes, items and rules are drawn as what they are" do
      state = streamed(tui(started_at: 0), ["# Plan\n> careful\n- first\n---\nend"])
      rendered = screen(state)

      assert rendered =~ "Plan\n▎ careful\n• first\n────"
      refute rendered =~ "# Plan"
      refute rendered =~ "> careful"
    end

    # Scrolled back, so the offset is a distance that has to grow by exactly
    # what arrives underneath. Closing the fence replaces three rows with
    # three re-highlighted ones — no change — and `done` is one more.
    test "the scroll position holds while a block closes above it" do
      state = %{streamed(tui(started_at: 0), ["one\ntwo\nthree\n```\ncode\n"]) | scroll: 3}

      assert info(state, {:text_delta, "```\ndone"}).scroll == 4
    end

    test "a resumed answer draws the same blocks it drew live" do
      text = "# Plan\n\n- a\n\n```elixir\n:ok\n```\n| k | v |\n|---|---|\n| 1 | 2 |"
      live = tui(started_at: 0) |> info({:text_delta, text}) |> info({:finished, :stop})

      entries = [Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => text}]})]
      session = fake_session(snapshot("02BLOCKS", entries))
      assert {:ok, resumed} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)

      assert Enum.filter(resumed.lines, &Blocks.model_row?/1) ==
               Enum.filter(live.lines, &Blocks.model_row?/1)

      assert Enum.any?(resumed.lines, &match?({:model_table, _table}, &1))
    end

    test "a prompt after a block still gets its blank line, live and resumed" do
      tmp = System.tmp_dir!() |> Path.join("lmx-tui-blocks-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      runtime = :"lemieux_tui_blocks_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: Scripted.new([[{:text_delta, "hi"}, {:done, :stop}]]),
          store: JSONL.new(tmp),
          model: "test:model",
          subscriber: self()
        )

      live =
        tui(session: session, started_at: 0)
        |> streamed(["```\nx\n```"])
        |> info({:finished, :stop})
        |> type("next")
        |> press("enter")

      assert [{:you, "next"}, {:space, ""}, {:summary, _}, {:model_fence, :close, nil, "```"} | _] =
               live.lines

      entries = [
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "```\nx\n```"}]}),
        Entry.new(:user, %{"text" => "follow-up"})
      ]

      assert {:ok, resumed} =
               TUI.mount(
                 test_mode: {80, 24},
                 start: fn -> {:ok, fake_session(snapshot("02SPACEDBLOCK", entries))} end
               )

      assert [{:you, "follow-up"}, {:space, ""}, {:model_fence, :close, nil, "```"} | _rest] =
               resumed.lines
    end
  end
end
