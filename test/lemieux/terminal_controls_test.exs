defmodule Lemieux.TerminalControlsTest do
  # Titles and notifications are written into an OSC sequence, so nothing in
  # their text may start or end one. C0 controls were stripped; the C1 ones
  # (U+0080 to U+009F) were not, and a terminal that honours them reads
  # U+009B as CSI and U+009D as OSC — an escape without the ESC.
  use ExUnit.Case, async: true

  alias Lemieux.Terminal

  test "C1 controls are stripped from a title" do
    assert Terminal.sequence("a\u009b31mb") == "\e]0;a31mb\a"
    assert Terminal.sequence("\u009d0;spoofed\u009cname") == "\e]0;0;spoofedname\a"
    assert Terminal.sequence("next\u0085line") == "\e]0;nextline\a"
  end

  test "and from a notification" do
    assert Terminal.notification("done\u009b2J") == "\e]9;done2J\a\a"
  end

  test "C0 controls still are" do
    assert Terminal.sequence("a\e]52;c;eA==\ab\u007f") == "\e]0;a]52;c;eA==b\a"
  end

  # Matched as characters: as bytes, 0x80-0x9F are also the continuation
  # bytes inside these, and stripping them would mangle the title.
  test "text whose UTF-8 holds those bytes is kept whole" do
    for text <- ["€", "日本", "Ğ ā", "naïve café"] do
      assert Terminal.sequence(text) == "\e]0;" <> text <> "\a"
    end
  end

  test "bytes that are not UTF-8 become U+FFFD, never a lone 0x9B" do
    assert Terminal.sequence(<<"a", 0x9B, "b", 0xFF>>) == "\e]0;a�b�\a"
  end
end
