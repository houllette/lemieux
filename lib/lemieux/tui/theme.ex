defmodule Lemieux.TUI.Theme do
  @moduledoc """
  The palette the terminal UI draws in, named by what each colour means.

  `Lemieux.TUI` used to hold every colour as a `%Style{}` literal at its call
  site, deliberately: the transcript's colours say what a row *is* — a
  question is yellow, an edit is green, an error is red — and driving all of
  them off one setting would have traded a legible palette for a
  configurable one. That argument is still right and this module keeps it:
  a theme is not one accent, it is one colour **per meaning**, and switching
  themes swaps the palette without changing which rows share a colour.

  What a single accent could not do is the reason this exists. A person on a
  light terminal saw `:white` option labels and `:gray` output vanish into the
  background, and the dark red-and-green diff tints painted over their page;
  a person on a terminal that has lost its palette, or who cannot tell the
  colours apart, had nothing but the colours to go on. `light/0` and `mono/0`
  answer those two: the first re-picks every slot for a pale background, the
  second empties every colour slot and leaves the bold, dim and italic that
  still carry the structure. `dark/0` is the palette the screen has always
  had, and the default.

  ## Pure data

  A theme is a struct of colours — `ExRatatui.Style` colours, which are atoms
  like `:cyan`, `{:rgb, r, g, b}` triples, or `nil` for the terminal's own
  default — grouped by what they colour: the voices of the transcript, its
  text tiers, the kinds of tool work, delegated children, the model's blocks
  and `/context`'s bands. Nothing here references the terminal UI dependency,
  so this module is compiled and tested in every host, including one that
  took lemieux without the optional NIF. `Lemieux.TUI.RichText` reads the
  slots when it styles a row; `Lemieux.TUI.Blocks` reads `blocks.code_theme`
  when it highlights a fenced block, which happens once when the block
  closes, so a theme switched mid-session recolours every row it draws from
  then on and leaves highlighting already computed as it was.

  `/theme NAME` picks one for a sitting and `"theme"` in `~/.lmx/config.json`
  picks the one a sitting starts with. With neither, and no `NO_COLOR`, a
  local screen asks the terminal what its background is
  (`Lemieux.TUI.Background`) and starts in `light/0` on a pale one: a person
  who cannot read the screen cannot find `/theme` on it either. `/color`
  still overrides `:accent` on top of whichever theme is showing.

  ## Why a theme is data, and not a module

  A palette is the kind of opinion a person changes without wanting to write
  Elixir for it — the status line is handed over as a module because what
  goes on it is a question of *layout*, but "my terminal's background is
  sepia" is forty colours and nothing else. So a theme has a second form,
  `to_map/1` and `from_map/1`: a plain string-keyed map with a group per
  slot group and a colour per slot, spelled as the names `ExRatatui.Style`
  takes, as `#rrggbb`, as a palette index, or as `null` for the terminal's
  own. That is the JSON shape a personal config file will carry, and the
  shape an extension hands over; the shipped three round-trip through it
  exactly, which is what keeps the two forms one theme.

  `from_map/1` names every slot it cannot read rather than the first one,
  and refuses a slot the renderer never reads: a misspelt slot silently
  ignored is a colour somebody set and never saw, and a file with three
  mistakes should cost one edit rather than three.

  ## The registry

  The palettes a sitting can switch between are a `t:registry/0` — a map of
  name to theme — that `Lemieux.TUI` builds once from `registry/1` and
  carries in its state, rather than a list this module knows. `shipped/0` is
  the three above; a host's `themes:` option is merged over them, so a
  registered `"dark"` replaces the shipped one, and a registered `"sepia"` is
  what `/theme sepia` finds and Tab offers. A value rather than a global so
  two screens in one VM can disagree about what `"sepia"` means.
  """

  alias Lemieux.TUI.Colour

  @typedoc "A colour as `ExRatatui.Style` takes it, or `nil` for the terminal's own."
  @type colour :: atom() | {:rgb, 0..255, 0..255, 0..255} | {:indexed, 0..255} | nil

  @typedoc """
  A syntax-highlighting theme name `ExRatatui.CodeBlock.highlight/3` accepts,
  or `nil` to leave code uncoloured.
  """
  @type code_theme :: atom() | nil

  @typedoc """
  Who is talking: the `›` gutter and the text a person typed, the voice
  `lmx` remarks in, the one it uses for an error or a cancellation, a
  notice about the workspace, an activity line, and a question that needs
  an answer.

  `alert` also marks a deprecated model in `/model`'s menu, and `question`
  is what an `ask_user` answer is drawn in where the accent has taken
  `children.ok`'s colour.
  """
  @type voices :: %{
          you: colour(),
          you_text: colour(),
          remark: colour(),
          alert: colour(),
          notice: colour(),
          activity: colour(),
          question: colour()
        }

  @typedoc """
  Plain content, its dimmer tier, the glyphs that draw a tier, and the
  output of a call that failed.
  """
  @type text :: %{plain: colour(), muted: colour(), gutter: colour(), error: colour()}

  @typedoc """
  One colour per kind of tool work, so a screenful of activity can be
  scanned for the edit in the middle of it.
  """
  @type tools :: %{
          explore: colour(),
          search: colour(),
          run: colour(),
          edit: colour(),
          write: colour(),
          eval: colour()
        }

  @typedoc """
  Delegated children: their names, and how each one is going.

  `ok` is also the colour of what a person has answered in the `ask_user`
  panel, beside the accent on the row being chosen: both say something is
  done. Re-picking it re-picks both.
  """
  @type children :: %{name: colour(), ok: colour(), warn: colour(), fail: colour()}

  @typedoc """
  The model's own blocks — headings, quotes, inline and fenced code, the
  rules between sections — and the diff rows in an edit or a `diff` fence.
  """
  @type blocks :: %{
          heading: colour(),
          quote: colour(),
          code: colour(),
          code_bg: colour(),
          rule: colour(),
          add: colour(),
          delete: colour(),
          add_bg: colour(),
          delete_bg: colour(),
          code_theme: code_theme()
        }

  @typedoc "`/context`'s bands."
  @type context :: %{
          system: colour(),
          tools: colour(),
          conversation: colour(),
          output: colour(),
          free: colour()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          accent: colour(),
          elixir_accent: colour(),
          voices: voices(),
          text: text(),
          tools: tools(),
          children: children(),
          blocks: blocks(),
          context: context()
        }

  @enforce_keys [
    :name,
    :accent,
    :elixir_accent,
    :voices,
    :text,
    :tools,
    :children,
    :blocks,
    :context
  ]
  defstruct @enforce_keys

  @typedoc """
  The palettes a sitting can switch between, keyed by the name `/theme`
  takes: lower-cased and trimmed, so the key is what a person types.
  """
  @type registry :: %{String.t() => t()}

  @typedoc """
  A theme as a config file or an extension carries it.

  String keys throughout. `"name"`, `"accent"` and `"elixir_accent"` at the
  top, then one map per slot group — `"voices"`, `"text"`, `"tools"`,
  `"children"`, `"blocks"`, `"context"` — holding the slots `t:t/0` names,
  every one of them present. A colour is one of the names `ExRatatui.Style`
  takes (`"cyan"`, `"light_magenta"`, `"dark_gray"`; a hyphen or a capital is
  forgiven), a `"#rrggbb"` string, an integer palette index, or `nil`.
  `"blocks" → "code_theme"` is a highlighter theme name or `nil`.
  """
  @type map_form :: %{String.t() => term()}

  # Every colour name `ExRatatui.Style` accepts, as atoms so a name read from
  # a file is matched against this list rather than reaching
  # `String.to_atom/1`. Listed here, rather than asked of the dependency,
  # because this module compiles where the dependency does not.
  @colour_names [
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
    :white,
    :reset
  ]

  # The highlighter themes `ExRatatui.CodeBlock.highlight/3` resolves by atom,
  # for the same reason. A raw string would pass through to the highlighter
  # and fall back to the dark theme silently, which is the failure a checked
  # file exists to prevent.
  @code_themes [
    :base16_ocean_dark,
    :base16_ocean_light,
    :base16_eighties_dark,
    :base16_mocha_dark,
    :inspired_github,
    :solarized_dark,
    :solarized_light
  ]

  @colour_slots [:accent, :elixir_accent]
  @groups [:voices, :text, :tools, :children, :blocks, :context]
  @keys ["name" | Enum.map(@colour_slots ++ @groups, &Atom.to_string/1)]

  @doc "The palettes `/theme` accepts with nothing registered, in menu order."
  @spec names() :: [String.t()]
  def names, do: names(shipped())

  @doc """
  The palettes a registry offers, in the order the menu shows them.

  Alphabetical, for the reason every other menu on the screen is: names
  nobody can see at once are names somebody has to scan for.
  """
  @spec names(registry :: registry()) :: [String.t()]
  def names(registry) when is_map(registry), do: registry |> Map.keys() |> Enum.sort()

  @doc "The palette a screen starts with when nothing chose one: `dark/0`."
  @spec default() :: t()
  def default, do: dark()

  @doc "The three palettes every sitting has, under the names `/theme` takes."
  @spec shipped() :: registry()
  def shipped, do: %{"dark" => dark(), "light" => light(), "mono" => mono()}

  @doc """
  Finds a shipped palette by the name `/theme` and the config file use.

  Case-insensitive, because `/theme Light` is not a different request from
  `/theme light`. `named/2` is the same lookup over a registry that has had
  a host's themes merged in, and is what `Lemieux.TUI` calls.
  """
  @spec named(name :: String.t()) :: {:ok, t()} | :error
  def named(name) when is_binary(name), do: named(name, shipped())

  @doc "Finds a palette by name in a registry, case-insensitively."
  @spec named(name :: String.t(), registry :: registry()) :: {:ok, t()} | :error
  def named(name, registry) when is_binary(name) and is_map(registry),
    do: Map.fetch(registry, key(name))

  @doc """
  The registry a sitting switches between: `extra` merged over `shipped/0`.

  `extra` is what a host passes as `themes:` — a map of name to either a
  `t:t/0` or a `t:map_form/0`. The key is the name the theme answers to,
  whatever its own `"name"` says, so `/theme sepia` and the row it prints
  agree; a key that matches a shipped name replaces that palette.

  Every problem in every theme comes back at once, each prefixed with the
  key it was found under, so a config file is fixed in one pass.
  """
  @spec registry(extra :: %{String.t() => t() | map_form()}) ::
          {:ok, registry()} | {:error, [String.t()]}
  def registry(extra) when is_map(extra) do
    {registered, problems} =
      Enum.reduce(extra, {%{}, []}, fn entry, {registered, problems} ->
        case register(entry) do
          {:ok, name, theme} -> {Map.put(registered, name, theme), problems}
          {:error, found} -> {registered, found ++ problems}
        end
      end)

    case problems do
      [] -> {:ok, Map.merge(shipped(), registered)}
      problems -> {:error, Enum.sort(problems)}
    end
  end

  @doc """
  `registry/1`, raising on a theme it cannot read.

  For the host that passed the map in code: a malformed theme there is a
  programming error, and a screen that started without the palette it was
  given would hide it. A config file is checked before it gets this far.
  """
  @spec registry!(extra :: %{String.t() => t() | map_form()}) :: registry()
  def registry!(extra) when is_map(extra) do
    case registry(extra) do
      {:ok, registry} -> registry
      {:error, problems} -> raise ArgumentError, "themes: " <> Enum.join(problems, "; ")
    end
  end

  defp register({name, value}) when is_binary(name) do
    key = key(name)

    cond do
      key == "" ->
        {:error, [nameless(name)]}

      is_struct(value, __MODULE__) ->
        {:ok, key, %{value | name: key}}

      is_map(value) and not is_struct(value) ->
        registered(key, value)

      true ->
        {:error, ["#{key}: a theme must be a map of slot groups or a #{inspect(__MODULE__)}"]}
    end
  end

  defp register({name, _value}), do: {:error, [nameless(name)]}

  defp registered(key, map) do
    case from_map(Map.put(map, "name", key)) do
      {:ok, theme} -> {:ok, key, theme}
      {:error, problems} -> {:error, Enum.map(problems, &"#{key}: #{&1}")}
    end
  end

  defp nameless(name), do: "#{inspect(name)}: a theme's name must be a non-empty string"

  defp key(name), do: name |> String.trim() |> String.downcase()

  @doc """
  Reads a theme from its `t:map_form/0`.

  Every slot must be present and readable, and nothing else may be: the
  problems come back together, each naming the slot as `group.slot`. A
  hyphen or a capital in a colour name is forgiven, as `/color` forgives
  them; anything else is a problem rather than a guess.
  """
  @spec from_map(map :: term()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) and not is_struct(map) do
    problems =
      name_problems(map) ++
        Enum.flat_map(@colour_slots, &top_slot_problems(map, &1)) ++
        Enum.flat_map(@groups, &group_problems(map, &1)) ++
        unknown_groups(map)

    case problems do
      [] -> {:ok, build(map)}
      problems -> {:error, problems}
    end
  end

  def from_map(_other), do: {:error, ["a theme must be a map of slot groups"]}

  @doc """
  Renders a theme as its `t:map_form/0`.

  What a config file would hold to get this theme back: `from_map/1` of the
  result is the theme, and the shipped three are tested to survive the trip
  through JSON as well. Colours come out as names, `#rrggbb` lower-cased,
  integers, or `nil`.
  """
  @spec to_map(theme :: t()) :: map_form()
  def to_map(%__MODULE__{} = theme) do
    groups = Map.new(@groups, &{Atom.to_string(&1), rendered_group(&1, Map.fetch!(theme, &1))})

    Map.merge(
      %{
        "name" => theme.name,
        "accent" => rendered_colour(theme.accent),
        "elixir_accent" => rendered_colour(theme.elixir_accent)
      },
      groups
    )
  end

  defp rendered_group(group, slots) do
    Map.new(slots, fn {slot, value} ->
      {Atom.to_string(slot), rendered_slot(group, slot, value)}
    end)
  end

  defp rendered_slot(:blocks, :code_theme, nil), do: nil
  defp rendered_slot(:blocks, :code_theme, code_theme), do: Atom.to_string(code_theme)
  defp rendered_slot(_group, _slot, colour), do: rendered_colour(colour)

  defp rendered_colour(nil), do: nil

  defp rendered_colour({:rgb, red, green, blue}),
    do: "#" <> Base.encode16(<<red, green, blue>>, case: :lower)

  defp rendered_colour({:indexed, index}), do: index
  defp rendered_colour(name) when is_atom(name), do: Atom.to_string(name)

  # Validation walks the map in the order a person reading the file would,
  # so the problems come out in file order: the name, the two accents, each
  # group's slots, then anything that should not be there at all.

  defp name_problems(map) do
    case Map.fetch(map, "name") do
      {:ok, name} when is_binary(name) and name != "" -> []
      {:ok, _other} -> ["name: must be a non-empty string"]
      :error -> ["name: missing"]
    end
  end

  defp top_slot_problems(map, slot) do
    case Map.fetch(map, Atom.to_string(slot)) do
      {:ok, value} -> colour_problems(Atom.to_string(slot), value)
      :error -> ["#{slot}: missing"]
    end
  end

  defp group_problems(map, group) do
    case Map.fetch(map, Atom.to_string(group)) do
      {:ok, slots} when is_map(slots) and not is_struct(slots) -> slot_problems(group, slots)
      {:ok, _other} -> ["#{group}: not a map of slots"]
      :error -> ["#{group}: missing"]
    end
  end

  defp slot_problems(group, slots) do
    known = slots(group)

    present =
      Enum.flat_map(known, fn slot ->
        case Map.fetch(slots, slot) do
          {:ok, value} -> slot_value_problems(group, slot, value)
          :error -> ["#{group}.#{slot}: missing"]
        end
      end)

    unknown =
      for {slot, _value} <- slots, slot not in known, do: "#{group}.#{label(slot)}: not a slot"

    present ++ unknown
  end

  defp slot_value_problems(:blocks, "code_theme", value) do
    case parse_code_theme(value) do
      {:ok, _code_theme} -> []
      :error -> ["blocks.code_theme: #{inspect(value)} is not a code theme"]
    end
  end

  defp slot_value_problems(group, slot, value), do: colour_problems("#{group}.#{slot}", value)

  defp colour_problems(path, value) do
    case parse_colour(value) do
      {:ok, _colour} -> []
      :error -> ["#{path}: #{inspect(value)} is not a colour"]
    end
  end

  defp unknown_groups(map),
    do: for({key, _value} <- map, key not in @keys, do: "#{label(key)}: not a group")

  defp label(key) when is_binary(key), do: key
  defp label(key), do: inspect(key)

  # The slots a group has are the dark palette's: one source of truth for
  # what the renderer reads, and the same one `mono/0` blanks.
  defp slots(group), do: dark() |> Map.fetch!(group) |> Map.keys() |> Enum.map(&Atom.to_string/1)

  # Only after validation, so every parse below is known to succeed.
  defp build(map) do
    groups = Map.new(@groups, &{&1, built_group(&1, Map.fetch!(map, Atom.to_string(&1)))})

    struct!(
      __MODULE__,
      Map.merge(groups, %{
        name: Map.fetch!(map, "name"),
        accent: colour!(Map.fetch!(map, "accent")),
        elixir_accent: colour!(Map.fetch!(map, "elixir_accent"))
      })
    )
  end

  defp built_group(group, slots) do
    dark()
    |> Map.fetch!(group)
    |> Map.new(fn {slot, _dark} ->
      {slot, built_slot(group, slot, Map.fetch!(slots, Atom.to_string(slot)))}
    end)
  end

  defp built_slot(:blocks, :code_theme, value) do
    {:ok, code_theme} = parse_code_theme(value)
    code_theme
  end

  defp built_slot(_group, _slot, value), do: colour!(value)

  defp colour!(value) do
    {:ok, colour} = parse_colour(value)
    colour
  end

  defp parse_colour(nil), do: {:ok, nil}

  defp parse_colour(index) when is_integer(index) and index in 0..255,
    do: {:ok, {:indexed, index}}

  # Six hex digits and nothing else, as `/color` takes it: `#rrggbb` is the
  # one spelling every terminal-facing tool already accepts.
  defp parse_colour("#" <> digits) when byte_size(digits) == 6 do
    case Base.decode16(digits, case: :mixed) do
      {:ok, <<red, green, blue>>} -> {:ok, {:rgb, red, green, blue}}
      :error -> :error
    end
  end

  defp parse_colour(name) when is_binary(name) do
    spelled = name |> String.trim() |> String.downcase() |> String.replace("-", "_")

    Enum.find_value(@colour_names, :error, fn colour ->
      if Atom.to_string(colour) == spelled, do: {:ok, colour}
    end)
  end

  defp parse_colour(_other), do: :error

  defp parse_code_theme(nil), do: {:ok, nil}

  defp parse_code_theme(name) when is_binary(name) do
    Enum.find_value(@code_themes, :error, fn code_theme ->
      if Atom.to_string(code_theme) == name, do: {:ok, code_theme}
    end)
  end

  defp parse_code_theme(_other), do: :error

  @doc """
  The palette the screen has always drawn: named colours on the terminal's
  own dark background.

  Named rather than `{:rgb, …}` wherever a name will do, so a terminal's own
  palette — the one its owner chose — is what actually appears. The tints
  are the exception: there is no named colour for "barely green", and the
  code tint is the background of the highlighter's own dark theme so a
  highlighted line and the line still being typed beside it match.
  """
  @spec dark() :: t()
  def dark do
    %__MODULE__{
      name: "dark",
      # The rails, the input cursor and the highlighted completion; what
      # `/color` overrides. Elixir mode has its own so the two agree.
      accent: :cyan,
      elixir_accent: :magenta,
      voices: %{
        you: :cyan,
        you_text: :light_cyan,
        remark: :gray,
        alert: :red,
        notice: :yellow,
        activity: :magenta,
        question: :yellow
      },
      text: %{plain: :white, muted: :gray, gutter: :dark_gray, error: :light_red},
      tools: %{
        explore: :light_blue,
        search: :light_cyan,
        run: :light_yellow,
        edit: :light_green,
        write: :light_green,
        eval: :light_magenta
      },
      children: %{name: :cyan, ok: :green, warn: :yellow, fail: :red},
      blocks: %{
        heading: :light_cyan,
        quote: :cyan,
        code: :cyan,
        code_bg: {:rgb, 43, 48, 59},
        rule: :dark_gray,
        add: :light_green,
        delete: :light_red,
        add_bg: {:rgb, 18, 48, 32},
        delete_bg: {:rgb, 55, 26, 32},
        code_theme: :base16_ocean_dark
      },
      context: %{
        system: :green,
        tools: :red,
        conversation: :blue,
        output: :magenta,
        free: :dark_gray
      }
    }
  end

  @doc """
  The same meanings re-picked for a pale background.

  From the 256-colour cube rather than by name, which is the one exception
  to `dark/0`'s rule and has a reason: the sixteen named colours are
  whatever the terminal's palette says, and the palettes light terminals
  ship were never picked for text. Measured on xterm's white, Terminal.app's
  Basic and Clear Light profiles, `:green` drew "Edited" at 2.2:1, `:yellow`
  a running command at 1.7:1, and `:gray` the gutters at 1.3:1. The cube
  (16–255) is the same fixed RGB in every terminal that has it, so the
  contrast below is a number rather than a hope:

    * text a person reads — remarks, muted output, notices, questions,
      errors, the activity row — clears WCAG AA's 4.5:1 on white:
      242 `#6c6c6c` 5.3:1, 94 `#875f00` 5.7:1, 160 `#d70000` 5.4:1,
      127 `#af00af` 6.1:1;
    * the tool colours do too: 25 `#005faf` 6.5:1, 23 `#005f5f` 7.5:1,
      28 `#008700` 4.7:1, 130 `#af5f00` 4.7:1 — and everything above but
      the last two also on Solarized Light's cream `#fdf6e3`, where those
      two read at 4.4:1;
    * gutters, rules and the free part of `/context`'s bar are glyphs rather
      than words, and clear the 3:1 WCAG asks of them: 245 `#8a8a8a` 3.5:1,
      246 `#949494` 3.0:1;
    * code and diff text clear 4.5:1 on their own tints, and on the palette
      colour each tint becomes without 24-bit colour;
    * plain text and what a person typed are the terminal's own foreground
      (`nil`), which its owner already chose to read on that background.

  `Lemieux.TUI.ThemeTest` holds those numbers, so a slot re-picked below
  them fails. Dimmed text cannot clear 4.5:1 on white at all — a faint
  black is mid-grey — so a palette with a pale code tint (`pale?/1`) has its
  dim rows drawn in the muted colour instead; see `Lemieux.TUI.Screen`.

  The diff tints are pale rather than deep, and `inspired_github` is the
  code theme `ExRatatui.CodeBlock` ships for light pages. The tints stay
  RGB: a terminal without 24-bit colour gets the nearest cube colour, as
  every RGB colour on the screen does (`Lemieux.TUI.Colour`).
  """
  @spec light() :: t()
  def light do
    blue = {:indexed, 25}
    teal = {:indexed, 23}
    green = {:indexed, 28}
    amber = {:indexed, 130}
    brown = {:indexed, 94}
    red = {:indexed, 160}
    magenta = {:indexed, 127}
    grey = {:indexed, 242}
    rule = {:indexed, 245}

    %__MODULE__{
      name: "light",
      accent: blue,
      elixir_accent: magenta,
      voices: %{
        you: blue,
        you_text: nil,
        remark: grey,
        alert: red,
        notice: brown,
        activity: magenta,
        question: brown
      },
      text: %{plain: nil, muted: grey, gutter: rule, error: red},
      tools: %{
        explore: blue,
        search: teal,
        run: amber,
        edit: green,
        write: green,
        eval: magenta
      },
      children: %{name: blue, ok: green, warn: amber, fail: red},
      blocks: %{
        heading: blue,
        quote: {:indexed, 24},
        code: {:indexed, 24},
        code_bg: {:rgb, 240, 241, 245},
        rule: rule,
        add: {:indexed, 22},
        delete: {:indexed, 124},
        add_bg: {:rgb, 220, 245, 228},
        delete_bg: {:rgb, 252, 226, 230},
        code_theme: :inspired_github
      },
      context: %{
        system: green,
        tools: red,
        conversation: blue,
        output: magenta,
        free: {:indexed, 246}
      }
    }
  end

  @doc """
  Whether `theme` was drawn for a pale background: its code tint is light.

  The one fact about the page a palette already carries, so a host's own
  palette answers it without a field of its own: a theme that tints its
  code blocks near-white was made for a white page. `nil` (no tint, as in
  `mono/0`) is not pale. `Lemieux.TUI.Screen` asks, because dim text —
  which terminals draw by fading towards the background — fades to
  unreadable on a pale one.
  """
  @spec pale?(theme :: t()) :: boolean()
  def pale?(%__MODULE__{blocks: %{code_bg: code_bg}}), do: Colour.light?(code_bg)

  @doc """
  No colour at all: every slot is the terminal's default.

  What survives is what the renderer says with weight — bold headings and
  tool verbs, dim output and gutters, italic remarks, the `+` and `-` on diff
  rows, the `›` and `?` and `•` glyphs. That is the palette for a terminal
  that has lost its colours, for a transcript being screen-read, and for
  somebody who cannot tell the colours apart. Code is left unhighlighted
  rather than highlighted in colours the theme then throws away.
  """
  @spec mono() :: t()
  def mono do
    blank = fn group -> Map.new(group, fn {slot, _colour} -> {slot, nil} end) end
    dark = dark()

    %__MODULE__{
      name: "mono",
      accent: nil,
      elixir_accent: nil,
      voices: blank.(dark.voices),
      text: blank.(dark.text),
      tools: blank.(dark.tools),
      children: blank.(dark.children),
      blocks: blank.(dark.blocks),
      context: blank.(dark.context)
    }
  end
end
