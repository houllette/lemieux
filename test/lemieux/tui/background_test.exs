defmodule Lemieux.TUI.BackgroundTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Background

  @macos_15 {{:unix, :darwin}, {24, 6, 0}}
  @macos_26 {{:unix, :darwin}, {25, 0, 0}}
  @linux {{:unix, :linux}, {6, 8, 0}}
  @windows {{:win32, :nt}, {10, 0, 22_631}}

  @white "\e]11;rgb:ffff/ffff/ffff\a\e[?62;22c"
  @black "\e]11;rgb:0000/0000/0000\e\\\e[?62;22c"

  @term %{"TERM" => "xterm-256color"}

  defp detect(opts) do
    opts = Keyword.update(opts, :env, @term, &Map.merge(@term, &1))

    Background.detect(
      Keyword.merge(
        [
          os: @linux,
          query: fn -> "" end,
          appearance: fn -> flunk("macOS's appearance was asked") end
        ],
        opts
      )
    )
  end

  describe "the terminal's own answer" do
    test "reads the colour in either terminator, with any number of hex digits" do
      assert Background.from_reply(@white) == :light
      assert Background.from_reply(@black) == :dark
      assert Background.from_reply("\e]11;rgb:fd/f6/e3\a") == :light
      assert Background.from_reply("\e]11;rgb:0/2/3\a") == :dark
      assert Background.from_reply("\e]11;rgba:0000/2b2b/3636/ffff\a") == :dark
    end

    test "finds it among keys typed meanwhile, and says nothing without one" do
      assert Background.from_reply("ab\e]11;rgb:ffff/ffff/ffff\a\e[?1;2c") == :light
      assert Background.from_reply("\e[?62;22c") == :unknown
      assert Background.from_reply("") == :unknown
    end

    test "is the first thing asked" do
      assert detect(query: fn -> @white end, env: %{"COLORFGBG" => "15;0"}) == :light
      assert detect(query: fn -> @black end, env: %{"COLORFGBG" => "0;15"}) == :dark
    end

    test "is not asked on Windows, which has no tty to ask on" do
      assert detect(os: @windows, query: fn -> flunk("queried") end) == :unknown
    end

    # One that cannot parse the question would print it.
    test "is not asked of a dumb terminal, nor of one that does not say what it is" do
      for term <- ["dumb", ""] do
        assert detect(env: %{"TERM" => term}, query: fn -> flunk("queried") end) == :unknown
        assert detect(env: %{"TERM" => term, "COLORFGBG" => "0;15"}) == :light
      end
    end
  end

  describe "COLORFGBG" do
    test "reads the background index as Vim does" do
      assert Background.from_colorfgbg("15;0") == :dark
      assert Background.from_colorfgbg("0;15") == :light
      assert Background.from_colorfgbg("0;default;7") == :light
      assert Background.from_colorfgbg("7;8") == :dark
      assert Background.from_colorfgbg("default;default") == :unknown
      assert Background.from_colorfgbg(nil) == :unknown
    end

    test "is asked when the terminal did not answer" do
      assert detect(env: %{"COLORFGBG" => "0;15"}) == :light
      assert detect(os: @windows, env: %{"COLORFGBG" => "15;0"}) == :dark
    end
  end

  describe "macOS's appearance" do
    test "decides for Terminal.app before macOS 26, whose default profile follows it" do
      env = %{"TERM_PROGRAM" => "Apple_Terminal"}

      assert detect(os: @macos_15, env: env, appearance: fn -> :light end) == :light
      assert detect(os: @macos_15, env: env, appearance: fn -> :dark end) == :dark
    end

    test "is not asked on macOS 26, nor for another terminal" do
      assert detect(os: @macos_26, env: %{"TERM_PROGRAM" => "Apple_Terminal"}) == :unknown
      assert detect(os: @macos_15, env: %{"TERM_PROGRAM" => "iTerm.app"}) == :unknown
    end

    test "comes after the terminal's answer and COLORFGBG" do
      env = %{"TERM_PROGRAM" => "Apple_Terminal", "COLORFGBG" => "15;0"}

      assert detect(os: @macos_15, env: env, appearance: fn -> :light end) == :dark
    end
  end
end
