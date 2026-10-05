defmodule Lemieux.TUI.Width do
  @moduledoc """
  How many terminal columns text occupies.

  `String.length/1` counts graphemes, and a CJK character, a full-width
  letter or an emoji is one grapheme drawn in two columns. Every wrapper that
  measured with it let a line of Chinese, Japanese or Korean run past the
  edge of its row, and the renderer clipped what ran over: the rest of the
  sentence was simply not on the screen (seen at 50, 60 and 70 columns).

  ## What counts as two

  The measurement has to agree with the renderer's, which is ratatui's
  `unicode-width`: a row this module thinks fits but the renderer draws
  wider loses its last characters, which is the failure this exists to
  prevent. So the rules are the renderer's, checked against what it actually
  draws:

    * a grapheme whose first code point is East Asian Wide or Fullwidth is
      two columns — the table below is Unicode 16's `W` and `F` ranges, plus
      the two ideograph planes whole;
    * an emoji presentation selector (U+FE0F) makes any grapheme two, and a
      text presentation selector (U+FE0E) makes it one: `❤` is one column,
      `❤️` two, `⌚︎` one;
    * a skin-tone modifier makes its base two: `☝` is one column, `☝🏽` two;
    * a pair of regional indicators — a flag — is two, and a lone one is one;
    * everything else is one, combining marks and joiners inside a cluster
      included.

  The renderer draws a zero-width grapheme on its own (a zero-width space) in
  no columns, where this says one. That direction is safe: a row measured
  too wide wraps a column early, a row measured too narrow is clipped.

  Pure data and arithmetic, outside the `ExRatatui` guard, so it is tested on
  a machine with no terminal and no NIF.
  """

  # Generated from Unicode 16.0's EastAsianWidth.txt (`W` and `F`), merged
  # into ranges — Python's `unicodedata.east_asian_width/1` over U+1100 to
  # U+3FFFF gives the same list. Regenerate rather than edit by hand, and
  # rerun `Lemieux.TUI.WidthTest`, which checks the result against the
  # renderer.
  @wide [
    0x1100..0x115F,
    0x231A..0x231B,
    0x2329..0x232A,
    0x23E9..0x23EC,
    0x23F0..0x23F0,
    0x23F3..0x23F3,
    0x25FD..0x25FE,
    0x2614..0x2615,
    0x2630..0x2637,
    0x2648..0x2653,
    0x267F..0x267F,
    0x268A..0x268F,
    0x2693..0x2693,
    0x26A1..0x26A1,
    0x26AA..0x26AB,
    0x26BD..0x26BE,
    0x26C4..0x26C5,
    0x26CE..0x26CE,
    0x26D4..0x26D4,
    0x26EA..0x26EA,
    0x26F2..0x26F3,
    0x26F5..0x26F5,
    0x26FA..0x26FA,
    0x26FD..0x26FD,
    0x2705..0x2705,
    0x270A..0x270B,
    0x2728..0x2728,
    0x274C..0x274C,
    0x274E..0x274E,
    0x2753..0x2755,
    0x2757..0x2757,
    0x2795..0x2797,
    0x27B0..0x27B0,
    0x27BF..0x27BF,
    0x2B1B..0x2B1C,
    0x2B50..0x2B50,
    0x2B55..0x2B55,
    0x2E80..0x2E99,
    0x2E9B..0x2EF3,
    0x2F00..0x2FD5,
    0x2FF0..0x303E,
    0x3041..0x3096,
    0x3099..0x30FF,
    0x3105..0x312F,
    0x3131..0x318E,
    0x3190..0x31E5,
    0x31EF..0x321E,
    0x3220..0x3247,
    0x3250..0xA48C,
    0xA490..0xA4C6,
    0xA960..0xA97C,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE52,
    0xFE54..0xFE66,
    0xFE68..0xFE6B,
    0xFF01..0xFF60,
    0xFFE0..0xFFE6,
    0x16FE0..0x16FE4,
    0x16FF0..0x16FF1,
    0x17000..0x187F7,
    0x18800..0x18CD5,
    0x18CFF..0x18D08,
    0x1AFF0..0x1AFF3,
    0x1AFF5..0x1AFFB,
    0x1AFFD..0x1AFFE,
    0x1B000..0x1B122,
    0x1B132..0x1B132,
    0x1B150..0x1B152,
    0x1B155..0x1B155,
    0x1B164..0x1B167,
    0x1B170..0x1B2FB,
    0x1D300..0x1D356,
    0x1D360..0x1D376,
    0x1F004..0x1F004,
    0x1F0CF..0x1F0CF,
    0x1F18E..0x1F18E,
    0x1F191..0x1F19A,
    0x1F200..0x1F202,
    0x1F210..0x1F23B,
    0x1F240..0x1F248,
    0x1F250..0x1F251,
    0x1F260..0x1F265,
    0x1F300..0x1F320,
    0x1F32D..0x1F335,
    0x1F337..0x1F37C,
    0x1F37E..0x1F393,
    0x1F3A0..0x1F3CA,
    0x1F3CF..0x1F3D3,
    0x1F3E0..0x1F3F0,
    0x1F3F4..0x1F3F4,
    0x1F3F8..0x1F43E,
    0x1F440..0x1F440,
    0x1F442..0x1F4FC,
    0x1F4FF..0x1F53D,
    0x1F54B..0x1F54E,
    0x1F550..0x1F567,
    0x1F57A..0x1F57A,
    0x1F595..0x1F596,
    0x1F5A4..0x1F5A4,
    0x1F5FB..0x1F64F,
    0x1F680..0x1F6C5,
    0x1F6CC..0x1F6CC,
    0x1F6D0..0x1F6D2,
    0x1F6D5..0x1F6D7,
    0x1F6DC..0x1F6DF,
    0x1F6EB..0x1F6EC,
    0x1F6F4..0x1F6FC,
    0x1F7E0..0x1F7EB,
    0x1F7F0..0x1F7F0,
    0x1F90C..0x1F93A,
    0x1F93C..0x1F945,
    0x1F947..0x1F9FF,
    0x1FA70..0x1FA7C,
    0x1FA80..0x1FA89,
    0x1FA8F..0x1FAC6,
    0x1FACE..0x1FADC,
    0x1FADF..0x1FAE9,
    0x1FAF0..0x1FAF8,
    0x20000..0x2FFFD,
    0x30000..0x3FFFD
  ]

  @ranges List.to_tuple(@wide)

  @emoji_presentation "\u{FE0F}"
  @text_presentation "\u{FE0E}"

  @doc "The columns `text` occupies."
  @spec of(text :: String.t()) :: non_neg_integer()
  def of(text) when is_binary(text) do
    # The transcript is mostly ASCII, and `Lemieux.TUI.Window` measures every
    # word of every row it draws: one grapheme count decides the common case.
    case String.length(text) do
      length when length == byte_size(text) -> length
      _other -> text |> String.graphemes() |> Enum.reduce(0, &(&2 + grapheme(&1)))
    end
  end

  @doc "The columns one grapheme occupies: 1 or 2. See the moduledoc for the rules."
  @spec grapheme(grapheme :: String.t()) :: 1 | 2
  def grapheme(<<first::utf8>>), do: code_point(first)

  def grapheme(<<first::utf8, rest::binary>>) do
    cond do
      String.contains?(rest, @emoji_presentation) -> 2
      String.contains?(rest, @text_presentation) -> 1
      modified?(rest) -> 2
      regional?(first) and flag?(rest) -> 2
      true -> code_point(first)
    end
  end

  def grapheme(_other), do: 1

  # A lone regional indicator is one column, as the renderer draws it, and
  # the table has none of them.
  defp code_point(code), do: if(wide?(code), do: 2, else: 1)

  @doc """
  How many of `items`, from the front, fit in `width` columns.

  `grapheme_of` reads the grapheme out of an item, for a caller whose
  graphemes carry a style beside them; by default the items are the
  graphemes. Walks only as far as the row reaches rather than measuring the
  whole list, because the wrapper asks this once per row of a paragraph that
  can be thousands of graphemes long.

  Always at least one when there is one, so a grapheme wider than the whole
  row still makes progress instead of looping.
  """
  @spec fit(items :: [term()], width :: pos_integer(), grapheme_of :: (term() -> String.t())) ::
          non_neg_integer()
  def fit(items, width, grapheme_of \\ &Function.identity/1)

  def fit([], _width, _grapheme_of), do: 0

  def fit(items, width, grapheme_of)
      when is_list(items) and is_integer(width) and is_function(grapheme_of, 1),
      do: items |> fitting(width, grapheme_of, 0) |> max(1)

  defp fitting([], _room, _grapheme_of, count), do: count

  defp fitting([item | rest], room, grapheme_of, count) do
    case room - grapheme(grapheme_of.(item)) do
      left when left >= 0 -> fitting(rest, left, grapheme_of, count + 1)
      _over -> count
    end
  end

  @doc "Splits `text` after the graphemes that fit in `width` columns."
  @spec split(text :: String.t(), width :: pos_integer()) :: {String.t(), String.t()}
  def split(text, width) when is_binary(text) do
    graphemes = String.graphemes(text)
    {head, tail} = Enum.split(graphemes, fit(graphemes, width))
    {Enum.join(head), Enum.join(tail)}
  end

  defp regional?(code), do: code in 0x1F1E6..0x1F1FF

  defp flag?(<<second::utf8, _rest::binary>>), do: regional?(second)
  defp flag?(_rest), do: false

  # A skin-tone modifier after a base makes it an emoji modifier sequence,
  # drawn as an emoji whatever the base's own width: `☝🏽` is two columns
  # although `☝` alone is one.
  defp modified?(rest),
    do: rest |> String.to_charlist() |> Enum.any?(&(&1 in 0x1F3FB..0x1F3FF))

  # Nothing below U+1100 is wide; above it, a binary search over the ranges.
  defp wide?(code) when code < 0x1100, do: false
  defp wide?(code), do: search(code, 0, tuple_size(@ranges) - 1)

  defp search(_code, low, high) when low > high, do: false

  defp search(code, low, high) do
    middle = div(low + high, 2)
    first..last//_ = elem(@ranges, middle)

    cond do
      code < first -> search(code, low, middle - 1)
      code > last -> search(code, middle + 1, high)
      true -> true
    end
  end
end
