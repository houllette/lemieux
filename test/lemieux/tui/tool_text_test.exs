defmodule Lemieux.TUI.ToolTextTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CodeBlock
  alias ExRatatui.Style
  alias ExRatatui.Text.Span
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText

  test "long output keeps two head and two tail rows around one marker" do
    rows = ToolText.output_rows("call", Enum.join(1..10, "\n"), 80)

    assert Enum.map(rows, &text/1) == [
             "1",
             "2",
             "… 6 lines hidden · full result in transcript",
             "9",
             "10"
           ]
  end

  test "each stored output row fits one rendered row at the requested width" do
    rows = ToolText.output_rows("call", String.duplicate("x", 200), 20)

    clipped = String.duplicate("x", 16)
    assert [^clipped, marker] = Enum.map(rows, &text/1)
    assert String.starts_with?(marker, "… long lines")

    assert Enum.all?(rows, &(String.length(text(&1)) <= 16))
  end

  test "ask_user calls leave a compact receipt outside the question panel" do
    rows =
      ToolText.call(%{
        id: "question",
        name: "ask_user",
        arguments: %{
          "question" => "which database?",
          "options" => [
            %{"label" => "Postgres", "description" => "Use the existing service"},
            %{"label" => "SQLite"}
          ]
        }
      })

    assert rows == [{:tool_heading, "question", :ordinary, "Asked user", ""}]
  end

  test "a failed call carries its tone onto every output row" do
    rows = ToolText.output_rows("call", "boom\nagain", 80, :error)

    assert Enum.all?(rows, &match?({:tool_output, "call", _position, :error, _text}, &1))
  end

  # The syntax highlighter returns each source line with its own trailing
  # newline still attached to the last span. A `:tool_code` row is already one
  # line, so carrying that terminator through is not merely redundant: the
  # renderer rebuilds these spans, and `ExRatatui.Text.Span.new/2` refuses a
  # span containing a newline by raising — from inside the draw loop, which
  # ends the terminal.
  test "code rows carry no line terminator into their spans" do
    {:replace, rows} =
      ToolText.result(
        %{
          id: "call",
          name: "write",
          arguments: %{"path" => "a.ex", "content" => "x = 1\ny = 2\n"}
        },
        %{"error" => false, "output" => "ok"},
        Theme.default()
      )

    code = for {:tool_code, _id, _change, _number, spans} <- rows, do: spans

    assert length(code) == 2
    assert Enum.all?(code, fn spans -> Enum.all?(spans, &(&1.content != "")) end)
    refute Enum.any?(code, fn spans -> Enum.any?(spans, &String.contains?(&1.content, "\n")) end)
  end

  # The code in an edit used to be highlighted with the dark palette whatever
  # theme was showing, so a light terminal got dark-background code in the one
  # place `/theme light` did not reach.
  describe "an edit's code takes its colours from the theme" do
    @write %{id: "call", name: "write", arguments: %{"path" => "a.ex", "content" => "x = 1"}}
    @done %{"error" => false, "output" => "ok"}

    test "the light theme's rows are the light highlighter's, not the dark one's" do
      {:replace, rows} = ToolText.result(@write, @done, Theme.light())

      assert colours(rows) == highlighted("x = 1", Theme.light().blocks.code_theme)
      refute colours(rows) == highlighted("x = 1", :base16_ocean_dark)
    end

    test "the dark theme still draws what it always did" do
      {:replace, rows} = ToolText.result(@write, @done, Theme.default())

      assert colours(rows) == highlighted("x = 1", :base16_ocean_dark)
    end

    test "the mono theme draws code plain" do
      {:replace, rows} = ToolText.result(@write, @done, Theme.mono())

      assert [[%Span{content: "x = 1", style: %Style{fg: nil, bg: nil}}]] = code_spans(rows)
    end
  end

  defp code_spans(rows), do: for({:tool_code, _id, _change, _number, spans} <- rows, do: spans)

  defp colours(rows),
    do: for(spans <- code_spans(rows), span <- spans, do: {span.style.fg, span.style.bg})

  defp highlighted(source, code_theme) do
    source
    |> CodeBlock.highlight("elixir", code_theme)
    |> Enum.flat_map(fn line ->
      for span <- line.spans,
          String.trim(span.content, "\n") != "",
          do: {span.style.fg, span.style.bg}
    end)
  end

  describe "shell command headings" do
    @command ~s(LMX_CONFIG=none mix test --warnings-as-errors "test/my test.exs" && echo "$HOME")
    @bash %{id: "bash-1", name: "bash", arguments: %{"command" => @command}}

    test "commands, flags, arguments, and quoted values have distinct styles" do
      assert [{:tool_heading, "bash-1", :run, "Ran", @command, spans} = row] =
               ToolText.call(@bash, false, Renderer.builtin(), Theme.dark())

      assert Enum.map_join(spans, & &1.content) == @command
      assert Enum.all?(spans, &is_nil(&1.style.bg))

      colours =
        for part <- ["mix", "test ", "--warnings-as-errors", "test/my test.exs"],
            do: style_at(spans, part).fg

      assert length(Enum.uniq(colours)) == 4
      assert style_at(spans, "HOME").fg != style_at(spans, "test ").fg
      assert Renderer.check_rows([row], "bash-1") == :ok
      assert ToolText.announced?([row], "bash-1")
      assert ToolText.call_id(row) == "bash-1"
    end

    test "command highlighting follows the current code palette and mono stays uncoloured" do
      rows =
        for theme <- [Theme.dark(), Theme.light(), Theme.mono()] do
          [{:tool_heading, "bash-1", :run, "Ran", @command, spans}] =
            ToolText.call(@bash, false, Renderer.builtin(), theme)

          assert Enum.map_join(spans, & &1.content) == @command
          assert Enum.all?(spans, &is_nil(&1.style.bg))
          spans
        end

      [dark, light, mono] = rows
      assert style_at(dark, "mix").fg != style_at(light, "mix").fg
      assert Enum.all?(mono, &is_nil(&1.style.fg))
    end

    test "the heading highlights only the displayed first line, keeping quotes and escapes literal" do
      command = ~S(printf '%s  **literal**' "a  b" foo\ bar) <> "\necho next"
      call = put_in(@bash.arguments["command"], command)

      [{:tool_heading, "bash-1", :run, "Ran", shown, spans}] =
        ToolText.call(call, false, Renderer.builtin(), Theme.dark())

      assert shown == hd(String.split(command, "\n"))
      assert Enum.map_join(spans, & &1.content) == shown
      refute Enum.any?(spans, &String.contains?(&1.content, "\n"))
    end
  end

  defp style_at(spans, text) do
    {start, _length} = :binary.match(Enum.map_join(spans, & &1.content), text)

    Enum.reduce_while(spans, 0, fn span, offset ->
      next = offset + byte_size(span.content)
      if next > start, do: {:halt, span.style}, else: {:cont, next}
    end)
  end

  defp text({:tool_output, _id, _position, _tone, text}), do: text
