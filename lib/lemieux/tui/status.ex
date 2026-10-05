# Guarded exactly as `Lemieux.TUI` is, and for the same reason: this one draws
# widgets, so it only exists when the optional terminal dependency does. The word
# list it labels a turn with is in `Lemieux.TUI.Processing`, which is not guarded,
# because a configuration file has to be checkable on a machine that never
# installed the NIF.
if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.Status do
    @moduledoc """
    The one row beneath the input box, and how to replace it.

    This module is two things at once, deliberately. It declares the contract a
    host implements to draw that row itself, and it *is* the implementation
    `lmx` ships — so the contract cannot drift from the thing it describes, and
    the default layout is a worked example of the behaviour rather than a
    paragraph about one.

    ## What the shipped layout says, and what it gave up

    The row is permanently visible, so what belongs on it is what is
    permanently true: where the context window stands, what the session has
    been billed for, and what that cost. It used to lead with what the turn was
    doing as well — `Pondering... (12s) · thinking (40s)` — and that half has
    moved into the transcript, where the tool calls and the answer it describes
    already are. See `Lemieux.TUI.Activity`. What is left here about activity is
    the screen's own: a resume, and an armed ctrl-c.

    ## Why this is an extension point at all

    Permanently visible also makes it the only part of the screen where what
    somebody wants on it is a matter of taste rather than of correctness. A
    host billing a team wants its own budget there, a host running against a
    gateway wants the route, somebody who never looks at cost wants the room
    back — and somebody who liked the old row wants the activity back on it,
    which `activity/1` is still here to give them.

    Rather than grow a settings language for that, the row is handed over
    whole. A host passes `status_line: MyApp.Status` to `Lemieux.TUI`, and gets
    a `t:t/0` and a `t:ExRatatui.Layout.Rect.t/0`, and returns whatever
    `ExRatatui` can draw. Anything the library can render is available —
    gauges, sparklines, a `Line` of individually styled spans — because the
    answer to "what can I put there" should be the library's answer and not a
    shorter list this module maintains.

    ## What it does not get to do

    Two limits, and both are about the rest of the screen rather than about
    taste.

    The rects come back clamped to the area — `confine/2` — so a status line
    cannot paint over the transcript or the input box. Without that, the
    obvious mistake (returning `%Rect{x: 0, y: 0, ...}` because that is where
    the widget goes *within* the row) silently erases the conversation, and
    the second-most-obvious one erases it only on some terminal sizes.

    And `c:height/0` is clamped too, to a third of the frame. A status line may
    ask for more than one row — two is enough for a bar above a line of text —
    but the transcript is what this program is for, and a row count read from
    an extension is exactly the number that eventually arrives as a hundred.

    ## What it is given

    More than the shipped layout draws, already resolved: the turn's label and
    how long it has been running, the phase and how long *that* has been
    running, the conversation (which carries the context position, the spend
    and the model), the theme and the accent. The turn's half is still here
    because a replacement is free to want it. `render/2` runs at frame rate, so
    nothing here is a call — it is a struct built by the caller once per frame
    from state it already holds.

    Elapsed times arrive as whole seconds *and* as milliseconds, because the
    two existing readers want different ones: a person reads seconds, and the
    retry countdown subtracts from a delay measured in milliseconds.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.Conversation
    alias Lemieux.TUI.Activity
    alias Lemieux.TUI.Theme

    @typedoc """
    What the session is doing right now, and for how long.

    `Lemieux.TUI.Activity`'s, because that is what turns one into a sentence. A
    status line that does not recognise a kind should say nothing about it
    rather than guess: new kinds get added, and a stale `case` that fell
    through to a label would start describing the wrong wait.
    """
    @type phase :: Activity.phase()

    @typedoc """
    Everything the row is drawn from.

      * `:width` and `:height` — the area, repeated here so a layout can be
        decided without carrying the rect around.
      * `:theme` and `:accent` — the palette, and the one colour `/color`
        overrides. The shipped layout draws in the theme's plain text colour,
        dimmed, and ignores the accent, which is a choice a replacement is
        free to disagree with.
      * `:conversation` — the whole of it, so the context position, the spend,
        the model and the reasoning effort are all reachable.
        `Lemieux.Conversation.status/1` is the stock formatting of the last
        three.
      * `:name` — what this sitting calls the session, `/name` included.
      * `:busy?` — a turn is in flight. False between turns, when `:label`,
        `:elapsed` and `:phase` describe the turn that just ended.
      * `:label` — the word this turn is being called; see
        `Lemieux.TUI.Processing`.
      * `:elapsed` — seconds since the turn began.
      * `:frame` — the spinner's phase, incremented on a timer. Anything
        animated should be driven from this rather than from a clock, so that
        it moves exactly when the screen is redrawn.
      * `:phase` — what the session is doing, or `nil` between phases.
      * `:delegation` — the size of the fan-out whose results are being read,
        from its close until the model's first delta, or `nil`.
      * `:draft?` and `:queued?` — whether the composer has an active message
        or one staged for the next turn. The shipped row shows the keys for
        steering, staging, revising, and unstaging while work is active.
      * `:queued_count` — how many messages are staged, up to nine.
      * `:revising` — the queue slot currently being edited, if any.
      * `:feedback` — a short-lived result of a local screen action, such as
        copying a selection or failing to open a link.
      * `:resuming?` and `:exiting?` — the two things the screen itself is
        doing that outrank the turn.
      * `:permission` — the permission mode's label (`"ask"`,
        `"accept edits"`, …), or `nil` when the host did not enable
        permissions and every tool call runs unasked.
      * `:requests` and `:request_cap` — direct provider requests so far and
        the `max_requests` bounding them; the cap is `nil` when there is none.
      * `:mcp_connecting` — the MCP servers still connecting, by name.
    """
    @type t :: %__MODULE__{
            width: pos_integer(),
            height: pos_integer(),
            theme: Theme.t() | nil,
            accent: Style.color() | nil,
            conversation: Conversation.t() | nil,
            compact_at: number() | nil,
            name: String.t() | nil,
            busy?: boolean(),
            label: String.t(),
            elapsed: non_neg_integer(),
            frame: non_neg_integer(),
            phase: phase() | nil,
            delegation: %{count: non_neg_integer(), bytes: non_neg_integer()} | nil,
            draft?: boolean(),
            queued?: boolean(),
            queued_count: non_neg_integer(),
            revising: pos_integer() | nil,
            feedback: String.t() | nil,
            resuming?: boolean(),
            exiting?: boolean(),
            permission: String.t() | nil,
            requests: non_neg_integer(),
            request_cap: pos_integer() | nil,
            mcp_connecting: [String.t()]
          }

    # Every default is a literal. A function call in a struct default is a
    # compile-time call, and this build fails on those — the same rule
    # `Lemieux.TUI` follows for its own conversation and theme fields.
    defstruct width: 80,
              height: 1,
              theme: nil,
              accent: nil,
              conversation: nil,
              compact_at: nil,
              name: nil,
              busy?: false,
              label: "Processing",
              elapsed: 0,
              frame: 0,
              phase: nil,
              delegation: nil,
              draft?: false,
              queued?: false,
              queued_count: 0,
              revising: nil,
              feedback: nil,
              resuming?: false,
              exiting?: false,
              permission: nil,
              requests: 0,
              request_cap: nil,
              mcp_connecting: []

    @doc """
    Builds a snapshot from the fields a caller has.

    A constructor rather than a struct literal at the call site, so that
    `Lemieux.TUI` — which builds one per frame — takes an ordinary runtime
    dependency on this module rather than a compile-time one. Unknown keys
    raise, which is what makes a renamed field a build failure in the host
    rather than a status line that quietly stopped showing something.
    """
    @spec new(fields :: keyword()) :: t()
    def new(fields \\ []) when is_list(fields), do: struct!(__MODULE__, fields)

    @doc """
    Draws the row.

    Returns what `ExRatatui.draw/2` takes: `{widget, rect}` pairs in absolute
    screen coordinates. `area` is where the row is; returning `area` itself is
    the ordinary case and `ExRatatui.Layout.split/4` over it is the next one.

    Rects are clamped to `area` before they are drawn, so a widget placed
    outside it is drawn smaller rather than over the transcript. Return `[]` to
    leave the row blank.
    """
    @callback render(status :: t(), area :: Rect.t()) :: [{term(), Rect.t()}]

    @doc """
    How many rows the status line wants. Defaults to one.

    Clamped to a third of the terminal, because the transcript is what the
    screen is for. Asked once per frame, so it may vary — a status line that
    grows while a fan-out runs is allowed.
    """
    @callback height() :: pos_integer()

    @optional_callbacks height: 0

    @doc """
    The status line a sitting draws with, given what the host asked for.

    `nil` is this module, so every caller can hold "whatever was configured"
    in one field without a second one saying whether anything was.
    """
    @spec module(configured :: module() | nil) :: module()
    def module(nil), do: __MODULE__
    def module(configured) when is_atom(configured), do: configured

    @doc """
    How tall the configured status line is, clamped to what the frame can spare.

    A module that does not implement `c:height/0` is one row, which is what the
    row was before it could be replaced. `frame_height` is the whole terminal:
    a third of it is the ceiling, and one row is the floor even on a terminal
    too short to have thirds.
    """
    @spec height(module :: module(), frame_height :: non_neg_integer()) :: pos_integer()
    def height(module, frame_height) when is_atom(module) and is_integer(frame_height) do
      ceiling = max(div(frame_height, 3), 1)

      requested =
        if function_exported?(module, :height, 0), do: module.height(), else: 1

      requested |> max(1) |> min(ceiling)
    end

    @doc """
    Clamps a rect into the area the status line was given.

    Applied to everything a status line returns. A widget entirely outside the
    area comes back with zero width or height, which draws nothing — the same
    outcome as omitting it, and a much easier one to debug than a transcript
    with a hole in it.
    """
    @spec confine(rect :: Rect.t(), area :: Rect.t()) :: Rect.t()
    def confine(%Rect{} = rect, %Rect{} = area) do
      x = rect.x |> max(area.x) |> min(area.x + area.width)
      y = rect.y |> max(area.y) |> min(area.y + area.height)

      %Rect{
        x: x,
        y: y,
        width: rect.width |> min(area.x + area.width - x) |> max(0),
        height: rect.height |> min(area.y + area.height - y) |> max(0)
      }
    end

    @doc """
    The shipped layout: one dim line of segments separated by `·`.

    Where the session stands, and before it the screen's own work when there is
    any. `Lemieux.Conversation.status/1` says why the context position leads:
    a bare ratio behind three labelled numbers read as the window to nobody.
    An illustrative cost estimate leads while present so its label remains
    visible on narrower terminals.
    """
    @spec render(status :: t(), area :: Rect.t()) :: [{term(), Rect.t()}]
    def render(%__MODULE__{} = status, %Rect{} = area) do
      # The theme's plain text, dimmed — the same style as the input box's
      # placeholder. A literal `:white` here was the one colour no theme
      # could change: on a light terminal the status row was white on white
      # under `/theme light` too.
      paragraph = %Paragraph{
        text: " " <> Enum.join(segments(status), " · "),
        style: %Style{fg: plain(status.theme), modifiers: [:dim]}
      }

      [{paragraph, area}]
    end

    defp plain(%{text: %{plain: colour}}), do: colour
    defp plain(_no_theme), do: nil

    @doc """
    The shipped layout's text, as the segments it joins.

    Public because a replacement that only wants to restyle the stock line, or
    to put one more thing on the end of it, should not have to reassemble it.
    """
    @spec segments(status :: t()) :: [String.t()]
    def segments(%__MODULE__{} = status) do
      Enum.reject(
        [
          screen(status),
          mcp(status),
          permission(status),
          requests(status),
          compaction_warning(status),
          conversation_status(status)
        ],
        &is_nil/1
      )
    end

    @doc """
    The permission mode, when the host enabled permissions. Nothing when it
    did not: the startup banner says so once, and a row repeating "full auto"
    forever is a row nobody reads.
    """
    @spec permission(status :: t()) :: String.t() | nil
    def permission(%__MODULE__{permission: nil}), do: nil
    def permission(%__MODULE__{permission: label}), do: "⏵ #{label}"

    @doc """
    Requests against the cap, `req 7/20`, when there is a cap: the one limit a
    person set on purpose and could not otherwise see approaching.
    """
    @spec requests(status :: t()) :: String.t() | nil
    def requests(%__MODULE__{request_cap: nil}), do: nil
    def requests(%__MODULE__{requests: used, request_cap: cap}), do: "req #{used}/#{cap}"

    @doc "The MCP servers still connecting, while there are any."
    @spec mcp(status :: t()) :: String.t() | nil
    def mcp(%__MODULE__{mcp_connecting: []}), do: nil
    def mcp(%__MODULE__{mcp_connecting: [name]}), do: "connecting #{name}…"
    def mcp(%__MODULE__{mcp_connecting: names}), do: "connecting #{length(names)} MCP servers…"

    @doc "Warns once the measured context is within ten percentage points of auto-compaction."
    @spec compaction_warning(status :: t()) :: String.t() | nil
    def compaction_warning(%__MODULE__{
          compact_at: at,
          conversation: %{context: %{measured?: true, fraction: fraction}}
        })
        when is_number(at) and is_number(fraction) and fraction >= at,
        do: "auto-compact due on next request"

    def compaction_warning(%__MODULE__{
          compact_at: at,
          conversation: %{context: %{measured?: true, fraction: fraction}}
        })
        when is_number(at) and is_number(fraction) and fraction >= at - 0.1 do
      remaining = Float.round((at - fraction) * 100, 1)
      "auto-compact in #{remaining}pp of context"
    end

    def compaction_warning(_status), do: nil

    defp conversation_status(%__MODULE__{conversation: nil}), do: nil

    defp conversation_status(%__MODULE__{conversation: conversation}),
      do: Conversation.status(conversation)

    @doc """
    What the *screen* is doing, which is the only activity the shipped row says.

    A resume is why the model is not answering and an armed ctrl-c is about to
    end the sitting: neither belongs in a transcript, because neither is
    something that happened in the conversation. What the turn is doing does,
    and `Lemieux.TUI` draws it there.
    """
    @spec screen(status :: t()) :: String.t() | nil
    def screen(%__MODULE__{resuming?: true}), do: "resuming…"
    def screen(%__MODULE__{exiting?: true}), do: "ctrl-c again to leave"
    def screen(%__MODULE__{feedback: feedback}) when is_binary(feedback), do: feedback

    def screen(%__MODULE__{revising: number}) when is_integer(number),
      do: "editing queued ##{number} · Enter/Tab save in place · Esc restore"

    def screen(%__MODULE__{busy?: true, queued?: true, draft?: true, queued_count: count}),
      do: "Enter steer · Tab queue (#{count}/9) · Alt+1–9 select, Alt+E revise / Alt+U unstage"

    def screen(%__MODULE__{busy?: true, queued?: true, queued_count: count}),
      do: "#{count} queued for next turns · Alt+1–9 select, Alt+E revise / Alt+U unstage"

    def screen(%__MODULE__{busy?: true, draft?: true}),
      do: "Enter steer · Tab queue for next turn"

    def screen(%__MODULE__{queued?: true, queued_count: count}),
      do: "#{count} queued after stopped turn · Alt+1–9 select, Alt+E revise / Alt+U unstage"

    def screen(%__MODULE__{}), do: nil

    @doc """
    The whole of the old row's left-hand half, spinner included.

    Not drawn by the shipped layout any more — `Lemieux.TUI.Activity` says why
    it moved into the transcript — and kept here so that putting it back is one
    call rather than a reimplementation of the phase vocabulary.
    """
    @spec activity(status :: t()) :: String.t() | nil
    def activity(%__MODULE__{resuming?: true}), do: "resuming…"

    def activity(%__MODULE__{busy?: true} = status),
      do: Activity.spinner(status.frame) <> " " <> Activity.line(status)

    def activity(%__MODULE__{exiting?: true}), do: "ctrl-c again to leave"
    def activity(%__MODULE__{}), do: nil

    @doc """
    What the wait is, in the words a person would use, with how long it has run.

    `nil` between phases rather than a guess at which one is next.
    """
    @spec phase(status :: t()) :: String.t() | nil
    defdelegate phase(status), to: Activity

    @doc """
    Seconds as somebody would say them: seconds, then minutes, then hours.

    Public for the reason `segments/1` is — a replacement that wants a
    different layout rarely wants a different clock.
    """
    @spec duration(seconds :: non_neg_integer()) :: String.t()
    defdelegate duration(seconds), to: Activity

    @doc "Bytes as a person reads them, which above a kilobyte is kilobytes."
    @spec bytes(bytes :: non_neg_integer()) :: String.t()
    defdelegate bytes(bytes), to: Activity

    @doc "A fan-out's size, named the way the transcript names it."
    @spec investigations(count :: non_neg_integer()) :: String.t()
    defdelegate investigations(count), to: Activity
  end
end
