defmodule Lemieux.Tools.Search.IgnoreTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Search.Ignore

  test "blank lines and comments are not rules" do
    assert Ignore.parse("\n# a comment\n\n", "") == []
  end

  test "a name without a slash is ignored at any depth" do
    rules = Ignore.parse("*.log\n", "")

    assert Ignore.ignored?(rules, "debug.log", false)
    assert Ignore.ignored?(rules, "a/b/debug.log", false)
    refute Ignore.ignored?(rules, "debug.log.txt", false)
  end

  test "a slash anywhere but the end anchors the rule at its file's directory" do
    rules = Ignore.parse("/build\ndocs/generated\n", "")

    assert Ignore.ignored?(rules, "build", true)
    refute Ignore.ignored?(rules, "src/build", true)
    assert Ignore.ignored?(rules, "docs/generated", true)
    refute Ignore.ignored?(rules, "other/docs/generated", true)
  end

  test "a trailing slash applies to directories only" do
    rules = Ignore.parse("cache/\n", "")

    assert Ignore.ignored?(rules, "cache", true)
    assert Ignore.ignored?(rules, "a/cache", true)
    refute Ignore.ignored?(rules, "cache", false)
  end

  test "the last matching rule wins, so a negation re-includes" do
    rules = Ignore.parse("*.log\n!keep.log\n", "")

    assert Ignore.ignored?(rules, "debug.log", false)
    refute Ignore.ignored?(rules, "keep.log", false)
  end

  test "rules from a nested file apply only below its directory" do
    rules = Ignore.parse("*.tmp\n/local\n", "sub")

    assert Ignore.ignored?(rules, "sub/x.tmp", false)
    assert Ignore.ignored?(rules, "sub/deeper/x.tmp", false)
    refute Ignore.ignored?(rules, "x.tmp", false)
    assert Ignore.ignored?(rules, "sub/local", true)
    refute Ignore.ignored?(rules, "local", true)
  end

  test "trailing spaces are dropped unless escaped" do
    assert Ignore.ignored?(Ignore.parse("name.txt   \n", ""), "name.txt", false)
    assert Ignore.ignored?(Ignore.parse("name\\ \n", ""), "name ", false)
  end

  test "the defaults skip dependency, build and version-control directories" do
    rules = Ignore.default()

    for directory <- ["node_modules", "a/node_modules", ".git", "_build", "deps", "target"] do
      assert Ignore.ignored?(rules, directory, true), "#{directory} should be ignored"
    end

    refute Ignore.ignored?(rules, "lib", true)
    refute Ignore.ignored?(rules, "deps.ex", false)
  end
end
