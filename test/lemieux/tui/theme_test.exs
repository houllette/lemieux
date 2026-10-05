defmodule Lemieux.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Colour
  alias Lemieux.TUI.Theme

  defp colours(%Theme{} = theme) do
    [:voices, :text, :tools, :children, :blocks, :context]
    |> Enum.flat_map(&Map.values(Map.fetch!(theme, &1)))
    |> Kernel.++([theme.accent, theme.elixir_accent])
  end

  test "the default is the dark palette the screen has always drawn" do
    assert Theme.default() == Theme.dark()
    assert Theme.dark().accent == :cyan
    assert Theme.dark().elixir_accent == :magenta
    assert Theme.dark().voices.you == :cyan
    assert Theme.dark().tools.edit == :light_green
  end

  test "every name the menu offers is one named/1 finds, case-insensitively" do
    for name <- Theme.names() do
      assert {:ok, %Theme{name: ^name}} = Theme.named(name)
      assert {:ok, %Theme{name: ^name}} = Theme.named(String.upcase(name))
    end

    assert Theme.named("sepia") == :error
  end

  test "every palette fills every slot the renderer reads" do
    for name <- Theme.names(), {:ok, theme} = Theme.named(name) do
      assert Map.keys(theme.voices) == Map.keys(Theme.dark().voices)
      assert Map.keys(theme.text) == Map.keys(Theme.dark().text)
      assert Map.keys(theme.tools) == Map.keys(Theme.dark().tools)
      assert Map.keys(theme.children) == Map.keys(Theme.dark().children)
      assert Map.keys(theme.blocks) == Map.keys(Theme.dark().blocks)
      assert Map.keys(theme.context) == Map.keys(Theme.dark().context)
    end
  end

  # The numbers `Theme.light/0` documents, measured. xterm, Terminal.app's
  # Basic and Clear Light, and a light VS Code all draw on #ffffff; the
  # sixteen named colours on those pages were where 1.0–2.7:1 came from.
  @white {255, 255, 255}

  defp contrast(colour, on), do: Colour.contrast(Colour.rgb(colour), on)

  test "light draws every slot a person reads at WCAG AA on white" do
    light = Theme.light()

    read =
      [light.accent, light.elixir_accent] ++
        Map.values(light.voices) ++
        [light.text.muted, light.text.error] ++
        Map.values(light.tools) ++
        Map.values(light.children) ++
        [light.blocks.heading, light.blocks.quote, light.blocks.code]

    for colour <- read, not is_nil(colour) do
      assert contrast(colour, @white) >= 4.5, "#{inspect(colour)} is below 4.5:1 on white"
    end

    # The terminal's own foreground, which its owner already reads.
    assert light.text.plain == nil
    assert light.voices.you_text == nil
    assert light.blocks.code_theme == :inspired_github
  end

  test "light draws its glyphs at the 3:1 asked of non-text" do
    light = Theme.light()

    for colour <- [light.text.gutter, light.blocks.rule | Map.values(light.context)] do
      assert contrast(colour, @white) >= 3.0, "#{inspect(colour)} is below 3:1 on white"
    end
  end

  test "light's code and diff text is legible on its tints, in 24-bit and in 256 colours" do
    light = Theme.light()

    for {text, tint} <- [
          {light.blocks.code, light.blocks.code_bg},
          {light.blocks.add, light.blocks.add_bg},
          {light.blocks.delete, light.blocks.delete_bg}
        ],
        tint <- [tint, Colour.downsample(tint)] do
      assert contrast(text, Colour.rgb(tint)) >= 4.5,
             "#{inspect(text)} is below 4.5:1 on #{inspect(tint)}"
    end
  end

  test "only a palette with a pale code tint is pale" do
    assert Theme.pale?(Theme.light())
    refute Theme.pale?(Theme.dark())
    refute Theme.pale?(Theme.mono())
  end

  test "mono has no colour in any slot and asks for no highlighting" do
    mono = Theme.mono()

    assert Enum.all?(colours(mono), &is_nil/1)
    assert mono.blocks.code_theme == nil
  end
