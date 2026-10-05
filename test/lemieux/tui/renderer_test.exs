defmodule Lemieux.TUI.RendererTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Text.Span
  alias Lemieux.TUI.Renderer
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText

  defmodule Card do
    @moduledoc false
    @behaviour Lemieux.TUI.Renderer

    @impl Lemieux.TUI.Renderer
    def call(call, _exploring?), do: [{:tool_heading, call.id, :other, "Card", call.name}]
  end

  @call %{id: "c1", name: "server__tool", arguments: %{"query" => "where is it", "n" => 3}}

  describe "the generic renderer" do
    test "announces a tool it has no verb for as Ran NAME with its first string argument" do
      assert Renderer.call(@call, false) == [
               {:tool_heading, "c1", :other, "Ran", "server__tool"},
               {:tool_detail, "c1", :ordinary, "where is it"}
             ]
    end

    test "says nothing under the heading when no argument is a string" do
      assert Renderer.call(%{@call | arguments: %{"n" => 3}}, false) ==
               [{:tool_heading, "c1", :other, "Ran", "server__tool"}]
    end

    test "shows a result as output" do
      assert Renderer.result(@call, %{output: "42", payload: %{}}, Theme.dark()) ==
               {:output, "42"}
    end
  end

  describe "the registry" do
    test "the built-ins cover every tool the screen has a verb for" do
      assert Renderer.builtin() |> Map.keys() |> Enum.sort() ==
               [
                 "apply_patch",
                 "ask_user",
                 "bash",
                 "edit",
                 "elixir",
                 "read",
                 "web_search",
                 "write"
               ]
    end

    test "merges a host's renderers over the built-ins, and falls back to the generic one" do
      assert {:ok, registry} = Renderer.registry(%{"server__tool" => Card, "read" => Card})

      assert Renderer.module(registry, "server__tool") == Card
      assert Renderer.module(registry, "read") == Card
      assert Renderer.module(registry, "bash") == Renderer.builtin()["bash"]
      assert Renderer.module(registry, "never_registered") == Renderer
    end

    test "nothing extra is the built-in map" do
      assert Renderer.registry(%{}) == {:ok, Renderer.builtin()}
    end

    test "refuses a value that is not a renderer, and a key that is not a tool name" do
      assert Renderer.registry(%{"read" => :not_a_module, "" => Card, 7 => Card}) ==
               {:error,
                [
                  "\"\": a tool name must be a non-empty string",
                  "7: a tool name must be a non-empty string",
                  "read: :not_a_module does not implement Lemieux.TUI.Renderer"
                ]}

      assert Renderer.registry(%{"read" => Enum}) ==
               {:error, ["read: Enum does not implement Lemieux.TUI.Renderer"]}
    end

    test "registry!/1 raises with the same problems" do
      assert_raise ArgumentError, ~r/read: :nope does not implement/, fn ->
        Renderer.registry!(%{"read" => :nope})
      end

      assert Renderer.registry!(%{"server__tool" => Card})["server__tool"] == Card
    end
  end

  describe "check_rows/2, the invariant every renderer is held to" do
    test "accepts what the built-ins return, and an empty list" do
      for name <- Map.keys(Renderer.builtin()) do
        call = %{id: "ok", name: name, arguments: %{"path" => "a", "command" => "b"}}
        rows = Renderer.module(Renderer.builtin(), name).call(call, false)

        assert Renderer.check_rows(rows, "ok") == :ok, name
      end

      assert Renderer.check_rows([], "ok") == :ok
    end

    test "accepts the group heading the shipped exploration rows use" do
      rows = ToolText.exploration("r1", "Read a.ex", false)

      assert {:tool_heading, nil, :explore, "Explored", ""} in rows
      assert Renderer.check_rows(rows, "r1") == :ok
    end

    test "rejects something that is not a list of rows" do
      assert Renderer.check_rows(:rows, "c1") == {:error, "returned :rows, not a list of rows"}
    end

    test "rejects a row of a shape the screen cannot measure" do
      assert Renderer.check_rows([{:banner, "hello"}], "c1") ==
               {:error, "returned a row that is not a transcript row: {:banner, \"hello\"}"}

      # A known tag with the wrong fields is not a row either.
      assert {:error, _reason} = Renderer.check_rows([{:tool_heading, "c1", "run", 1, 2}], "c1")

      assert {:error, _reason} =
               Renderer.check_rows([{:tool_output, "c1", :middle, :ok, "x"}], "c1")

      assert {:error, _reason} = Renderer.check_rows([{:tool_code, "c1", :add, ["x"]}], "c1")
    end

    test "rejects a code row whose span carries a newline, which the draw loop cannot" do
      rows = [{:tool_code, "c1", :add, [Span.new("x"), %Span{content: "y\n"}]}]

      assert {:error, _reason} = Renderer.check_rows(rows, "c1")
    end

    test "highlighted headings must draw the exact command and carry no embedded newlines" do
      valid = {:tool_heading, "c1", :run, "Ran", "mix test", [Span.new("mix test")]}
      assert Renderer.check_rows([valid], "c1") == :ok

      for spans <- [[Span.new("different command")], [%Span{content: "mix test\n"}], ["mix test"]] do
        row = {:tool_heading, "c1", :run, "Ran", "mix test", spans}
        assert {:error, _reason} = Renderer.check_rows([row], "c1")
      end
    end

    test "rejects a row that names another call" do
      rows = [{:tool_heading, "c1", :other, "Ran", "x"}, {:tool_detail, "c2", :ordinary, "y"}]

      assert Renderer.check_rows(rows, "c1") ==
               {:error, "returned a row naming call \"c2\", not \"c1\""}
    end

    test "rejects rows none of which announces the call" do
      assert Renderer.check_rows([{:tool_heading, nil, :other, "Ran", "x"}], "c1") ==
               {:error, "returned rows none of which carries call id \"c1\""}

      # Output alone is not an announcement: a call whose rows were only
      # output would be drawn again by every re-delivered call event.
      assert {:error, _reason} =
               Renderer.check_rows([{:tool_output, "c1", :first, :ok, "x"}], "c1")
    end
  end

  describe "check_outcome/2" do
    test "accepts the four outcomes with well-formed payloads" do
      assert Renderer.check_outcome(:none, "c1") == :ok
      assert Renderer.check_outcome({:output, "text"}, "c1") == :ok
      assert Renderer.check_outcome({:answer, "text"}, "c1") == :ok

      assert Renderer.check_outcome({:replace, [{:tool_heading, "c1", :other, "Ran", "x"}]}, "c1") ==
               :ok
    end

    test "holds replacement rows to the row invariant" do
      assert Renderer.check_outcome({:replace, [{:tool_heading, "c2", :other, "Ran", "x"}]}, "c1") ==
               {:error, "returned a row naming call \"c2\", not \"c1\""}
    end

    test "rejects anything else" do
      assert Renderer.check_outcome({:output, 42}, "c1") ==
               {:error, "returned {:output, 42}, not an outcome"}

      assert Renderer.check_outcome(:done, "c1") == {:error, "returned :done, not an outcome"}
    end
  end
end
