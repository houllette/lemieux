defmodule Lemieux.TUI.Background do
  @moduledoc """
  Whether the terminal's background is light or dark.

  The default palette is drawn for a dark background, and on a light one most
  of it measured 1.0–1.7:1: white option labels on a white page, grey remarks
  that vanished, a status row nobody could read. `/theme light` fixes that,
  and nobody who cannot read the screen can find `/theme` on it. So a local
  screen that nothing told which theme to use asks, in this order:

    1. **The terminal itself**, with the xterm query for the background
       colour (OSC 11), which xterm, VTE (GNOME Terminal), iTerm2, kitty,
       WezTerm, Alacritty, Konsole, VS Code's xterm.js and tmux answer with
       the colour they draw. The query is followed by a device attributes
       request (DA1), which practically every terminal answers, so one that
       ignores OSC 11 — GNU screen does — costs a round trip rather than a
       timeout.
    2. **`COLORFGBG`**, which rxvt, Konsole and some others set to
       `"fg;bg"` as palette indices: a background of 0–6 or 8 is dark, 7 or
       9–15 light, as Vim reads it.
    3. **macOS's appearance**, for Terminal.app only and only before macOS
       26, whose default profile (Basic) is white in light mode and black in
       dark mode. macOS 26 made Clear Dark the default, which is dark in both,
       and the system setting stopped saying anything about the terminal.

  Anything else is `:unknown`, and the screen keeps the dark default.

  ## The query, and why it runs before the screen starts

  The answer arrives on the terminal's input, the same stream keys arrive
  on. Once the screen owns the terminal, its input reader would take the
  answer for keystrokes — `ESC ]` is Alt-`]` to it — and type
  `11;rgb:ffff/ffff/ffff` into the input box. So the query runs before the
  screen starts, from `Lemieux.TUI.start_link/1`: the terminal is put in
  non-canonical, no-echo mode with `stty`, the BEAM's own terminal reader is
  parked so it cannot take the answer either, the reply is read off the
  terminal device until the DA1 answer or a deadline, and the terminal's
  settings are put back exactly as they were. Keys typed in that instant are
  read with the answer and dropped.

  Only on Unix, and only where `TERM` names a terminal other than `dumb`:
  Windows has no terminal device or `stty`, and a terminal that cannot
  parse the question prints it. Both still get steps 2 and 3. `detect/1`
  takes every effect as an option, so the order and the parsing are tested
  without a terminal.
  """

  alias Lemieux.TUI.Colour
  alias Lemieux.TUI.Tty

  @typedoc "What the background is, as far as anything could tell."
  @type t :: :light | :dark | :unknown

  @query "\e]11;?\a\e[c"

  @doc """
  The background of the terminal behind `opts`.

  Options, each replacing one effect:

    * `:env` — the environment, `System.get_env/0` by default.
    * `:query` — a function of no arguments answering what the terminal
      replied to the OSC 11 query, or `""`; `query/1` by default.
    * `:appearance` — a function of no arguments answering macOS's
      appearance as `:light`, `:dark` or `:unknown`; `macos_appearance/0` by
      default, asked only for Terminal.app before macOS 26.
    * `:os` — `:os.type/0` and `:os.version/0` together, as
      `{type, version}`.
  """
  @spec detect(opts :: keyword()) :: t()
  def detect(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    os = Keyword.get_lazy(opts, :os, fn -> {:os.type(), :os.version()} end)
    query = Keyword.get(opts, :query, fn -> query(deadline(env)) end)
    appearance = Keyword.get(opts, :appearance, &macos_appearance/0)

    [
      fn -> if unix?(os) and answers?(env), do: from_reply(query.()), else: :unknown end,
      fn -> from_colorfgbg(Map.get(env, "COLORFGBG")) end,
      fn -> if follows_appearance?(env, os), do: appearance.(), else: :unknown end
    ]
    |> Enum.find_value(:unknown, fn source ->
      case source.() do
        :unknown -> nil
        found -> found
      end
    end)
  end

  @doc """
  The background a terminal's reply to the OSC 11 query names, or `:unknown`.

  The reply is `ESC ] 11 ; rgb:RRRR/GGGG/BBBB` ended by `BEL` or `ESC \\`,
  with one to four hex digits per channel; `rgba:` adds an alpha channel,
  which says nothing about lightness. Anything else in the buffer — the DA1
  answer, keys typed meanwhile — is ignored.
  """
  @spec from_reply(reply :: binary()) :: t()
  def from_reply(reply) when is_binary(reply) do
    case Regex.run(
           ~r|\e\]11;rgba?:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})|,
           reply,
           capture: :all_but_first
         ) do
      [red, green, blue] -> lightness({scale(red), scale(green), scale(blue)})
      nil -> :unknown
    end
  end

  @doc """
  The background `COLORFGBG` names, or `:unknown`.

  The last field is the background as a palette index: 0–6 and 8 are dark,
  7 and 9–15 light. `default`, or anything that is not an index, says
  nothing.
  """
  @spec from_colorfgbg(value :: String.t() | nil) :: t()
  def from_colorfgbg(value) when is_binary(value) do
    case value |> String.split(";") |> List.last() |> Integer.parse() do
      {index, ""} when index in 0..6 or index == 8 -> :dark
      {index, ""} when index in 7..15 -> :light
      _other -> :unknown
    end
  end

  def from_colorfgbg(_unset), do: :unknown

  @doc """
  Asks the terminal the VM is attached to for its background colour and
  returns its raw reply, or `""` when there is no terminal to ask or it did
  not answer.

  `deadline` is in milliseconds; it is only reached by a terminal that
  answers neither query, and practically every one answers DA1. See the
  moduledoc for why the terminal's modes are set by hand around it, and
  `Lemieux.TUI.Tty` for why `stty` is pointed at the device by name.
  """
  @spec query(deadline :: pos_integer()) :: binary()
  def query(deadline \\ 500) do
    with sh when is_binary(sh) <- System.find_executable("sh"),
         tty when is_binary(tty) <- Tty.device(),
         {:ok, saved} <- raw_mode(sh, tty) do
      try do
        ask(tty, deadline)
      after
        restore(sh, tty, saved)
      end
    else
      _no_terminal -> ""
    end
  end

  @doc """
  macOS's appearance setting: `:dark` when the system is in dark mode,
  `:light` otherwise, and `:unknown` where `defaults` is not there to ask.
  """
  @spec macos_appearance() :: t()
  def macos_appearance do
    case System.find_executable("defaults") do
      nil ->
        :unknown

      defaults ->
        # The key exists only in dark mode: `defaults` failing to read it is
        # how light mode answers.
        case System.cmd(defaults, ["read", "-g", "AppleInterfaceStyle"], stderr_to_stdout: true) do
          {"Dark" <> _rest, 0} -> :dark
          {_output, _status} -> :light
        end
    end
  end

  defp unix?({{:unix, _name}, _version}), do: true
  defp unix?(_os), do: false

  # A terminal that does not say what it is, or says it is `dumb`, is not
  # asked: one that cannot parse the question prints it as text.
  defp answers?(env), do: Map.get(env, "TERM", "") not in ["", "dumb"]

  # The deadline is only reached by a terminal that answers nothing, but an
  # answer that arrives after it is typed into the input box once the screen
  # starts reading keys: over SSH the round trip is the network's, so it gets
  # longer to arrive.
  defp deadline(env) do
    if Map.has_key?(env, "SSH_CONNECTION") or Map.has_key?(env, "SSH_TTY"),
      do: 1_000,
      else: 500
  end

  # Darwin 25 is macOS 26, where Terminal.app's default profile stopped
  # following the system appearance.
  defp follows_appearance?(%{"TERM_PROGRAM" => "Apple_Terminal"}, {{:unix, :darwin}, version}),
    do: darwin_major(version) < 25

  defp follows_appearance?(_env, _os), do: false

  defp darwin_major({major, _minor, _patch}) when is_integer(major), do: major
  defp darwin_major(_unknown), do: 0

  # A channel of n hex digits is a fraction of 16^n - 1, so `ff` and `ffff`
  # are both full intensity.
  defp scale(digits) do
    {value, ""} = Integer.parse(digits, 16)
    max = Integer.pow(16, byte_size(digits)) - 1
    round(value * 255 / max)
  end

  defp lightness(rgb), do: if(Colour.light?(rgb), do: :light, else: :dark)

  # Non-canonical so the reply is readable without a newline, no echo so it
  # is not printed over the shell, and `min 0 time 1` so a read with nothing
  # to read returns after a tenth of a second instead of blocking.
  defp raw_mode(sh, tty) do
    script = ~S|s=$(stty -g < "$1") && stty -icanon -echo min 0 time 1 < "$1" && echo "$s"|

    case System.cmd(sh, ["-c", script, "lmx-stty", tty], stderr_to_stdout: true) do
      {saved, 0} -> {:ok, String.trim(saved)}
      {_output, _status} -> :error
    end
  end

  defp restore(sh, tty, saved) do
    System.cmd(sh, ["-c", ~S|stty "$2" < "$1"|, "lmx-stty", tty, saved], stderr_to_stdout: true)
    :ok
  end

  # A terminal that cannot be written to is one that answers nothing: the
  # question is an optimisation, and failing it must not stop the screen.
  defp ask(path, deadline) do
    case :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]) do
      {:ok, tty} ->
        try do
          asked(tty, :file.write(tty, @query), deadline)
        after
          :file.close(tty)
        end

      {:error, _reason} ->
        ""
    end
  end

  defp asked(tty, :ok, deadline),
    do: read(tty, "", System.monotonic_time(:millisecond) + deadline)

  defp asked(_tty, {:error, _reason}, _deadline), do: ""

  # Until the DA1 answer (`ESC [ ? … c`) arrives, which a terminal sends
  # after the OSC 11 one it answers first, or the deadline passes. A read
  # with nothing to read returns after `stty`'s tenth of a second; the pause
  # on one that returns at once (a terminal that hung up) keeps the wait for
  # the deadline from spinning.
  defp read(tty, buffer, until) do
    cond do
      Regex.match?(~r/\e\[\?[0-9;]*c/, buffer) ->
        buffer

      System.monotonic_time(:millisecond) >= until ->
        buffer

      true ->
        case :file.read(tty, 64) do
          {:ok, data} ->
            read(tty, buffer <> data, until)

          _eof_or_error ->
            Process.sleep(5)
            read(tty, buffer, until)
        end
    end
  end
end
