defmodule Lemieux.Tools.Search.GlobPatternTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Search.GlobPattern

  defp matches(pattern, paths) do
    {:ok, glob} = GlobPattern.compile(pattern)
    Enum.filter(paths, &GlobPattern.match?(glob, &1))
  end

  @tree [
    "a.ex",
    "lib/a.ex",
    "lib/sub/b.ex",
    "lib/sub/deep/c.exs",
    "test/a_test.exs",
    ".credo.exs",
    ".github/workflows/ci.yml",
    "assets/app.ts",
    "assets/view.tsx",
    "notes/a[1].txt"
  ]

  test "a pattern without a slash matches file names at any depth" do
    # The Path.wildcard reading (top level only) is the one a model gets wrong:
    # asked for *.ex it would see a.ex and conclude there is one Elixir file.
    assert matches("*.ex", @tree) == ["a.ex", "lib/a.ex", "lib/sub/b.ex"]
  end

  test "a pattern with a slash is anchored at the search root" do
    assert matches("lib/*.ex", @tree) == ["lib/a.ex"]
    assert matches("/lib/*.ex", @tree) == ["lib/a.ex"]
    assert matches("./lib/*.ex", @tree) == ["lib/a.ex"]
  end

  test "** crosses directories and * does not" do
    assert matches("lib/**/*.ex", @tree) == ["lib/a.ex", "lib/sub/b.ex"]
    assert matches("lib/*/*.ex", @tree) == ["lib/sub/b.ex"]
    assert matches("**/*.exs", @tree) == ["lib/sub/deep/c.exs", "test/a_test.exs", ".credo.exs"]
  end

  test "a trailing ** matches everything below a directory" do
    assert matches("lib/**", @tree) == ["lib/a.ex", "lib/sub/b.ex", "lib/sub/deep/c.exs"]
  end

  test "a trailing slash names a directory and matches what is under it" do
    assert matches("sub/", @tree) == ["lib/sub/b.ex", "lib/sub/deep/c.exs"]
    assert matches("lib/sub/", @tree) == ["lib/sub/b.ex", "lib/sub/deep/c.exs"]
  end

  test "braces choose between alternatives" do
    assert matches("*.{ts,tsx}", @tree) == ["assets/app.ts", "assets/view.tsx"]
    assert matches("{lib,test}/*.ex*", @tree) == ["lib/a.ex", "test/a_test.exs"]
  end

  test "dotfiles are ordinary names" do
    assert matches("*.yml", @tree) == [".github/workflows/ci.yml"]
    assert matches(".*.exs", @tree) == [".credo.exs"]
  end

  test "? and bracket classes match one character within a segment" do
    assert matches("?.ex", @tree) == ["a.ex", "lib/a.ex", "lib/sub/b.ex"]
    assert matches("/?.ex", @tree) == ["a.ex"]
    assert matches("lib/?/b.ex", ["lib/s/b.ex", "lib/sub/b.ex", "lib//b.ex"]) == ["lib/s/b.ex"]
    assert matches("[ab].ex", @tree) == ["a.ex", "lib/a.ex", "lib/sub/b.ex"]
    assert matches("[!a].ex", @tree) == ["lib/sub/b.ex"]
  end

  test "an unterminated bracket is a literal character, not an error" do
    assert matches("a[1].txt", @tree) == []
    assert matches("a\\[1].txt", @tree) == ["notes/a[1].txt"]
    assert {:ok, _glob} = GlobPattern.compile("a[")
  end

  test "regular-expression metacharacters in a name are literal" do
    assert matches("a.ex", ["a.ex", "abex"]) == ["a.ex"]
    assert matches("(x)+.txt", ["(x)+.txt", "xx.txt"]) == ["(x)+.txt"]
  end

  test "an empty pattern is an error" do
    assert {:error, message} = GlobPattern.compile("  ")
    assert message =~ "empty"
  end
end
