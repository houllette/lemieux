defmodule Lemieux.TUI.RichTextTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Style
  alias ExRatatui.Text.Encode
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias Lemieux.TUI.Blocks
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.RichText
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText

  defp rendered(rows, width \\ 80), do: RichText.lines(rows, width)

  defp spans([%Line{spans: spans}]), do: spans

  defp text(lines) do
    Enum.map_join(lines, "\n", fn %Line{spans: spans} ->
      Enum.map_join(spans, & &1.content)
    end)
  end

  test "model rows render bold, italic, and inline code without their markers" do
    spans = spans(rendered([{:model, "plain **bold** *italic* `code`"}]))

    assert Enum.any?(spans, &(&1.content == "bold" and :bold in &1.style.modifiers))
    assert Enum.any?(spans, &(&1.content == "italic" and :italic in &1.style.modifiers))
    assert Enum.any?(spans, &(&1.content == "code" and &1.style.fg == :cyan))
    refute String.contains?(Enum.map_join(spans, & &1.content), ["*", "`"])
  end

  test "unmatched model markers remain literal" do
    assert text(rendered([{:model, "an **unfinished thought"}])) ==
             "an **unfinished thought"
  end

  test "model Markdown links render as styled labels with visible destinations" do
    [%Line{spans: spans}] = rendered([{:model, "Visit [Google](https://google.com) today"}])

    assert Enum.map_join(spans, & &1.content) ==
             "Visit ↗ Google (https://google.com) today"

    assert Enum.any?(spans, fn span ->
             span.content == "↗ Google (https://google.com)" and
               :underlined in span.style.modifiers
           end)
  end

  test "user and lemieux rows get semantic styles without interpreting user markdown" do
    [user, notice, error] =
      rendered([
        {:you, "send **literally**"},
        {:lmx, "working on it"},
        {:lmx, "error: unavailable"}
      ])

    assert [%{content: "› ", style: %Style{fg: :cyan, modifiers: modifiers}} | _] = user.spans
    assert :bold in modifiers
    assert Enum.map_join(user.spans, & &1.content) == "› send **literally**"

    assert Enum.all?(notice.spans, &(&1.style.fg == :gray))
    assert Enum.all?(notice.spans, &(:italic in &1.style.modifiers))

    assert Enum.all?(error.spans, &(&1.style.fg == :red))
    assert Enum.all?(error.spans, &(:bold in &1.style.modifiers))
  end

  test "compaction keeps its activity color and steer keeps user text inside a muted box" do
    [compacting, compacted, top, body, bottom] =
      rendered([
        {:compacting, make_ref(), "Compacting...(2s)"},
        {:compact_result, "Compacted · 14 entries"},
        {:steer, :pending, "keep this approach"}
      ])

    assert hd(compacting.spans).style.fg == :magenta
    assert hd(compacted.spans).style.fg == :magenta
    assert :italic in hd(top.spans).style.modifiers
    assert hd(top.spans).style.fg == :gray

    assert Enum.any?(
             body.spans,
             &(&1.content == "keep this approach" and &1.style.fg == :light_cyan)
           )

    assert hd(bottom.spans).style.fg == :gray
  end

  test "wrapping counts visible content and carries styles across rows" do
    [first, second] = rendered([{:model, "**abcdefgh**"}], 4)

    assert Enum.map_join(first.spans, & &1.content) == "abcd"
    assert Enum.map_join(second.spans, & &1.content) == "efgh"
    assert Enum.all?(first.spans ++ second.spans, &(:bold in &1.style.modifiers))
  end

  test "wrapping prefers whitespace and preserves the whitespace's style" do
    [first, second] = rendered([{:model, "**one two** three"}], 7)

    assert text([first, second]) == "one two\nthree"
    assert Enum.all?(first.spans, &(:bold in &1.style.modifiers))
  end

  test "blank rows remain one blank rich-text line" do
    assert [%Line{spans: [%{content: ""}]}] = rendered([{:model, ""}], 10)
    assert [%Line{spans: [%{content: ""}]}] = rendered([{:space, ""}], 10)
  end

  test "summary rows wrap and close the final row with a width-sized rule" do
    lines = rendered([{:summary, "12s · 2 reqs · 1.5k tok · 2 tool calls"}], 24)
    rendered_lines = Enum.map(lines, &Enum.map_join(&1.spans, fn span -> span.content end))

    assert hd(rendered_lines) |> String.starts_with?("── 12s")
    assert List.last(rendered_lines) |> String.ends_with?("───")
    assert Enum.all?(rendered_lines, &(String.length(&1) <= 24))
    assert String.length(List.last(rendered_lines)) == 24

    assert Enum.all?(lines, fn line ->
             Enum.all?(line.spans, &(&1.style.fg == :gray and :dim in &1.style.modifiers))
           end)
  end

  describe "a delegated child's row" do
    defp child(fields) do
      base = %{
        id: "01K2QF8YV3RB4TJ6WQ0N7XZDP5",
        name: "holden-gretzky",
        kind: "explore",
        goal: "find the build commands",
        status: "running",
        activity: nil,
        count: 1,
        text: nil
      }

      [{:subagent_child, Enum.into(fields, base)}] |> rendered() |> Enum.map(&drawn/1)
    end

    defp drawn(line), do: Enum.map_join(line.spans, & &1.content)

    # Name, then how it is going, then why it exists — and what it is doing
    # right now on its own line, because that changes several times a second
    # while the rest does not.
    test "is what it is, then what it is doing" do
      assert child(text: "read mix.exs") == [
               "├─ holden-gretzky · running · find the build commands",
               "│ └ read mix.exs"
             ]
    end

    # A child transcript retains every call. Its row needs only the latest:
    # drawing every repeated read made a stuck scout consume the viewport
    # while conveying no new state.
    test "counts a repeated call instead of repeating it" do
      assert child(text: "read mix.exs", count: 12) == [
               "├─ holden-gretzky · running · find the build commands",
               "│ └ read mix.exs ×12"
             ]
    end

    # A queued child has done nothing yet, and a resumed one's calls are in
    # its own transcript rather than its parent's. One line, not two with an
    # empty one.
    test "is one line when there is nothing to report under it" do
      assert child(status: "queued") == ["├─ holden-gretzky · queued · find the build commands"]
    end

    test "carries no brief when the transcript recorded none" do
      assert child(goal: nil) == ["├─ holden-gretzky · running"]
    end

    # How a delegation ended is the thing somebody scans a block of these
    # for, so the statuses do not all look the same.
    test "colours the status by whether anybody has to do something" do
      styled = fn status ->
        [line] = rendered([{:subagent_child, child_row(status)}])

        Enum.find_value(line.spans, &if(&1.content == status, do: &1.style.fg))
      end

      assert styled.("ok") == :green
      assert styled.("failed") == :red
      assert styled.("cancelled") == :yellow
      assert styled.("budget_exhausted") == :yellow
      assert styled.("queued") == :gray
    end

    defp child_row(status) do
      %{
        id: "01C",
        name: "holden-gretzky",
        kind: nil,
        goal: nil,
        status: status,
        activity: nil,
        count: 1,
        text: nil
      }
    end
  end

  # A cancellation is the one thing here somebody did on purpose and then has
  # to find again in the scrollback. It read as grey italic, the same as every
  # other remark lmx makes.
  test "a cancellation is red, live and restored alike" do
    for text <- ["cancelled", "— cancelled —"] do
      [line] = rendered([{:lmx, text}])

      assert Enum.all?(line.spans, &(&1.style.fg == :red and :bold in &1.style.modifiers)),
             "#{text} is not red"
    end

    # Still distinct from an ordinary remark, which stays out of the way.
    [ordinary] = rendered([{:lmx, "switched to test:model"}])
    assert Enum.all?(ordinary.spans, &(&1.style.fg == :gray))
  end

  describe "the context window's bands" do
    defp bar(segments, width) do
      [line] = RichText.lines([{:context_bar, segments}], width)

      Enum.map(line.spans, &{&1.style.fg, String.length(&1.content)})
    end

    # The bar is a proportion, so the cells have to add up to the pane and
    # the colours have to be the legend's. Green is the prompt the harness
    # wrote, red the tool schemas it attached, blue the conversation.
    test "tile the pane exactly, in the legend's colours" do
      drawn =
        bar(
          [{:system, 0.1}, {:tools, 0.2}, {:conversation, 0.2}, {:output, 0.1}, {:free, 0.4}],
          40
        )

      assert drawn == [{:green, 4}, {:red, 8}, {:blue, 8}, {:magenta, 4}, {:dark_gray, 16}]
      assert drawn |> Enum.map(&elem(&1, 1)) |> Enum.sum() == 40
    end

    # Flooring every band leaves cells over. They go to the widest one, where
    # one cell is least visible — and never off the end of the pane.
    test "hand the cells rounding left over to the widest band" do
      drawn = bar([{:system, 0.33}, {:tools, 0.33}, {:free, 0.34}], 10)

      assert drawn |> Enum.map(&elem(&1, 1)) |> Enum.sum() == 10
      assert {:dark_gray, 4} in drawn
    end

    # A band under one cell of the pane draws as nothing rather than being
    # rounded up into a bar wider than the pane. The legend still names it.
    test "drop a band too small to draw rather than overflowing for it" do
      drawn = bar([{:system, 0.001}, {:free, 0.999}], 20)

      assert drawn == [{:dark_gray, 20}]
    end

    # Two glyphs so the bar still reads where the palette does not.
    test "use a lighter glyph for free space" do
      [line] = RichText.lines([{:context_bar, [{:conversation, 0.5}, {:free, 0.5}]}], 8)

      assert Enum.map_join(line.spans, & &1.content) == "████░░░░"
    end

    # Breaking on whitespace put `free` at the end of one line and `181.5k`
    # at the start of the next, which reads as a sixth band with no name.
    test "the legend wraps between entries, never inside one" do
      entries = [
        {:system, "system prompt 2.1k"},
        {:tools, "tools & MCP 10.3k"},
        {:free, "free 181.5k"}
      ]

      drawn =
        RichText.lines([{:context_key, entries}], 44)
        |> Enum.map(fn line -> Enum.map_join(line.spans, & &1.content) end)

      assert drawn == ["█ system prompt 2.1k · █ tools & MCP 10.3k", "░ free 181.5k"]
    end

    test "every legend swatch carries its band's colour" do
      [line] = RichText.lines([{:context_key, [{:tools, "tools & MCP 10.3k"}]}], 80)

      assert Enum.any?(line.spans, &(&1.content == "█ " and &1.style.fg == :red))
    end
  end

  test "tool output preserves indentation and uses a subdued style" do
    [line] = rendered([{:tool_output, "call", :first, :ok, "  nested"}], 80)

    assert Enum.map_join(line.spans, & &1.content) == "  └   nested"
    assert Enum.any?(line.spans, &(&1.content == "  └ " and &1.style.fg == :dark_gray))

    assert Enum.any?(
             line.spans,
             &(&1.content == "  nested" and &1.style.fg == :gray and :dim in &1.style.modifiers)
           )
  end

  # `:dark_gray` is the darkest colour a terminal renders as visible, and
  # `:dim` on top of it made tool output unreadable on a dark background. The
  # gutter may stay that dark; text a person has to read may not.
  test "tool text is never dark gray, however subdued the row" do
    rows = [
      {:tool_heading, "call", :run, "Ran", "mix test"},
      {:tool_detail, "call", :ordinary, "mix test"},
      {:tool_output, "call", :first, :ok, "12 tests"},
      {:tool_output, "call", :rest, :ok, "0 failures"},
      {:summary, "12s · 2 reqs"}
    ]

    for line <- rendered(rows, 80),
        span <- line.spans,
        String.trim(span.content) not in ["", "└"] do
      assert span.style.fg != :dark_gray, "#{inspect(span.content)} is too dark to read"
    end
  end

  # The complaint this answers: every tool row shared one colour, so a
  # screenful of them was a block of text rather than something to scan.
  test "each kind of tool work gets its own heading colour" do
    colours =
      for {kind, verb} <- [
            {:explore, "Explored"},
            {:search, "Searched the web for"},
            {:run, "Ran"},
            {:edit, "Edited"},
            {:eval, "Evaluated Elixir"}
          ] do
        [line] = rendered([{:tool_heading, "call", kind, verb, ""}])
        line.spans |> hd() |> Map.fetch!(:style) |> Map.fetch!(:fg)
      end

    assert Enum.uniq(colours) == colours, "heading colours repeat: #{inspect(colours)}"
  end

  # A renderer may bring a kind of its own. The theme has no slot for it, so
  # it is drawn in the plain text colour rather than refused; a renderer that
  # reuses a shipped kind gets that kind's colour.
  test "a kind no theme slot names is drawn plain, and a reused one borrows its colour" do
    [own] = rendered([{:tool_heading, "call", :deploy, "Deployed", "staging"}])
    [borrowed] = rendered([{:tool_heading, "call", :edit, "Patched", "a.ex"}])

    assert own.spans |> hd() |> Map.fetch!(:style) |> Map.fetch!(:fg) == :white
    assert borrowed.spans |> hd() |> Map.fetch!(:style) |> Map.fetch!(:fg) == :light_green
    assert Enum.map_join(own.spans, & &1.content) == "• Deployed staging"
  end

  # An approval card is a question put to the person, so its heading is
  # drawn in the question's colour rather than a tool's or the plain one.
  test "an approval heading borrows the question colour" do
    [card] = rendered([{:tool_heading, "call", :approval, "Approve", "rm -rf tmp?"}])

    assert card.spans |> hd() |> Map.fetch!(:style) |> Map.fetch!(:fg) == :yellow
    assert Enum.map_join(card.spans, & &1.content) == "• Approve rm -rf tmp?"
  end

  test "a heading keeps its verb accented and its subject plain" do
    [line] = rendered([{:tool_heading, "call", :run, "Ran", "mix test"}])

    assert Enum.map_join(line.spans, & &1.content) == "• Ran mix test"

    assert Enum.any?(
             line.spans,
             &(&1.content == "Ran" and &1.style.fg == :light_yellow and
                 :bold in &1.style.modifiers)
           )

    assert Enum.any?(line.spans, &(&1.content == " mix test" and &1.style.fg == :white))
  end

  test "highlighted commands wrap without changing quoted whitespace or interpreting Markdown" do
    command = ~S(printf '%s  **literal**' "a  b" foo\ bar)
    call = %{id: "shell", name: "bash", arguments: %{"command" => command}}

    for theme <- [Theme.dark(), Theme.light(), Theme.mono()], width <- [1, 19, 80] do
      rows = ToolText.call(call, false, Renderer.builtin(), theme)
      lines = RichText.lines(rows, width, theme)
      spans = Enum.flat_map(lines, & &1.spans)

      assert Enum.map_join(spans, & &1.content) == "• Ran " <> command

      assert Enum.all?(
               lines,
               &(String.length(Enum.map_join(&1.spans, fn s -> s.content end)) <= width)
             )

      assert Enum.all?(spans, &is_nil(&1.style.bg))

      for line <- lines, do: assert(%{"spans" => [_ | _]} = Encode.to_wire_line!(line))

      if theme.name == "mono", do: assert(Enum.all?(spans, &is_nil(&1.style.fg)))
    end
  end

  test "wrapping carries each command token's highlighting across rows" do
    call = %{
      id: "shell",
      name: "bash",
      arguments: %{"command" => "mix test --warnings-as-errors"}
    }

    rows = ToolText.call(call)

    character_styles = fn width ->
      for line <- rendered(rows, width),
          span <- line.spans,
          char <- String.graphemes(span.content),
          do: {char, span.style}
    end

    assert character_styles.(9) == character_styles.(80)
    assert character_styles.(9) |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 3
  end

  # A failed call and a successful one arrive through the same path. Without
  # the tone the only difference on screen was the wording of the output.
  test "failed tool output is red where successful output recedes" do
    [failed] = rendered([{:tool_output, "call", :first, :error, "exit status 1"}], 80)
    [passed] = rendered([{:tool_output, "call", :first, :ok, "exit status 0"}], 80)

    assert Enum.any?(failed.spans, &(&1.content == "exit status 1" and &1.style.fg == :light_red))
    assert Enum.any?(passed.spans, &(&1.content == "exit status 0" and &1.style.fg == :gray))
  end

  # `preserve/2` keeps whitespace where `wrap/2` collapses it, so a newline
  # reaching it has to become another line. Building a span around it raises
  # inside the draw loop instead, which ends the terminal rather than
  # mis-drawing one row — this is how a `write` result took down a session.
  test "a row whose spans carry newlines becomes more lines, not a crash" do
    code = [
      %ExRatatui.Text.Span{content: "x = 1", style: %Style{}},
      %ExRatatui.Text.Span{content: "\n", style: %Style{}}
    ]

    lines = rendered([{:tool_code, "call", :add, code}])

    assert text(lines) =~ "x = 1"

    refute Enum.any?(lines, fn %Line{spans: spans} ->
             Enum.any?(spans, &String.contains?(&1.content, "\n"))
           end)
  end

  test "questions, choices, and answers retain their interaction hierarchy" do
    [question, option, answer] =
      rendered([
        {:tool_question, "call", "which database?"},
        {:tool_option, "call", 1, "Postgres", "Use the existing service"},
        {:tool_answer, "call", "Postgres"}
      ])

    assert Enum.map_join(question.spans, & &1.content) == "? which database?"
    assert Enum.all?(question.spans, &(&1.style.fg == :yellow and :bold in &1.style.modifiers))
    assert Enum.map_join(option.spans, & &1.content) == "1. Postgres — Use the existing service"
    assert Enum.map_join(answer.spans, & &1.content) == "› Postgres"
  end

  # Every row the screen can hold, rendered under every palette and then
  # encoded the way the runtime encodes it before painting. The tests above
  # assert on the structs `lines/3` returns, which is what lets them run
  # without a terminal — and is also why a style holding something that is
  # not a colour passed every one of them. The painter is the first thing
  # that checks, and it checked on a live screen: a delegated tool's heading
  # carried a whole theme group where its accent colour should have been,
  # `ExRatatui.Text.Encode.encode_color/1` had no clause for a map, and every
  # frame of one session failed to draw from the moment `delegate` ran
  # (2026-09-18). These encode what `lines/3` returns through the same
  # module, so that class of mistake fails here.
  describe "painting" do
    @tool_kinds [:explore, :search, :run, :edit, :write, :eval, :other]
    @statuses ["queued", "running", "ok", "failed", "timeout", "cancelled", "budget_exhausted"]

    # A single-quote heredoc, because the sample itself holds a `"""` heredoc.
    @markdown ~S'''
    # Heading one
    ## Heading two
    > quoted
    - bullet
      * nested
    3. third
    ---
    | left | right |
    |:-----|------:|
    | `mix test` | **1** |
    ```elixir
    """
    heredoc
    """
    ```
    ```diff
    +added
    -removed
    @@ hunk
     context
    ```
    ~~~
    plain fence
    ~~~
    ```
    never closed
    '''

    # One of everything `lines/3` has a clause for, so a row kind added later
    # has to be added here to be drawn at all.
    defp every_row(theme) do
      [
        {:model, "plain **bold** *italic* `code` and an unclosed *marker"},
        {:model, ""},
        {:lmx, "error: it broke"},
        {:lmx, "? a question"},
        {:lmx, "  · an activity"},
        {:lmx, "a remark"},
        {:you, "what was typed"},
        {:space, ""},
        {:summary, "1m · 2 req"},
        {:notice, "found something; and what to do about it"},
        {:notice, "found something else"},
        {:tool_detail, "id", :explore, "Read lib/x.ex"},
        {:tool_detail, "id", :ordinary, "a detail"},
        {:tool_output, "id", :first, :ok, "first line of output"},
        {:tool_output, "id", :rest, :error, "a failed line"},
        {:tool_question, "id", "which one?"},
        {:tool_option, "id", 1, "This", "with a description"},
        {:tool_option, "id", 2, "That", nil},
        {:tool_answer, "id", "this"},
        {:tool_code, "id", :add, [Span.new("added")]},
        {:tool_code, "id", :delete, [Span.new("removed")]},
        {:context_bar,
         [{:system, 0.2}, {:tools, 0.3}, {:conversation, 0.1}, {:output, 0.1}, {:free, 0.3}]},
        {:context_key,
         [
           {:system, "system prompt 1.0k"},
           {:tools, "tools & MCP 2.0k"},
           {:conversation, "conversation 500"},
           {:output, "model output 100"},
           {:free, "free 96.4k"}
         ]},
        {:model_code, nil, "still streaming", nil}
      ] ++
        Enum.map(@tool_kinds, &{:tool_heading, "id", &1, "Ran", "the subject"}) ++
        Enum.map(@statuses, fn status ->
          {:subagent_child,
           %{
             id: "child-" <> status,
             name: "ada-lovelace",
             kind: "scout",
             goal: "find the thing",
             status: status,
             activity: "read x",
             count: 3,
             text: "read lib/x.ex"
           }}
        end) ++
        Blocks.rows(@markdown, theme)
    end

    # Wraps a style the way the painter meets it, so a style is checked by
    # the same clauses a span's is.
    defp encode_style!(style),
      do: Encode.to_wire_line!(%Line{spans: [Span.new("x", style: style)]})

    test "every row under every theme encodes for the painter" do
      for name <- Theme.names(), {:ok, theme} = Theme.named(name), width <- [24, 80] do
        rows = every_row(theme)
        lines = RichText.lines(rows, width, theme)

        assert length(lines) >= length(rows)

        for line <- lines do
          assert %{"spans" => spans} = Encode.to_wire_line!(line)
          assert is_list(spans)
        end
      end
    end

    test "no row renders wider than the pane it was given" do
      for name <- Theme.names(), {:ok, theme} = Theme.named(name), width <- [24, 80, 120] do
        for line <- RichText.lines(every_row(theme), width, theme) do
          text = Enum.map_join(line.spans, & &1.content)
          assert String.length(text) <= width, "#{inspect(text)} is wider than #{width}"
        end
      end
    end

    test "every colour slot of every theme is a colour the painter accepts" do
      for name <- Theme.names(), {:ok, theme} = Theme.named(name) do
        colours =
          [:voices, :text, :tools, :children, :blocks, :context]
          |> Enum.flat_map(&Map.values(Map.fetch!(theme, &1)))
          |> Kernel.++([theme.accent, theme.elixir_accent])
          |> Enum.reject(&is_nil/1)

        for colour <- colours do
          assert %{"spans" => [_span]} = encode_style!(%Style{fg: colour, bg: colour})
        end
      end
    end
  end
end
