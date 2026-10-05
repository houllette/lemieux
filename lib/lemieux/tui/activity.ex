# Unguarded, unlike `Lemieux.TUI` and `Lemieux.TUI.Status`: there is no widget
# and no NIF in here, only the words and a clock. The row it feeds is drawn by
# `Lemieux.TUI.RichText`, which is guarded; what is worth testing about a phase
# is the sentence it produces, and that stays testable on a machine that never
# installed the terminal dependency.
defmodule Lemieux.TUI.Activity do
  @moduledoc """
  What the session is doing right now, in the words a person would use.

  This was the left-hand half of the status line, and where it is now is the
  point of the module. A permanently visible row is where what is permanently
  true belongs — where the context window stands, what the session has been
  billed for, what that cost. `thinking (40s)` is none of those: it is one
  moment of one turn, it changes several times a minute, and it describes the
  tool calls and the answer directly above it. `Lemieux.TUI` draws it as the
  last row of the transcript, under whatever the model has said so far, and
  drops it when the turn ends — where the summary rule takes its place.

  ## Why the words live apart from either row

  Two things say them. The transcript draws the live row, and a host that
  writes its own `Lemieux.TUI.Status` may want the old one back —
  `Lemieux.TUI.Status.activity/1` is exactly that, and it is a call into here.
  A vocabulary one of them had to guess at is a vocabulary that drifts.

  ## Nothing here claims anything it has not measured

  Every phase is a fact the session reported — a request went out, a thinking
  delta arrived, a tool was called — with a clock beside it. The turn's label
  is the one decorative word, and `Lemieux.TUI.Processing` is explicit that it
  is a label rather than a guess. A phase kind this does not recognise says
  nothing rather than falling through to a sentence: new kinds get added, and
  a stale `case` describes the previous wait to somebody waiting on this one.
  """

  @typedoc """
  What the wait is, and how long it has been one.

  `:detail` is the phase's own and its shape depends on `:kind` — see
  `Lemieux.TUI`'s `t:phase/0`, which is where they are produced.
  """
  @type phase :: %{
          kind:
            :waiting
            | :thinking
            | :answering
            | :composing
            | :tool
            | :approval
            | :delegating
            | :retrying
            | :connecting,
          detail: term(),
          for: non_neg_integer(),
          elapsed_ms: non_neg_integer()
        }

  @typedoc """
  A turn as `Lemieux.TUI` resolves it once per frame.

  A map rather than a struct of its own, and open rather than exact, because
  `t:Lemieux.TUI.Status.t/0` carries exactly these keys among its others: the
  status line contract and the transcript row read one snapshot instead of one
  of them converting the other's.

  Elapsed times arrive already read off the screen's clock. `render/2` runs at
  frame rate, so nothing here is a call.
  """
  @type t :: %{
          required(:busy?) => boolean(),
          required(:label) => String.t(),
          required(:elapsed) => non_neg_integer(),
          required(:frame) => non_neg_integer(),
          required(:phase) => phase() | nil,
          required(:delegation) => %{count: non_neg_integer(), bytes: non_neg_integer()} | nil,
          optional(atom()) => term()
        }

  # Ten frames at the 250ms activity tick is one revolution every two and a
  # half seconds — fast enough to read as alive, slow enough not to be the
  # thing on screen demanding attention while somebody reads the answer above
  # it. Braille rather than the old trailing dots: a glyph in a fixed gutter
  # column animates without moving the text beside it, which is what the dots
  # needed padding to avoid.
  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc """
  The one turning glyph, for the tick the screen is on.

  Driven by the frame counter rather than a clock, so it moves exactly when
  the screen is redrawn instead of skipping while a terminal is busy.
  """
  @spec spinner(frame :: non_neg_integer()) :: String.t()
  def spinner(frame) when is_integer(frame) and frame >= 0,
    do: Enum.at(@spinner, rem(frame, length(@spinner)))

  @doc """
  The live row's text, or `nil` when no turn is running.

  The turn's label and how long it has run, then what it is doing and how long
  *that* has. The label is first because it is the thing that changes once per
  turn: it is how somebody glancing back knows a new turn started rather than
  the old one still going.
  """
  @spec line(activity :: t()) :: String.t() | nil
  def line(%{busy?: true} = activity) do
    ["#{activity.label} (#{duration(activity.elapsed)})", phase(activity)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def line(_idle), do: nil

  @doc """
  What the wait is, in the words a person would use, with how long it has run.

  `nil` between phases rather than a guess at which one is next.
  """
  @spec phase(activity :: t()) :: String.t() | nil
  def phase(%{phase: nil}), do: nil

  def phase(%{phase: phase} = activity), do: wording(phase, duration(phase.for), activity)

  # One clause per kind rather than one `case`, so the vocabulary can grow a
  # wait at a time without one function growing past what credo allows.
  defp wording(%{kind: :waiting}, for, activity),
    do: delegation(activity[:delegation]) <> "waiting for the model (#{for})"

  defp wording(%{kind: :thinking}, for, _activity), do: "thinking (#{for})"
  defp wording(%{kind: :answering}, _for, _activity), do: "answering"

  defp wording(%{kind: :composing, detail: %{name: name, target: target, bytes: bytes}}, _f, _a),
    do: "composing #{name}#{target(target)} (#{bytes(bytes)})"

  defp wording(%{kind: :tool, detail: %{name: name}}, for, _activity),
    do: "running #{name} (#{for})"

  # The one wait that is on the person, not the model or a tool, so it says
  # so: a row reading `running bash` while a hook holds the call would have
  # somebody watching for output that is waiting on them.
  defp wording(%{kind: :approval, detail: %{name: name}}, for, _activity),
    do: "waiting for your approval of #{name} (#{for})"

  defp wording(%{kind: :delegating, detail: %{running: running}}, for, _activity),
    do: "#{investigations(running)} running (#{for})"

  defp wording(%{kind: :retrying, detail: detail} = phase, _for, _activity) do
    %{attempt: attempt, max: max, delay_ms: delay, kind: kind} = detail
    remaining = max(delay - phase.elapsed_ms, 0)

    kept =
      if Map.get(detail, :after_output, false), do: " · the partial answer was kept", else: ""

    "#{kind}, retrying in #{div(remaining + 999, 1_000)}s (#{attempt}/#{max})#{kept}"
  end

  # A prompt waits a bounded moment for MCP servers still connecting, so the
  # tools they bring can be in its first request.
  defp wording(%{kind: :connecting, detail: %{servers: servers}}, for, _activity),
    do: "waiting for MCP #{servers_named(servers)} (#{for})"

  defp wording(_phase, _for, _activity), do: nil

  @doc """
  Seconds as somebody would say them: seconds, then minutes, then hours.

  Public because the summary line a finished turn prints reads the same clock,
  and a second copy of this eventually disagrees about what an hour looks like.
  """
  @spec duration(seconds :: non_neg_integer()) :: String.t()
  def duration(seconds) when seconds < 60, do: "#{seconds}s"
  def duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"

  def duration(seconds),
    do: "#{div(seconds, 3_600)}hr #{seconds |> rem(3_600) |> div(60)}m"

  @doc "Bytes as a person reads them, which above a kilobyte is kilobytes."
  @spec bytes(bytes :: non_neg_integer()) :: String.t()
  def bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def bytes(bytes), do: "#{Float.round(bytes / 1_024, 1)} KB"

  @doc "A fan-out's size, named the way the transcript names it."
  @spec investigations(count :: non_neg_integer()) :: String.t()
  def investigations(1), do: "1 read-only investigation"
  def investigations(count), do: "#{count} read-only investigations"

  defp delegation(nil), do: ""

  defp delegation(%{count: count, bytes: bytes}),
    do: "reading #{investigations(count)} (#{bytes(bytes)}) · "

  defp servers_named([name]), do: name
  defp servers_named(names) when is_list(names), do: Enum.join(names, ", ")
  defp servers_named(_names), do: "servers"

  defp target(target) when is_binary(target) and target != "", do: " #{target}"
  defp target(_target), do: ""
end
