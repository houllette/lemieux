# `ex_ratatui` is an optional dependency — `mix.exs` says why a Rust NIF is not
# something to impose on an embedder — so without it this file compiles to
# nothing, and `Lemieux.CLI.TUI.available/0` turns that absence into a sentence.
if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI do
    @moduledoc """
    A full-screen terminal UI for a session.

    Every decision about what a line *means* — prompt, steer, answer, command
    — is `Lemieux.Conversation`'s; what is here
    is a transcript that scrolls, an input box that shows what you typed, a
    live row under the conversation saying what the turn is doing, and a status
    line under that which can afford to be permanently visible.

    Those last two are the point of the whole exercise, and the split between
    them is deliberate. A row that is always on screen costs nothing to keep
    current. What the turn is doing
    costs nothing to keep current either, but it is not permanently true, so it
    goes where the tool calls and the answer it describes already are. See
    `Lemieux.TUI.Activity` and `Lemieux.TUI.Status`.

    ## Why the callback runtime

    `ex_ratatui` offers a LiveView-shaped runtime and an Elm-shaped one. A
    session is a `GenServer` that sends `{:lemieux, id, event}` to its
    subscribers, and the callback runtime's `handle_info/2` receives exactly
    that with nothing in between. The TUI process must be one subscriber; a
    host may watch the same stream through another. Under the reducer runtime
    the same messages arrive as subscriptions, which is a second concept
    describing a mailbox that already worked.

    ## Where each part lives

    This module is the app: the state struct, and `handle_event/2` and
    `handle_info/2` as routing tables whose clause order is the precedence
    between a modal, a pending scroll and an ordinary key. What each route
    does belongs to one module per concern, so a feature has one obvious home:

      * `Lemieux.TUI.Setup` builds the state from options and the harness.
      * `Lemieux.TUI.Lifecycle` starts, hydrates, switches and stops the
        session the screen shows — startup, `/new`, `/resume`, clearing, exit.
      * `Lemieux.TUI.Composer` turns keys into edits, completions and history
        moves in the input box; `Lemieux.TUI.History` owns what was typed
        before and the staged-message queue.
      * `Lemieux.TUI.Submission` sends what was typed: skills, echoes, steers,
        and the queue behind them.
      * `Lemieux.TUI.Events` applies the session's own events: the live row's
        phase, tool calls, approvals, questions, compaction.
      * `Lemieux.TUI.Effects` performs `Lemieux.Conversation` effects, with
        `Lemieux.TUI.Appearance` for `/name`, `/color`, `/theme` and
        `Lemieux.TUI.Choices` for what the menus and the command policy offer.
      * `Lemieux.TUI.Pointer` handles the mouse and the transcript viewport;
        `Lemieux.TUI.Flash` is the one-line feedback in the status row, and
        `Lemieux.TUI.Notices` the box of startup and update notices that
        closes itself.

    ## The callbacks are called directly, terminal or no terminal

    `render/2`, `handle_event/2` and `handle_info/2` are called straight from
    the tests, which assert on the widgets that come back rather than on a
    screen. No TTY is involved and no terminal is started, which is what lets
    this run in CI — `docs/terminal-ui.md` records why that mattered enough to
    shape the design.

    They are not, however, *pure*. Two things reach outside the struct: a
    `Lemieux.Conversation` effect performed against the session — the shared
    ones through `Lemieux.Conversation.Dispatch`, with the screen's callbacks
    and its own effects in `Lemieux.TUI.Effects`; and the input box.

    ## The input box is the library's editor, and it is a reference

    `:input` is a handle on state that lives in Rust. Shift+Enter inserts a
    newline at its caret; every other key this module does not claim is
    forwarded to it, so the editing vocabulary — cursor, word
    motion, selection with shift, kill and yank, undo — is whatever the
    underlying editor supports rather than whatever this file remembered to
    reimplement. Selection in particular is not something worth hand-rolling
    twice.

    What it costs is worth stating plainly, because it is the one place where
    `%{state | ...}` does not mean what it says: two copies of this struct
    share one buffer, and clearing the box mutates the buffer rather than
    replacing the field. `Lemieux.TUI.Submission` says so where it does it.
    The NIF was already a hard requirement of this suite — the real-runtime
    tests start an actual app — so what this gives up is smaller than it
    first looks.

    ## Scrolling back

    `Lemieux.TUI.Window` owns the viewport, and owns it from the bottom: the
    offset is a distance in rows from the newest one, so following the newest
    line is the number `0` and holding still while the model streams is a
    number that grows by exactly as many rows as arrive. It also does the
    wrapping, exactly rather than by estimate, walking back from the newest
    line only as far as the window needs. Transcript rows are kept newest-first.
    A width-and-theme-bound row cache keeps repeated deep scrolls from
    reformatting the same text, and wheel bursts paint once per frame.

    That module is deliberately outside this one, and outside the
    `Code.ensure_loaded?` guard below, so the arithmetic most likely to be
    wrong is tested on a machine with no terminal and no NIF.

    ## Blocks, and what is still not Markdown

    Model answers render inline bold, italic and code spans, and the blocks
    `Lemieux.TUI.Blocks` recognises: fenced code highlighted by language and
    `diff` fences drawn as diffs, pipe tables, block quotes, headings, list
    items and rules. Every one of them has an exact height, which is the
    condition the bottom-pinned viewport and the transcript-anchored
    selection put on anything drawn here — and the reason the answer is not
    handed to `ExRatatui.Widgets.Markdown`, which reflows for itself. The
    line being streamed is classified the moment the next line begins, so a
    block is drawn as a block while the model is still writing it; `Blocks`
    says why nothing can be known about a line before then. Images, nested
    lists and setext headings are still plain text. Mouse capture is
    enabled for link clicks and scrollback; unmodified drags select
    transcript text and copy it through the host's clipboard callback.

    Colours come from a `Lemieux.TUI.Theme`: one colour per *meaning* rather
    than one accent, so a question is still one colour and an edit another
    under every palette. `/theme` switches between the dark default, a light
    palette and a colourless one for the sitting; `"theme"` in the config
    file chooses the one a sitting starts with, and with none a terminal that
    reports a light background starts in the light one. `/color` overrides
    the one accent — the transcript rails, the input cursor, the highlighted
    completion — on top of whichever theme is showing.

    `docs/terminal-ui.md` describes the rendering and native packaging
    contract. The scrollback design was informed by ex_athena; source credit
    is retained in `docs/why-lemieux.md`.
    """

    @behaviour ExRatatui.App

    alias Lemieux.Conversation
    alias Lemieux.Environment
    alias Lemieux.Extensions.Workspace.Skill
    alias Lemieux.Session
    alias Lemieux.TUI.Appearance
    alias Lemieux.TUI.Background
    alias Lemieux.TUI.Choices
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Events
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Lifecycle
    alias Lemieux.TUI.MCPInteraction
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Notices
    alias Lemieux.TUI.Pointer
    alias Lemieux.TUI.QuestionInteraction
    alias Lemieux.TUI.Renderer
    alias Lemieux.TUI.Replies
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Selection
    alias Lemieux.TUI.Setup
    alias Lemieux.TUI.Submission
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Turn
    alias Lemieux.TUI.Types
    alias Lemieux.TUI.Updates

    @doc """
    Starts the TUI over a local terminal or a caller-owned ex_ratatui transport.

    `:transport` defaults to `:local`, and mouse capture defaults to true so
    link clicks and scroll-wheel events reach the TUI. Unmodified drags select
    and copy transcript text. A host that owns an
    `ExRatatui.Session` may pass `{:session, session, writer_fn}` and carry the
    rendered bytes anywhere it chooses. A shared host passes
    `command_policy: fn parsed_action -> :allow | {:deny, message} end`; denied
    commands are omitted from help and completion and checked again when the
    parsed action is dispatched. The action is an effect such as
    `{:mcp_add, path}` or `{:attach, target}`, never terminal text.

    `:theme` names the `Lemieux.TUI.Theme` a sitting starts in — `"dark"`,
    `"light"` or `"mono"`, a name from `:themes`, or a theme struct — and
    `/theme` changes it after. `:themes` is a map of name to theme, as a
    struct or as the map form `Lemieux.TUI.Theme.from_map/1` reads, merged
    over the shipped three: what `/theme NAME` finds and Tab offers. A
    theme that cannot be read raises, because it came from code.

    Two modules replace what the screen says on its own account:
    `:status_line` draws the row under the transcript (`Lemieux.TUI.Status`),
    and `:followups` guesses the next prompt offered in the empty input box
    (`Lemieux.TUI.Followup`). Each defaults to the shipped implementation.
    `:renderers` maps tool names to `Lemieux.TUI.Renderer` modules, merged
    over the built-ins, and is how a host's own tool or an MCP tool gets a
    receipt of its own rather than `Ran NAME`. `:commands` is a list of
    `Lemieux.Conversation.Command` modules, put ahead of the built-in slash
    commands; `Lemieux.Conversation.new/1` says how a host's module shadows
    a built-in.

    `:keys` says which key does what: a module implementing
    `Lemieux.TUI.Keys`, or the map form that module reads —
    `%{"ctrl-j" => "submit", "enter" => "forward"}` — merged over the
    shipped bindings key by key. A map that cannot be read raises, because
    it came from code; the config file's `"keys"` is checked before it gets
    here. `:layout` is a module implementing `Lemieux.TUI.Layout`, which
    says where the three panes go; one that breaks that module's invariants
    is drawn as the shipped arrangement, with the reason on the transcript's
    lower rail.

    `:harness` is a `Lemieux.Harness`, and each of `:theme`, `:themes`,
    `:keys`, `:layout`, `:status_line`, `:followups`, `:processing`,
    `:skills`, `:notices`, `:renderers` and `:commands` is read from it when
    the option itself is absent — so a host that assembled a harness for the session passes it
    once, and the screen cannot disagree with the session it shows about
    which skills exist or whose status line is drawn. An option given
    explicitly still wins, which is what lets a test pin one thing without
    building a harness around it.

    On the local terminal the screen also adapts to the terminal it is on.
    With no theme chosen it asks the terminal whether its background is
    light, before taking it over, and starts in the light palette if so
    (`Lemieux.TUI.Background`); `:background` — `:light`, `:dark` or
    `:unknown` — answers for it and skips the question. It draws RGB colours
    as their nearest 256-colour equivalents unless `COLORTERM` says the
    terminal has 24-bit colour (`Lemieux.TUI.Colour`); `:colours` —
    `:truecolor` or `:ansi256` — overrides that. With `trap_signals: true`
    it also traps SIGTERM for as long as it runs, so a `kill` leaves the
    terminal restored rather than inside the alternate screen
    (`Lemieux.TUI.Signals`); it is off by default, because how the VM stops
    is the host's decision.

    `:prompt` is a first message to send for the person: staged in the
    queue from the first frame, so it can be revised or dropped like
    anything typed ahead, and sent, echoed as if typed, once the session is
    up and the questions a sitting opens with — the `:first_run` provider
    setup and the `:mcp_trust` question — are answered
    (`Lemieux.TUI.History.hold/2`). It is how `lmx --prompt TEXT` opens an
    interactive session with a task.

    All options are also passed to `mount/1`; pass `:size` so paging is correct
    before the first resize event.
    """
    @spec start_link(opts :: keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) when is_list(opts) do
      opts = opts |> Keyword.put_new(:mouse_capture, true) |> Keyword.put(:mod, __MODULE__)

      case Keyword.get(opts, :transport, :local) do
        :local ->
          opts |> with_background() |> ExRatatui.App.dispatch_start()

        transport when transport in [:ssh, :distributed] ->
          ExRatatui.App.dispatch_start(opts)

        _caller_owned ->
          ExRatatui.Transport.start_server(opts)
      end
    end

    # Asked here, before the server below takes the terminal: the answer
    # arrives as input, and once the screen reads input it would be typed
    # into the box. The BEAM's own terminal reader is parked for the length
    # of the question for the same reason. Skipped wherever the answer could
    # not change the palette: a host that said, a theme already chosen,
    # `NO_COLOR`, or the headless test terminal.
    defp with_background(opts) do
      env = Keyword.get_lazy(opts, :env, &System.get_env/0)

      if Keyword.has_key?(opts, :background) or Keyword.has_key?(opts, :test_mode) or
           chosen_theme?(opts) or Map.get(env, "NO_COLOR", "") != "" do
        opts
      else
        Keyword.put(opts, :background, background(env))
      end
    end

    defp chosen_theme?(opts), do: not is_nil(Keyword.get(Setup.with_harness(opts), :theme))

    defp background(env) do
      reader = ExRatatui.LocalInput.detach()

      try do
        detected(env)
      after
        ExRatatui.LocalInput.reattach(reader)
      end
    end

    # In a process of its own, because asking runs `stty` (and `ps`, and on
    # macOS `defaults`) through ports, and each port's exit goes to the
    # process that opened it. `Lemieux.CLI.TUI` traps exits for the length of
    # this call, so every one of them was left in its mailbox for the rest of
    # the sitting.
    defp detected(env) do
      caller = self()
      {asker, ref} = spawn_monitor(fn -> send(caller, {self(), Background.detect(env: env)}) end)

      receive do
        {^asker, background} ->
          Process.demonitor(ref, [:flush])
          background

        {:DOWN, ^ref, :process, ^asker, _reason} ->
          :unknown
      end
    end

    @doc false
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :transient
      }
    end

    # Each state group's shape and its reasoning live in `Lemieux.TUI.Types`;
    # these keep the public names (`t:Lemieux.TUI.line/0` and the rest).
    @typedoc "See `t:Lemieux.TUI.Types.line/0`."
    @type line :: Types.line()

    @typedoc "See `t:Lemieux.TUI.Types.processing_usage/0`."
    @type processing_usage :: Types.processing_usage()

    @typedoc "See `t:Lemieux.TUI.Types.history/0`."
    @type history :: Types.history()

    @typedoc "See `t:Lemieux.TUI.Types.turn/0`."
    @type turn :: Types.turn()

    @typedoc "See `t:Lemieux.TUI.Types.phase/0`."
    @type phase :: Types.phase()

    @typedoc "See `t:Lemieux.TUI.Types.catalog/0`."
    @type catalog :: Types.catalog()

    @typedoc "See `t:Lemieux.TUI.Types.appearance/0`."
    @type appearance :: Types.appearance()

    @typedoc "See `t:Lemieux.TUI.Types.resume/0`."
    @type resume :: Types.resume()

    @typedoc "See `t:Lemieux.TUI.Types.session_view/0`."
    @type session_view :: Types.session_view()

    @typedoc "See `t:Lemieux.TUI.Types.modal/0`."
    @type modal :: Types.modal()

    @typedoc "See `t:Lemieux.TUI.Types.in_flight/0`."
    @type in_flight :: Types.in_flight()

    @type t :: %__MODULE__{
            session: pid() | nil,
            id: String.t() | nil,
            conversation: Conversation.t(),
            lines: [line()],
            input: reference(),
            # The optional keys are what `Lemieux.TUI.Lifecycle.mount/1` learns
            # about a terminal; a state built by `new/1` alone has none of them.
            terminal: %{
              optional(:background) => Lemieux.TUI.Background.t(),
              optional(:colours) => Lemieux.TUI.Colour.depth(),
              optional(:signal_traps) => Lemieux.TUI.Signals.traps(),
              width: pos_integer(),
              height: non_neg_integer(),
              cursor_blink: %{visible?: boolean(), tick: reference() | nil},
              link_press: {String.t(), {non_neg_integer(), non_neg_integer()}} | nil,
              feedback: %{text: String.t(), token: reference()} | nil,
              notices: Lemieux.TUI.Notices.t(),
              row_cache: %{width: pos_integer(), theme: Theme.t(), rows: map()} | nil,
              scroll_coalesce?: boolean(),
              scroll_pending: %{token: reference()} | nil,
              clipboard: (String.t() -> :ok | {:error, term()}),
              open_link: (String.t() -> :ok | {:error, term()}),
              title: (String.t() -> :ok | {:error, term()}),
              notify: (String.t() -> :ok | {:error, term()}),
              notifications?: boolean(),
              editor: (String.t() -> {:ok, String.t()} | {:error, term()}) | nil,
              paste_image: (-> {:ok, binary()} | {:error, term()}) | nil,
              repaint: non_neg_integer()
            },
            catalog: catalog(),
            appearance: appearance(),
            skills: [Skill.t()],
            tool_choices: %{
              standard: [Lemieux.Tool.t()],
              statuses: [Session.tool_status()],
              command_policy: Conversation.command_policy(),
              elixir: :allow | {:deny, Lemieux.Tool.Profile.denial()},
              delegation: Lemieux.Tool.t() | nil,
              permissions: term() | nil,
              checkpoints: Path.t() | nil
            },
            resume: resume(),
            feedback_opts: keyword(),
            elixir_mode?: boolean(),
            turn: turn(),
            overlay: %{frame: non_neg_integer(), tick: reference()} | nil,
            clock: (-> integer()),
            tools: in_flight(),
            references: %{
              cwd: Path.t() | nil,
              mcp_config: Path.t() | nil,
              environment: Environment.t() | nil,
              directory: String.t() | nil,
              entries: [Environment.directory_entry()],
              refreshed_at: integer() | nil,
              index: %{files: [String.t()], at: integer()} | :loading | nil,
              fuzzy: %{query: String.t(), matches: [String.t()]} | nil,
              config_path: Path.t() | nil
            },
            status: %{
              line: module() | nil,
              compact_at: number() | nil,
              words: [String.t()] | nil,
              followups: module() | nil,
              renderers: Renderer.registry() | nil,
              keys: module() | Keys.t() | nil,
              layout: module() | nil,
              update: Updates.t()
            },
            command_index: non_neg_integer(),
            model_tab: String.t(),
            command_tab: String.t(),
            command_menu?: boolean(),
            history: history(),
            exit_armed: {reference(), integer()} | nil,
            scroll: non_neg_integer(),
            selection: Selection.t() | nil,
            session_view: session_view(),
            modal: modal()
          }

    # `conversation: nil`, filled in by `new/1`, for the reason
    # `Lemieux.Conversation` gives about its own `:context` field: a struct
    # literal in a module body is a compile-time dependency, and this build
    # fails on those.
    #
    # The groups below (`terminal`, `catalog`, `tools`, `history` and the rest)
    # are state that is written together, and new state belongs in the group
    # whose lifecycle it shares rather than in a field of its own. Credo's
    # `StructFieldAmount` caps this struct at 31 fields — the size past which
    # the BEAM stops representing a map compactly — so a field is not free.
    defstruct session: nil,
              id: nil,
              conversation: nil,
              lines: [],
              # A handle on the editor widget's own state, which lives in Rust.
              # `new/1` fills it in — see the @moduledoc on what that costs and
              # buys.
              input: nil,
              # What the completion menus offer. See `t:catalog/0`.
              catalog: %{
                providers: [],
                models: [],
                model_choices: [],
                model_tabs: [],
                model_tab_rows: 0,
                model_metadata: %{},
                preferred_models: %{},
                preferred_efforts: %{},
                recent_models: [],
                model_now: nil,
                discovered: [],
                efforts: [],
                mcp: []
              },
              # What `/name`, `/color` and `/theme` override, and what `/theme`
              # picks from. See `t:appearance/0`. The theme and the registry
              # are `nil` rather than their defaults because a function call in
              # a struct default is a compile-time call this build fails on;
              # `Lemieux.TUI.Screen` supplies them.
              appearance: %{name: nil, colour: nil, theme: nil, themes: nil},
              skills: [],
              tool_choices: %{
                standard: [],
                statuses: [],
                command_policy: nil,
                elixir: :allow,
                delegation: nil,
                # The host's `Lemieux.Extensions.Permissions` handle and
                # checkpoint directory, or nil when the feature is off.
                permissions: nil,
                checkpoints: nil
              },
              # `/resume`'s list, the session-start callbacks, and whether one is in
              # flight. See `t:resume/0`.
              resume: %{
                sessions: [],
                list: nil,
                start: nil,
                new: nil,
                busy?: false,
                initial_task: nil,
                startup_status: :idle,
                start_async: nil,
                task_supervisor: nil,
                monitor: nil,
                down: nil
              },
              # Where `/feedback` and `/reflect opportunities` write. Carried
              # rather than derived at the call site so a host that moved its
              # sessions directory moves the ledger with it, exactly as
              # `lmx feedback` does.
              feedback_opts: [],
              elixir_mode?: false,
              # `new/1` fills this in, for the same reason `conversation` is
              # nil here: the empty value is a function call, and a call in a
              # struct default is a compile-time call this build fails on.
              turn: nil,
              # The Go Habs Go animation for startup and `/habs`: `nil` when
              # the screen is the screen, otherwise the frame drawn over it.
              overlay: nil,
              clock: nil,
              # Announced calls, the output streaming into them, and the
              # approval cards waiting on a decision, keyed by call id. See
              # `t:in_flight/0`.
              tools: %{
                calls: %{},
                outputs: %{},
                approvals: %{},
                permissions: %{},
                question_flow: nil,
                mcp_flow: nil,
                deferred_steer: nil,
                sent_steers: [],
                jev: nil
              },
              # The `@` picker's state in one field, because its parts are read
              # and written together. `cwd` comes from the session's own
              # snapshot, so the path Tab leaves on the line is the one the
              # session will read back; `environment` defaults in
              # `Lemieux.TUI.Composer`, because a struct default cannot call a
              # function; `directory` and `entries` cache one listing, because
              # `render/2` runs at frame rate and must not touch a filesystem.
              references: %{
                cwd: nil,
                mcp_config: nil,
                environment: nil,
                directory: nil,
                entries: [],
                refreshed_at: nil,
                # Every file under the working directory, listed once in a
                # task for the fuzzy `@` picker; see `Lemieux.TUI.FileIndex`.
                index: nil,
                fuzzy: nil,
                config_path: nil
              },
              # The things a host can replace in what the screen does on its
              # own account — the status row, what a running turn is called,
              # the follow-up hint, how each tool's receipt is drawn, which key
              # does what, and where the panes go — in one field because each
              # is `nil` when nothing replaced the shipped answer. See
              # `Lemieux.TUI.Status`, `Lemieux.TUI.Processing`,
              # `Lemieux.TUI.Followup`, `Lemieux.TUI.Renderer`,
              # `Lemieux.TUI.Keys` and `Lemieux.TUI.Layout`.
              status: %{
                line: nil,
                compact_at: nil,
                words: nil,
                followups: nil,
                renderers: nil,
                keys: nil,
                layout: nil,
                update: %{
                  host: nil,
                  phase: :idle,
                  task: nil,
                  pending: nil,
                  requested?: false,
                  timer: nil,
                  announced: nil
                }
              },
              command_index: 0,
              model_tab: "Automatic",
              command_tab: "Commands",
              command_menu?: true,
              # Input history, where you are in it, and the staged queue. One
              # field: `draft` exists only while `index` does, and the queue is
              # edited by the same keys. See `Lemieux.TUI.History`.
              history: %{
                entries: [],
                index: nil,
                draft: nil,
                queued: [],
                queued_selected: 1,
                revising: nil,
                revising_original: nil,
                file: nil,
                global: []
              },
              exit_armed: nil,
              # Rows from the newest, so `0` is following the transcript. See
              # `Lemieux.TUI.Window`.
              scroll: 0,
              # An in-progress or finished drag over the transcript, as
              # depth-and-column rather than a screen position, or nil. See
              # `Lemieux.TUI.Selection` for why, and for what still drops one.
              selection: nil,
              # What the session has reported about itself. See
              # `t:session_view/0`.
              session_view: %{
                mcp: %{},
                mcp_ready?: true,
                mcp_announced?: false,
                plan: nil,
                requests: 0,
                request_cap: nil,
                sandbox: nil,
                mcp_trust: nil,
                first_run: nil,
                banner?: false,
                outputs: [],
                noticed: []
              },
              # The panel holding the keyboard, if any. See `t:modal/0`.
              modal: nil,
              # What `render/2` last laid out. Paging needs the page height and
              # the wrap width before the next frame, so they are remembered
              # rather than guessed — a key pressed before the first paint moves
              # by the fallback rather than crashing.
              terminal: nil

    @doc """
    Builds the initial state.

    Public because `mount/1` is not the only caller: the tests build a state
    directly rather than standing up a terminal to get one.
    """
    @spec new(opts :: keyword()) :: t()
    def new(opts \\ []), do: Setup.new(opts)

    @impl ExRatatui.App
    def mount(opts), do: Lifecycle.mount(opts)

    # Three panes: transcript, status, input. Where each goes is
    # `Lemieux.TUI.Layout`'s answer, computed once here and threaded to every
    # widget drawn this frame; between frames the same computation runs from
    # the size the last resize reported. `Lemieux.TUI.Status` clamps the
    # status band's height to the frame before the layout is asked for it.
    @impl ExRatatui.App
    def render(state, frame),
      do: Screen.render(state, frame, fn panes -> Composer.autocomplete(state, panes) end)

    @doc """
    The accent colours `/color` offers, as `/color` spells them.

    Public because the completion menu is the only place they are listed, and
    a menu that could not be asserted on is a list that silently stops
    matching what the command accepts.
    """
    @spec accents() :: [String.t()]
    def accents, do: Appearance.accents()

    # Which module handles an input event. The order is the precedence: an
    # update being applied swallows everything but a resize, a pending wheel
    # burst is painted before anything else moves, and a modal — startup, a
    # question, the MCP manager — claims keys before the input box sees them.
    @impl ExRatatui.App
    def handle_event(event, state)

    def handle_event(event, %{status: %{update: %{phase: :apply}}} = state)
        when not is_struct(event, ExRatatui.Event.Resize),
        do: {:noreply, state}

    def handle_event(event, %{terminal: %{scroll_pending: %{}}} = state)
        when not is_struct(event, ExRatatui.Event.Mouse),
        do: handle_event(event, Pointer.flush_scroll(state))

    def handle_event(
          %ExRatatui.Event.Mouse{kind: kind} = event,
          %{terminal: %{scroll_pending: %{}}} = state
        )
        when kind not in ["scroll_up", "scroll_down"],
        do: handle_event(event, Pointer.flush_scroll(state))

    # Enhanced keyboard protocols also report releases. A released Shift+Enter
    # may arrive without Shift; treating it as another press submits the draft
    # immediately after inserting its newline.
    def handle_event(%ExRatatui.Event.Key{kind: "release"}, state), do: {:noreply, state}

    # The Go Habs Go banner covers everything, the provider panel and the
    # notice box included, and once the session is ready it is only playing
    # out (`Lemieux.TUI.Lifecycle.start_habs/1`). A key ends it first, so the
    # key is answered on a screen the person can see rather than under one
    # they cannot. While loading, keys edit the draft behind it as before.
    def handle_event(
          %ExRatatui.Event.Key{} = event,
          %__MODULE__{overlay: %{}, resume: %{startup_status: status}} = state
        )
        when status != :loading,
        do: handle_event(event, %{state | overlay: nil})

    def handle_event(%ExRatatui.Event.Key{} = event, %__MODULE__{modal: %{}} = state),
      do: Modal.key(event, state)

    def handle_event(
          %ExRatatui.Event.Key{} = event,
          %__MODULE__{resume: %{startup_status: status}} = state
        )
        when status in [:loading, :failed],
        do: Lifecycle.starting_key(event, state)

    def handle_event(%ExRatatui.Event.Key{} = event, %{tools: %{question_flow: flow}} = state)
        when not is_nil(flow),
        do: QuestionInteraction.key(event, state, %{edit: &Composer.edit/2, run: &Effects.run/2})

    def handle_event(%ExRatatui.Event.Key{} = event, %{tools: %{mcp_flow: flow}} = state)
        when not is_nil(flow) do
      MCPInteraction.key(event, state, %{
        edit: &Composer.edit/2,
        interrupt: &Composer.interrupt/1,
        continue: &Submission.continue_queued/1,
        policy: Choices.command_policy(state)
      })
    end

    # Cmd-Z takes back a pending steer where the terminal reports the Command
    # key, which only the kitty keyboard protocol does: Terminal.app, iTerm2
    # and VS Code keep Cmd-Z for their own Undo. The key map cannot name the
    # Command key, so it is caught here; Alt-Z, its stand-in for everyone
    # whose Option key sends Alt, is the key map's (`:revoke_steer`), so it
    # can be rebound like any other. `/unsteer` works everywhere.
    def handle_event(%ExRatatui.Event.Key{code: "z", modifiers: modifiers} = event, state) do
      if "super" in modifiers or "meta" in modifiers,
        do: Submission.revoke_steer(event, state),
        else: Composer.key(event, state)
    end

    def handle_event(%ExRatatui.Event.Key{code: "back_tab"} = event, state),
      do: Composer.cycle_tab_or_edit(event, state)

    def handle_event(%ExRatatui.Event.Key{code: "tab", modifiers: modifiers} = event, state)
        when is_list(modifiers) do
      if "shift" in modifiers,
        do: Composer.cycle_tab_or_edit(event, state),
        else: Composer.key(event, state)
    end

    # Every key is one question to the key map — which action, or `:forward`
    # — and one clause of `Lemieux.TUI.Composer`'s. What a key *means* lives
    # in `Lemieux.TUI.Keys`, so that rebinding is data and this function never
    # has to know which key it was.
    def handle_event(%ExRatatui.Event.Key{code: code} = event, state) when is_binary(code),
      do: Composer.key(event, state)

    def handle_event(%ExRatatui.Event.Mouse{} = event, state), do: Pointer.mouse(event, state)

    # Pasted text goes in whole. Re-dispatched as keystrokes it would be
    # indistinguishable from typing, and a pasted newline would send the
    # message half-written.
    def handle_event(%ExRatatui.Event.Paste{} = event, %__MODULE__{modal: %{}} = state),
      do: Modal.paste(event, state)

    def handle_event(%ExRatatui.Event.Paste{} = event, state), do: Composer.paste(event, state)

    # `render/2` is handed the frame and cannot write anything down, so the
    # size is learned here. Paging happens between frames and has to know how
    # tall a page is and how wide a row wraps.
    def handle_event(%ExRatatui.Event.Resize{width: width, height: height}, state),
      do:
        {:noreply,
         put_in(
           state.terminal,
           %{state.terminal | width: max(width, 1), height: max(height, 1)}
         )}

    def handle_event(_event, state), do: {:noreply, state}

    # See `Lemieux.TUI.Replies`, which routes each to its module.
    @replies [
      :file_index,
      :image_pasted,
      :mcp_resources,
      :mcp_settled,
      :mcp_trust_check,
      :mcp_trust_result,
      :first_run_saved,
      :session_catalog,
      :write_preimage
    ]

    # Every answer shape `Lemieux.Conversation.Dispatch.run/2` work sends back
    # as a two-tuple. `{:mcp_result, _, _, _}` is the one four-tuple.
    @answers [
      :reflection_result,
      :compaction_result,
      :retry_result,
      :feedback_anchors,
      :feedback_result,
      :opportunities_result,
      :refresh_result,
      :clear_result,
      :diff_result,
      :export_result,
      :doctor_result,
      :undo_result,
      :rewind_result,
      :mcp_prompts_result,
      :mcp_listing,
      :said
    ]

    # Which module handles a message. As with events, the order is the
    # precedence: a pending wheel burst is painted before any message is
    # handled, and the startup task's reply is recognised by its reference
    # before a later clause could mistake it for another task's.
    @impl ExRatatui.App
    def handle_info(message, state)

    def handle_info({:scroll_flush, token}, state), do: Pointer.scroll_flush(state, token)

    def handle_info(message, %{terminal: %{scroll_pending: %{}}} = state),
      do: handle_info(message, Pointer.flush_scroll(state))

    def handle_info(
          {ref, {:ok, details, ready_opts}},
          %__MODULE__{resume: %{initial_task: %Task{ref: ref}}} = state
        ),
        do: Lifecycle.started(state, ref, details, ready_opts)

    def handle_info(
          {ref, {:error, reason}},
          %__MODULE__{resume: %{initial_task: %Task{ref: ref}}} = state
        ),
        do: Lifecycle.start_failed(state, ref, reason)

    def handle_info(
          {:DOWN, ref, :process, _pid, reason},
          %__MODULE__{resume: %{initial_task: %Task{ref: ref}}} = state
        ),
        do: {:noreply, Lifecycle.startup_failed(state, reason)}

    def handle_info(
          {:DOWN, ref, :process, _pid, reason},
          %__MODULE__{resume: %{monitor: ref}} = state
        ),
        do: {:noreply, Lifecycle.session_down(state, reason)}

    # Replies from the tasks the screen sends off so it never waits.
    def handle_info(message, state)
        when is_tuple(message) and elem(message, 0) in @replies,
        do: {:noreply, Replies.handle(message, state)}

    def handle_info(:repaint_done, state), do: {:noreply, put_in(state.terminal.repaint, 0)}

    # The last opening question was answered with something staged, or a
    # session started before the screen left a `:prompt` to send; see
    # `Lemieux.TUI.History.answered/2`.
    def handle_info(:continue_queued, state), do: Submission.continue_queued(state)

    # SIGTERM, through the trap a host asked `mount/1` to set: leave as
    # Ctrl-C twice does, so the terminal is restored. See
    # `Lemieux.TUI.Signals`.
    def handle_info({:terminal_signal, signal}, state), do: Lifecycle.signalled(state, signal)

    # The CLI checks Hex after the screen opens; only its result reaches the UI.
    def handle_info({:version_notice, notice}, state) when is_binary(notice),
      do: {:noreply, Notices.say(state, :info, notice)}

    def handle_info(:check_update, state), do: {:noreply, Updates.check(state)}
    def handle_info({:update_check, token}, state), do: {:noreply, Updates.poll(state, token)}
    def handle_info(:update_idle, state), do: {:noreply, Updates.tick(state)}

    def handle_info({ref, result}, %{status: %{update: %{task: %Task{ref: ref}}}} = state) do
      Process.demonitor(ref, [:flush])
      {:noreply, Updates.result(state, result)}
    end

    def handle_info(
          {:DOWN, ref, :process, _pid, reason},
          %{status: %{update: %{task: %Task{ref: ref}}}} = state
        ),
        do: {:noreply, Updates.result(state, {:error, reason})}

    def handle_info({:open_link_result, result}, state),
      do: Pointer.open_link_result(state, result)

    def handle_info({:feedback_expired, token}, state), do: Flash.expire(state, token)
    def handle_info({:notices_expired, token}, state), do: Notices.expire(state, token)
    def handle_info({:compact_tick, tick}, state), do: Events.compact_tick(state, tick)

    def handle_info({:lemieux, id, event}, %__MODULE__{id: id} = state),
      do: Events.handle(state, event)

    # The answers to work `Lemieux.Conversation.Dispatch` sent off to a task so
    # it would not block the loop that draws: a compaction, a reflection, a
    # feedback write. What each answer means — that an accepted retry is a
    # turn starting, that an MCP change is followed by a fresh listing — is
    # that module's to say, whichever host receives the answer.
    def handle_info({:compaction_result, {:error, _reason}} = message, state) do
      state
      |> Events.remove_compact_row()
      |> Effects.answer(message)
      |> Submission.continue_queued()
    end

    def handle_info({:compaction_result, _result} = message, state),
      do: state |> Effects.answer(message) |> Submission.continue_queued()

    def handle_info({tag, _result} = message, state) when tag in @answers,
      do: {:noreply, Effects.answer(state, message)}

    # The answers that carry what was asked beside the result: a `!cmd` and
    # the command line it ran, an MCP prompt and the server it came from, and
    # the models `/provider NAME` found for the provider it named.
    def handle_info({tag, _first, _second} = message, state)
        when tag in [:shell_result, :mcp_prompt_result, :provider_discovered],
        do: {:noreply, Effects.answer(state, message)}

    def handle_info({:mcp_result, _action, _result, _statuses} = message, state),
      do: {:noreply, Effects.answer(state, message)}

    def handle_info({:mcp_ui_result, action, result, statuses}, state),
      do: MCPInteraction.ui_result(state, action, result, statuses)

    # The automatic refresh speaks only when it re-attached something: nobody asked
    # for it, so "every attached file is current" is a line about nothing, and a
    # failure is not news either. The typed `/refresh` still reports all three
    # outcomes, through the answer clause above.
    def handle_info({:refresh_result, :automatic, {:ok, count}}, state) when count > 0,
      do: {:noreply, Effects.fold(state, {:refresh_result, {:ok, count}})}

    def handle_info({:refresh_result, :automatic, _result}, state), do: {:noreply, state}

    def handle_info({:models_discovered, models}, state) when is_list(models),
      do: {:noreply, Choices.discovered(state, models)}

    def handle_info({:resume_result, _reference, {:ok, details, sessions}}, state),
      do: {:noreply, Lifecycle.switched(state, details, sessions, "resumed")}

    def handle_info({:new_result, {:ok, details, sessions}}, state),
      do: {:noreply, Lifecycle.switched(state, details, sessions, nil)}

    def handle_info({:resume_result, _id, {:error, reason}}, state),
      do: {:noreply, Lifecycle.resume_failed(state, reason)}

    def handle_info({:new_result, {:error, reason}}, state),
      do: {:noreply, Lifecycle.new_failed(state, reason)}

    def handle_info({:ctrl_c_expired, token}, state), do: Composer.exit_expired(state, token)
    def handle_info({:cursor_blink, tick}, state), do: Composer.blink(state, tick)
    def handle_info({:habs_tick, token}, state), do: Lifecycle.habs_tick(state, token)
    def handle_info({:activity_tick, token}, state), do: Turn.tick(state, token)

    def handle_info(_message, state), do: {:noreply, state}

    @impl ExRatatui.App
    def terminate(reason, state), do: Lifecycle.terminate(reason, state)
  end
end
