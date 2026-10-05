defmodule Lemieux.Tool.Escapes do
  @moduledoc """
  Removes terminal control sequences from command output before a model reads it.

  A command run through a pipe usually notices it has no terminal and prints
  plain text, but plenty do not ask: test runners force colour, progress bars
  redraw with cursor movement, a shell prompt sets the window title. None of
  it is information to a model, all of it is paid for as tokens on every later
  request, and some of it — `\\e[2K\\e[1G` between two versions of the same
  line — reads as corruption. So output loses its escape sequences at the tool
  boundary, where the text is still the tool's rather than the transcript's.

  Three shapes are recognised, which between them are what programs emit:
  CSI (`ESC [` … final byte — colour, cursor, erase), OSC (`ESC ]` … BEL or
  `ESC \\` — titles, hyperlinks) and the two-byte escapes (`ESC` followed by
  one byte from `0` to `~` — keypad mode, save and restore cursor). Anything
  else, a lone `ESC` included, is left for a person to see rather than
  guessed at.

  ## Streaming

  Output arrives in chunks, and a chunk boundary can fall inside a sequence —
  `…\\e[3` then `2mFAIL…`. `strip_chunk/2` therefore holds back an unfinished
  sequence at the end of a chunk and prepends it to the next. What it holds is
  bounded: a "sequence" longer than #{4_096} bytes is not one, and is released
  as text.
  """

  # CSI, then OSC, then every other two-byte escape (a final byte from `0` to
  # `~`, less `[` and `]`, which introduce the two above — matching them here
  # would eat the start of a sequence that has not finished arriving).
  @complete ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[0-Z\\^-~]/
  @unfinished ~r/\e(?:\[[0-?]*[ -\/]*|\][^\a\e]*\e?)?\z/
  @max_pending 4_096

  @doc "Removes every complete terminal control sequence from `text`."
  @spec strip(text :: binary()) :: binary()
  def strip(text) when is_binary(text) do
    if String.contains?(text, "\e"), do: Regex.replace(@complete, text, ""), else: text
  end

  @doc """
  Strips `chunk` after the unfinished sequence held back from the previous one.

  Returns the clean text and what to hold for the next call. At the end of a
  stream the held bytes are an unfinished sequence that never completed;
  callers drop them.
  """
  @spec strip_chunk(pending :: binary(), chunk :: binary()) ::
          {clean :: binary(), pending :: binary()}
  def strip_chunk(pending, chunk) when is_binary(pending) and is_binary(chunk) do
    text = strip(pending <> chunk)

    case Regex.run(@unfinished, text, return: :index) do
      [{start, length}] when length <= @max_pending ->
        {binary_part(text, 0, start), binary_part(text, start, length)}

      _complete_or_too_long ->
        {text, ""}
    end
  end
end
