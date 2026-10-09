# The shapes of `Lemieux.TUI`'s state groups, apart from its callbacks.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Types do
    @moduledoc """
    The shapes of `Lemieux.TUI`'s state groups, each with the reasoning
    behind it.

    Kept apart from the screen's callbacks so `Lemieux.TUI` stays a routing
    table a person can read end to end. `Lemieux.TUI` re-exports every type
    here under its own name — `t:Lemieux.TUI.line/0`, `t:Lemieux.TUI.turn/0` and
    the rest — and those are the names hosts and specs use.
    """

    alias Lemieux.CLI.SessionIndex
    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.CatalogState
    alias Lemieux.TUI.Followup
    alias Lemieux.TUI.ModelChoices
    alias Lemieux.TUI.QuestionFlow
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.ToolText

    @typedoc """
    A line of the transcript, and who it came from.

    Stored newest-first. The model's answer is the conversation; everything
    else is `lmx` talking about it, and `:you` is what was typed.
    """
    @type line ::
            {:lmx | :you | :space | :summary | :notice | :interrupted | :verify | :hook,
             String.t()}
            | {:steer, :pending | :sent | :not_sent, String.t()}
            | {:compacting, reference(), String.t()}
            | {:compact_space, reference()}
            | {:compact_result, String.t()}
            | Blocks.row()
            | {:subagent_child, RichText.child()}
            | {:context_bar, [{RichText.context_key(), float()}]}
            | {:context_key, [{RichText.context_key(), String.t()}]}
            | ToolText.row()
            | {:notice_box, reference(), [Lemieux.TUI.Notices.item()]}

    @type processing_usage :: %{
            input: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_write: non_neg_integer(),
            output: non_neg_integer(),
            tokens: non_neg_integer(),
            requests: non_neg_integer(),
            tool_calls: non_neg_integer(),
            cost_usd: number() | nil,
            measured?: boolean()
          }

    @typedoc """
    What was typed before, and where in it the arrow keys currently are.

      * `:entries` — previous inputs, newest first.
      * `:index` — how far back the input box is showing, or `nil` when it is
        showing what the person is actually typing.
      * `:draft` — what they were typing before they started looking back, so
        coming forward again returns it rather than an empty box.
      * `:queued` — up to nine messages staged in send order. They remain
        editable and are never persisted. The selected number is the target
        of Alt+E and Alt+U; Alt+1 through Alt+9 change that selection.
      * `:held_for` — the opening questions the queue waits for before
        anything in it is sent; see `Lemieux.TUI.History.hold/2`.
    """
    @type history :: %{
            required(:entries) => [String.t()],
            required(:index) => non_neg_integer() | nil,
            required(:draft) => String.t() | nil,
            required(:queued) => [String.t()],
            required(:queued_selected) => pos_integer(),
            required(:revising) => pos_integer() | nil,
            required(:revising_original) => String.t() | nil,
            optional(:file) => Path.t() | nil,
            optional(:global) => [String.t()],
            optional(:held_for) => [:trust | :first_run]
          }

    @typedoc """
    Everything about the turn in flight, or the one that just ended.

    One field rather than five because they share a lifecycle exactly:
    `start_processing/1` resets all of them together and `stop_processing/1`
    winds them down together. They were separate until the struct reached
    Credo's field cap, and separating state that is only ever written as a
    unit was what had put it there.

      * `:started_at` — when the turn began, and the flag for whether one is
        running at all.
      * `:tick` and `:frame` — the spinner's timer token and its phase.
      * `:label` — what the live row calls this turn while it runs, drawn once
        when it starts. `nil` before the first one. See
        `Lemieux.TUI.Processing` for why it is one word per turn and not one
        word per request.
      * `:usage` — what the summary line prints when the turn ends.
      * `:signals` — what the turn did, for `Lemieux.TUI.Followup`. Outlives
        the turn deliberately: the hint is offered *after* the answer lands.
      * `:phase` — what the session is doing right now, and since when, for
        the live row. A session on 2026-09-18 spent two and a half minutes
        composing one 35 KB `write` with nothing on screen but `Processing`,
        and before that its parent read three investigation results in a
        silence that looked the same. A person cannot tell working from hung
        without being told which it is.
      * `:delegation` — the last fan-out's size, kept from its close until
        the model's first delta, so the wait that follows can say what it
        is a wait for.
    """
    @type turn :: %{
            started_at: integer() | nil,
            tick: reference() | nil,
            frame: non_neg_integer(),
            label: String.t() | nil,
            usage: processing_usage(),
            signals: Followup.signals(),
            phase: phase() | nil,
            delegation: %{count: non_neg_integer(), bytes: non_neg_integer()} | nil,
            compacting: %{since: integer(), tick: reference()} | nil
          }

    @typedoc "One thing the session is doing: its kind, what it is about, and since when."
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
            since: integer()
          }

    @typedoc """
    What `/provider`, `/model` and `/effort` complete against.

    One field rather than four because they are one answer to one question —
    what can be picked — and every path that changes any of them changes the
    others in the same breath: starting a session, resuming one, switching
    provider, and a host's model discovery arriving late.

      * `:providers`, `:models`, `:efforts`, `:mcp` — what the menus offer now,
        the session's own lists merged with whatever was discovered. `:mcp` is
        the configured server names, which is what `/mcp remove` and
        `/mcp reconnect` take.
      * `:model_choices` — model metadata prepared when the catalog changes,
        so rendering the menu only filters already ranked choices.
      * `:model_tabs` — route tabs prepared with those choices, so rendering
        never sorts the gateway catalog.
      * `:model_tab_rows` — one menu height across those tabs, measured before
        rendering so a route switch does not resize the picker.
      * `:model_metadata` — optional presentation facts from the session's
        provider. It never determines availability or request routing.
      * `:preferred_models`, `:recent_models` — explicit host choices and model
        specs from recent sessions or this session's selections.
      * `:preferred_efforts` — effort defaults to apply when switching providers.
      * `:discovered` — what the host found (an Ollama list, say), kept apart
        because the merge has to be redone from it every time the session's
        own lists change, and a merged list cannot be un-merged. Its order is
        the host's and it matters: when the session has no model of its own
        for a provider, `/provider NAME` takes the first of NAME's models here
        unless the person's preferred one is among them
        (`Lemieux.TUI.CatalogState.discover/3`).
      * `:discover` — the host's way to look again, by provider: what
        `/provider NAME` asks when nothing above has a model for `NAME`
        (`Lemieux.Conversation.Command.Provider`). `lmx` gives `ollama`.
    """
    @type catalog :: %{
            providers: [String.t()],
            models: [String.t()],
            model_choices: [ModelChoices.choice()],
            model_tabs: [String.t()],
            model_tab_rows: non_neg_integer(),
            model_metadata: %{optional(String.t()) => map()},
            preferred_models: %{optional(String.t()) => String.t()},
            preferred_efforts: %{optional(String.t()) => String.t()},
            recent_models: [String.t()],
            model_now: DateTime.t() | nil,
            discovered: [String.t()],
            discover: %{optional(String.t()) => (-> [CatalogState.discovery()])},
            efforts: [String.t()],
            mcp: [String.t()]
          }

    @typedoc """
    What this sitting calls the session, and what colour it draws.

    One field rather than two because they are one feature — the two things
    `/name` and `/color` override about a session's presentation — and both
    are `nil` for the same reason: nothing has been overridden, so the derived
    answer stands.

      * `:name` — what the header and the terminal title say instead of
        `Lemieux.ID.Shorthand.of/1`. A caption, never a handle: it is not
        stored, `--resume` has never heard of it, and resuming another session
        drops it. See that module on why a name is derived rather than kept.
      * `:colour` — an `ExRatatui.Style` colour for the accents this module
        draws, or `nil` for the profile's own. Held here rather than in
        `Lemieux.Conversation`, which is explicit about holding nothing about
        how a front end draws.
      * `:theme` — the `Lemieux.TUI.Theme` every other colour comes from, or
        `nil` for the default one. `/theme` sets it for the sitting; the
        config file's `"theme"` sets what a sitting starts with. Not stored
        with the session, for the same reason the name and the colour are
        not: it is about this screen, not about the conversation.
      * `:themes` — what `/theme` can pick from: the host's `:themes` merged
        over the shipped three, or `nil` for the shipped three alone. A value
        here rather than anything global, so two screens in one VM can be
        given different palettes under the same name.
      * `:no_color` — what `NO_COLOR` did to this screen: `:mono` when it
        chose the theme, `:named` when a theme chosen by name won but the
        terminal layer still draws no colour while the variable is set, `nil`
        when it is unset. The startup notice and `/theme` say so, because an
        inherited `NO_COLOR` looks exactly like a terminal without colour.
    """
    @type appearance :: %{
            name: String.t() | nil,
            colour: ExRatatui.Style.color() | nil,
            theme: Theme.t() | nil,
            themes: Theme.registry() | nil,
            no_color: :mono | :named | nil
          }

    @typedoc """
    Session switching: what `/resume` can offer and how `/new` starts afresh.

    The host hands in `:list`, `:start` and `:new` at mount. The list and the
    flag live beside those callbacks so switching cannot race itself.

      * `:sessions` — what `/resume` completes against.
      * `:list` — refreshes that, after resuming changes which is current.
      * `:start` — starts the resumed session. `nil` in a host without one.
      * `:new` — starts a fresh session. `nil` in a host without one.
      * `:busy?` — a switch is in flight, so another is refused rather than raced.
    """
    @type resume :: %{
            sessions: [SessionIndex.t()],
            list: (-> {:ok, [SessionIndex.t()]} | {:error, term()}) | nil,
            start: (String.t(), pid() -> {:ok, pid()} | {:error, term()}) | nil,
            new: (pid() -> {:ok, pid()} | {:error, term()}) | nil,
            busy?: boolean(),
            initial_task: Task.t() | nil,
            startup_status: :idle | :loading | :failed | :ready,
            start_async: (pid() -> term()) | (pid(), keyword() -> term()) | nil,
            task_supervisor: atom() | pid() | nil,
            monitor: reference() | nil,
            down: term() | nil
          }

    @typedoc """
    What the session has reported about itself, kept so nothing is asked of
    it per frame: MCP server statuses (`Lemieux.TUI.MCPStatus`), the plan
    (`Lemieux.TUI.PlanPanel`), requests against the cap, the sandbox, the
    host's trust and first-run offers (`Lemieux.TUI.Trust`,
    `Lemieux.TUI.FirstRun`), recent full tool outputs (`Lemieux.TUI.Pager`),
    and whether the host earned the permissions banner
    (`Lemieux.TUI.Policy`). One field, because `/new` and `/resume` replace
    all of it together.
    """
    @type session_view :: %{
            mcp: %{optional(String.t()) => map()},
            mcp_ready?: boolean(),
            mcp_announced?: boolean(),
            plan: [map()] | nil,
            plan_progress: {:model_art, term(), String.t()} | nil,
            requests: non_neg_integer(),
            request_cap: pos_integer() | nil,
            sandbox: map() | nil,
            mcp_trust: map() | nil,
            first_run: map() | nil,
            banner?: boolean(),
            outputs: [%{id: String.t(), name: String.t(), text: String.t()}],
            noticed: [term()]
          }

    @typedoc "The one panel holding the keyboard, if any. See `Lemieux.TUI.Modal`."
    @type modal :: %{required(:kind) => atom(), optional(atom()) => term()} | nil

    @typedoc """
    The tool calls this turn has announced, and the output streaming into them.

    One field rather than two: both are keyed by call id, both are written
    only between a call being announced and its result arriving, and every
    path that empties one empties the other — a result landing, a host clear event,
    `/resume` or `/new`. They were separate until the struct reached the size where the
    BEAM stops representing a map compactly, which credo fails the build over,
    and splitting state that is only ever written as a unit was what had put
    it there. `approvals` is the card drawn for each parked call, by call
    id: the exact rows, so the decision can take exactly them down again
    and leave the call's own announcement where it was. `sent_steers` is
    the text the session was handed for each steer still drawn as waiting,
    beside the text its row shows, which is what `/unsteer` revokes with
    (`Lemieux.TUI.Submission`).
    """
    @type in_flight :: %{
            calls: %{optional(String.t()) => map()},
            outputs: %{optional(String.t()) => String.t()},
            approvals: %{optional(String.t()) => [ToolText.row()]},
            permissions: %{optional(String.t()) => map() | nil},
            question_flow: QuestionFlow.t() | nil,
            mcp_flow: map() | nil,
            deferred_steer: {:pending | :sent | :not_sent, String.t()} | nil,
            sent_steers: [{shown :: String.t(), sent :: String.t()}],
            systemone:
              %{mode: String.t(), saved: non_neg_integer() | nil, outcome: String.t() | nil} | nil
          }
  end
end
