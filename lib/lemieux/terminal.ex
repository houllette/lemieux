defmodule Lemieux.Terminal do
  @moduledoc """
  Terminal control sequences that are not about drawing.

  Window and tab titles (OSC 0), desktop notifications (OSC 9 and the bell),
  and program status (OSC 7501). All have the same transport ownership as
  `Lemieux.Clipboard` and for the same reason — they belong to the terminal
  *displaying* the interface, not to the machine running the session, so a
  byte-stream transport writes through its own writer and a transport with
  no stream to write to is reported as unsupported rather than retitling (or
  ringing) whatever tty this OS process happens to have inherited.

  `ex_ratatui` has `set_terminal_title/1`, and this does not call it. That
  function writes to the local process's stdout, which is the wrong terminal
  for every transport but `:local`, and it lives behind a Rust NIF, which
  would put a title change out of reach of a suite that deliberately runs
  without one.

  Best-effort, like OSC 52: a terminal that ignores the escape says nothing
  about having ignored it, and there is no acknowledgement to distinguish
  that from a title nobody looked at.
  """

  # Deliberately spelled out rather than borrowed from `Lemieux.Clipboard`: a
  # remote type is a compile-time dependency, and `mix xref graph --label
  # compile-connected` fails this build over those.
  @type transport :: :local | {:session, term(), (iodata() -> :ok)} | term()

  @doc """
  Sets the title of the terminal owned by the given transport.

  An empty `text` clears it, which is what leaves the shell free to put its
  own title back on the next prompt.
  """
  @spec title(text :: String.t(), transport()) :: :ok | {:error, term()}
  def title(text, :local) when is_binary(text),
    do: emit(fn bytes -> IO.binwrite(:stdio, bytes) end, text)

  def title(text, {:session, _session, writer}) when is_binary(text) and is_function(writer, 1),
    do: emit(writer, text)

  def title(text, _transport) when is_binary(text), do: {:error, :unsupported_transport}

  @doc false
  @spec sequence(text :: String.t()) :: String.t()
  def sequence(text) when is_binary(text), do: "\e]0;" <> sanitized(text) <> "\a"

  @doc """
  Asks the terminal showing the interface to notify its owner.

  OSC 9 is the notification iTerm2, WezTerm, kitty, Ghostty and Windows
  Terminal post to the desktop; a terminal that does not know it consumes
  the whole sequence, because an OSC is terminated whether or not it was
  understood. The bell after it is for the rest: Terminal.app bounces the
  dock icon and badges the tab on one. Sent when a long turn finishes or a
  turn waits on a decision; `Lemieux.TUI` decides when, and whether at all.
  """
  @spec notify(text :: String.t(), transport()) :: :ok | {:error, term()}
  def notify(text, :local) when is_binary(text),
    do: write(fn bytes -> IO.binwrite(:stdio, bytes) end, notification(text))

  def notify(text, {:session, _session, writer}) when is_binary(text) and is_function(writer, 1),
    do: write(writer, notification(text))

  def notify(text, _transport) when is_binary(text), do: {:error, :unsupported_transport}

  @doc false
  @spec notification(text :: String.t()) :: String.t()
  def notification(text) when is_binary(text), do: "\e]9;" <> sanitized(text) <> "\a\a"

  @typedoc "A root program-status record; blocked records say what the user must supply."
  @type program_status ::
          :idle | :working | :done | :error | :clear | {:blocked, :permission | :question | :auth}

  @doc """
  Reports the host's state through OSC 7501, using `app=lemieux`.

  Reports replace the root record, so every report repeats the app identity.
  Only fixed protocol values are written: prompts, tool arguments, credentials
  and model output never enter these sequences. No capability query is needed;
  the protocol permits unsolicited reports and unknown OSCs are ignored.

  The host owns when to report. Importing Lemieux or starting an embedded
  session emits nothing. `:clear` removes the terminal's records when an
  interactive host relinquishes it; a one-shot host leaves `:done` or `:error`.
  See the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).
  """
  @spec program_status(status :: program_status(), transport :: transport()) ::
          :ok | {:error, term()}
  def program_status(status, :local),
    do: write(fn bytes -> IO.binwrite(:stdio, bytes) end, status_sequence(status))

  def program_status(status, {:session, _session, writer}) when is_function(writer, 1),
    do: write(writer, status_sequence(status))

  def program_status(_status, _transport), do: {:error, :unsupported_transport}

  defp status_sequence({:blocked, kind}) when kind in [:permission, :question, :auth],
    do: "\e]7501;state=blocked:kind=#{kind}:app=lemieux\e\\"

  defp status_sequence(state) when state in [:idle, :working, :done, :error, :clear],
    do: "\e]7501;state=#{state}:app=lemieux\e\\"

  # OSC 0 rather than OSC 2: it sets the icon name as well as the window title, and
  # the icon name is what several terminals put on the tab. The text reaches here
  # from `/name`, so it is whatever somebody typed — a BEL would end the sequence
  # early and leave the rest on screen as garbage the drawing code has no idea is
  # there, and an ESC would start a new one.
  #
  # The C1 controls, U+0080 to U+009F, go with the C0 ones: a terminal that
  # honours them reads U+009B as CSI, U+009D as OSC and U+009C as the string
  # terminator — the same sequences without an ESC, which stripping C0 alone
  # let through. They are matched as characters, in Unicode mode: as bytes,
  # `\x80-\x9f` is also the middle of "€" and "日本". Unicode mode raises on a
  # string that is not UTF-8, so invalid bytes become U+FFFD first, which is
  # also what a UTF-8 terminal would have drawn for them — and never the lone
  # byte 0x9B that an 8-bit terminal takes for CSI.
  defp sanitized(text) do
    text
    |> String.replace_invalid()
    |> String.replace(~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u, "")
  end

  defp emit(writer, text), do: write(writer, sequence(text))

  defp write(writer, bytes) do
    case writer.(bytes) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_writer_result, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
