defmodule Lemieux.TUI.ColourTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Colour

  describe "depth/1" do
    test "24-bit only where the terminal says so" do
      assert Colour.depth(%{"COLORTERM" => "truecolor"}) == :truecolor
      assert Colour.depth(%{"COLORTERM" => "24bit"}) == :truecolor
      assert Colour.depth(%{"COLORTERM" => "TrueColor"}) == :truecolor
      assert Colour.depth(%{"TERM" => "xterm-direct"}) == :truecolor
    end

    # Terminal.app before macOS 26 and GNU screen 4 set nothing, and drew
    # 24-bit escapes as attributes; 256 colours is what they have.
    test "everything else is the 256-colour palette" do
      assert Colour.depth(%{}) == :ansi256
      assert Colour.depth(%{"TERM" => "xterm-256color"}) == :ansi256
      assert Colour.depth(%{"TERM_PROGRAM" => "Apple_Terminal"}) == :ansi256
      assert Colour.depth(%{"COLORTERM" => "yes"}) == :ansi256
    end

    # GNU screen passes on the COLORTERM of the terminal it started in, and
    # screen 4 draws 24-bit escapes as garbage.
    test "inside GNU screen, an inherited COLORTERM says nothing" do
      screen = %{"STY" => "12345.pts-0.host", "TERM" => "screen-256color"}

      assert Colour.depth(Map.put(screen, "COLORTERM", "truecolor")) == :ansi256
      assert Colour.depth(%{screen | "TERM" => "screen-direct"}) == :truecolor
      assert Colour.depth(%{"STY" => "", "COLORTERM" => "truecolor"}) == :truecolor
    end
  end

  describe "downsampling" do
    test "an RGB colour becomes the nearest cube colour or grey" do
      assert Colour.downsample({:rgb, 0, 0, 0}) == {:indexed, 16}
      assert Colour.downsample({:rgb, 255, 255, 255}) == {:indexed, 231}
      assert Colour.downsample({:rgb, 0x87, 0x00, 0x87}) == {:indexed, 90}
      assert Colour.downsample({:rgb, 0x6C, 0x6C, 0x6C}) == {:indexed, 242}
      # The default palette's code tint and the light one's.
      assert Colour.downsample({:rgb, 43, 48, 59}) == {:indexed, 236}
      assert Colour.downsample({:rgb, 240, 241, 245}) == {:indexed, 255}
    end

    test "every cube and grey entry comes back as itself" do
      for index <- 16..255 do
        {red, green, blue} = Colour.rgb({:indexed, index})
        assert Colour.rgb(Colour.downsample({:rgb, red, green, blue})) == {red, green, blue}
      end
    end

    test "only RGB colours change, and only at 256 colours" do
      for colour <- [:cyan, nil, :reset, {:indexed, 3}] do
        assert Colour.downsample(colour) == colour
        assert Colour.for_depth(colour, :ansi256) == colour
      end

      assert Colour.for_depth({:rgb, 1, 2, 3}, :truecolor) == {:rgb, 1, 2, 3}
      assert Colour.for_depth({:rgb, 1, 2, 3}, :ansi256) == {:indexed, 16}
    end
  end

  describe "lightness" do
    test "WCAG's luminance and contrast" do
      assert_in_delta Colour.contrast({0, 0, 0}, {255, 255, 255}), 21.0, 0.001
      assert Colour.contrast({255, 255, 255}, {255, 255, 255}) == 1.0
      assert_in_delta Colour.contrast(Colour.rgb({:indexed, 242}), {255, 255, 255}), 5.25, 0.01
    end

    test "light where black text out-contrasts white" do
      assert Colour.light?({255, 255, 255})
      assert Colour.light?({:rgb, 0xFD, 0xF6, 0xE3})
      assert Colour.light?(:white)
      refute Colour.light?({0, 0, 0})
      refute Colour.light?({:rgb, 0x00, 0x2B, 0x36})
      refute Colour.light?(:black)
      refute Colour.light?(nil)
      refute Colour.light?(:reset)
    end
  end
end
