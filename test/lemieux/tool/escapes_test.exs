defmodule Lemieux.Tool.EscapesTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool.Escapes

  test "removes colour, cursor, title and two-byte escapes" do
    assert Escapes.strip("\e[1;31mFAIL\e[0m \e[2K\e[1Gdone\e]0;title\a\e=") == "FAIL done"
  end

  test "text without escapes is returned unchanged" do
    assert Escapes.strip("plain\ttext\n") == "plain\ttext\n"
  end

  test "holds back a sequence cut by a chunk boundary" do
    assert Escapes.strip_chunk("", "red\e[3") == {"red", "\e[3"}
    assert Escapes.strip_chunk("\e[3", "1mtext") == {"text", ""}
  end

  test "holds back an unterminated title until its terminator arrives" do
    assert Escapes.strip_chunk("", "a\e]0;my ti") == {"a", "\e]0;my ti"}
    assert Escapes.strip_chunk("\e]0;my ti", "tle\e\\b") == {"b", ""}
  end

  test "releases an overlong unfinished 'sequence' as text" do
    long = "\e]" <> String.duplicate("x", 5_000)
    assert {^long, ""} = Escapes.strip_chunk("", long)
  end
end
