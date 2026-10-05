defmodule Lemieux.TUI.Colour do
  @moduledoc """
  Colour arithmetic for the terminal UI: what a colour is in RGB, how light
  it is, how two of them contrast, and how many colours the terminal can
  draw.

  ## 24-bit colour, and the terminals without it

  The screen draws some colours as `{:rgb, r, g, b}`: the code and diff
  tints, every colour the syntax highlighter picks, and a `/color #rrggbb`.
  A terminal that does not understand the 24-bit escape for them does not
  ignore it: macOS Terminal before macOS 26 and GNU screen 4 read
  `38;2;r;g;b` as a run of separate attributes, and code blocks came out dim
  on a yellow background. Those terminals do draw the 256-colour palette, so
  `depth/1` says which one this terminal has and `downsample/1` turns an RGB
  colour into the nearest of the 256.

  `COLORTERM=truecolor` (or `24bit`) is the convention a terminal uses to say
  it draws 24-bit colour, and every terminal that does sets it — iTerm2,
  VS Code, kitty, WezTerm, Alacritty, GNOME's VTE. A `TERM` ending in
  `-direct` says the same thing in terminfo's words. Anything else gets 256
  colours: the cost of being wrong in that direction is a tint one step off,
  and in the other it is a screen of garbage.

  Except inside GNU screen, which says so with `STY`: it passes on the
  `COLORTERM` of the terminal it was started in, which says nothing about
  screen itself, and screen 4 is one of the two that turn 24-bit escapes
  into garbage. tmux needs no exception: it converts the colours it cannot
  pass on.

  ## Lightness

  `luminance/1` and `contrast/2` are WCAG 2's relative luminance and
  contrast ratio, which is what the light palette's numbers in
  `Lemieux.TUI.Theme.light/0` are measured in. `light?/1` puts the line
  between light and dark where black text starts to out-contrast white:
  relative luminance 0.179.

  A named colour (`:cyan`) is whatever the terminal's palette says; where a
  number is needed for one, this uses xterm's defaults, which is what most
  palettes approximate. The cube (16–231) and the grey ramp (232–255) are
  the same everywhere.

  Pure arithmetic, outside the `ExRatatui` guard.
  """

  @typedoc "A colour as `ExRatatui.Style` takes it, or `nil` for the terminal's own."
  @type t :: atom() | {:rgb, 0..255, 0..255, 0..255} | {:indexed, 0..255} | nil

  @typedoc "Red, green and blue, each 0 to 255."
  @type rgb :: {0..255, 0..255, 0..255}

  @typedoc "How many colours the terminal draws: 24-bit, or the 256-colour palette."
  @type depth :: :truecolor | :ansi256

  # xterm's default sixteen, in index order.
  @ansi {
    {0x00, 0x00, 0x00},
    {0xCD, 0x00, 0x00},
    {0x00, 0xCD, 0x00},
    {0xCD, 0xCD, 0x00},
    {0x00, 0x00, 0xEE},
    {0xCD, 0x00, 0xCD},
    {0x00, 0xCD, 0xCD},
    {0xE5, 0xE5, 0xE5},
    {0x7F, 0x7F, 0x7F},
    {0xFF, 0x00, 0x00},
    {0x00, 0xFF, 0x00},
    {0xFF, 0xFF, 0x00},
    {0x5C, 0x5C, 0xFF},
    {0xFF, 0x00, 0xFF},
    {0x00, 0xFF, 0xFF},
    {0xFF, 0xFF, 0xFF}
  }

  @names [
    :black,
    :red,
    :green,
    :yellow,
    :blue,
    :magenta,
    :cyan,
    :gray,
    :dark_gray,
    :light_red,
    :light_green,
    :light_yellow,
    :light_blue,
    :light_magenta,
    :light_cyan,
    :white
  ]

  @levels [0, 95, 135, 175, 215, 255]

  @doc """
  How many colours the terminal behind `env` draws. See the moduledoc.
  """
  @spec depth(env :: %{optional(String.t()) => String.t()}) :: depth()
  def depth(env) when is_map(env) do
    colorterm = env |> Map.get("COLORTERM", "") |> String.downcase()
    term = Map.get(env, "TERM", "")
    screen? = Map.get(env, "STY", "") != ""

    cond do
      String.ends_with?(term, "-direct") -> :truecolor
      colorterm in ["truecolor", "24bit"] and not screen? -> :truecolor
      true -> :ansi256
    end
  end

  @doc """
  `colour` as the terminal at `depth` can draw it: an RGB colour becomes
  the nearest of the 256 on `:ansi256`, and everything else is unchanged.
  """
  @spec for_depth(colour :: t(), depth :: depth()) :: t()
  def for_depth({:rgb, _red, _green, _blue} = colour, :ansi256), do: downsample(colour)
  def for_depth(colour, _depth), do: colour

  @doc "The nearest 256-colour palette entry to an RGB colour; other colours unchanged."
  @spec downsample(colour :: t()) :: t()
  def downsample({:rgb, red, green, blue}), do: {:indexed, nearest_256({red, green, blue})}
  def downsample(colour), do: colour

  @doc """
  The index, 16 to 255, of the cube colour or grey nearest `rgb`.

  The first sixteen are never the answer: they are the terminal's palette,
  and the point of downsampling is a colour whose RGB is known.
  """
  @spec nearest_256(rgb :: rgb()) :: 16..255
  def nearest_256({red, green, blue} = rgb) do
    {r, r_level} = level(red)
    {g, g_level} = level(green)
    {b, b_level} = level(blue)
    cube = {16 + 36 * r + 6 * g + b, {r_level, g_level, b_level}}

    step = ((red + green + blue) / 3 - 8) |> Kernel./(10) |> round() |> max(0) |> min(23)
    grey = {232 + step, {8 + 10 * step, 8 + 10 * step, 8 + 10 * step}}

    [cube, grey]
    |> Enum.min_by(fn {_index, candidate} -> distance(rgb, candidate) end)
    |> elem(0)
  end

  @doc """
  `colour` in RGB, or `nil` for the terminal's own colour, which nobody but
  the terminal knows. Named colours and indices below 16 are xterm's defaults.
  """
  @spec rgb(colour :: t()) :: rgb() | nil
  def rgb({:rgb, red, green, blue}), do: {red, green, blue}
  def rgb({:indexed, index}) when index in 0..15, do: elem(@ansi, index)

  def rgb({:indexed, index}) when index in 16..231 do
    offset = index - 16

    {
      Enum.at(@levels, div(offset, 36)),
      Enum.at(@levels, rem(div(offset, 6), 6)),
      Enum.at(@levels, rem(offset, 6))
    }
  end

  def rgb({:indexed, index}) when index in 232..255 do
    value = 8 + 10 * (index - 232)
    {value, value, value}
  end

  def rgb(name) when name in @names,
    do: elem(@ansi, Enum.find_index(@names, &(&1 == name)))

  def rgb(_default), do: nil

  @doc "WCAG 2 relative luminance, 0 (black) to 1 (white)."
  @spec luminance(rgb :: rgb()) :: float()
  def luminance({red, green, blue}),
    do: 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)

  @doc "WCAG 2 contrast ratio between two RGB colours, 1.0 to 21.0."
  @spec contrast(first :: rgb(), second :: rgb()) :: float()
  def contrast(first, second) do
    {low, high} = Enum.min_max([luminance(first), luminance(second)])
    (high + 0.05) / (low + 0.05)
  end

  @doc """
  Whether a colour is light: black text on it out-contrasts white.

  `nil` and `:reset` — the terminal's own — are not known to be light.
  """
  @spec light?(colour :: t() | rgb()) :: boolean()
  def light?({red, green, blue}) when is_integer(red) and is_integer(green) and is_integer(blue),
    do: luminance({red, green, blue}) > 0.179

  def light?(colour) do
    case rgb(colour) do
      nil -> false
      rgb -> light?(rgb)
    end
  end

  defp channel(value) do
    scaled = value / 255
    if scaled <= 0.03928, do: scaled / 12.92, else: :math.pow((scaled + 0.055) / 1.055, 2.4)
  end

  defp level(value) do
    @levels
    |> Enum.with_index()
    |> Enum.min_by(fn {level, _index} -> abs(level - value) end)
    |> then(fn {level, index} -> {index, level} end)
  end

  # The "redmean" weighting: plain RGB distance treats a step in green as no
  # more visible than one in blue, which picks greys for muted greens.
  defp distance({r1, g1, b1}, {r2, g2, b2}) do
    mean = (r1 + r2) / 2
    dr = r1 - r2
    dg = g1 - g2
    db = b1 - b2
    (2 + mean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - mean) / 256) * db * db
  end
end
