defmodule Lemieux.Messages do
  @moduledoc """
  The words the loop puts in front of the model, and how a host replaces them.

  This module is two things at once, on purpose. It declares the contract a
  host implements to say these things its own way, and it *is* the wording
  `Lemieux.Session` ships — so the contract cannot drift from the copy it
  describes, and the default is a worked example of the behaviour rather than
  a paragraph about one. `Lemieux.TUI.Status` is built the same way, for the
  same reason.

  ## What these strings are

  A session writes about a dozen English sentences of its own into the
  conversation: what a tool result says when nobody approved the call in
  time, what stands in for a result the tool never reported, what a re-attached
  file is introduced with, what the catalog notice says when the tools change.
  The model reads most of them as tool results or system entries and acts on
  them, which is why they were never `Logger` calls — a result that says
  "denied" is a fact the model has to work around, and how it is worded
  changes what it does next.

  A few are read by a person instead. The budget stop and the three
  loop-stop messages go into an `:error` entry, which the provider adapter
  never sends, so they are what a transcript says about why the work ended;
  a parent session sees a child's as an uncertainty in its result.

  ## Why they are replaceable

  They were literals in `Lemieux.Session`, and a host that wanted the model
  told something else — a tool denial that names the policy that denied it,
  a timeout that says who to ask, another language — had no way in but a
  fork. Every other opinion in the loop is a `{module, state}` a host can
  swap; the copy is the last one that was not.

  A host passes `messages: MyApp.Messages` to `Lemieux.start_session/1`.
  Implement only the sentences you want to change; omitted callbacks use
  this module's defaults. A module must implement at least one callback, so
  a misspelled module or an unrelated module fails at session start. The option
  is host behaviour, like `:hooks`, and is neither recorded in the transcript
  nor restored from one: a resumed session says what the host resuming it
  says.

  ## What a replacement should keep true

  Each callback receives the facts the sentence is about — a timeout in
  milliseconds, a budget payload, a call — and returns a string. Nothing else
  is promised, and a replacement that returns an empty string gets an empty
  tool result, which the model reads as the tool having said nothing. The
  useful invariant is the one the defaults keep: say what happened, so the
  model can decide, rather than what to do about it.
  """

  @behaviour __MODULE__

  @typedoc "A tool call as the session holds it: its id, name and arguments."
  @type call :: %{id: String.t(), name: String.t(), arguments: map()}

  @typedoc """
  Why a request or a tool call was refused under a budget.

  `:kind` is `:requests` when the request allowance ran out; otherwise the
  cost gate stopped it, with the measured spend so far, the estimate for what
  was about to run, and the cap. `spent` is `nil` when earlier spend could
  not be measured, `estimate` when the next step could not be priced.
  `:model` names the model the stopped request was for, when the session
  knows it; a tool call refused under the cap carries none.
  """
  @type budget :: %{
          optional(:kind) => :requests,
          optional(:model) => String.t(),
          spent: number() | nil,
          estimate: number() | nil,
          cap: number()
        }

  @doc """
  The system entry written when the tool catalog changes between turns.

  Tool calls from earlier turns remain in the provider conversation, so merely
  changing the request's catalog leaves a model free to infer that an old name
  is still callable. This entry makes the new boundary explicit, and is
  replayed on resume like the calls whose availability it corrects. `names`
  is the catalog now in force, and may be empty.
  """
  @callback tools_changed(names :: [String.t()]) :: String.t()

  @doc "The denial a parked tool call becomes when nobody approved it in time."
  @callback approval_timed_out(timeout_ms :: pos_integer()) :: String.t()

  @doc "The answer a tool's question gets when nobody answered it in time."
  @callback question_timed_out(timeout_ms :: pos_integer()) :: String.t()

  @doc "Why a provider request was not sent: the `:error` entry that ends the prompt."
  @callback budget_stopped(payload :: budget()) :: String.t()

  @doc "The tool result a call gets when its declared cost would exceed the cap."
  @callback tool_budget_denied(payload :: budget()) :: String.t()

  @doc "Why the loop stopped at its turn budget."
  @callback turn_budget_spent(max_turns :: pos_integer()) :: String.t()

  @doc """
  Why the loop stopped: `repeats` consecutive rounds asked for the same thing
  and got the same answer.
  """
  @callback stuck(repeats :: pos_integer()) :: String.t()

  @doc """
  Why the loop stopped: most of the last `calls` tool calls repeated an
  earlier one, answer and all — the alternating loop identical rounds never
  catch.
  """
  @callback cycling(calls :: non_neg_integer()) :: String.t()

  @doc "The tool result a call gets during an aside (see `Lemieux.Session.aside/2`), where no tool may run."
  @callback aside_denied(call :: call()) :: String.t()

  @doc """
  The tool result written on resume for a call the previous session never
  answered. `Lemieux.Tool.Receipt` decides whether the model is told the
  outcome is unknown; this is the text it frames.
  """
  @callback lost_call(call :: call()) :: String.t()

  @doc "The tool result for a call whose task died. `reason` is the exit reason."
  @callback tool_crashed(call :: call(), reason :: term()) :: String.t()

  @doc "The tool result for a call stopped at its deadline."
  @callback tool_timed_out(call :: call(), timeout_ms :: pos_integer()) :: String.t()

  @doc "The tool result written for a call still running when the turn was cancelled."
  @callback tool_cancelled(call :: call()) :: String.t()

  @doc """
  The prompt `Lemieux.Session.refresh/1` submits ahead of files that changed
  since they were attached. `paths` are the files re-attached with it.
  """
  @callback attachments_refreshed(paths :: [String.t()]) :: String.t()

  @doc "Why a compaction failed when the summariser returned no text at all."
  @callback summary_empty() :: String.t()

  @optional_callbacks tools_changed: 1,
                      approval_timed_out: 1,
                      question_timed_out: 1,
                      budget_stopped: 1,
                      tool_budget_denied: 1,
                      turn_budget_spent: 1,
                      stuck: 1,
                      cycling: 1,
                      aside_denied: 1,
                      lost_call: 1,
                      tool_crashed: 2,
                      tool_timed_out: 2,
                      tool_cancelled: 1,
                      attachments_refreshed: 1,
                      summary_empty: 0

  # Internal dispatch keeps adding default copy from becoming a new callback
  # every existing host must implement. Do not rescue the selected callback:
  # a broken override must not silently turn into different wording.
  @doc false
  @spec render(module :: module(), callback :: atom(), arguments :: [term()]) :: String.t()
  def render(module, callback, arguments) do
    target =
      if function_exported?(module, callback, length(arguments)), do: module, else: __MODULE__

    apply(target, callback, arguments)
  end

  @doc false
  @spec validate!(module :: module()) :: module()
  def validate!(module) do
    if Code.ensure_loaded?(module) and
         Enum.any?(__MODULE__.behaviour_info(:callbacks), fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      module
    else
      raise ArgumentError,
            ":messages must implement at least one Lemieux.Messages callback, got: #{inspect(module)}"
    end
  end

  @impl true
  def tools_changed([]) do
    "The available tools changed. No tools are available for subsequent work. " <>
      "Do not call tools from earlier turns."
  end

  def tools_changed(names) when is_list(names) do
    "The available tools changed. For subsequent work, use only these tools: " <>
      Enum.join(names, ", ") <>
      ". Do not call tools from earlier turns unless they are listed here."
  end

  @impl true
  def approval_timed_out(timeout_ms),
    do: "nobody approved this call within #{timeout_ms}ms, so it was not run"

  @impl true
  def question_timed_out(timeout_ms),
    do: "nobody answered within #{timeout_ms}ms. Carry on without an answer."

  @impl true
  def budget_stopped(%{kind: :requests, spent: spent, cap: cap}),
    do: "stopped before the request: #{spent} requests against a #{cap} request cap"

  def budget_stopped(%{spent: nil, cap: cap}),
    do: "stopped before the request because prior spend is unknown; cap is $#{cap}"

  # Named, because "cannot be estimated" alone reads as the model's fault: a
  # benchmark host saw every metered attempt stop this way and could not tell
  # that the gate, not the model, had ended them.
  def budget_stopped(%{estimate: nil, cap: cap, model: model}) when is_binary(model),
    do:
      "stopped before the request because its cost cannot be estimated: " <>
        "no price is known for #{model}; cap is $#{cap}"

  def budget_stopped(%{estimate: nil, cap: cap}),
    do: "stopped before the request because its cost cannot be estimated; cap is $#{cap}"

  def budget_stopped(%{spent: spent, estimate: estimate, cap: cap}),
    do: "stopped before an estimated $#{estimate} request: $#{spent} spent against a $#{cap} cap"

  @impl true
  def tool_budget_denied(%{spent: nil, cap: cap}),
    do: "denied: prior spend is unknown, so this tool cannot run under the $#{cap} cost cap"

  def tool_budget_denied(%{estimate: nil, cap: cap}),
    do: "denied: this tool's external cost is unknown under the $#{cap} cost cap"

  def tool_budget_denied(%{spent: spent, estimate: estimate, cap: cap}),
    do:
      "denied: estimated tool spend $#{estimate} after $#{spent} would exceed the $#{cap} cost cap"

  @impl true
  def turn_budget_spent(max_turns), do: "stopped after #{max_turns} turns"

  @impl true
  def stuck(repeats),
    do: "stopped after #{repeats} rounds that asked for the same thing and got the same answer"

  @impl true
  def cycling(calls) do
    "stopped because most of the last #{calls} calls repeated an earlier call " <>
      "and got the same answer"
  end

  @impl true
  def aside_denied(_call), do: "This request is read-only; tool calls are disabled."

  @impl true
  def lost_call(_call), do: "the session ended before this tool reported a result."

  @impl true
  def tool_crashed(_call, reason), do: "the tool crashed: #{Exception.format_exit(reason)}"

  @impl true
  def tool_timed_out(_call, timeout_ms),
    do: "the tool exceeded its #{timeout_ms}ms deadline and was stopped."

  @impl true
  def tool_cancelled(_call), do: "cancelled before the tool completed."

  @impl true
  def attachments_refreshed(paths) do
    "These files have changed on disk since they were attached: " <>
      Enum.join(paths, ", ") <> ". What follows is how they read now."
  end

  @impl true
  def summary_empty, do: "the summariser answered with nothing"
end
