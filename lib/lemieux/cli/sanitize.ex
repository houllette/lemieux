defmodule Lemieux.CLI.Sanitize do
  @moduledoc """
  Makes model and tool text safe to write to a person's terminal.

  The terminal UI draws text into cells and never hands the terminal a
  control byte it did not write itself. The line-oriented commands — `lmx
  run`'s answer and its activity lines, `lmx log`, `lmx explain` — wrote
  whatever the model said straight to the device, and what the model says
  is whatever a repository file, a fetched page or an MCP result talked it
  into: `ESC ] 52` writes the clipboard in kitty, Ghostty, WezTerm,
  Alacritty and Windows Terminal, `ESC ] 8` disguises where a link goes,
  `ESC ] 0` retitles the window, and SGR can hide text in plain sight
  (2026-10: a scripted answer did all four through `lmx run` and `lmx log`
  while the TUI showed it inert). So, on a terminal, text loses:

    * every complete escape sequence — CSI, OSC and the two-byte escapes,
      recognised by `Lemieux.Tool.Escapes`, the same matcher that cleans
      command output before a model reads it;
    * every C0 control character except newline and tab, which covers a
      lone `ESC`, `BEL` and the carriage return that overwrites a line;
    * `DEL` and the C1 controls (U+0080–U+009F), which xterm still honours
      as 8-bit `CSI` and `OSC` in UTF-8 mode.

  Only on a terminal. Text redirected to a file or a pipe is the program's
  output, and a script that asked for the answer gets the answer's exact
  bytes; the danger is a device that interprets them. JSON is never
  stripped either — its encoder already escapes C0 — but `json/1` escapes
  the C1 range as well, which changes the bytes and not the text a decoder
  reads back.

  ## Text a person is reviewing

  `lmx mcp list` and `lmx mcp trust` print a repository's `.mcp.json` —
  server names, commands, arguments, URLs — for a person deciding whether to
  run it, and printed it byte for byte (2026-10): a server name retitled the
  window, a URL wrote the clipboard, and a carriage return with an
  erase-line inside one argument made `trust` show a harmless `npx …` over
  the command the server would really run. Removing the controls, as
  `text/1` does, would stop the terminal acting on them but hide that they
  were there, and something hidden in a command is exactly what that person
  is looking for. So that text goes through `visible/1`, which writes each
  one out (`\\e`, `\\r`, `\\u{9B}`), always, terminal or not: a copy of the
  listing kept in a log is read by a person later.
  """

  alias Lemieux.Tool.Escapes

  @controls ~r/[\x{00}-\x{08}\x{0B}-\x{1F}\x{7F}-\x{9F}]/u
  @json_controls ~r/[\x{7F}-\x{9F}]/u

  # Every C0 control, newline and tab included (one line of a listing must
  # stay one line), DEL, the C1 controls, and the format characters that
  # draw nothing or reorder what follows: zero-width spaces and joiners, the
  # bidirectional marks, embeddings, overrides and isolates (an override
  # makes the rest of a name read backwards), and the byte-order mark.
  @hidden ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]/u

  @named %{
    0x00 => "\\0",
    0x07 => "\\a",
    0x08 => "\\b",
    0x09 => "\\t",
    0x0A => "\\n",
    0x0B => "\\v",
    0x0C => "\\f",
    0x0D => "\\r",
    0x1B => "\\e"
  }

  @typedoc "A device a command writes to."
  @type device :: :stdio | :stderr

  @doc """
  `text` with escape sequences and control characters removed, keeping
  newlines and tabs. Invalid UTF-8 becomes U+FFFD first, so the result is
  always printable.
  """
  @spec text(text :: String.t()) :: String.t()
  def text(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> Escapes.strip()
    |> String.replace(@controls, "")
  end

  @doc """
  `text` with every control character, and every character that draws
  nothing or reorders the text after it, written out as an escape a person
  can read: `ESC` as `\\e`, a carriage return as `\\r`, a newline as `\\n`,
  another C0 control or `DEL` as `\\xHH`, and anything above as `\\u{H}`.
  Invalid UTF-8 becomes U+FFFD first. The result is always one line, safe
  on any device, and shows that something was there; see "Text a person is
  reviewing" in the module documentation.

  A backslash already in `text` is left as it is: one that looks like an
  escape can only make the text look more suspicious than it is, never hide
  a character this writes out.
  """
  @spec visible(text :: String.t()) :: String.t()
  def visible(text) when is_binary(text) do
    Regex.replace(@hidden, String.replace_invalid(text), fn <<codepoint::utf8>> ->
      escape(codepoint)
    end)
  end

  defp escape(codepoint) when is_map_key(@named, codepoint), do: Map.fetch!(@named, codepoint)
  defp escape(codepoint) when codepoint <= 0x7F, do: "\\x" <> hex(codepoint, 2)
  defp escape(codepoint), do: "\\u{" <> hex(codepoint, 1) <> "}"

  defp hex(codepoint, digits),
    do: codepoint |> Integer.to_string(16) |> String.pad_leading(digits, "0")

  @doc """
  `text` as it should reach `device`: `text/1` when the device is a
  terminal, unchanged otherwise. `terminal?` overrides the check, which is
  how tests (whose captured devices are never terminals) ask for either.
  """
  @spec for_device(text :: String.t(), device :: device(), terminal? :: boolean() | nil) ::
          String.t()
  def for_device(text, device, terminal? \\ nil) when is_binary(text) do
    if terminal?(device, terminal?), do: text(text), else: text
  end

  @doc """
  Whether `device` is a terminal, unless `override` already says.

  OTP reports it per descriptor in the standard io server's options, which
  is where `Lemieux.CLI.Run` already learns whether standard input is one.
  A device that does not say — a test's captured io — is not a terminal.
  """
  @spec terminal?(device :: device(), override :: boolean() | nil) :: boolean()
  def terminal?(device, override \\ nil)
  def terminal?(_device, override) when is_boolean(override), do: override

  def terminal?(device, nil) when device in [:stdio, :stderr] do
    key = if device == :stdio, do: :stdout, else: :stderr

    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, key, false) == true
      _unknown -> false
    end
  end

  @doc """
  An encoded JSON document with DEL and the C1 controls escaped as `\\uXXXX`.

  They can only occur inside strings, where the escape means the same
  character, so a decoder reads back exactly what was encoded.
  """
  @spec json(encoded :: String.t()) :: String.t()
  def json(encoded) when is_binary(encoded) do
    Regex.replace(@json_controls, encoded, fn <<codepoint::utf8>> ->
      "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")
    end)
  end
end