end

defmodule Lemieux.TUI.ThemeMapTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Theme

  # What a config file or an extension carries: the dark palette with its
  # name changed and one colour re-picked, in the string-keyed shape.
  defp sepia_map do
    Theme.dark()
    |> Theme.to_map()
    |> Map.put("name", "sepia")
    |> put_in(["accent"], "#c08040")
  end

  describe "to_map/1 and from_map/1" do
    test "every shipped palette round-trips through the map form unchanged" do
      for name <- Theme.names(), {:ok, theme} = Theme.named(name) do
        assert Theme.from_map(Theme.to_map(theme)) == {:ok, theme}
      end
    end

    test "every shipped palette survives a trip through JSON" do
      for name <- Theme.names(), {:ok, theme} = Theme.named(name) do
        decoded = theme |> Theme.to_map() |> JSON.encode!() |> JSON.decode!()

        assert Theme.from_map(decoded) == {:ok, theme}
      end
    end

    test "the map is string-keyed, with colours as names, #rrggbb, or nil" do
      map = Theme.to_map(Theme.dark())

      assert map["name"] == "dark"
      assert map["accent"] == "cyan"
      assert map["voices"]["you_text"] == "light_cyan"
      assert map["blocks"]["code_bg"] == "#2b303b"
      assert map["blocks"]["code_theme"] == "base16_ocean_dark"

      assert Enum.all?(Map.keys(map), &is_binary/1)
      assert Enum.all?(Map.keys(map["voices"]), &is_binary/1)
    end

    test "mono's empty slots come back as nil, not as a colour" do
      map = Theme.to_map(Theme.mono())

      assert map["accent"] == nil
      assert map["voices"]["you"] == nil
      assert map["blocks"]["code_theme"] == nil

      {:ok, mono} = Theme.from_map(map)
      assert mono == Theme.mono()
      assert mono.voices.you == nil
    end

    test "a hex colour is read case-insensitively and written lower-case" do
      {:ok, theme} = Theme.from_map(Map.put(sepia_map(), "accent", "#FF8800"))

      assert theme.accent == {:rgb, 255, 136, 0}
      assert Theme.to_map(theme)["accent"] == "#ff8800"
    end

    test "a palette index is an integer, both ways" do
      {:ok, theme} = Theme.from_map(Map.put(sepia_map(), "accent", 208))

      assert theme.accent == {:indexed, 208}
      assert Theme.to_map(theme)["accent"] == 208
    end

    test "a colour name is read the way /color reads one" do
      {:ok, theme} = Theme.from_map(Map.put(sepia_map(), "accent", "Light-Magenta"))

      assert theme.accent == :light_magenta
    end

    test "names every bad slot at once rather than the first one" do
      map =
        sepia_map()
        |> put_in(["voices", "you"], "teal")
        |> put_in(["tools", "edit"], "#12345")
        |> put_in(["blocks", "code_theme"], "dracula")

      assert {:error, problems} = Theme.from_map(map)

      assert "voices.you: \"teal\" is not a colour" in problems
      assert "tools.edit: \"#12345\" is not a colour" in problems
      assert "blocks.code_theme: \"dracula\" is not a code theme" in problems
      assert length(problems) == 3
    end

    test "rejects a slot the renderer never reads, and says which" do
      map = put_in(sepia_map(), ["tools", "grep"], "cyan")

      assert Theme.from_map(map) == {:error, ["tools.grep: not a slot"]}
    end

    test "rejects a group it does not know" do
      map = Map.put(sepia_map(), "flavour", %{"sweet" => "red"})

      assert Theme.from_map(map) == {:error, ["flavour: not a group"]}
    end

    test "a missing slot or group is named, not defaulted" do
      map =
        sepia_map()
        |> update_in(["voices"], &Map.delete(&1, "notice"))
        |> Map.delete("context")

      assert {:error, problems} = Theme.from_map(map)
      assert "voices.notice: missing" in problems
      assert "context: missing" in problems
    end

    test "a group that is not a map of slots is rejected" do
      map = Map.put(sepia_map(), "voices", "cyan")

      assert Theme.from_map(map) == {:error, ["voices: not a map of slots"]}
    end

    test "the name must be a non-empty string" do
      assert Theme.from_map(Map.put(sepia_map(), "name", "")) ==
               {:error, ["name: must be a non-empty string"]}

      assert Theme.from_map(Map.delete(sepia_map(), "name")) == {:error, ["name: missing"]}
    end

    test "anything that is not a map is rejected in one line" do
      assert Theme.from_map("dark") == {:error, ["a theme must be a map of slot groups"]}
    end

    # The example a person would copy is held to the same validator as the
    # file they would paste it into.
    test "the example in docs/terminal-ui.md is a theme this reads" do
      docs = File.read!(Path.expand("../../../docs/terminal-ui.md", __DIR__))

      [example | _rest] =
        docs
        |> String.split("### Adding a theme", parts: 2)
        |> List.last()
        |> String.split("```json\n", parts: 2)
        |> List.last()
        |> String.split("\n```", parts: 2)

      assert {:ok, %Theme{name: "sepia", accent: {:rgb, 192, 128, 64}}} =
               example |> JSON.decode!() |> Theme.from_map()
    end
  end

  describe "the registry" do
    test "shipped/0 holds exactly the three palettes, under their names" do
      assert Map.keys(Theme.shipped()) |> Enum.sort() == ["dark", "light", "mono"]
      assert Theme.shipped()["light"] == Theme.light()
    end

    test "registry/1 merges a map over the shipped three, keyed by name" do
      assert {:ok, registry} = Theme.registry(%{"sepia" => sepia_map()})

      assert Theme.names(registry) == ["dark", "light", "mono", "sepia"]

      assert {:ok, %Theme{name: "sepia", accent: {:rgb, 192, 128, 64}}} =
               Theme.named("sepia", registry)

      assert {:ok, %Theme{name: "sepia"}} = Theme.named("SEPIA", registry)
      assert Theme.named("sepia") == :error
    end

    test "a struct registers as it is, and the key is the name /theme answers to" do
      warm = %{Theme.dark() | name: "Warm"}

      assert {:ok, registry} = Theme.registry(%{" Warm " => warm})
      assert {:ok, %Theme{name: "warm"}} = Theme.named("warm", registry)
      assert "warm" in Theme.names(registry)
    end

    test "a shipped name can be replaced" do
      assert {:ok, registry} = Theme.registry(%{"dark" => Map.put(sepia_map(), "name", "dark")})

      assert Theme.names(registry) == ["dark", "light", "mono"]
      assert {:ok, %Theme{accent: {:rgb, 192, 128, 64}}} = Theme.named("dark", registry)
    end

    test "nothing extra is the shipped three" do
      assert Theme.registry(%{}) == {:ok, Theme.shipped()}
      assert Theme.names(Theme.shipped()) == Theme.names()
    end

    test "a bad theme is reported under its key, with every problem" do
      bad = put_in(sepia_map(), ["voices", "you"], "teal")

      assert Theme.registry(%{"sepia" => bad, 7 => sepia_map(), "" => sepia_map()}) ==
               {:error,
                [
                  "\"\": a theme's name must be a non-empty string",
                  "7: a theme's name must be a non-empty string",
                  "sepia: voices.you: \"teal\" is not a colour"
                ]}

      assert Theme.registry(%{"sepia" => :dark}) ==
               {:error, ["sepia: a theme must be a map of slot groups or a Lemieux.TUI.Theme"]}
    end

    test "registry!/1 raises with the same problems, for a host that passed one" do
      assert_raise ArgumentError, ~r/sepia: voices.you: "teal" is not a colour/, fn ->
        Theme.registry!(%{"sepia" => put_in(sepia_map(), ["voices", "you"], "teal")})
      end

      assert Theme.registry!(%{"sepia" => sepia_map()}) |> Theme.names() ==
               ["dark", "light", "mono", "sepia"]
    end
  end
end
