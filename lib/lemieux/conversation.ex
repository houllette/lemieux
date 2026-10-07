defmodule Lemieux.Conversation do
  @moduledoc """
  What an interactive front end decides, with nothing about how it draws.

  A person talking to a session generates two kinds of input — lines they
  type, and events the session emits — and both need the same set of
  decisions made about them: is this line a prompt, a steer, or the answer to
  a question the agent asked? Has the turn ended, and should the status line
  appear this time? Those decisions are kept here so an embedded host can
  share them with the TUI.

  It is a pure fold, in the same shape as `Lemieux.Turn`: `input/2` and
  `event/2` take a conversation and return a new one plus a list of effects.
  Nothing here writes, reads, sends or calls. That keeps the input decisions
  testable without a terminal or provider.

  ## Why the effects are a list rather than a return value

  A single input often has to do two things — steer the turn *and* say that
  it landed, cancel *and* stop waiting on a question — and an interpreter that
  received one instruction would have to infer the second from the struct.
  The list is ordered, and front ends run it in order.

  ## The effects

  Output, which the front end shows:

    * `{:write, text}` — a fragment of the model's answer, with no line
      ending. Streamed as it arrives, so a terminal appends and a widget
      extends the last line. Kept distinct from `:say` because the model's
      answer is the conversation, and everything else is `lmx` talking about
      it — which is exactly the line a TUI needs in order to style them
      differently.
    * `{:say, text}` — a complete line from `lmx` itself.
    * `{:asked, question}` — the agent asked something; the next line answers
      it rather than starting a turn.
    * `{:approval, call}` — a hook parked a tool call; a short reply (`y`,
      `n reason`) answers it. See "Approvals" below.
    * `:ready` — ready for another line.
    * `:idle` — a turn just ended. Emitted only on the transition, never on a
      redraw: a blank line reprints a prompt without anything having
      finished, and a listener that heard `:idle` for that could not tell it
      from a turn ending.

  Actions, which the front end performs against the session:

    * `{:prompt, text}`, `{:steer, text}`, `{:answer, call_id, text}`
    * `:help`, `:context_status`, `:cancel`, `:compact`, `:new`, `:refresh`,
      `:provider_status`, `{:set_provider, provider}`
    * `{:reflect, :assessment | :opportunities}`, `:mine_opportunities`
    * `:feedback`, `{:feedback, submission}`
    * `:model_status`, `{:set_model, spec}`, `:reasoning_effort_status`,
      `{:set_reasoning_effort, effort}`
    * `:name_status`, `{:set_name, text}`, `:colour_status`,
      `{:set_colour, text}` — what this sitting calls the session and what
      colour it draws its accents in. Parsed here so both front ends read one
      grammar, and performed there because neither answer belongs to the
      session: nothing is written, and a resumed session is relabelled by its
      own id again.
    * `:resume_status`, `{:resume, session_id}`
    * `:toggle_elixir_mode`
    * `:copy`
    * `:habs`
    * `:tools_status`, `{:enable_tools, names}`, `{:disable_tools, names}`
    * `:mcp_status`, `{:mcp_add, path}`, `{:mcp_remove, name}`,
      `{:mcp_reconnect, name_or_all}`, `:quit`
    * `{:approve, call_id}`, `{:deny, call_id, reason}` — the answer to a
      parked tool call, through `Lemieux.Session.resolve_tool/3`.
    * `{:shell, command}` — `!command`: run it in the session's environment
      for the person, show what it printed, and share it with the next
      message. See "A person's own commands" below.
    * `:diff`, `{:export, path | nil}`, `:doctor` — the working tree's
      changes, the conversation as Markdown, and a readable health check.
    * `{:undo, force?}`, `{:rewind, turns, force?}` — put back the files the
      agent changed, from `Lemieux.Checkpoint`; `{:redo, force?}` takes the
      last undo back.
    * `:permissions_status`, `{:set_permission_mode, mode}`,
      `{:remember_permission, rule}`, `{:forget_permission, rule}`
    * `:verify_status`, `{:set_verify, boolean}`, `:delegate_status`,
      `{:set_delegate, boolean}`
    * `:init`, `{:memory, :personal | :project, text}`
    * `:mcp_prompts`, `{:mcp_prompt, command, arguments}` — list the MCP
      servers' prompts, and send one as a message.
    * `{:resume_list, :all}` — `/resume all`, every stored session rather
      than this directory's.

  ## A person's own commands

  `!command` is the person's, not the model's: it runs through the same
  environment the agent's `bash` does — so a sandbox or a credential policy
  holds for it too — and its output is shown and then carried into the next
  message the person sends, marked as theirs. Not a turn of its own: running
  `git status` to show the agent something should not cost a request and an
  answer about `git status`. `/undo` leaves a note the same way, because a
  model that is not told its edits were put back reasons from files that no
  longer exist. `pending_context` holds those notes until a prompt or steer
  carries them.

  `:compact` is the one that answers back: `Lemieux.Session.compact/2` is
  synchronous, so a front end runs it and feeds the result in as
  `event(conversation, {:compaction_result, result})`. Making the pure module
  wait for it would have made it not pure, and making it fire-and-forget would
  have thrown away the only thing worth reporting.

  Performing the effects is `Lemieux.Conversation.Dispatch`'s job for
  everything both front ends do the same way — the session calls, and the
  answers they fold back in. What a front end does differently (where its
  prompt goes, what it draws) stays in the front end.

  ## Commands are modules

  Every slash command is a `Lemieux.Conversation.Command`: one module that
  says what it is called, how the rest of its line is read, and what
  performing it does. `new/1` takes `commands: [module]` and puts them ahead
  of the built-ins `Lemieux.Conversation.Command.Builtin` lists — a host
  module with a built-in's name replaces it — and `input/2` finds the module
  by the name after the slash. `commands/2`, `help/2` and `command_action?/2`
  read the same registry, so `/help`, the completion menu and a host's
  `command_policy` cannot disagree about which commands exist. The
  arity-one forms describe the built-ins alone, for a caller with no
  conversation in hand.

  ## Approvals

  A `before_tool_call` hook that answers `:pending` parks the call, and the
  session says so with an `:approval` entry and a `{:tool_approval, call}`
  event. Both are folded here into `approvals`, oldest first, so a front end
  can show the call and know it is waiting on somebody. While one is parked
  and no question is, a short typed reply answers the oldest — `y`, `yes`,
  `allow` run it; `n`, `no`, `deny`, each with an optional reason after it,
  refuse it — and `/approve` and `/deny` name one when several wait. Any
  other line is a steer, said with a reminder, because a steer lands at the
  next turn boundary and there is no boundary until the call resolves.

  The decision, whoever made it, arrives back as the entry the session
  writes when the call resolves — this host's answer, another host's, or
  the timeout's — and that is what clears the waiting state, so two hosts on
  one session cannot both believe the call is theirs to answer. The tool
  result that follows says what became of it.

  ## Capturing feedback without touching the transcript

  `/feedback` opens a short dialogue owned by `Lemieux.Feedback.Dialogue`:
  which moment, what should have happened, and at most three questions that
  change where the record goes. While it is open every typed line is an
  answer, and the only command it accepts is `/cancel` — a half-answered
  capture that silently became a prompt would put a complaint into the
  conversation it is about.

  It answers back twice, in the `:compact` shape. `:feedback` asks the front
  end for the entries a person can point at (`event(conversation,
  {:feedback_anchors, anchors})`), because only the front end holds the
  session; `{:feedback, submission}` asks it to write the record
  (`event(conversation, {:feedback_result, result})`). Nothing in either
  direction appends to the transcript, which is the whole point: resume and
  replay are byte-for-byte what they would have been.
  """

  alias Lemieux.Provider.Error, as: ProviderError

  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.Models
  alias Lemieux.Context
  alias Lemieux.Conversation.Columns
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Estimate
  alias Lemieux.Conversation.Shell
  alias Lemieux.Feedback.Dialogue
  alias Lemieux.ModelSpec
  alias Lemieux.Tool.Profile

  @type option :: %{
          required(:label) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:diagram) => String.t() | nil,
          optional(:preview) => String.t() | nil
        }

  @typedoc """
  One field an MCP elicitation asks for: its name, its JSON Schema type and
  the server's description of it. `Lemieux.MCP.Elicitation` casts the typed
  answer to the type; this only shows what was asked.
  """
  @type field :: %{
          required(:name) => String.t(),
          optional(:type) => String.t(),
          optional(:description) => String.t() | nil
        }

  @typedoc """
  What the agent asked. `ask_user` carries `options`; an MCP elicitation may
  carry a `title` and the `fields` its schema requested, and both are
  rendered when present.
  """
  @type question :: %{
          required(:call_id) => String.t(),
          required(:question) => String.t(),
          optional(:options) => [option()],
          optional(:title) => String.t() | nil,
          optional(:fields) => [field()],
          optional(:ask_user) => boolean(),
          optional(:questionnaire) => boolean(),
          optional(:questions) => [map()]
        }

  @typedoc "A tool call a hook parked, waiting for somebody to decide."
  @type approval :: %{call_id: String.t(), name: String.t(), arguments: map()}

  @type effect ::
          {:write, String.t()}
          | {:say, String.t()}
          | {:asked, question()}
          | {:approval, approval()}
          | {:approve, String.t()}
          | {:deny, String.t(), String.t() | nil}
          | {:prompt, String.t()}
          | {:steer, String.t()}
          | {:answer, String.t(), String.t() | map()}
          | :ready
          | :idle
          | :help
          | :context_status
          | :cancel
          | :compact
          | :retry
          | :update
          | {:reflect, :assessment | :opportunities}
          | :mine_opportunities
          | :feedback
          | {:feedback, Dialogue.submission()}
          | :new
          | :refresh
          | :provider_status
          | {:set_provider, String.t()}
          | :model_status
          | {:set_model, String.t()}
          | :reasoning_effort_status
          | {:set_reasoning_effort, String.t()}
          | :name_status
          | {:set_name, String.t()}
          | :colour_status
          | {:set_colour, String.t()}
          | :theme_status
          | {:set_theme, String.t()}
          | :resume_status
          | {:resume, String.t()}
          | :toggle_elixir_mode
          | :copy
          | :habs
          | :tools_status
          | {:enable_tools, [String.t()]}
          | {:disable_tools, [String.t()]}
          | :mcp_status
          | {:mcp_add, Path.t()}
          | {:mcp_remove, String.t()}
          | {:mcp_reconnect, String.t() | :all}
          | {:attach, String.t() | nil}
          | :detach
          | :quit
          | {:shell, String.t()}
          | :diff
          | {:export, String.t() | nil}
          | :doctor
          | {:undo, boolean()}
          | {:rewind, pos_integer(), boolean()}
          | {:redo, boolean()}
          | :permissions_status
          | {:set_permission_mode, String.t()}
          | {:remember_permission, String.t()}
          | {:forget_permission, String.t()}
          | :verify_status
          | {:set_verify, boolean()}
          | :delegate_status
          | {:set_delegate, boolean()}
          | :init
          | {:memory, :personal | :project, String.t()}
          | :mcp_prompts
          | {:mcp_prompt, String.t(), String.t()}
          | {:resume_list, :all}

  @type t :: %__MODULE__{
          model: String.t() | nil,
          model_chosen?: boolean(),
          reasoning_effort: String.t(),
          context: Context.t(),
          spent_usd: number() | nil,
          measured_spent_usd: number(),
          unmeasured_requests: non_neg_integer(),
          estimated_usd: Estimate.t() | nil,
          estimated_requests: non_neg_integer(),
          estimate_unknown_reasons: [String.t()],
          estimate_sources: [String.t()],
          estimate_excludes: [String.t()],
          observed_request_ids: MapSet.t(),
          delegated_spent_usd: number() | nil,
          delegated_usage?: boolean(),
          busy?: boolean(),
          asking: String.t() | nil,
          question: question() | nil,
          approvals: [approval()],
          commands: [module()],
          reflecting: :assessment | :opportunities | nil,
          feedback: Dialogue.t() | {:pending, String.t()} | nil,
          noted_window?: boolean(),
          pending_context: [String.t()]
        }

  # `context: nil` rather than `%Context{}`, filled in by `new/1`: a struct literal
  # in a module body is a compile-time dependency, which `mix xref graph --label
  # compile-connected` fails the build over — an edit to `Lemieux.Context` would
  # otherwise recompile every front end. In a function body it is only an export
  # dependency.
  defstruct model: nil,
            # Whether anybody chose `model` — the person, or a host on their
            # behalf. False for a placeholder a host started on because
            # nothing named a model and no key was found (`unchosen/1`); a
            # model change makes it somebody's choice again.
            model_chosen?: true,
            reasoning_effort: "default",
            # Where the session stands in its context window, as of the last
            # turn. Kept rather than asked for, because a snapshot copies the
            # whole transcript and a status line wants a number.
            context: nil,
            spent_usd: 0.0,
            measured_spent_usd: 0.0,
            unmeasured_requests: 0,
            estimated_usd: nil,
            estimated_requests: 0,
            estimate_unknown_reasons: [],
            estimate_sources: [],
            estimate_excludes: [],
            observed_request_ids: nil,
            delegated_spent_usd: 0.0,
            delegated_usage?: false,
            busy?: false,
            # The call_id of a question the agent is waiting on, or nil.
            asking: nil,
            # The complete question is separate from `asking` so consumers
            # that already treat that field as a call id keep doing so while
            # richer front ends can render the available choices.
            question: nil,
            # Tool calls a hook parked, oldest first. A short reply answers the
            # head; `/approve` and `/deny` name any of them.
            approvals: [],
            # The slash commands this conversation answers to, host modules
            # ahead of the built-ins. `[]` here and filled in by `new/1`,
            # because the built-in list is a function call and a call in a
            # struct default is a compile-time call this build fails on.
            commands: [],
            # Which kind of reflection is in flight, or nil. The opportunity
            # mode has a second half — parsing the answer into feedback records
            # — and the turn ending is the only signal that the answer exists.
            # Reading it back off the transcript would mean guessing which
            # assistant message was the reflection.
            reflecting: nil,
            # An open `/feedback` capture, or nil. While a
            # `Lemieux.Feedback.Dialogue` is here every typed line is an answer
            # to it. `{:pending, text}` is the gap between asking the front end
            # for anchors and getting them back, holding any prose that came
            # with the command.
            feedback: nil,
            # Whether the "nothing knows this model's window" note has been
            # said. Once per conversation, not once per turn.
            noted_window?: false,
            # What the next prompt or steer carries ahead of what is typed:
            # a `!command`'s output, a note that `/undo` put files back.
            # Newest first; see "A person's own commands".
            pending_context: []

  @doc """
  A conversation with nothing said yet.

  ## Options

    * `:model` — what the session is running as, named in the note about an
      unknown context window.
    * `:model_chosen?` — `false` when nobody chose `:model`: see
      `unchosen/1`. Defaults to `true`, the case for a host that named the
      model it starts on.
    * `:reasoning_effort` — the model's selected effort, or `"default"`.
    * `:commands` — `Lemieux.Conversation.Command` modules of the host's own,
      put ahead of the built-ins. A module whose name or alias is a
      built-in's replaces that built-in — see that behaviour's documentation
      for why. A module that is not a command raises, because it came from
      code and a conversation that quietly answered without it would hide
      the mistake.
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      model: Keyword.get(opts, :model),
      model_chosen?: Keyword.get(opts, :model_chosen?, true) != false,
      reasoning_effort: Keyword.get(opts, :reasoning_effort, "default"),
      context: %Context{},
      observed_request_ids: MapSet.new(),
      commands: Command.registry!(Keyword.get(opts, :commands) || [])
    }
  end

  @doc """
  Marks the model this conversation runs on as one nobody chose.

  A host that found no key and nothing naming a model still has to start a
  session on something, and `lmx` starts on the first row of its provider
  table. The first prompt's missing-key line then named that row's vendor —
  "no API key for anthropic · set ANTHROPIC_API_KEY" — to somebody who had
  picked no vendor and was being steered to one, as Z.AI's row steered
  every keyless newcomer before it. Marked, the line says no provider key
  was found and every way to get one (`error_line/2`), and names no vendor.

  A model change — `/model`, `/provider`, a provider picked in a host's
  first-run panel — is a choice, and the line names its provider again.
  """
  @spec unchosen(conversation :: t()) :: t()
  def unchosen(%__MODULE__{} = conversation), do: %{conversation | model_chosen?: false}

  @doc "Restores the known-cost subtotal and unknown request count from a transcript."
  @spec restore_usage(conversation :: t(), entries :: [map()]) :: t()
  def restore_usage(%__MODULE__{} = conversation, entries) when is_list(entries) do
    direct =
      Enum.flat_map(entries, fn
        %{usage: usage} when is_map(usage) -> [usage]
        _entry -> []
      end)

    usages = direct ++ Context.delegated_usages(entries)

    Enum.reduce(usages, conversation, fn usage, conversation ->
      cost = Map.get(usage, "cost_usd") || Map.get(usage, :cost_usd)

      %{
        conversation
        | measured_spent_usd: add_measured(conversation.measured_spent_usd, cost),
          unmeasured_requests: unmeasured_requests(conversation.unmeasured_requests, cost)
      }
    end)
  end

  @doc """
  Decides what a typed line means, given where the conversation stands.
  """
  @spec input(conversation :: t(), line :: String.t()) :: {t(), [effect()]}
  def input(conversation, line), do: line |> String.trim() |> typed(conversation)

  # An open capture owns the line before anything else looks at it. Falling
  # through to the command table would let `/help` land as feedback prose, and
  # falling through to the prompt clause would send a half-typed complaint to
  # the model as an instruction.
  defp typed("/cancel", %__MODULE__{feedback: %Dialogue{}} = conversation),
    do: {%{conversation | feedback: nil}, [{:say, "feedback discarded"}, :ready]}

  defp typed("/" <> _rest = command, %__MODULE__{feedback: %Dialogue{}} = conversation),
    do:
      {conversation,
       [{:say, "#{command} has to wait: finish the feedback, or /cancel it"}, :ready]}

  defp typed(line, %__MODULE__{feedback: %Dialogue{} = dialogue} = conversation),
    do: capture(conversation, Dialogue.answer(dialogue, line))

  defp typed("", conversation), do: ready_unless_busy(conversation)

  # Every slash command is a module: the name after the slash finds it in the
  # conversation's registry, and its `parse/2` decides what the rest of the
  # line means — `Lemieux.Conversation.Command` says why. A lookup rather
  # than a clause per command is what lets a host add one, or shadow one,
  # without editing this module.
  defp typed(line, %__MODULE__{asking: id, question: %{questionnaire: true}} = conversation)
       when is_binary(id) and line in ["/decline", "/cancel-question"] do
    status = if line == "/decline", do: "declined", else: "cancelled"
    {%{conversation | asking: nil, question: nil}, [{:answer, id, %{"status" => status}}]}
  end

  defp typed(
         line,
         %__MODULE__{asking: id, question: %{questionnaire: true} = question} = conversation
       )
       when is_binary(id) do
    answers = Map.get(question, :staged_answers, []) ++ [line]
    remaining = Enum.drop(question.questions, length(answers))

    case remaining do
      [next | _] ->
        updated = question |> Map.merge(next) |> Map.put(:staged_answers, answers)
        {%{conversation | question: updated}, [{:say, format_question(updated)}]}

      [] ->
        {%{conversation | asking: nil, question: nil}, [{:answer, id, %{"answers" => answers}}]}
    end
  end

  # A person's own command, ahead of a question or an approval: `!ls` typed
  # under a question is somebody looking at the files before answering it,
  # not the answer.
  defp typed("!" <> command, conversation) do
    case String.trim(command) do
      "" ->
        ready_unless_busy(conversation, [
          {:say, "type a command after ! to run it here · its output goes with your next message"}
        ])

      command ->
        {conversation, [{:shell, command}]}
    end
  end

  defp typed("/" <> rest = line, conversation) do
    {name, arguments} = split_command(rest)

    case Command.find(conversation.commands, name) do
      nil -> unregistered(line, name, arguments, conversation)
      module -> command(module, arguments, conversation)
    end
  end

  # A question in flight owns the next line, ahead of a parked approval: the
  # agent asked it in so many words, and a `y` typed under a question is an
  # answer to the question.
  defp typed(line, %__MODULE__{asking: call_id, question: question} = conversation)
       when is_binary(call_id),
       do:
         {%{conversation | asking: nil, question: nil},
          [{:answer, call_id, selected_answer(question, line)}]}

  # A short reply answers the oldest parked call. Anything else is a steer,
  # said with a reminder that the call is still waiting: a steer lands at the
  # next turn boundary, and there is no boundary until the call resolves.
  defp typed(
         line,
         %__MODULE__{approvals: [%{call_id: call_id, name: name} | _rest]} = conversation
       ) do
    case approval_reply(line) do
      :allow ->
        {conversation, [{:approve, call_id}]}

      {:deny, reason} ->
        {conversation, [{:deny, call_id, reason}]}

      nil ->
        {conversation, text} = carrying_context(conversation, line)

        {conversation,
         [
           {:steer, text},
           {:say,
            "… noted, will pass it on · #{name} is still waiting: y runs it, n [reason] refuses it"}
         ]}
    end
  end

  defp typed(line, %__MODULE__{busy?: true} = conversation) do
    {conversation, text} = carrying_context(conversation, line)
    {conversation, [{:steer, text}, {:say, "… noted, will pass it on"}]}
  end

  defp typed(line, conversation) do
    {conversation, text} = carrying_context(conversation, line)
    {%{conversation | busy?: true}, [{:prompt, text}]}
  end

  # A name no command answers to. The MCP servers' prompts are offered as
  # `/mcp__server__prompt` — named by `Lemieux.MCP.prompt_command/2` — and are
  # not in the registry because they come and go with the servers; one typed
  # by name is looked up when it is performed, where the servers are.
  defp unregistered(_line, "mcp__" <> _rest, _arguments, %__MODULE__{busy?: true} = conversation),
    do: {conversation, Command.wait("wait for this turn before sending an MCP prompt")}

  defp unregistered(_line, "mcp__" <> _rest = name, arguments, conversation),
    do: {conversation, [{:mcp_prompt, name, String.trim(arguments)}]}

  defp unregistered(line, _name, _arguments, conversation),
    do: ready_unless_busy(conversation, [{:say, "#{line} is not a command. /help lists them."}])

  # The pending notes go ahead of what was typed, oldest first, and are
  # spent: a second message does not carry the first one's `git status` again.
  defp carrying_context(%__MODULE__{pending_context: []} = conversation, line),
    do: {conversation, line}

  defp carrying_context(%__MODULE__{pending_context: notes} = conversation, line) do
    text = Enum.join(Enum.reverse(notes) ++ [line], "\n\n")
    {%{conversation | pending_context: []}, text}
  end

  @doc """
  Holds `note` for the next prompt or steer, ahead of what the person types.

  Public for a command module's answer: `!command` and `/undo` fold their
  results back as events, and a host command with something the model
  should hear before the next message can do the same.
  """
  @spec note_for_next(conversation :: t(), note :: String.t()) :: t()
  def note_for_next(%__MODULE__{} = conversation, note) when is_binary(note),
    do: %{conversation | pending_context: [note | conversation.pending_context]}

  defp split_command(rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [name, arguments] -> {name, arguments}
      [name] -> {name, ""}
    end
  end

  # An argument to a command that takes none is refused before the module is
  # asked, so no module has to remember to; the module's own parse decides
  # everything else, and answers in one of the three shapes
  # `Lemieux.Conversation.Command` names. Anything else is a bug in the
  # module, and raising names it rather than sending the line to the model.
  defp command(module, arguments, conversation) do
    spec = Command.spec!(module)

    if arguments != "" and not spec.accepts_arguments?,
      do: ready_unless_busy(conversation, [{:say, "/#{spec.name} takes no argument"}]),
      else: parsed(module, module.parse(arguments, conversation), conversation)
  end

  defp parsed(_module, effects, conversation) when is_list(effects), do: {conversation, effects}

  defp parsed(_module, {%__MODULE__{} = changed, effects}, _conversation) when is_list(effects),
    do: {changed, effects}

  defp parsed(_module, {:error, line}, conversation) when is_binary(line),
    do: ready_unless_busy(conversation, [{:say, line}])

  defp parsed(module, other, _conversation) do
    raise ArgumentError,
          "#{inspect(module)}.parse/2 must return effects, {conversation, effects} or " <>
            "{:error, line}; got #{inspect(other)}"
  end

  # The words that answer a parked call. Exact for yes — `yes please` is a
  # sentence to the model, not a decision — and open-ended for no, because
  # what follows `no` is the reason the model will read.
  @approving ~w(y yes allow approve ok)
  @refusing ~w(n no deny refuse)

  defp approval_reply(line) do
    [word | rest] = String.split(line, ~r/\s+/, parts: 2)
    word = word |> String.downcase() |> String.replace(~r/[[:punct:]]+$/u, "")

    cond do
      word in @approving and rest == [] -> :allow
      word in @refusing -> {:deny, reason(rest)}
      true -> nil
    end
  end

  defp reason([]), do: nil

  defp reason([text]) do
    case String.trim(text) do
      "" -> nil
      reason -> reason
    end
  end

  @doc """
  Whether a tool catalog is Elixir mode: `elixir` present, the file tools gone.

  Asked of the names, and by what is *missing* rather than by an exact list,
  because the catalog can legitimately hold more than the mode's own tool —
  `ask_user` in a session with somebody attached, `delegate` wherever the host
  supplies subagents. Three places had the exact list, and the first tool to
  arrive beside `elixir` made the front ends stop recognising the mode:
  re-entered it on every toggle, and turning it on announced that it was off.
  """
  @spec elixir_mode?(tool_names :: [String.t()]) :: boolean()
  def elixir_mode?(tools) when is_list(tools),
    do: "elixir" in tools and Enum.all?(~w(read write edit bash), &(&1 not in tools))

  @doc """
  Folds one of the session's events into the conversation.

  Unrecognised events are ignored rather than crashing the front end: the
  session's event vocabulary grows, and a host that died on an event it had
  not been taught about would be the most fragile part of the system.
  """
  @spec event(conversation :: t(), event :: term()) :: {t(), [effect()]}
  def event(conversation, event)

  def event(conversation, {:text_delta, %{text: text}}), do: {conversation, [{:write, text}]}
  def event(conversation, {:text_delta, text}), do: {conversation, [{:write, text}]}
  def event(conversation, {:tool_delta, %{text: text}}), do: {conversation, [{:write, text}]}

  # Route receipts are illustrative comparisons, not transcript lines or
  # billed usage. Keeping them here lets both interactive front ends show one
  # running status without changing Session's spending and budget decisions.
  def event(conversation, {:route_observation, %{"kind" => "ixway_api_equivalent"} = observation}) do
    {note_estimate(conversation, observation), []}
  end

  def event(conversation, {:route_observation, _observation}), do: {conversation, []}

  def event(conversation, {:usage, usage}) do
    cost = Map.get(usage, "cost_usd") || Map.get(usage, :cost_usd)

    spent =
      case {conversation.spent_usd, cost} do
        {total, cost} when is_number(total) and is_number(cost) -> total + cost
        _unknown -> nil
      end

    context = Context.with_usage(conversation.context, usage)

    {%{
       conversation
       | context: context,
         spent_usd: spent,
         measured_spent_usd: add_measured(conversation.measured_spent_usd, cost),
         unmeasured_requests: unmeasured_requests(conversation.unmeasured_requests, cost)
     }, []}
  end

  # Child usage belongs in the bill a person sees for the root run but not in the
  # parent's context position: a child has a fresh transcript, and its tokens will
  # never be sent in the parent's next request. Accumulated here rather than waited
  # for, because waiting was the bug — a fan-out's whole cost appeared only when the
  # children finished, and a cancelled fan-out never got there at all.
  def event(conversation, {:subagent, [_root_id, _child_id], {:usage, usage}})
      when is_map(usage) do
    cost = Map.get(usage, "cost_usd") || Map.get(usage, :cost_usd)

    {%{
       conversation
       | context: Context.with_delegated_usage(conversation.context, usage),
         spent_usd: add_cost(conversation.spent_usd, cost),
         measured_spent_usd: add_measured(conversation.measured_spent_usd, cost),
         unmeasured_requests: unmeasured_requests(conversation.unmeasured_requests, cost),
         delegated_spent_usd: add_cost(conversation.delegated_spent_usd, cost),
         delegated_usage?: true
     }, []}
  end

  def event(conversation, {:tool_call, call}),
    do: {conversation, [{:say, "  · #{call.name} #{summarise(call.arguments)}"}]}

  def event(conversation, {:entry, %{type: :tool_result, payload: payload}}) do
    marker = if payload["error"] == true, do: "✗", else: "✓"
    name = payload["name"] || "tool"
    output = preview(payload["output"])

    {conversation, [{:say, "  #{marker} #{name} #{output}" |> String.trim_trailing()}]}
  end

  def event(conversation, {:question, question}) do
    normalized = Map.put_new(question, :options, [])

    {%{conversation | asking: normalized.call_id, question: normalized},
     [{:say, format_question(normalized)}, {:asked, question}]}
  end

  # A hook parked this call. The session says so twice — the `:approval`
  # entry it writes, then the `{:tool_approval, call}` event — and a host
  # attached late may hear either first, so both list it and only the first
  # to arrive says anything.
  def event(conversation, {:tool_approval, call}) when is_map(call),
    do: parked(conversation, approval(call))

  def event(
        conversation,
        {:entry, %{type: :approval, payload: %{"kind" => "approval", "status" => "pending"} = p}}
      ),
      do: parked(conversation, approval(p))

  # The decision, whoever made it: this host, another one on the same
  # session, or the timeout. The tool result that follows says what became
  # of the call; this only stops waiting on it.
  def event(
        conversation,
        {:entry,
         %{type: :approval, payload: %{"kind" => "approval", "call_id" => id, "status" => status}}}
      )
      when status in ~w(allowed denied rewritten timed_out),
      do: {forget_approval(conversation, id), []}

  # A question answered from another host, or timed out: the next line typed
  # here is no longer an answer to it.
  def event(
        %__MODULE__{asking: id} = conversation,
        {:entry,
         %{type: :approval, payload: %{"kind" => "question", "call_id" => id, "status" => status}}}
      )
      when status in ~w(answered timed_out),
      do: {%{conversation | asking: nil, question: nil}, []}

  # What `Lemieux.Session.resolve_tool/3` said. The entry above clears the
  # call when the answer landed; a call that was not there to answer — taken
  # by another host, or timed out a moment ago — is cleared here and said,
  # because a host that got no error would believe it had approved something
  # it had not.
  def event(conversation, {:approval_result, id, :ok}),
    do: {forget_approval(conversation, id), []}

  def event(conversation, {:approval_result, id, {:error, :unknown_call}}),
    do:
      {forget_approval(conversation, id),
       [{:say, "#{id} is not waiting any more · it was answered elsewhere, or timed out"}]}

  # Kept rather than announced: the status line belongs after the turn's
  # output, next to the prompt, not in the middle of it.
  def event(conversation, {:context, context}),
    do: note_unmeasured(%{conversation | context: context})

  # Elixir mode is "the file tools are gone and `elixir` is here", not an exact
  # list. It was an exact list, and then delegation arrived beside `elixir` and
  # turning the mode *on* announced that it was off — a literal list cannot
  # survive the catalog gaining anything.
  def event(conversation, {:tools_changed, _previous, tools}) when is_list(tools) do
    message =
      if elixir_mode?(tools),
        do: elixir_mode_message(tools),
        else: "Elixir mode off · tools: #{Enum.join(tools, ", ")}"

    {conversation, [{:say, message}]}
  end

  def event(conversation, {:tool_access_changed, action, names, _local_tools}) do
    {conversation, [{:say, "tools #{action}: #{Enum.join(names, ", ")}"}]}
  end

  def event(conversation, {:tools_status, []}),
    do: {conversation, [{:say, "no tools are currently available"}]}

  def event(conversation, {:tools_status, statuses}) when is_list(statuses) do
    {conversation, [{:say, Enum.map_join(statuses, "\n", &tool_status/1)}]}
  end

  # What the cut cost, what it bought, and what it found. One clause rather than
  # four, because the sections and the token counts are each present or absent
  # independently. The token counts are the point of the line: an entry count
  # measures the transcript, and the reason anybody compacts is the window.
  # The event still carries a byte-apportioned projection for hosts that want
  # it. The interactive report names the last measured request and leaves the
  # next one unknown until provider usage arrives.
  def event(conversation, {:compacted, %{entries: entries} = compacted}) do
    line =
      ["  · summarised the earlier conversation (#{length(entries)} entries)"] ++
        compaction_window(compacted) ++ compaction_sections(compacted)

    usage = Map.get(compacted, :usage)
    context = Context.after_compaction(conversation.context, usage)

    conversation =
      if is_map(usage) do
        cost = Map.get(usage, "cost_usd")

        %{
          conversation
          | context: context,
            spent_usd: add_cost(conversation.spent_usd, cost),
            measured_spent_usd: add_measured(conversation.measured_spent_usd, cost),
            unmeasured_requests: unmeasured_requests(conversation.unmeasured_requests, cost)
        }
      else
        %{conversation | context: context}
      end

    {conversation, [{:say, Enum.join(line, " · ")}]}
  end

  # A host may still clear context through Session.clear/1. The session event
  # is the one line that reports it. The count
  # is what stopped being sent, not what was removed — nothing is ever removed.
  def event(conversation, {:cleared, %{entries: entries}}),
    do: {conversation, [{:say, "  · cleared #{entries} entries · still in the transcript"}]}

  # A host clear operation's synchronous half, deliberately silent when it worked: the
  # `{:cleared, …}` event above has already said so, and `/compact` printing both
  # its event and its result is a wart rather than a pattern to copy. Only failures
  # speak here, because no event is emitted for them.
  def event(conversation, {:clear_result, {:ok, _cleared}}),
    do: ready_unless_busy(conversation)

  def event(conversation, {:clear_result, {:error, :nothing_to_do}}),
    do: ready_unless_busy(conversation, [{:say, "nothing to clear"}])

  def event(conversation, {:clear_result, {:error, reason}}),
    do: ready_unless_busy(conversation, [{:say, "could not clear: #{describe(reason)}"}])

  # A model change is somebody's choice — the person's `/model` or
  # `/provider`, a provider picked in a first-run panel — so a placeholder
  # the conversation started on stops being one (`unchosen/1`).
  def event(conversation, {:model_changed, _old, model}) do
    {%{conversation | model: model, model_chosen?: true, noted_window?: false},
     [{:say, "switched to #{model}"}]}
  end

  def event(conversation, {:reasoning_effort_changed, _old, effort}) do
    {%{conversation | reasoning_effort: effort}, [{:say, "reasoning effort: #{effort}"}]}
  end

  def event(conversation, {:mcp_status, []}),
    do: {conversation, [{:say, "no MCP servers configured · /mcp add PATH"}]}

  def event(conversation, {:mcp_status, statuses}) when is_list(statuses) do
    lines =
      Enum.map_join(statuses, "\n", fn status ->
        "#{status.name} · #{status.transport} · #{status.tool_count} tools"
      end)

    {conversation, [{:say, lines}]}
  end

  def event(conversation, {:mcp_result, action, :ok}),
    do: {conversation, [{:say, "MCP #{action} complete"}]}

  def event(conversation, {:mcp_result, _action, {:error, reason}}),
    do: {conversation, [{:say, "MCP: #{describe(reason)}"}]}

  def event(conversation, {:compaction_failed, reason}),
    do: {conversation, [{:say, "  · could not summarise the conversation: #{describe(reason)}"}]}

  # The front end's half of `/reflect`, fed in before the model is asked: a
  # reflection is a turn, so a line typed while it runs is a steer. The parse
  # cannot mark the conversation busy itself, because a host policy may still
  # refuse the command between the parse and the call.
  def event(conversation, {:reflection_started, _mode}),
    do: {%{conversation | busy?: true}, []}

  def event(conversation, {:reflection_result, :ok}), do: {conversation, []}

  def event(conversation, {:reflection_result, {:error, reason}}),
    do:
      {%{conversation | busy?: false, reflecting: nil},
       [{:say, "Could not reflect: #{inspect(reason)}"}, :ready]}

  # The anchors the front end read from its own session. A session with
  # nothing a person could point at cannot carry anchored feedback, and says
  # so rather than writing a record whose anchor was invented.
  def event(%__MODULE__{feedback: {:pending, text}} = conversation, {:feedback_anchors, anchors}) do
    case Dialogue.open(anchors, text: text) do
      {:ok, dialogue} ->
        capture(conversation, {:ask, dialogue})

      {:error, :nothing_to_anchor} ->
        {%{conversation | feedback: nil},
         [{:say, "nothing to anchor feedback to yet — say something first"}, :ready]}
    end
  end

  def event(conversation, {:feedback_anchors, _anchors}), do: {conversation, []}

  def event(conversation, {:feedback_result, {:ok, id}}),
    do:
      {conversation, [{:say, "feedback #{id} captured · not part of this conversation"}, :ready]}

  def event(conversation, {:feedback_result, {:error, reason}}),
    do: {conversation, [{:say, "could not capture feedback: #{describe(reason)}"}, :ready]}

  def event(conversation, {:opportunities_result, {:ok, []}}),
    do:
      {conversation,
       [{:say, "  · no opportunities the evidence supports · nothing recorded"}, :ready]}

  def event(conversation, {:opportunities_result, {:ok, ids}}) when is_list(ids) do
    counted = if length(ids) == 1, do: "1 opportunity", else: "#{length(ids)} opportunities"
    lines = ["  · recorded #{counted} as feedback"] ++ Enum.map(ids, &"    #{&1}")

    {conversation, [{:say, Enum.join(lines, "\n")}, :ready]}
  end

  def event(conversation, {:opportunities_result, {:error, reason}}),
    do: {conversation, [{:say, "could not record opportunities: #{describe(reason)}"}, :ready]}

  def event(conversation, {:compaction_result, {:ok, %{entries: _entries}}}),
    do: ready_unless_busy(conversation)

  def event(conversation, {:compaction_result, {:error, :nothing_to_do}}),
    do: ready_unless_busy(conversation, [{:say, "nothing worth summarising yet"}])

  def event(conversation, {:compaction_result, {:error, reason}}),
    do: ready_unless_busy(conversation, [{:say, "could not summarise: #{describe(reason)}"}])

  # The synchronous half of `/refresh`, handed back by the front end. Nothing
  # to say when nothing moved: the answer to "are these still current?" being
  # yes is the quiet case, and a turn does not start.
  def event(conversation, {:refresh_result, {:ok, 0}}),
    do: ready_unless_busy(conversation, [{:say, "every attached file is current"}])

  def event(conversation, {:refresh_result, {:ok, count}}),
    do: {conversation, [{:say, "re-attached #{count} changed #{plural(count, "file")}"}]}

  def event(conversation, {:refresh_result, {:error, reason}}),
    do: ready_unless_busy(conversation, [{:say, "could not refresh: #{describe(reason)}"}])

  # A provider failure, worded by what the person can do about it. `/retry`
  # is offered only where sending the same request again could work: it
  # cannot fix a key, refill an account or shrink a conversation, and a hint
  # that says otherwise sends somebody round the same failure twice.
  def event(conversation, {:error, reason}),
    do: {conversation, [{:say, error_line(conversation, reason)}]}

  # The session is trying again on its own; the person should see that the
  # wait is deliberate and how long it is, not a screen that went quiet. A
  # retry after the answer had started says so, because the partial answer
  # stays on the screen and in the transcript, and the next one starts over.
  def event(
        conversation,
        {:provider_retry, %{attempt: attempt, max: max, delay_ms: delay} = retry}
      ) do
    kept = if Map.get(retry, :after_output) == true, do: " · the partial answer is kept", else: ""

    {conversation,
     [
       {:say,
        "#{retry_description(conversation, retry)} · " <>
          "retrying in #{retry_delay(delay)} (#{attempt}/#{max})" <> kept}
     ]}
  end

  # Said once per model, and it replaces the older note below: the session
  # now plans with a conservative window rather than none, so the sentence to
  # read is how big that window was assumed to be and how to say the real one.
  # A host that turned the fallback off (`context_window_fallback: nil`) gets
  # the other true sentence: nothing compacts on a threshold it cannot place.
  def event(conversation, {:context_window_unknown, %{} = unknown}) do
    model = Map.get(unknown, :model) || conversation.model
    fallback = Map.get(unknown, :fallback)

    assumed =
      if is_integer(fallback),
        do: "is planning as if it held #{tokens(fallback)} tokens",
        else: "will not compact on its own"

    {%{conversation | noted_window?: true}, [{:say, unknown_window(model, assumed)}]}
  end

  # Said once per model and window. A window this small loses the task, and a
  # local server loses it without an error: Ollama drops the oldest part of a
  # conversation that does not fit. Its window is the server's setting, which
  # nothing a request carries can change, so that is the fix named.
  def event(
        conversation,
        {:context_window_small, %{model: _model, window: _window, overhead: _overhead} = small}
      ),
      do: {conversation, [{:say, "  · " <> small_window(small)}]}

  # The session summarised and the next request was still over the threshold,
  # so it stopped summarising on its own for a while rather than paying for a
  # summary every few requests. Saying so is what keeps that from looking
  # like a session that forgot how to compact.
  def event(
        conversation,
        {:compaction_ineffective,
         %{input_tokens: _tokens, threshold: _threshold, retry_in: _retry_in} = ineffective}
      ),
      do:
        {conversation,
         [{:say, "  · " <> ineffective_compaction(ineffective) <> " · /compact still works"}]}

  # A person's own command, back from the session's environment: shown the
  # way a terminal would have shown it, and held for their next message.
  def event(conversation, {:shell_result, _command, {:ok, result}}) do
    conversation
    |> note_for_next(Shell.context(result))
    |> ready_unless_busy([
      {:say, Shell.display(result)},
      {:say, "  · shared with your next message"}
    ])
  end

  def event(conversation, {:shell_result, _command, {:error, message}}),
    do: ready_unless_busy(conversation, [{:say, describe(message)}])

  def event(conversation, {:diff_result, {:ok, text}}),
    do: ready_unless_busy(conversation, [{:say, text}])

  def event(conversation, {:diff_result, {:error, message}}),
    do: ready_unless_busy(conversation, [{:say, describe(message)}])

  def event(conversation, {:export_result, {:ok, path}}),
    do: ready_unless_busy(conversation, [{:say, "exported this conversation to #{path}"}])

  def event(conversation, {:export_result, {:error, reason}}),
    do: ready_unless_busy(conversation, [{:say, "could not export: #{describe(reason)}"}])

  def event(conversation, {:doctor_result, report}) when is_binary(report),
    do: ready_unless_busy(conversation, [{:say, report}])

  # What undo put back is said to the person and noted for the model: the
  # model's context still describes the edits, and a model not told they are
  # gone reasons from files that no longer exist.
  def event(conversation, {:undo_result, {:ok, report}}),
    do: undone(conversation, [report])

  def event(conversation, {:rewind_result, {:ok, reports}}) when is_list(reports),
    do: undone(conversation, reports)

  # "nothing to undo · only file changes the agent made in this session are
  # kept" used to answer here even after a command deleted a file outside a
  # git repository; it read as "the agent changed nothing". A turn that did
  # something undo cannot reverse comes back as a report that says so, which
  # leaves this for when no recorded turn is left.
  def event(conversation, {kind, {:error, :nothing_to_undo}})
      when kind in [:undo_result, :rewind_result],
      do: ready_unless_busy(conversation, [{:say, Command.Undo.nothing()}])

  def event(conversation, {kind, {:error, {:unwritable, path}}})
      when kind in [:undo_result, :rewind_result] and is_binary(path),
      do: ready_unless_busy(conversation, [{:say, Command.Undo.unwritable(path)}])

  def event(conversation, {kind, {:error, :still_recording}})
      when kind in [:undo_result, :rewind_result],
      do: ready_unless_busy(conversation, [{:say, Command.Undo.still_recording()}])

  # `/redo` answers through `:undo_result` — see `Lemieux.Conversation.Command.Redo`.
  def event(conversation, {:undo_result, {:error, :nothing_to_redo}}),
    do: ready_unless_busy(conversation, [{:say, Command.Redo.nothing()}])

  def event(conversation, {kind, {:error, reason}}) when kind in [:undo_result, :rewind_result],
    do: ready_unless_busy(conversation, [{:say, "could not undo: #{describe(reason)}"}])

  def event(conversation, {:mcp_prompts_result, {:ok, prompts}}) when is_list(prompts),
    do: ready_unless_busy(conversation, [{:say, Command.Prompts.describe(prompts)}])

  def event(conversation, {:mcp_prompts_result, {:error, reason}}),
    do:
      ready_unless_busy(conversation, [
        {:say, "could not list MCP prompts: #{describe(reason)}"}
      ])

  def event(conversation, {:mcp_prompt_result, command, {:ok, text}}),
    do: send_prompt(conversation, text, "sending /#{command}")

  def event(conversation, {:mcp_prompt_result, command, {:error, reason}}),
    do: ready_unless_busy(conversation, [{:say, "/#{command}: #{describe(reason)}"}])

  # A command's answer that is only a line — `/verify`, whose check had to
  # read the session off the host's draw loop.
  def event(conversation, {:said, text}) when is_binary(text),
    do: ready_unless_busy(conversation, [{:say, text}])

  # Remembered for later sessions, which read the file at start, and told to
  # this one now: "remember we use tabs" should not wait for a restart.
  def event(conversation, {:memory_saved, path, text}) do
    conversation
    |> note_for_next("[The person asked you to remember this from now on: #{text}]")
    |> ready_unless_busy([{:say, "remembered in #{path} · later sessions read it at start"}])
  end

  # A prompt a command wrote rather than the person: `/init`. Busy is set
  # here, when it is sent, rather than in the parse — a host policy may still
  # refuse the command after the parse, and a conversation left busy by a
  # refused command would treat every later line as a steer.
  def event(conversation, {:send_prompt, text, note}) when is_binary(text),
    do: send_prompt(conversation, text, note)

  def event(conversation, {:retry_result, :ok}), do: {%{conversation | busy?: true}, []}

  def event(conversation, {:retry_result, {:error, :busy}}),
    do: {conversation, [{:say, "it is still running"}]}

  def event(conversation, {:retry_result, {:error, :nothing_to_retry}}),
    do: {conversation, [{:say, "nothing failed, so there is nothing to retry"}]}

  def event(conversation, {:retry_result, {:error, reason}}),
    do: {conversation, [{:say, "could not retry: #{describe(reason)}"}]}

  def event(conversation, {:finished, :cancelled}),
    do: finished(conversation, [{:say, "cancelled"}], :cancelled)

  # A session that stopped itself has to say so. The transcript gets an error entry
  # either way, but nobody is reading the transcript at the moment the prompt comes
  # back — and a turn that ends early without a word is indistinguishable from one
  # that finished.
  def event(conversation, {:finished, :max_turns}),
    do: finished(conversation, [{:say, "stopped: too many turns without finishing"}], :max_turns)

  def event(conversation, {:finished, :no_progress}),
    do:
      finished(
        conversation,
        [{:say, "stopped: the last rounds asked the same thing and got the same answer"}],
        :no_progress
      )

  def event(conversation, {:finished, {:budget, %{spent: spent, estimate: estimate, cap: cap}}}),
    do:
      finished(
        conversation,
        [
          {:say,
           "stopped before the next request: #{money(spent)} spent + #{money(estimate)} estimated, " <>
             "cap #{money(cap)}"}
        ],
        :budget
      )

  def event(conversation, {:finished, stop_reason}), do: finished(conversation, [], stop_reason)

  def event(conversation, _other), do: {conversation, []}

  defp compaction_window(%{tokens: %{before: before, after: _remaining}}),
    do: ["last request #{tokens(before)} tok"]

  defp compaction_window(_compacted), do: []

  # What is still open and what has not been checked are the two numbers a
  # person reads a structured compaction for.
  defp compaction_sections(%{sections: %{} = sections}) do
    [
      "open #{length(sections.open_work)}",
      "blocked #{length(sections.dependencies)}",
      "decided #{length(sections.decisions)}",
      "unverified #{length(sections.verification_debt)}"
    ]
  end

  defp compaction_sections(_compacted), do: []

  defp elixir_mode_message(tools) do
    case tools -- ["elixir"] do
      [] -> "Elixir mode on · only the elixir tool is available"
      rest -> "Elixir mode on · the file tools are off · also: #{Enum.join(rest, ", ")}"
    end
  end

  # A reflection that asked for opportunities has a second half: the answer is a
  # JSON list that belongs in the feedback ledger, and the turn ending is the
  # only moment at which it exists. Mining is emitted before `:ready` so the
  # prompt comes back after the records are written rather than mid-write.
  defp finished(%__MODULE__{reflecting: :opportunities} = conversation, said, stop_reason) do
    {%{conversation | busy?: false, asking: nil, question: nil, approvals: [], reflecting: nil},
     said ++
       announce(conversation.context) ++
       truncated(stop_reason) ++ [:mine_opportunities, :idle]}
  end

  defp finished(conversation, said, stop_reason) do
    {%{conversation | busy?: false, asking: nil, question: nil, approvals: [], reflecting: nil},
     said ++ cut_off(stop_reason) ++ announce(conversation.context) ++ [:ready, :idle]}
  end

  # A turn the output cap ended stops mid-answer, and it used to stop without
  # a word: a long file write, or a local model repeating itself up to the
  # 16,384-token cap a direct Ollama request now carries, just ended, and
  # looked finished. The cap is the model's or the provider's, which nothing
  # typed here raises; what a person can do is ask for the rest.
  # `Lemieux.Extensions.Continuation` asks for it on its own; this is what is
  # left when the answer was cut off again with nothing done in between.
  defp cut_off(:length),
    do: [
      {:say,
       "  · the answer was cut off at the model's output limit · " <>
         "send \"continue\" to have it pick up where it stopped"}
    ]

  defp cut_off(_stop_reason), do: []

  # Only the last report of a rewind may say which turn another /undo would
  # take, or offer --force: the ones before it name a turn the next report
  # has already undone, and --force finishes only the last undo.
  defp undone(conversation, []),
    do: ready_unless_busy(conversation, [{:say, Command.Undo.nothing()}])

  defp undone(conversation, reports) do
    {earlier, [last]} = Enum.split(reports, -1)

    said =
      earlier
      |> Enum.map(&Map.merge(&1, %{next: nil, last?: false}))
      |> Kernel.++([last])
      |> Enum.map(&{:say, Command.Undo.describe(&1)})

    conversation =
      case Command.Undo.note(reports) do
        nil -> conversation
        note -> note_for_next(conversation, note)
      end

    ready_unless_busy(conversation, said)
  end

  # Mid-turn it is a steer, said as one: a second prompt cannot start under a
  # running turn, and dropping what the command produced would lose it.
  defp send_prompt(%__MODULE__{busy?: true} = conversation, text, _note),
    do: {conversation, [{:say, "a turn is running, so this goes in as a steer"}, {:steer, text}]}

  defp send_prompt(conversation, text, note) do
    {conversation, text} = carrying_context(conversation, text)
    {%{conversation | busy?: true}, [{:say, note}, {:prompt, text}]}
  end

  # A reflection that ran out of output tokens produces a half-written JSON array,
  # which parses to nothing and reads as "the evidence supported no opportunities".
  # Two live GLM runs at the default output limit did exactly that.
  defp truncated(:length),
    do: [
      {:say,
       "  · the reflection ran out of output tokens, so anything after the cut is lost · " <>
         "raise the model's max tokens and try again"}
    ]

  defp truncated(_stop_reason), do: []

  defp selected_answer(%{options: options}, line) when is_list(options) do
    with {number, ""} when number > 0 <- Integer.parse(String.trim(line)),
         option when is_map(option) <- Enum.at(options, number - 1),
         label when is_binary(label) <- Map.get(option, :label) || Map.get(option, "label") do
      label
    else
      _not_a_choice -> line
    end
  end

  defp selected_answer(_question, line), do: line

  defp format_question(%{question: question} = payload) do
    options = Map.get(payload, :options, [])
    fields = Map.get(payload, :fields) || []

    head =
      case Map.get(payload, :title) do
        title when is_binary(title) and title != "" -> "? #{title} — #{question}"
        _none -> "? #{question}"
      end

    head =
      case Map.get(payload, :diagram) do
        diagram when is_binary(diagram) -> head <> "\n" <> diagram
        _missing -> head
      end

    head = Enum.reduce(fields, head, fn field, text -> text <> "\n  " <> field_line(field) end)

    head = if payload[:instructions], do: head <> "\n" <> payload.instructions, else: head
    head = head <> question_answer_hint(payload)

    Enum.reduce(Enum.with_index(options, 1), head, &format_question_option/2)
  end

  defp question_answer_hint(%{type: "multi_select"}),
    do: "\nSelect numbers separated by commas, /none, or type your own answer."

  defp question_answer_hint(%{type: "ranking"}),
    do: "\nType every option number in priority order, separated by commas."

  defp question_answer_hint(%{type: "number"}), do: "\nType a number."
  defp question_answer_hint(%{type: "text"}), do: "\nType your answer."
  defp question_answer_hint(_payload), do: ""

  defp format_question_option({option, index}, text) do
    label = value(option, :label) || ""
    description = value(option, :description)
    detail = if is_binary(description), do: " — #{description}", else: ""
    preview = value(option, :preview)
    suffix = if is_binary(preview), do: "\n     " <> preview, else: ""
    diagram = value(option, :diagram)
    suffix = if is_binary(diagram), do: suffix <> "\n" <> diagram, else: suffix
    text <> "\n  #{index}. #{label}#{detail}" <> suffix
  end

  # One requested field of an elicitation: what it is called, what type the
  # answer is cast to, and what the server said it is for.
  defp field_line(field) when is_map(field) do
    name = value(field, :name) || "?"
    type = value(field, :type) || "string"
    line = "#{name} · #{type}"

    case value(field, :description) do
      description when is_binary(description) and description != "" ->
        line <> " — " <> description

      _none ->
        line
    end
  end

  defp field_line(_field), do: "?"

  defp parked(conversation, %{call_id: call_id} = approval) do
    if Enum.any?(conversation.approvals, &(&1.call_id == call_id)) do
      {conversation, []}
    else
      approvals = conversation.approvals ++ [approval]

      {%{conversation | approvals: approvals},
       [{:say, approval_card(approval, length(approvals))}, {:approval, approval}]}
    end
  end

  # What a person reads before deciding: the tool, enough of its arguments to
  # know what it would do, and the two answers. When it is not the only call
  # waiting, the count, because a bare `y` answers the oldest and the
  # commands are how to name another.
  defp approval_card(%{name: name, arguments: arguments}, waiting) do
    target = String.trim("#{name} #{summarise(arguments)}")
    card = "? approve #{target}? · y runs it · n [reason] refuses it"

    if waiting > 1,
      do: card <> " · #{waiting} waiting · /approve ID or /deny ID picks one",
      else: card
  end

  defp forget_approval(conversation, call_id),
    do: %{conversation | approvals: Enum.reject(conversation.approvals, &(&1.call_id == call_id))}

  # The parked call as the session's event carries it (`%{id:, name:,
  # arguments:}`, the hook's own map) or as its `:approval` entry recorded it
  # (`"call_id"` and a `"detail"` with the name and arguments), in one shape.
  defp approval(%{"call_id" => call_id, "detail" => detail}) when is_map(detail) do
    %{
      call_id: call_id,
      name: detail["name"] || "tool",
      arguments: detail["arguments"] || %{}
    }
  end

  defp approval(call) when is_map(call) do
    %{
      call_id: value(call, :id) || value(call, :call_id) || "tool",
      name: value(call, :name) || "tool",
      arguments: value(call, :arguments) || %{}
    }
  end

  defp value(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp money(nil), do: "unknown"
  defp money(amount), do: "$#{amount}"

  # Only once the window is half gone. A session that will never fill one
  # should not have a token count printed under every answer it gives, and a
  # session that is about to fill one should not have to be asked.
  defp announce(%Context{fraction: fraction} = context) when is_float(fraction) do
    if fraction >= 0.5, do: [{:say, "  " <> status(context)}], else: []
  end

  defp announce(_context), do: []

  # Said once, and only for a session that never said it itself. The session's
  # own `{:context_window_unknown, _}` comes before its first request and is
  # the accurate one: it knows whether a fallback window is being planned
  # against. This used to say the session "will not compact on its own",
  # which stopped being true when the fallback arrived — the sentence a
  # person saw while their local model compacted at a third of its window.
  defp note_unmeasured(%__MODULE__{noted_window?: true} = conversation), do: {conversation, []}

  defp note_unmeasured(%__MODULE__{context: %Context{window: nil}} = conversation),
    do: {%{conversation | noted_window?: true}, [{:say, unmeasured(conversation.model)}]}

  defp note_unmeasured(conversation), do: {%{conversation | noted_window?: true}, []}

  # A local Ollama model's window is the daemon's to say, and the session
  # learns it from the daemon once the model has loaded; a flag here would
  # only describe it, so the flag is not the advice.
  defp unknown_window("ollama:" <> _tag = model, assumed),
    do:
      "  · Ollama has not said yet what window it serves #{model} with, so this " <>
        "session #{assumed} until it does · `ollama ps` shows it once the model is loaded"

  defp unknown_window(model, assumed),
    do:
      "  · nothing publishes #{model}'s context window, so this session #{assumed} · " <>
        "pass --context-window N if you know it"

  defp unmeasured("ollama:" <> _tag = model),
    do:
      "  · Ollama has not said what window it serves #{model} with · " <>
        "`ollama ps` shows it once the model is loaded"

  defp unmeasured(model),
    do: "  · nothing publishes #{model}'s context window · pass --context-window N if you know it"

  @doc """
  What a front end says when the session reports a context window too small
  to work in (`{:context_window_small, small}`), without the transcript's
  leading mark: the window, what this session's own instructions and tools
  take of it, and the fix where the window comes from.

  Public so `lmx run` (`Lemieux.CLI.Run.activity/1`) says the sentence the
  terminal UI does: the fix for a local model is the server's setting, and
  a second copy of it is the one that would go on saying `--context-window`.
  """
  @spec small_window(small :: map()) :: String.t()
  def small_window(%{model: model, window: window, overhead: overhead} = small) do
    "#{model} has a #{thousands(window)}-token context window, and this session's own " <>
      "instructions and tools take about #{thousands(overhead)} of it, which leaves " <>
      "little room to work · " <> small_window_fix(model, small)
  end

  @doc """
  What a front end says when a summary made no room
  (`{:compaction_ineffective, info}`): how big the next request still is,
  over which threshold, and for how many requests the session leaves
  summarising alone. A front end with a way to summarise by hand says so
  after it; `lmx run` has none.
  """
  @spec ineffective_compaction(info :: map()) :: String.t()
  def ineffective_compaction(%{input_tokens: tokens, threshold: threshold, retry_in: retry_in}) do
    "summarising made no room: the next request is still about #{thousands(tokens)} tokens, " <>
      "over the #{thousands(threshold)} this session compacts at, so it will not summarise " <>
      "on its own for #{retry_in} requests"
  end

  # The app's setting as well as the variable: Ollama run as the desktop app
  # does not see a variable exported in a shell.
  defp small_window_fix("ollama:" <> _tag, _small),
    do:
      "Ollama drops what does not fit without saying so: set " <>
        "OLLAMA_CONTEXT_LENGTH=65536 (32768 at the least), or the Ollama app's " <>
        "Context length setting, then restart Ollama and check the CONTEXT column " <>
        "of `ollama ps`"

  defp small_window_fix(_model, %{source: :configured}),
    do: "if the model holds more, pass the real size with --context-window N"

  defp small_window_fix(_model, _small), do: "choose a model with a larger window"

  defp thousands(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp thousands(count), do: to_string(count)

  @doc """
  Where the session stands in its context window, in one line.

  Three numbers, each answering a different question: where the window
  stands, what the whole session has been billed for, and what it cost.
  An illustrative estimate leads while one is available so it stays visible
  on narrow terminals. The last request's own split — uncached input against cache reads against cache
  writes — used to be here too, as `cache 9.0k/0`, which said which number
  was which to nobody. It moved to `/context`, where the bands have labels
  and colours and where a reader went looking for it anyway.
  """
  @spec status(conversation :: t() | Context.t()) :: String.t()
  def status(%__MODULE__{estimated_usd: {_amount, _scale}} = conversation),
    do: [cost(conversation), status(conversation.context)] |> Enum.join(" · ")

  def status(%__MODULE__{estimate_unknown_reasons: [_ | _]} = conversation),
    do: [cost(conversation), status(conversation.context)] |> Enum.join(" · ")

  def status(%__MODULE__{context: context} = conversation) do
    [status(context), cost(conversation)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def status(%Context{} = context),
    do: "#{position(context)} · session #{tokens(Context.cumulative(context))} tok"

  # Labelled, because this used to be the status line's last segment — where a
  # bare ratio read as the window because of the three labelled numbers in
  # front of it. It is the first segment now, and `Lemieux.Context.describe/1`
  # only says the word itself for the unmeasured case.
  defp position(%Context{compacted?: true, window: nil}), do: "context ?"
  defp position(%Context{compacted?: true, window: window}), do: "context ?/#{tokens(window)}"
  defp position(%Context{measured?: false, window: nil}), do: "context 0"
  defp position(%Context{measured?: false, window: window}), do: "context 0/#{tokens(window)}"
  defp position(%Context{} = context), do: "context " <> Context.describe(context)

  @doc "Formats the current context and cost for an interactive front end."
  @spec context_report(conversation :: t()) :: String.t()
  def context_report(%__MODULE__{context: context} = conversation) do
    Context.details(context) <>
      "\n" <>
      context_cost(conversation) <>
      estimate_details(conversation)
  end

  defp context_cost(%__MODULE__{spent_usd: spent, delegated_spent_usd: delegated})
       when is_number(spent) and is_number(delegated) and delegated > 0,
       do: "  Cost             #{usd(spent)} (#{usd(delegated)} delegated)"

  defp context_cost(%__MODULE__{spent_usd: spent}) when is_number(spent),
    do: "  Cost             #{usd(spent)}"

  defp context_cost(%__MODULE__{delegated_usage?: true}),
    do: "  Cost             unmeasured (includes delegated work)"

  defp context_cost(_conversation), do: "  Cost             unmeasured"

  @doc """
  What this session has cost, as a status line and `/context` both word it.

  Public because the two of them have to agree: an unmeasured cost is the
  interesting case — one unpriced delegated request makes the whole total
  unknowable rather than merely smaller — and two copies of that rule is one
  copy that eventually says `$0.0000` instead.
  """
  @spec cost(conversation :: t()) :: String.t()
  def cost(%__MODULE__{estimated_usd: {_amount, _scale}} = conversation),
    do: estimated_cost(conversation)

  def cost(%__MODULE__{estimate_unknown_reasons: [_ | _] = reasons} = conversation) do
    unknown = "estimated cost: unknown (#{Enum.join(reasons, ", ")})"

    if conversation.measured_spent_usd > 0,
      do:
        unknown <>
          " + measured cost: #{measured_display(measured_decimal(conversation.measured_spent_usd))}",
      else: unknown
  end

  def cost(%__MODULE__{spent_usd: spent, delegated_spent_usd: delegated})
      when is_number(spent) and is_number(delegated) and delegated > 0,
      do: "#{usd(spent)} incl. #{usd(delegated)} delegated"

  def cost(%__MODULE__{spent_usd: spent}) when is_number(spent), do: usd(spent)

  def cost(%__MODULE__{delegated_usage?: true}), do: "cost unmeasured incl. delegated"

  def cost(%__MODULE__{}), do: "cost unmeasured"

  defp add_cost(total, cost) when is_number(total) and is_number(cost), do: total + cost
  defp add_cost(_total, _cost), do: nil

  defp add_measured(total, cost) when is_number(cost), do: total + cost
  defp add_measured(total, _cost), do: total

  defp unmeasured_requests(count, cost) when is_number(cost), do: count
  defp unmeasured_requests(count, _cost), do: count + 1

  defp note_estimate(conversation, %{"request_id" => id, "data" => data})
       when is_binary(id) and is_map(data) do
    if MapSet.member?(conversation.observed_request_ids, id) do
      conversation
    else
      conversation
      |> Map.put(:observed_request_ids, MapSet.put(conversation.observed_request_ids, id))
      |> record_estimate(data)
    end
  end

  defp note_estimate(conversation, _observation), do: conversation

  defp record_estimate(conversation, %{"state" => "estimated", "amount" => amount} = data) do
    case Estimate.parse(amount) do
      {:ok, parsed} ->
        current = conversation.estimated_usd || {0, 0}

        conversation
        |> Map.put(:estimated_usd, Estimate.add(current, parsed))
        |> Map.update!(:estimated_requests, &(&1 + 1))
        |> estimate_metadata(data)

      :error ->
        record_estimate(conversation, %{"state" => "unknown", "reason" => "invalid_estimate"})
    end
  end

  defp record_estimate(conversation, %{"state" => "unknown", "reason" => reason} = data)
       when is_binary(reason) do
    conversation
    |> Map.update!(:estimate_unknown_reasons, &Enum.uniq(&1 ++ [reason]))
    |> estimate_metadata(data)
  end

  defp record_estimate(conversation, _data), do: conversation

  defp estimate_metadata(conversation, data) do
    source =
      case {data["reference_provider"], data["reference_source"]} do
        {provider, reference} when is_binary(provider) and is_binary(reference) ->
          ["#{provider} / #{reference}"]

        _missing ->
          []
      end

    excludes =
      case data["excludes"] do
        values when is_list(values) -> Enum.filter(values, &is_binary/1)
        _missing -> []
      end

    %{
      conversation
      | estimate_sources: Enum.uniq(conversation.estimate_sources ++ source),
        estimate_excludes: Enum.uniq(conversation.estimate_excludes ++ excludes)
    }
  end

  defp estimated_cost(conversation) do
    estimate = "estimated cost: $" <> Estimate.format(conversation.estimated_usd)
    measured = conversation.measured_spent_usd

    cond do
      measured > 0 and complete_estimate?(conversation) ->
        measured_decimal = measured_decimal(measured)
        total = Estimate.add(conversation.estimated_usd, measured_decimal)

        estimate <>
          " + measured cost: #{measured_display(measured_decimal)}" <>
          " (≈ total cost: $#{Estimate.format(total)})"

      measured > 0 ->
        estimate <>
          " + measured cost: #{measured_display(measured_decimal(measured))} " <>
          "(≈ total cost: unknown#{unknown_suffix(conversation)})"

      complete_estimate?(conversation) ->
        estimate

      true ->
        estimate <> " + unknown estimate#{unknown_suffix(conversation)}"
    end
  end

  defp complete_estimate?(conversation),
    do:
      conversation.estimate_unknown_reasons == [] and
        conversation.estimated_requests >= conversation.unmeasured_requests

  defp unknown_suffix(%{estimate_unknown_reasons: []}), do: ""

  defp unknown_suffix(%{estimate_unknown_reasons: reasons}),
    do: ": " <> Enum.join(reasons, ", ")

  defp measured_decimal(measured) do
    {:ok, decimal} = Estimate.parse(:erlang.float_to_binary(measured / 1, decimals: 9))
    decimal
  end

  defp measured_display(decimal) do
    case decimal |> Estimate.format() |> String.split(".", parts: 2) do
      [whole] -> "$" <> whole <> ".0000"
      [whole, fraction] -> "$" <> whole <> "." <> String.pad_trailing(fraction, 4, "0")
    end
  end

  defp estimate_details(%__MODULE__{estimated_usd: nil, estimate_unknown_reasons: []}),
    do: ""

  defp estimate_details(conversation) do
    source =
      case conversation.estimate_sources do
        [] -> ""
        values -> "\n  Reference        " <> Enum.join(values, ", ")
      end

    exclusions =
      case conversation.estimate_excludes do
        [] ->
          ""

        values ->
          "\n  Excludes         " <>
            Enum.map_join(values, ", ", &String.replace(&1, "_", " "))
      end

    "\n  API equivalent   #{cost(conversation)}" <>
      source <>
      exclusions <>
      "\n  Illustrative at current catalog rates; may change when the catalog changes."
  end

  defp usd(spent), do: "$" <> :erlang.float_to_binary(spent / 1, decimals: 4)

  defp tokens(amount) when amount < 1_000, do: Integer.to_string(amount)
  defp tokens(amount) when amount < 1_000_000, do: compact(amount / 1_000) <> "k"
  defp tokens(amount), do: compact(amount / 1_000_000) <> "m"

  defp compact(amount), do: :erlang.float_to_binary(amount, decimals: 1)

  @typedoc "A host-owned decision over an already parsed command action."
  @type command_policy :: (effect() -> :allow | {:deny, String.t()}) | nil

  @doc """
  The commands, as `/help` lists them.

  `help/0` and `help/1` list the built-ins, for a caller with no conversation
  in hand; `help/2` lists what `conversation` answers to, host commands
  included. A policy filters the list the way it filters the completion
  menu, and filters the subcommand lines under `/tools` and `/mcp` the
  same way — a denied `add` is not offered and not explained.
  """
  @spec help() :: String.t()
  def help, do: help(nil)

  @spec help(conversation_or_policy :: t() | command_policy()) :: String.t()
  def help(%__MODULE__{} = conversation), do: help(conversation, nil)
  def help(command_policy), do: help_for(Builtin.all(), command_policy)

  @spec help(conversation :: t(), command_policy :: command_policy()) :: String.t()
  def help(%__MODULE__{commands: commands}, command_policy),
    do: help_for(commands, command_policy)

  defp help_for(commands, command_policy) do
    specs = Command.listed(commands, command_policy)
    listed = specs |> Enum.map(&command_help/1) |> Columns.format() |> Enum.join("\n")
    details = specs |> Enum.map(&subcommand_help(&1, command_policy)) |> Enum.reject(&is_nil/1)

    Enum.join(
      [listed | details] ++
        [
          "anything else is sent to the model. type while it works to steer it.\n" <>
            "!command runs a shell command here and shares its output with your next message."
        ],
      "\n\n"
    )
  end

  defp command_help(command), do: {"/" <> command.name, command.description}

  defp subcommand_help(%{subcommands: []}, _command_policy), do: nil

  defp subcommand_help(%{name: name, subcommands: subcommands}, command_policy) do
    case for {label, action} <- subcommands,
             command_decision(command_policy, action) == :allow,
             do: label do
      [] -> nil
      labels -> "/#{name} " <> Enum.join(labels, " | ")
    end
  end

  @doc """
  Command specs shared by help and TUI autocomplete: every command that is
  not hidden and that the policy allows, in the order help lists them.

  `commands/0` and `commands/1` describe the built-ins; `commands/2` — or
  `commands/1` given a conversation — describes what that conversation
  answers to, host commands included. Each is a
  `t:Lemieux.Conversation.Command.spec/0`, which carries the `name`,
  `aliases`, `description` and `accepts_arguments?` a menu reads. Kept free
  of widget structs so the core stays independent of the optional terminal
  dependency.
  """
  @spec commands() :: [Command.spec()]
  def commands, do: commands(nil)

  @spec commands(conversation_or_policy :: t() | command_policy()) :: [Command.spec()]
  def commands(%__MODULE__{} = conversation), do: commands(conversation, nil)
  def commands(command_policy), do: Command.listed(Builtin.all(), command_policy)

  @spec commands(conversation :: t(), command_policy :: command_policy()) :: [Command.spec()]
  def commands(%__MODULE__{commands: commands}, command_policy),
    do: Command.listed(commands, command_policy)

  @doc "Applies a TUI host's command policy, failing closed on invalid decisions."
  @spec command_decision(command_policy(), effect()) :: :allow | {:deny, String.t()}
  def command_decision(nil, _action), do: :allow

  def command_decision(command_policy, action) when is_function(command_policy, 1) do
    case command_policy.(action) do
      :allow -> :allow
      {:deny, message} when is_binary(message) and message != "" -> {:deny, message}
      _invalid -> {:deny, "the host denied this command"}
    end
  rescue
    _error -> {:deny, "the host denied this command"}
  catch
    _kind, _reason -> {:deny, "the host denied this command"}
  end

  def command_decision(_invalid_policy, _action), do: {:deny, "the host denied this command"}

  @doc """
  Whether an effect is a parsed slash command rather than ordinary
  conversation IO — the effects a host policy is asked about.

  Decided by the commands' own `actions` lists, so a command added to the
  registry is policy-checked without a table here learning its name. The
  arity-one form asks the built-ins; the arity-two form asks the
  conversation's registry, host commands included, and is the one a front
  end dispatching effects should use.
  """
  @spec command_action?(effect()) :: boolean()
  def command_action?(effect), do: Command.action?(Builtin.all(), effect)

  @spec command_action?(conversation :: t(), effect()) :: boolean()
  def command_action?(%__MODULE__{commands: commands}, effect),
    do: Command.action?(commands, effect)

  @doc """
  Turns a failure into something worth reading.

  Public because both front ends report the same failures, and because the
  two that matter — no key, no such model — are the ones a person can act on
  and `inspect/1` renders as a tuple.
  """
  @spec describe(reason :: term()) :: String.t()
  def describe({:missing_api_key, provider, hint}),
    do: "no API key for #{provider} · set #{key_variable(hint)}"

  def describe({:unknown_model, spec, hint}), do: Errors.unknown_model(spec, hint)

  def describe({:provider_unavailable, provider}),
    do: "#{provider} has no available models for this session"

  def describe({:unknown_tools, names}),
    do:
      "unknown #{plural(length(names), "tool")}: #{Enum.join(names, ", ")} · " <>
        "/tools lists available tools"

  # Each refusal says which setting produced it. "Does not authorize" alone was
  # true and useless: the commonest case is a host sharing one session between
  # people, where `elixir` is off by policy and `ask_user` is off because there is
  # nobody on the other end — two settings, neither of them the allowlist somebody
  # would check first.
  def describe({:tools_disallowed, [{_name, _reason} | _rest] = denials}) do
    Enum.join(
      [
        "this host does not authorize #{plural(length(denials), "tool")}: " <>
          Enum.map_join(denials, ", ", &elem(&1, 0))
        | Enum.map(denials, fn {name, reason} -> "  #{name} — #{denial(reason)}" end)
      ],
      "\n"
    )
  end

  def describe({:tools_disallowed, names}),
    do: "this host does not authorize #{plural(length(names), "tool")}: #{Enum.join(names, ", ")}"

  def describe(:not_found), do: "no such stored session"

  # A transcript from a build that is not this one. Nothing was cut and
  # nothing was lost — the file is exactly as it was — so what this has to
  # convey is which build to go back to, and that the session is still there.
  def describe({:unreadable, session_id, reason}),
    do:
      "session #{session_id} was written by a different version of lemieux " <>
        "and this one cannot read it (#{reason}). The transcript is intact; " <>
        "resume it with the version that wrote it."

  def describe({:ambiguous, ids}),
    do: "that name belongs to #{length(ids)} sessions: #{Enum.join(ids, ", ")}"

  # Two processes appending to one transcript would interleave it, so the
  # second is refused. What a person needs is where the other one is, and
  # what to do if it is not there any more — a lock left by a crash is the
  # case they can fix themselves.
  def describe({:session_locked, %{} = holder}) do
    pid = Map.get(holder, :os_pid)
    since = Map.get(holder, :since)
    path = Map.get(holder, :path)

    where =
      [
        if(pid, do: "pid #{pid}"),
        if(Map.get(holder, :host), do: "on #{holder.host}"),
        if(since, do: "since #{format_since(since)}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    open = if where == "", do: "open in another lmx", else: "open in another lmx (#{where})"

    case path do
      path when is_binary(path) -> "#{open}; delete #{path} if that process is gone"
      _none -> open
    end
  end

  def describe({:reasoning_effort_unsupported, model, effort, []}),
    do: "#{model} does not offer a selectable reasoning effort (asked for #{effort})"

  def describe({:reasoning_effort_unsupported, model, effort, supported}),
    do: "#{effort} is not supported by #{model}; choose #{Enum.join(supported, ", ")}"

  # A session that refuses to start writes the sentence it wants read into an
  # exception, and `DynamicSupervisor` hands that back wrapped with a stacktrace,
  # where inspecting the tuple renders a careful message as a page of hex. Only the
  # tuple is unwrapped here: the exception goes to `ProviderError.message/1` below,
  # because `Exception.message/1` would prefix provider errors with the transport
  # noise that projection exists to strip.
  def describe({%{__exception__: true} = error, stacktrace}) when is_list(stacktrace),
    do: describe(error)

  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: ProviderError.message(reason)

  # The dialogue decides; this only turns its answer into effects. A completed
  # capture clears the field before the write is asked for, so a front end
  # that fails to write cannot leave a dialogue half-open waiting on lines
  # nobody is going to type.
  defp capture(conversation, {:ask, dialogue}),
    do: {%{conversation | feedback: dialogue}, [{:say, Dialogue.question(dialogue)}, :ready]}

  defp capture(conversation, {:retry, dialogue, message}),
    do:
      {%{conversation | feedback: dialogue},
       [{:say, message}, {:say, Dialogue.question(dialogue)}, :ready]}

  defp capture(conversation, {:done, submission}),
    do: {%{conversation | feedback: nil}, [{:feedback, submission}]}

  @doc """
  Adds `:ready` to `said` unless a turn is running.

  A prompt is only worth reprinting when the conversation is actually
  waiting for a line. Mid-turn it is not, and printing one would put a
  prompt in the middle of the model's answer. Public because a command
  module's parse ends the same way — `/help` says its piece and hands the
  prompt back.
  """
  @spec ready_unless_busy(conversation :: t(), said :: [effect()]) :: {t(), [effect()]}
  def ready_unless_busy(conversation, said \\ [])

  def ready_unless_busy(%__MODULE__{busy?: true} = conversation, said),
    do: {conversation, said}

  def ready_unless_busy(conversation, said), do: {conversation, said ++ [:ready]}

  defp summarise(arguments) when is_map(arguments) and map_size(arguments) > 0 do
    arguments
    |> Map.values()
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> ""
      value -> value |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 90)
    end
  end

  defp summarise(_arguments), do: ""

  defp preview(output) when is_binary(output) do
    case String.split(output, "\n", parts: 2) do
      [line] -> String.slice(line, 0, 160)
      [line, _rest] -> String.slice(line, 0, 160) <> " …"
    end
  end

  defp preview(_output), do: ""

  defp tool_status(%{name: name, source: source, enabled?: enabled?}) do
    state = if enabled?, do: "enabled", else: "disabled"
    "#{name} · #{tool_source(source)} · #{state}"
  end

  defp tool_source(:local), do: "local"
  defp tool_source({:mcp, server}), do: "MCP #{server}"

  @doc """
  Why a host profile refused a tool, as a sentence.

  Shared with front ends, which have the same thing to explain in a different
  shape: `describe/1` renders a refusal that already happened, while a menu
  deciding not to offer a command has to say why before anybody runs it.
  """
  @spec denial(reason :: Profile.denial()) :: String.t()
  def denial(:not_allowlisted), do: "this host's allowlist does not name it"

  def denial(:default_off_shared),
    do:
      "off by default where one session is shared between people; " <>
        "the host has to name it in its allowlist to turn it on"

  def denial(:no_human_channel),
    do: "it needs a channel to a person to ask, and this host has none"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  @doc """
  What kind of provider failure a retry is waiting out, as a phrase.

  Public because the TUI's live row says it too — `provider error, retrying
  in 6s (2/2)` — and it had its own copy of these three phrases, which is
  one copy that eventually says something different.
  """
  @spec retry_kind(category :: atom() | nil) :: String.t()
  def retry_kind(:rate_limit), do: "rate limited"
  def retry_kind(:timeout), do: "the provider went quiet"
  def retry_kind(_server_or_other), do: "provider error"

  defp retry_description(conversation, retry) do
    case ProviderError.http_status(retry.reason) do
      status when is_integer(status) -> http_description(conversation, status, retry.reason)
      _no_http_response -> "#{retry_kind(retry[:category])}: #{describe(retry.reason)}"
    end
  end

  defp error_description(conversation, reason) do
    case ProviderError.http_status(reason) do
      status when is_integer(status) -> http_description(conversation, status, reason)
      _no_http_response -> describe(reason)
    end
  end

  @doc """
  A provider failure as the line a person reads, worded by what they can do
  about it.

    * No key: which variable to set, or `/provider` to switch. On a model
      nobody chose (`unchosen/1`), no vendor: that no provider key was
      found, and the ways to one — a key, or a model run locally.
    * The provider refused the key, or the account has no credit or quota:
      what to fix, and that retrying will not help — the session does not
      retry these either.
    * Rate limited: how long the provider asked for, then `/retry`.
    * The conversation no longer fits: `/compact`, then `/retry`.
    * A model specification that does not resolve: how to write one, and
      `/model` or `/provider` to pick another — never `/retry`.
    * Anything else: the error and `/retry`.

  Public because every front end reports the same failures, and a front end
  with its own copy of these sentences is the one that eventually tells
  somebody to retry a missing key.
  """
  @spec error_line(conversation :: t(), reason :: term()) :: String.t()
  def error_line(%__MODULE__{} = conversation, reason) do
    case error_kind(reason) do
      :missing_key ->
        missing_key(conversation, reason)

      :auth ->
        "#{provider_name(conversation)} refused the credentials: " <>
          "#{error_description(conversation, reason)} · check the key, or switch with " <>
          "/provider · retrying will not help"

      :billing ->
        "#{provider_name(conversation)} refused for billing or quota: " <>
          "#{error_description(conversation, reason)} · add credit or switch with " <>
          "/provider · retrying will not help"

      :rate_limit ->
        "rate limited: #{error_description(conversation, reason)} · " <>
          wait_hint(ProviderError.retry_after_ms(reason))

      :context_limit ->
        "the conversation no longer fits the model's context window: " <>
          "#{error_description(conversation, reason)} · /compact, then /retry"

      :unknown_model ->
        unknown_model(reason)

      :other ->
        "error: #{other_description(conversation, reason)} · /retry to send the request again"
    end
  end

  # A connection that never opened names the provider and the likely fix —
  # Ollama not running said only "connection refused" — as `lmx run` does
  # (`Lemieux.CLI.Errors.connection_failure/2`). No address: a gateway
  # (`--base-url`) would make the provider's own one wrong, and this
  # conversation cannot tell whether there was one.
  defp other_description(conversation, reason) do
    Errors.connection_failure(reason,
      model: conversation.model,
      base_url: :unknown,
      switch: "/model"
    ) || error_description(conversation, reason)
  end

  # On a placeholder nobody chose (`unchosen/1`), what is missing is a key for
  # any provider, so the line names none: the key examples are the first two
  # rows of `lmx`'s provider table, as `lmx run`'s keyless refusal names them
  # (`Lemieux.CLI.Models.missing_key_message/2`). A key is pasted into the
  # first-run panel, which opens again at the next start, or set before it;
  # `/provider` saves none, and switching to a vendor with no key set
  # anywhere switches to the same refusal. Ollama needs no key, and
  # `/provider ollama` switches to a model it serves. Not `/model
  # ollama:NAME`: `/model` names a model within the current provider, so on
  # the placeholder it asks for `anthropic:ollama:NAME`, which a keyless
  # sitting refused with this same missing key.
  defp missing_key(%__MODULE__{model_chosen?: false}, _reason) do
    examples =
      Models.recommended()
      |> Enum.map(& &1.env)
      |> Enum.filter(&is_binary/1)
      |> Enum.take(2)

    such_as = if examples == [], do: "", else: " such as " <> Enum.join(examples, " or ")

    "no provider key was found · start again and paste one when asked, or set one" <>
      "#{such_as} first; or run a model on this machine with Ollama: /provider ollama"
  end

  defp missing_key(_conversation, reason), do: describe(reason) <> ", or switch with /provider"

  # A model specification nothing can resolve fails the same way on every
  # retry, so the line offers the switch that fixes it and not `/retry`,
  # which it used to. No `lmx help models` either: the screen cannot tell
  # whether that is `lmx` or `mix lmx`, and `/model` lists the models here.
  defp unknown_model({:unknown_model, spec, hint}),
    do: "error: #{Errors.unknown_model(spec, hint, nil)} · /model or /provider picks another"

  defp error_kind({:missing_api_key, _provider, _hint}), do: :missing_key
  defp error_kind({:unknown_model, _spec, _hint}), do: :unknown_model

  defp error_kind(reason) do
    case account_problem(reason) do
      nil -> category_kind(ProviderError.category(reason))
      problem -> problem
    end
  end

  defp category_kind(:rate_limit), do: :rate_limit
  defp category_kind(:context_limit), do: :context_limit
  defp category_kind(_category), do: :other

  # Whether the account is at fault is `Lemieux.Provider.Error.account?/1`'s
  # call: the same one `Lemieux.Session` makes before it declines to retry, so
  # the screen and the retry policy cannot disagree about which failures a
  # retry will not fix. This used to be a second list of codes kept here, and a
  # code added to one list and not the other would have had the screen offer
  # /retry for a failure the session had already refused to retry.
  #
  # Only the sentence is chosen here. A 401 or 403 is the key or what it may
  # do; any other account failure — a 402, or an exhausted quota a provider
  # names in its code while answering 429 — is billing or quota.
  defp account_problem(reason) do
    cond do
      not ProviderError.account?(reason) -> nil
      ProviderError.http_status(reason) in [401, 403] -> :auth
      true -> :billing
    end
  end

  defp provider_name(conversation), do: ModelSpec.provider(conversation.model) || "the provider"

  defp wait_hint(ms) when is_integer(ms) and ms > 0, do: "/retry after #{retry_delay(ms)}"
  defp wait_hint(_unknown), do: "wait a moment, then /retry"

  # req_llm's hint names every place a key may come from, in its own
  # vocabulary (`:api_key option, config :req_llm, zai_coding_plan_api_key, or
  # ZAI_API_KEY env var`). The environment variable is the one a person sets.
  defp key_variable(hint) when is_binary(hint) do
    case Regex.scan(~r/\b[A-Z][A-Z0-9_]*_(?:API_KEY|KEY|TOKEN)\b/, hint) do
      [] -> hint
      matches -> matches |> List.last() |> List.first()
    end
  end

  defp key_variable(hint), do: inspect(hint)

  defp format_since(%DateTime{} = since), do: Calendar.strftime(since, "%Y-%m-%d %H:%M UTC")
  defp format_since(since) when is_binary(since), do: since
  defp format_since(since), do: inspect(since)

  # A typed HTTP status proves some service answered. Name the selected route
  # so a gateway's own backend refusal is not mistaken for a local missing key
  # or an unreachable endpoint. Keep the original reason and retry policy intact.
  defp http_description(conversation, status, reason) do
    provider = ModelSpec.provider(conversation.model) || "provider"
    "#{provider} returned HTTP #{status}: #{describe(reason)}"
  end

  defp retry_delay(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
  defp retry_delay(ms) when is_integer(ms), do: "#{Float.round(ms / 1_000, 1)}s"
  defp retry_delay(_ms), do: "a moment"
end
