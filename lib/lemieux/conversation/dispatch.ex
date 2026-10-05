defmodule Lemieux.Conversation.Dispatch do
  @moduledoc """
  Performs the effects whose meaning is the same in every front end.

  `Lemieux.Conversation` decides what a line means and answers with effects;
  something then has to call the session, and for most effects that call is
  the same whether the answer is printed or painted: `{:prompt, text}` is
  `Lemieux.Session.prompt/2`, `:compact` is `Lemieux.Session.compact/1` with
  its result folded back in as `{:compaction_result, _}`, and so on. Before
  this module each front end held its own copy of that table, so a new
  command needed several edits that could disagree. Keeping the shared
  effects here also lets an embedded host use the same session operations.

  ## What a host supplies

  Front ends differ in three ways, and `t:t/0` is those three things
  plus the session. Every callback takes the host's own state and returns it;
  this module never looks inside it.

    * How to show text — `:say` for a line of `lmx`'s own, `:write` for a
      fragment of the model's answer. A host decides how to display each.
    * How to run work that may block — `:run`. The TUI starts a task and
      receives the answer later in `handle_info/2`, because `handle_event/2`
      runs in the process that draws and a blocked draw loop is a frozen
      screen with nothing on it to say why. A host without a render loop may
      run it inline. Either way the
      answer is a message, and `answer/3` is what to do with it.
    * What it may want to reflect on its own screen — `:react`, called with a
      `t:reaction/0`. The TUI starts its spinner, refreshes a completion menu, or empties the
      pane. A host that cares about none of them returns the state.

  One more, `:fold`, is how to run `Lemieux.Conversation.event/2` over the
  host's conversation and perform what comes back — which every answer to an
  effect eventually needs, and which only the host can do because only the
  host holds the conversation.

  ## Two halves, one owner

  Work that may block answers as a message, and the message needs
  interpreting: `{:retry_result, :ok}` is a turn starting, and an MCP change
  is followed by a fresh listing. `answer/3` is that second half, so a host's
  `handle_info/2` hands the message here rather than keeping its own copy of
  what each answer means. `run/2` and `answer/3` are one table read from both
  ends, and a host that runs work inline reads them back to back.

  ## The command registry

  A slash command's session call is its module's
  `c:Lemieux.Conversation.Command.perform/3`, which takes the same `t:t/0`
  the functions below take. `perform/3` handles the effects that are the
  conversation's own — a line to print, a prompt or a steer to send, the
  answer to a question, and the two halves of feedback a dialogue rather
  than a command produces — and looks every other effect up in `:commands`
  by its shape, handing it to the module that owns it.

  The host struct did have to change for that, by one field: the registry is
  the conversation's, and the dispatcher cannot read the conversation.
  `:commands` defaults to the built-ins, so a host that passes nothing keeps
  every built-in command working; a host that gave
  `Lemieux.Conversation.new/1` modules of its own passes that conversation's
  `commands` here too, or those modules parse and are never performed.

  `say/3`, `fold/3`, `run/3` and `react/3` are public for the same reason:
  they are how a command module reaches the host, and a module of a host's
  own needs them exactly as the built-ins do.

  ## What stays in the front ends

  Anything that is about the screen rather than the session: drawing,
  `/name`, `/color` and `/theme`, `/resume` (which needs host callbacks to
  start a session), `/help` and `/context` where the TUI draws them, the
  `/habs` overlay, the completion menus, and the three statuses whose wording
  says what the menu offers — `:model_status`, `:provider_status`,
  `:reasoning_effort_status`. A front end keeps those as clauses ahead of its
  fallback to `perform/3`, which is why `perform/3` returns the state
  unchanged for anything it does not know: `:ready` and `:idle` are a
  terminal reprinting its prompt, and a screen redrawn after every message
  has nothing to do with either.
  """

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Command.Provider
  alias Lemieux.Session

  @typedoc "The host's own state, threaded through every callback and never read here."
  @type acc :: term()

  @typedoc """
  What just happened that a host may want to show.

    * `:turn_started` — a prompt was accepted or a retry was; the spinner's
      moment. `{:reflecting, mode}` is the same moment for `/reflect`, named
      apart because the TUI says what kind of reflection is running.
    * `:steered` — a mid-turn line reached the session.
    * `:cleared` — the session forgot its context, so a pane still showing
      it would be showing what the model can no longer see.
    * `{:model_set, model}`, `{:provider_set, model}`,
      `{:reasoning_effort_set, effort}` — a setting changed; the completion
      menus that depend on it are stale.
    * `{:tool_statuses, statuses}`, `{:mcp_statuses, statuses}` — a fresh
      listing, for a host that caches one for its menus. `:tools_changed`
      says a listing *would* be fresh, without fetching one for a host that
      keeps none.
    * `{:mcp_started, action}` — an MCP change is under way and may take a
      moment.
    * `{:models_discovered, found}` — the host's `:discover` was asked again
      (`/provider NAME`), and found these: specs, and `{:preferred, spec}`
      for the one to take first, as a host's own discovery reports them.
  """
  @type reaction ::
          :turn_started
          | :steered
          | {:reflecting, :assessment | :opportunities}
          | :cleared
          | {:model_set, String.t()}
          | {:provider_set, String.t()}
          | {:reasoning_effort_set, String.t()}
          | {:tool_statuses, [map()]}
          | :tools_changed
          | {:mcp_statuses, [map()]}
          | {:mcp_started, String.t()}
          | {:models_discovered, [String.t() | {:preferred, String.t()}]}

  @typedoc """
  A front end, as this module sees it.

    * `:session` — the `Lemieux.Session` every effect is performed against,
      or `nil` for a screen with nothing mounted yet.
    * `:id` — its id, which a feedback submission is filed under.
    * `:say`, `:write`, `:fold`, `:run`, `:react` — see the moduledoc.
    * `:clipboard` — where `/copy` puts the text, answering `:ok` or
      `{:error, reason}`; `nil` when the transport has none.
    * `:discovered` — model specs the host found that the session's own
      catalog does not list (an Ollama scan, say). `/provider NAME` falls
      back to them when the session has no model for `NAME`.
    * `:discover` — the providers whose models the host can look for again,
      each with the function that looks (it blocks, so it is called inside
      `run/3`) and returns what `:discovered` holds, `{:preferred, spec}`
      first. `/provider NAME` asks it when neither the session nor
      `:discovered` has a model for `NAME`: a host that looked once, at
      start, found nothing from a local daemon that was not yet running,
      and the switch kept failing until a restart.
    * `:preferred_models` — provider-scoped model specs chosen by the host or
      remembered from earlier selections. A valid preference is used before
      the provider catalog's first model on `/provider NAME`.
    * `:preferred_efforts` — provider-scoped effort defaults applied when
      `/provider NAME` switches to that route.
    * `:feedback` — the module `/feedback` and `/reflect opportunities`
      write through, exporting `anchors/1`, `capture/2` and `harvest/2` as
      `Lemieux.CLI.Feedback` does. Supplied rather than defaulted, because
      the ledger writer is the host layer's and the core does not name it.
    * `:feedback_opts` — what that module is given: the store, or the
      sessions directory to derive one from.
    * `:commands` — the `Lemieux.Conversation.Command` modules effects are
      looked up in: the conversation's own `commands`, which a host that
      added modules must pass. Defaults to the built-ins.

  The rest are what a few commands need from the host beyond the session,
  each `nil` when the host has nothing to say — the command then says what
  is missing rather than guessing:

    * `:environment` — the session's `Lemieux.Environment`, where `!cmd`,
      `/diff` and `/undo` run, so a sandbox and a credential policy apply to
      them exactly as they do to the agent's own `bash`. `nil` is the local
      machine.
    * `:cwd` — the session's working directory. `nil` asks the session.
    * `:permissions` — the `Lemieux.Extensions.Permissions` handle `/permissions`
      reads and changes; `nil` when the host applied no permission policy.
    * `:checkpoints` — the directory `Lemieux.Extensions.Checkpoints` records
      into, which `/undo` and `/rewind` read; `nil` when nothing is recorded.
    * `:export_dir` — where a bare `/export` writes. `nil` is `~/.lmx/exports`.
    * `:personal_dir` — the directory whose `MEMORY.md` `/memory` appends to.
      `nil` is `~/.lmx`, where workspace discovery reads it from.
  """
  @type t :: %__MODULE__{
          session: pid() | nil,
          id: String.t() | nil,
          say: (acc(), String.t() -> acc()),
          write: (acc(), String.t() -> acc()),
          fold: (acc(), term() -> acc()),
          run: (acc(), (-> term()) -> acc()),
          react: (acc(), reaction() -> acc()),
          clipboard: (String.t() -> :ok | {:error, term()}) | nil,
          discovered: [String.t()],
          discover: %{optional(String.t()) => (-> [String.t() | {:preferred, String.t()}])},
          preferred_models: %{optional(String.t()) => String.t()},
          preferred_efforts: %{optional(String.t()) => String.t()},
          feedback: module() | nil,
          feedback_opts: keyword(),
          commands: [module()],
          environment: Lemieux.Environment.t() | nil,
          cwd: Path.t() | nil,
          permissions: term() | nil,
          checkpoints: Path.t() | nil,
          export_dir: Path.t() | nil,
          personal_dir: Path.t() | nil
        }

  @enforce_keys [:say, :write, :fold, :run, :react]
  defstruct session: nil,
            id: nil,
            say: nil,
            write: nil,
            fold: nil,
            run: nil,
            react: nil,
            clipboard: nil,
            discovered: [],
            discover: %{},
            preferred_models: %{},
            preferred_efforts: %{},
            feedback: nil,
            feedback_opts: [],
            # Filled in by `new/1`: the built-in list is a function call, and a
            # call in a struct default is a compile-time call this build
            # fails on.
            commands: [],
            environment: nil,
            cwd: nil,
            permissions: nil,
            checkpoints: nil,
            export_dir: nil,
            personal_dir: nil

  @doc """
  Builds a host from the fields a front end has.

  A constructor rather than a struct literal at the call site, for the reason
  `Lemieux.TUI.Status.new/1` gives: a `%Dispatch{}` in a front end is a
  compile-time dependency on this module, and this module's own dependencies
  are the session and everything behind it — which `mix xref graph --label
  compile-connected` fails the build over. Unknown keys raise. `:commands`
  left out is the built-ins.
  """
  @spec new(fields :: keyword()) :: t()
  def new(fields) when is_list(fields),
    do: struct!(__MODULE__, Keyword.put_new_lazy(fields, :commands, &Builtin.all/0))

  @doc """
  Performs one effect against the session, through the host.

  Returns the host's state. Effects this module does not perform come back
  unchanged, so a front end can put its own clauses first and this call last.
  """
  @spec perform(acc :: acc(), host :: t(), effect :: Conversation.effect()) :: acc()
  def perform(acc, host, effect)

  def perform(acc, host, {:write, text}), do: host.write.(acc, text)
  def perform(acc, host, {:say, text}), do: say(acc, host, text)
  def perform(acc, host, {:prompt, text}), do: prompt(acc, host, text)
  def perform(acc, host, {:steer, text}), do: steer(acc, host, text)
  def perform(acc, host, {:answer, call_id, text}), do: reply(acc, host, call_id, text)
  def perform(acc, host, {:feedback, submission}), do: feedback_capture(acc, host, submission)
  def perform(acc, host, :mine_opportunities), do: mine_opportunities(acc, host)

  # Everything else is a command's, or nobody's. `:ready`, `:idle`,
  # `{:asked, _}` and `{:approval, _}` are nobody's here: they are a terminal
  # reprinting its prompt, and the front end that cares claims them first.
  def perform(acc, host, effect) do
    case Command.owner(host.commands, effect) do
      nil -> acc
      module -> module.perform(acc, host, effect)
    end
  end

  @doc """
  Interprets the answer to work that `perform/3` handed to `:run`.

  Most answers are events `Lemieux.Conversation.event/2` already understands
  and are folded as they are. Three carry more: an accepted retry is a turn
  starting, an MCP change that worked is followed by the fresh listing
  the task fetched so that the host's menu and the person both see it, and
  what `/provider NAME` found when it asked the host's `:discover` again is
  recorded and then switched to.
  """
  @spec answer(acc :: acc(), host :: t(), message :: term()) :: acc()
  def answer(acc, host, message)

  def answer(acc, host, {:retry_result, :ok} = message),
    do: acc |> fold(host, message) |> react(host, :turn_started)

  def answer(acc, host, {:mcp_result, action, result, nil}),
    do: fold(acc, host, {:mcp_result, action, result})

  def answer(acc, host, {:mcp_result, action, result, statuses}) do
    acc
    |> fold(host, {:mcp_result, action, result})
    |> react(host, {:mcp_statuses, statuses})
    |> react(host, :tools_changed)
    |> fold(host, {:mcp_status, statuses})
  end

  # A listing fetched off the host's own process: `Lemieux.Session.mcp_status/2`
  # waits for startup connections to settle, and a first `/mcp` typed while a
  # slow server was still connecting froze the screen for as long as it took.
  def answer(acc, host, {:mcp_listing, statuses}) do
    acc
    |> react(host, {:mcp_statuses, statuses})
    |> fold(host, {:mcp_status, statuses})
  end

  # `/provider NAME`'s second look (`Lemieux.Conversation.Command.Provider`).
  def answer(acc, host, {:provider_discovered, provider, found}),
    do: Provider.discovered(acc, host, provider, found)

  def answer(acc, host, message), do: fold(acc, host, message)

  defp prompt(acc, host, text) do
    :ok = Session.prompt(host.session, text)

    react(acc, host, :turn_started)
  end

  defp steer(acc, host, text) do
    :ok = Session.steer(host.session, text)

    react(acc, host, :steered)
  end

  defp reply(acc, host, call_id, text) do
    :ok = Session.answer(host.session, call_id, text)

    acc
  end

  defp feedback_capture(acc, host, submission) do
    %{feedback: feedback, feedback_opts: opts} = host
    submission = Map.put(submission, :session_id, host.id)

    run(acc, host, fn -> {:feedback_result, written(feedback, submission, opts)} end)
  end

  # The second half of `/reflect opportunities`: the answer has already
  # streamed and been persisted, so this reads it back and records what it
  # names in the same ledger `lmx feedback --mine` writes. The snapshot is
  # taken now, in the host's process, so a host that defers the work is not
  # reading a transcript that moved on.
  defp mine_opportunities(acc, host) do
    %{feedback: feedback, feedback_opts: opts} = host
    snapshot = Session.snapshot(host.session)

    run(acc, host, fn -> {:opportunities_result, feedback.harvest(snapshot, opts)} end)
  end

  defp written(feedback, submission, opts) do
    case feedback.capture(submission, opts) do
      {:ok, record} -> {:ok, record.id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A line of `lmx`'s own, through the host's `:say`."
  @spec say(acc :: acc(), host :: t(), text :: String.t()) :: acc()
  def say(acc, host, text), do: host.say.(acc, text)

  @doc """
  Runs `Lemieux.Conversation.event/2` over the host's conversation and
  performs what comes back, through the host's `:fold`.
  """
  @spec fold(acc :: acc(), host :: t(), event :: term()) :: acc()
  def fold(acc, host, event), do: host.fold.(acc, event)

  @doc """
  Work that may block, through the host's `:run`. Its answer is a message
  for `answer/3`, however the host chose to wait for it.
  """
  @spec run(acc :: acc(), host :: t(), work :: (-> term())) :: acc()
  def run(acc, host, work), do: host.run.(acc, work)

  @doc "Tells the host something it may want to show — see `t:reaction/0`."
  @spec react(acc :: acc(), host :: t(), reaction :: reaction()) :: acc()
  def react(acc, host, reaction), do: host.react.(acc, reaction)

  @doc """
  Where the session works: the host's `:cwd`, or the session's own answer.

  Asks the session when the host did not say, so it blocks for a call — call
  it inside work handed to `run/3`, not on a host's draw loop.
  """
  @spec cwd(host :: t()) :: Path.t()
  def cwd(%__MODULE__{cwd: cwd}) when is_binary(cwd), do: cwd
  def cwd(%__MODULE__{session: session}) when is_pid(session), do: Session.info(session).cwd
  def cwd(%__MODULE__{}), do: File.cwd!()

  @doc """
  The environment a person's own command runs in: the session's when the
  host supplied it, the local machine otherwise. See `t:t/0` on why it must be
  the session's.
  """
  @spec environment(host :: t()) :: Lemieux.Environment.t()
  def environment(%__MODULE__{environment: nil}), do: Lemieux.Environment.local()
  def environment(%__MODULE__{environment: environment}), do: environment
end
