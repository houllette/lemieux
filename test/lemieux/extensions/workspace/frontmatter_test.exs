defmodule Lemieux.Extensions.Workspace.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Frontmatter

  test "valid YAML is read as YAML" do
    assert {:ok, %{"name" => "scout", "tools" => ["Read", "Grep"], "draft" => true}} =
             Frontmatter.parse("name: scout\ntools:\n  - Read\n  - Grep\ndraft: true")
  end

  # The shape Claude Code's `/agents` writes: the whole description on one
  # line, a colon inside it and literal \n sequences. Strict YAML refuses the
  # `including:`; Claude Code reads it, and so must a person's own agents.
  test "a Claude Code agent file that is not strict YAML is read the way Claude Code reads it" do
    frontmatter =
      "name: elixir-expert\n" <>
        "description: Use this agent for Elixir work, including: writing tests first." <>
        "\\n\\nExamples:\\n- User: 'I need a GenServer'\n" <>
        "model: inherit\n" <>
        "color: purple"

    assert {:error, _strict} = YamlElixir.read_from_string(frontmatter)

    assert {:ok, attributes} = Frontmatter.parse(frontmatter)
    assert attributes["name"] == "elixir-expert"
    assert attributes["model"] == "inherit"
    assert attributes["color"] == "purple"

    assert attributes["description"] ==
             "Use this agent for Elixir work, including: writing tests first.\n\nExamples:\n- User: 'I need a GenServer'"
  end

  test "the lenient reading keeps lists, continuations, quotes and booleans" do
    frontmatter =
      "name: \"quoted: name\"\n" <>
        "description: first line: with a colon\n" <>
        "  continued here\n" <>
        "tools:\n" <>
        "  - Read\n" <>
        "  - Grep\n" <>
        "disable-model-invocation: true"

    assert {:error, _strict} = YamlElixir.read_from_string(frontmatter)

    assert {:ok, attributes} = Frontmatter.parse(frontmatter)
    assert attributes["name"] == "quoted: name"
    assert attributes["description"] == "first line: with a colon\ncontinued here"
    assert attributes["tools"] == ["Read", "Grep"]
    assert attributes["disable-model-invocation"] == true
  end

  test "a block neither reading understands is refused with a sentence, not a struct" do
    # Indented, so no top-level key for the lenient reading; not YAML either.
    assert {:error, {:invalid, positioned}} = Frontmatter.parse("  a: b: c")
    assert positioned =~ ~r/line \d+, column \d+: /
    refute positioned =~ "%YamlElixir"

    assert {:error, {:invalid, unpositioned}} = Frontmatter.parse("  : [unbalanced\n  }{")
    assert is_binary(unpositioned)
    refute unpositioned =~ "%YamlElixir"
  end

  test "YAML that is not an object is refused as such" do
    assert {:error, :not_an_object} = Frontmatter.parse("- just\n- a list")
  end
end
