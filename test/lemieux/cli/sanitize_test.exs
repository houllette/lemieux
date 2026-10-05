defmodule Lemieux.CLI.SanitizeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Sanitize

  # The answer the gap audit's fake model gave (2026-10): a title, a
  # clipboard write, colour, a disguised link and a bell, which `lmx run` and
  # `lmx log` wrote to the terminal byte for byte.
  @hostile "before \e]0;PWNED-TITLE\a title \e]52;c;cHduZWQtY2xpcGJvYXJk\a clip " <>
             "\e[31mRED\e[0m \e]8;;https://evil.example/\alinktext\e]8;;\a bell \a after"

  describe "text/1" do
    test "removes every escape sequence and control byte, keeping the words" do
      clean = Sanitize.text(@hostile)

      refute clean =~ "\e"
      refute clean =~ "\a"
      refute clean =~ "PWNED-TITLE"
      refute clean =~ "cHduZWQtY2xpcGJvYXJk"
      refute clean =~ "evil.example"
      assert clean =~ "before"
      assert clean =~ "RED"
      assert clean =~ "linktext"
      assert clean =~ "after"
    end

    test "keeps newlines and tabs, and drops the carriage return that overwrites a line" do
      assert Sanitize.text("one\ttwo\r\nthree\rfour") == "one\ttwo\nthreefour"
    end

    test "drops a lone ESC and the C1 controls xterm reads as CSI and OSC" do
      assert Sanitize.text("a\e b") == "a b"
      assert Sanitize.text("a\u009b31mb\u009d0;t\u009c c") == "a31mb0;t c"
      assert Sanitize.text("del\u007f") == "del"
    end

    test "leaves ordinary text, Unicode included, exactly as it was" do
      text = "Résumé · naïve — 日本語 ✓\n  indented\tcode"
      assert Sanitize.text(text) == text
    end

    test "turns invalid UTF-8 into the replacement character rather than failing" do
      assert Sanitize.text(<<"ok ", 0xFF, " ok">>) == "ok � ok"
    end
  end

  describe "for_device/3" do
    test "cleans text bound for a terminal and leaves redirected text exact" do
      assert Sanitize.for_device(@hostile, :stdio, true) == Sanitize.text(@hostile)
      assert Sanitize.for_device(@hostile, :stderr, false) == @hostile
    end

    # Asked inside `capture_io/1`, whose device is not a terminal and says
    # so. Asked outside it, the answer is whatever the test runner's own
    # output is — a terminal for anybody running `mix test` by hand — and the
    # test failed for exactly the people meant to run it.
    test "asks the device when nothing says, and a captured device is not a terminal" do
      capture_io(fn ->
        send(self(), {:terminal?, Sanitize.terminal?(:stdio), Sanitize.terminal?(:stderr)})
        send(self(), {:written, Sanitize.for_device(@hostile, :stdio)})
      end)

      assert_received {:terminal?, false, false}
      assert_received {:written, @hostile}
    end
  end

  describe "json/1" do
    test "escapes the C1 controls a JSON encoder leaves raw, and decodes to the same text" do
      text = "a\u009b31mb\u009dc\u007fd\e[0m"
      encoded = Sanitize.json(JSON.encode!(%{"text" => text}))

      refute encoded =~ "\u009b"
      refute encoded =~ "\u009d"
      refute encoded =~ "\u007f"
      refute encoded =~ "\e"
      assert encoded =~ ~S(\u009B)
      assert JSON.decode!(encoded) == %{"text" => text}
    end

    test "leaves a document without them byte for byte" do
      encoded = JSON.encode!(%{"text" => "plain · ✓"})
      assert Sanitize.json(encoded) == encoded
    end
  end
end
