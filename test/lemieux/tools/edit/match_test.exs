defmodule Lemieux.Tools.Edit.MatchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Edit.Match

  defp replace(contents, old, new, all? \\ false), do: Match.replace(contents, old, new, all?)

  describe "line endings" do
    test "a region's line endings follow the file; the rest is byte for byte" do
      # Mixed: mostly CRLF, one bare LF that must survive untouched.
      contents = "a\r\nb\r\nc\nd\r\n"

      assert {:ok, %{contents: result}} = replace(contents, "a\nb", "x\ny")
      assert result == "x\r\ny\r\nc\nd\r\n"
    end

    test "a file with no CRLF keeps LF" do
      assert {:ok, %{contents: "x\ny\nz\n"}} = replace("a\nb\nz\n", "a\nb", "x\ny")
    end

    test "CRLF in the strings themselves is the same as LF" do
      assert {:ok, %{contents: "1\n2\n"}} = replace("one\ntwo\n", "one\r\ntwo", "1\r\n2")
    end

    test "strings equal once line endings are ignored are identical" do
      assert replace("a\r\nb\r\n", "a\nb", "a\r\nb") == {:error, :identical}
    end
  end

  describe "replace_all" do
    test "replaces every exact occurrence, and reports the first" do
      assert {:ok, %{contents: "c\nb\nc\n", count: 2, first_line: 1}} =
               replace("a\nb\na\n", "a", "c", true)
    end

    test "does not use a loose rule to find more places" do
      assert replace("  a  b\n a  b\n", "a b", "x", true) == {:error, :not_found}
    end
  end

  describe "loose rules" do
    test "report which rule found the match" do
      assert {:ok, %{strategy: :trailing_whitespace}} = replace("a \nb\n", "a\nb", "c\nd")
      assert {:ok, %{strategy: :indentation}} = replace("    a\n    b\n", "a\nb", "c\nd")
      assert {:ok, %{strategy: :whitespace}} = replace("x  =  1\n", "x = 1", "x = 2")
    end

    test "never pick one of several places" do
      assert replace("  a\n    a\n", "a\n", "b\n") == {:error, {:ambiguous, :exact, 2}}

      assert replace("x  =  1\ny\nx =  1\n", "x = 1", "z") ==
               {:error, {:ambiguous, :whitespace, 2}}
    end

    test "line-number prefixes come off only when every line has one" do
      assert {:ok, %{strategy: :line_numbers, contents: "b\n"}} = replace("a\n", "1\ta", "1\tb")
      assert replace("a\n", "1\ta\nb", "c") == {:error, :not_found}
    end
  end

  describe "closest/2" do
    test "finds the most similar region" do
      contents = "one\ntwo\nfn handle(conn, params)\nthree\n"

      assert {3, 3, similarity} = Match.closest(contents, "fn handle(conn, _params)")
      assert similarity > 0.9
    end

    test "is nil when nothing is similar" do
      assert Match.closest("aaaa\nbbbb\n", "zzzzzzzzzzzzzzzzz") == nil
    end

    test "stays bounded on a large file, comparing only likely starts" do
      contents = Enum.map_join(1..20_000, "\n", &"line number #{&1}")
      wanted = "line number 15000x\nline number 15001\nline number 15002"

      assert {15_000, 15_002, _score} = Match.closest(contents, wanted)
    end
  end
end
