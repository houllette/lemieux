defmodule Lemieux.Conversation.Shell do
  @moduledoc """
  One command a person asked for, run through the session's environment,
  with a bounded record of what it printed.

  `!cmd`, `/diff` and `/doctor` all run something on the person's behalf, and
  all of them go through `Lemieux.Environment.run/3` with the session's
  environment rather than `System.cmd/3` on the host. The difference is the
  whole point: a session in a sandbox, or one that withholds credentials from
  its commands, must not grow a side door that runs unsandboxed with every
  key in the environment because a person typed `!` instead of asking the
  model. It also means the command runs where the session's files are — a
  container, a remote workspace — rather than on whatever machine the screen
  happens to be drawn on.

  The environment's own streaming contract is kept: the output is collected
  as it arrives, terminal escapes are stripped as the `bash` tool strips
  them, the non-interactive variables that keep pagers and credential
  prompts from waiting on a person nobody can reach are set, and what is
  kept is the head and the tail. A person running `cat` on a large file
  wants to see that it ran and how it ended, not to have a screen's worth of
  scrollback replaced — and a transcript that carried all of it into the
  next request would pay for it on every request after.
  """

  alias Lemieux.Environment
  alias Lemieux.Tool.Escapes
  alias Lemieux.Tools.Bash

  @default_timeout_ms 120_000
  # What the environment is allowed to produce before it stops the command,
  # which is far more than is kept: a command is stopped as a runaway, not
  # for printing a page.
  @output_limit 2_000_000
  @default_keep_bytes 32_000

  @typedoc """
  How a command ended.

    * `:exited` — it exited, with `exit_status`.
    * `:timeout` — the environment stopped it at its deadline.
    * `:output_limit` — the environment stopped it for printing too much.
    * `{:failed, reason}` — it could not be run to completion at all.
  """
  @type outcome :: :exited | :timeout | :output_limit | {:failed, term()}

  @typedoc """
  What running a command left: its kept output (the head and the tail when
  it printed more than the budget), how many bytes it printed in all, and how
  it ended.
  """
  @type result :: %{
          command: String.t(),
          output: String.t(),
          bytes: non_neg_integer(),
          truncated?: boolean(),
          exit_status: non_neg_integer() | nil,
          outcome: outcome()
        }

  @doc """
  Runs `command` in `environment` from `cwd` and waits for it.

  Options: `:timeout_ms` (default two minutes) and `:keep_bytes`, how much of
  the output is kept (default #{@default_keep_bytes}). Blocks for as long as
  the command runs, so a host calls it from work handed to
  `Lemieux.Conversation.Dispatch.run/3`.
  """
  @spec run(
          environment :: Environment.t(),
          command :: String.t(),
          cwd :: Path.t(),
          opts :: keyword()
        ) :: {:ok, result()} | {:error, String.t()}
  def run(environment, command, cwd, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_list(opts) do
    keep = Keyword.get(opts, :keep_bytes, @default_keep_bytes)

    case Environment.run(environment, command,
           cwd: cwd,
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
           env: Bash.non_interactive_env(),
           max_output_bytes: @output_limit
         ) do
      {:ok, events} -> {:ok, collect(events, command, keep)}
      {:error, reason} -> {:error, "could not run #{command}: #{describe(reason)}"}
    end
  end

  # Head and tail kept as the bytes arrive, so a command that prints for two
  # minutes never holds more than the budget in this process: `head` fills
  # first, `tail` keeps the most recent bytes after it.
  defp collect(events, command, keep) do
    initial = %{
      command: command,
      head: [],
      head_bytes: 0,
      tail: "",
      bytes: 0,
      clean: 0,
      pending: "",
      exit_status: nil,
      outcome: {:failed, :no_exit_status}
    }

    events
    |> Enum.reduce(initial, &observe(&1, &2, div(keep, 2)))
    |> finish()
  end

  defp observe({:data, chunk}, acc, half) do
    {stripped, pending} = Escapes.strip_chunk(acc.pending, chunk)

    acc = %{
      acc
      | pending: pending,
        bytes: acc.bytes + byte_size(chunk),
        clean: acc.clean + byte_size(stripped)
    }

    keep(acc, stripped, half)
  end

  defp observe({:exit_status, status}, acc, _half),
    do: %{acc | exit_status: status, outcome: :exited}

  defp observe({:timeout, _timeout_ms}, acc, _half), do: %{acc | outcome: :timeout}
  defp observe({:output_limit, _bytes}, acc, _half), do: %{acc | outcome: :output_limit}
  defp observe({:failed, reason}, acc, _half), do: %{acc | outcome: {:failed, reason}}
  defp observe(_other, acc, _half), do: acc

  defp keep(acc, "", _half), do: acc

  defp keep(%{head_bytes: filled} = acc, text, half) when filled < half do
    room = half - filled

    if byte_size(text) <= room do
      %{acc | head: [acc.head, text], head_bytes: filled + byte_size(text)}
    else
      {now, later} = byte_split(text, room)
      keep(%{acc | head: [acc.head, now], head_bytes: half}, later, half)
    end
  end

  defp keep(acc, text, half) do
    tail = acc.tail <> text
    %{acc | tail: last_bytes(tail, half)}
  end

  # A sequence still held back when the stream ends never completed, and
  # `Lemieux.Tool.Escapes.strip_chunk/2` says to drop it.
  defp finish(acc) do
    head = IO.iodata_to_binary(acc.head)
    tail = acc.tail
    kept = byte_size(head) + byte_size(tail)
    # Measured after escapes are stripped: a coloured listing is not a longer
    # one, and counting its escape bytes would announce a cut that never
    # happened.
    truncated? = acc.clean > kept

    output =
      if truncated?,
        do: head <> "\n… #{acc.clean - kept} bytes not shown …\n" <> tail,
        else: head <> tail

    %{
      command: acc.command,
      output: utf8(output),
      bytes: acc.bytes,
      truncated?: truncated?,
      exit_status: acc.exit_status,
      outcome: acc.outcome
    }
  end

  # A command prints bytes, not text: `!cat` of a Latin-1 file or a binary
  # prints bytes that are not UTF-8, and they were kept as they came. Every
  # reader of the result wants text — the screen's line wrapping runs a
  # Unicode regex over it, which raised and took the screen and `lmx` down
  # with it, and the note the next message carries went into the transcript,
  # whose JSON encoder raised and stopped the session. So it is repaired here,
  # once, the way `Lemieux.Tool.Result` repairs a tool's output: each invalid
  # sequence becomes U+FFFD, which is what a terminal would have drawn.
  defp utf8(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  # Cut on a character boundary, not a byte one: a multi-byte character split
  # across the gap would render as replacement characters on both sides of it.
  # A UTF-8 character is at most four bytes, so backing off past at most three
  # continuation bytes finds the boundary; output that is not UTF-8 at all is
  # cut where the budget says.
  defp byte_split(text, at) do
    at = boundary(text, at, 3)
    <<now::binary-size(^at), later::binary>> = text
    {now, later}
  end

  defp boundary(_text, 0, _steps), do: 0
  defp boundary(_text, at, 0), do: at

  defp boundary(text, at, steps) do
    if continuation?(:binary.at(text, at)), do: boundary(text, at - 1, steps - 1), else: at
  end

  defp continuation?(byte), do: Bitwise.band(byte, 0b1100_0000) == 0b1000_0000

  defp last_bytes(text, size) when byte_size(text) <= size, do: text

  defp last_bytes(text, size) do
    skip = byte_size(text) - size
    <<_dropped::binary-size(^skip), kept::binary>> = text
    drop_partial(kept)
  end

  # The first bytes of a tail cut mid-character are a character's continuation
  # bytes; dropping them costs at most three bytes and keeps the text valid.
  defp drop_partial(text, steps \\ 3)
  defp drop_partial(text, 0), do: text

  defp drop_partial(<<byte, rest::binary>> = text, steps) do
    if continuation?(byte), do: drop_partial(rest, steps - 1), else: text
  end

  defp drop_partial(<<>>, _steps), do: <<>>

  @doc """
  The one-line ending a person reads under the output: how the command
  finished, in words.
  """
  @spec ending(result :: result()) :: String.t()
  def ending(%{outcome: :exited, exit_status: 0}), do: "exit 0"
  def ending(%{outcome: :exited, exit_status: status}), do: "exit #{status}"
  def ending(%{outcome: :timeout}), do: "stopped at its deadline"
  def ending(%{outcome: :output_limit}), do: "stopped: it printed too much"
  def ending(%{outcome: {:failed, reason}}), do: "failed to run: #{describe(reason)}"

  @doc """
  The result as a person reads it: the command, what it printed, and how it
  ended — the same three things a terminal would have shown.
  """
  @spec display(result :: result()) :: String.t()
  def display(%{command: command, output: output} = result) do
    body = String.trim_trailing(output)

    ["$ " <> command, body, "(#{ending(result)})"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # What the model is given of the output: less than the person was shown,
  # because it is paid for on every request of the conversation afterwards.
  @context_bytes 8_000

  @doc """
  The note the next message carries: marked as the person's command, not the
  model's, with the output bounded to #{@context_bytes} bytes (its head and
  tail).

  Marked because a model that finds a command's output in the conversation
  otherwise believes it ran it — and a model that believes it ran `rm` has
  been told something false about its own actions.
  """
  @spec context(result :: result()) :: String.t()
  def context(%{command: command, output: output} = result) do
    body =
      output
      |> String.trim_trailing()
      |> bounded(@context_bytes)

    """
    [The person ran this command in lmx before this message. You did not run it; \
    its output is here so you can see what they saw.]
    $ #{command}
    #{body}
    (#{ending(result)})\
    """
  end

  defp bounded(text, max) when byte_size(text) <= max, do: text

  defp bounded(text, max) do
    half = div(max, 2)
    {head, _rest} = byte_split(text, half)
    tail = last_bytes(text, half)

    head <>
      "\n… #{byte_size(text) - byte_size(head) - byte_size(tail)} bytes not shown …\n" <> tail
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