end

defmodule Lemieux.TUI.ToolTextRendererTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText

  defmodule ReadCard do
    @moduledoc false
    @behaviour Lemieux.TUI.Renderer

    @impl Lemieux.TUI.Renderer
    def call(call, _exploring?),
      do: [{:tool_heading, call.id, :explore, "Opened", call.arguments["path"]}]

    @impl Lemieux.TUI.Renderer
    def result(call, result, _theme),
      do:
        {:replace,
         [{:tool_heading, call.id, :explore, "Opened", "#{byte_size(result.output)} bytes"}]}
  end

  defmodule Announcement do
    @moduledoc false
    @behaviour Lemieux.TUI.Renderer

    @impl Lemieux.TUI.Renderer
    def call(call, _exploring?),
      do: [{:tool_heading, call.id, :search, "Asked the index", call.arguments["query"]}]
  end

  defmodule Nameless do
    @moduledoc false
    @behaviour Lemieux.TUI.Renderer

    @impl Lemieux.TUI.Renderer
    def call(_call, _exploring?), do: [{:tool_heading, nil, :other, "Ran", "something"}]

    @impl Lemieux.TUI.Renderer
    def result(_call, _result, _theme), do: {:replace, [{:tool_detail, "other", :ordinary, "x"}]}
  end

  defmodule Silent do
    @moduledoc false
    @behaviour Lemieux.TUI.Renderer

    @impl Lemieux.TUI.Renderer
    def call(_call, _exploring?), do: []

    @impl Lemieux.TUI.Renderer
    def result(_call, _result, _theme), do: :none
  end

  @read %{id: "r1", name: "read", arguments: %{"path" => "lib/x.ex"}}
  @mcp %{id: "m1", name: "index__search", arguments: %{"query" => "where is it"}}
  @done %{"error" => false, "output" => "found it"}
  @failed %{"error" => true, "output" => "no such index"}

  defp registry(extra), do: Renderer.registry!(extra)

  test "a renderer registered for read replaces the built-in rows, live and on resume" do
    registry = registry(%{"read" => ReadCard})

    assert ToolText.call(@read, false, registry) ==
             [{:tool_heading, "r1", :explore, "Opened", "lib/x.ex"}]

    assert ToolText.result(@read, @done, Theme.dark(), registry) ==
             {:replace, [{:tool_heading, "r1", :explore, "Opened", "8 bytes"}]}

    # And without it, what the screen always drew.
    assert ToolText.call(@read, false) ==
             [
               {:tool_heading, nil, :explore, "Explored", ""},
               {:tool_detail, "r1", :explore, "Read lib/x.ex"}
             ]

    assert ToolText.result(@read, @done, Theme.dark()) == :none
  end

  test "an MCP-shaped name with a registered renderer gets its own rows" do
    registry = registry(%{"index__search" => Announcement})

    assert ToolText.call(@mcp, false, registry) ==
             [{:tool_heading, "m1", :search, "Asked the index", "where is it"}]
  end

  test "a renderer without result/3 gets the generic result" do
    registry = registry(%{"index__search" => Announcement})

    assert ToolText.result(@mcp, @done, Theme.dark(), registry) == {:output, "found it"}
  end

  test "an unregistered MCP name still gets the generic rows" do
    assert ToolText.call(@mcp, false) == [
             {:tool_heading, "m1", :other, "Ran", "index__search"},
             {:tool_detail, "m1", :ordinary, "where is it"}
           ]

    assert ToolText.result(@mcp, @done, Theme.dark()) == {:output, "found it"}
  end

  test "a renderer whose rows carry no call id is rejected and the generic rows appear" do
    registry = registry(%{"index__search" => Nameless})
    rows = ToolText.call(@mcp, false, registry)

    assert [
             {:tool_heading, "m1", :other, "Ran", "index__search"},
             {:tool_detail, "m1", :ordinary, "where is it"},
             {:tool_detail, "m1", :ordinary, notice}
           ] = rows

    assert notice =~ "Nameless returned rows none of which carries call id"
    assert notice =~ "drawn plainly"

    # The rows that appeared are usable: the call counts as announced, and every
    # row is one the call's result can find and replace.
    assert ToolText.announced?(rows, "m1")
    assert Enum.all?(rows, &(ToolText.call_id(&1) == "m1"))
  end

  test "a renderer whose result rows name another call is rejected the same way" do
    registry = registry(%{"index__search" => Nameless})

    assert {:output, output} = ToolText.result(@mcp, @done, Theme.dark(), registry)
    assert [notice, "found it"] = String.split(output, "\n")
    assert notice =~ "Nameless returned a row naming call \"other\", not \"m1\""
  end

  test "a renderer may say nothing at all" do
    registry = registry(%{"index__search" => Silent})

    assert ToolText.call(@mcp, false, registry) == []
    assert ToolText.result(@mcp, @done, Theme.dark(), registry) == :none
  end

  test "a failure is drawn as output whatever the renderer says" do
    registry = registry(%{"index__search" => Silent, "read" => Silent})

    assert ToolText.result(@mcp, @failed, Theme.dark(), registry) == {:output, "no such index"}
    assert ToolText.result(@read, @failed, Theme.dark(), registry) == {:output, "no such index"}
  end

  test "a renderer is given the call normalised, however the event spelled it" do
    defmodule Echo do
      @moduledoc false
      @behaviour Lemieux.TUI.Renderer

      @impl Lemieux.TUI.Renderer
      def call(call, exploring?),
        do: [{:tool_heading, call.id, :other, inspect({call, exploring?}), ""}]
    end

    registry = registry(%{"index__search" => Echo})

    [{:tool_heading, "m1", :other, seen, ""}] =
      ToolText.call(
        %{"id" => "m1", "name" => "index__search", "arguments" => %{"query" => "q"}},
        true,
        registry
      )

    assert seen ==
             inspect({%{id: "m1", name: "index__search", arguments: %{"query" => "q"}}, true})
  end
end
