defmodule Lemieux.Extensions.Continuation do
  @moduledoc """
  Sends the model back to work when it stops with its own plan unfinished,
  or when its answer was cut off at the output limit.

  A response without a tool call ends the prompt (`Lemieux.Turn`): the loop
  takes "I have stopped asking for things" to mean "I am done". On a long
  task a model often is not. It reports progress, says what it will do next,
  or asks whether to go on — and then the session sits idle until somebody
  types "continue". A long `lmx` task was reported (2026-10-07) to stop
  partway until it was prompted again. Its transcript was not available, but
  a scripted reproduction showed the loop ending a prompt exactly that way:
  a plan with one task in progress and one pending, a turn that said "Next
  I'll start on step 2", and a prompt that finished `:stop` with nothing to
  send it on.

  Codex answers the same failure with `/goal`: a stored objective and a
  continuation prompt at every turn boundary until the model declares the
  goal met. This needs no command, because the objective is already on the
  transcript — the plan the model keeps with `todo`
  (`Lemieux.Extensions.Planning`). Its own record of what is left is the
  test of whether it is done.

  ## When the model is sent back to its plan

  At an ordinary stop (`:stop`), when:

    * it is enabled (`:enabled`);
    * the plan has tasks still `pending` or `in_progress`;
    * the model wrote the plan during this prompt. A plan left open by an
      earlier task is not what the person is asking about now, and sending a
      model back to it after "what does this function do?" answers the wrong
      question;
    * fewer than `:max_continuations` (default 5) messages have sent it back
      during this prompt;
    * the model called a tool since the last time it was sent back.

  The last rule is the model's way to say no. The message tells it that a
  model the person asked to stop at this point, or one that is blocked or
  needs something only the person can give, should say so and stop without
  calling a tool, and that it will not be sent back again; answering that
  way ends the prompt. Arguing with a stop the model has reasons for would
  spend the allowance on nothing, and `Lemieux.Extensions.Verify` stops
  after an answer without edits for the same reason.

  The person's own "stop here" is named first, as its own sentence, because
  the hook cannot see it: the rules read the plan, not the prompt. Without
  it, live runs on `openai:gpt-5-mini` and `zai_coding_plan:glm-5.3`
  (2026-10-07) told "do only the first task, then stop" did the first task,
  stopped as asked, and were carried through the rest of the plan by a
  message that said only to go on.

  Completion is read from the plan, never from prose. A sentence like "all
  done" proves nothing and "next I'll…" is the very failure this exists for;
  a model judging every stop would cost a request at each one. Plan statuses
  are the model's report too, not proof — `Lemieux.Extensions.Goal` is the
  extension for completion a host has to verify.

  ## When an answer was cut off

  A response that reached its output-token limit ends `:length`. When it
  carried no tool call the prompt ended there, silently — a front end has
  nothing else to show — and the work stopped halfway through whatever the
  model was writing. So the model is told what happened and asked to pick
  up where it stopped, in smaller pieces if it was writing something long,
  at most `:max_output_continuations` (default 3) times a prompt and, as
  above, only when it called a tool since the last time. A model whose
  single answer cannot fit hits the limit again at once; the second time
  the prompt ends `:length` and the host says so.

  A cut-off that carried a tool call is not this extension's: the loop runs
  the call, and a call whose arguments were cut short comes back as an
  error the model reads.

  ## Never an aside

  An aside (`Lemieux.Session.aside/2`) is one request a program composed,
  and a stop hook's veto ends it as `:hook_failed`. Nobody is waiting on
  further work from it, so neither rule applies there; a reflection cut off
  at its limit must still end `:length` so its host can say so.

  ## Order

  Stop hooks run in order and the first to deny wins (`Lemieux.Hooks`).
  Applied ahead of `Lemieux.Extensions.Verify`, as `Lemieux.Extensions.coding/3`
  does, a model sent back to its plan is not first checked on half-done work;
  the check runs at the stop that leaves the plan finished, against every
  edit the prompt made.

  ## What it keeps

  Nothing in a process. The counts are read from the transcript: this
  extension's messages start with `marker/0` or `output_marker/0`, and the
  session marks every stop hook's message (`Lemieux.Transcript.stop_hook?/1`),
  so "this prompt" is everything since the person last spoke. They survive
  resume, and a cancelled turn leaves nothing half-updated. The turn budget,
  the repeat guard and the cost and request budgets still bound the work
  each message starts.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Entry
  alias Lemieux.Extensions.Planning
  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Transcript

  @marker "[lmx continue]"
  @output_marker "[lmx output limit]"

  # Enough of the open plan for the model to see what is left without a
  # 64-task plan becoming the longest message in the request.
  @listed_tasks 10

  @type t :: %__MODULE__{
          max_continuations: non_neg_integer(),
          max_output_continuations: non_neg_integer(),
          enabled: boolean()
        }

  defstruct max_continuations: 5, max_output_continuations: 3, enabled: true

  @doc """
  Options: `:max_continuations` (0–100, default 5) bounds how often one
  prompt is sent back to its plan; `:max_output_continuations` (0–10,
  default 3) how often a cut-off answer is picked up; `:enabled` (default
  true). Unknown or malformed options are an error rather than a policy
  that silently never applies.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    known = __MODULE__ |> struct() |> Map.from_struct() |> Map.keys()

    case Keyword.keys(opts) -- known do
      [] -> validate(struct(__MODULE__, opts))
      unknown -> {:error, "unknown continuation options: #{inspect(unknown)}"}
    end
  end

  defp validate(%__MODULE__{} = config) do
    Enum.find_value(
      [
        {bounded?(config.max_continuations, 100),
         "max_continuations must be an integer from 0 to 100"},
        {bounded?(config.max_output_continuations, 10),
         "max_output_continuations must be an integer from 0 to 10"},
        {is_boolean(config.enabled), "enabled must be true or false"}
      ],
      {:ok, config},
      fn
        {true, _problem} -> nil
        {false, problem} -> {:error, "continuation: " <> problem}
      end
    )
  end

  defp bounded?(value, most), do: is_integer(value) and value in 0..most

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %__MODULE__{} = config),
    do: Harness.append_hooks(harness, stop: &stop(config, &1, &2))

  @impl Lemieux.Extension
  def describe(%__MODULE__{} = config) do
    %{
      "max_continuations" => config.max_continuations,
      "max_output_continuations" => config.max_output_continuations,
      "enabled" => config.enabled
    }
  end

  @doc "The prefix of the message that sends the model back to its plan."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "The prefix of the message that picks up an answer cut off at the output limit."
  @spec output_marker() :: String.t()
  def output_marker, do: @output_marker

  @doc false
  @spec stop(config :: t(), reason :: atom(), context :: map()) :: :allow | {:deny, String.t()}
  def stop(%__MODULE__{enabled: false}, _reason, _context), do: :allow
  def stop(_config, _reason, %{aside: kind}) when not is_nil(kind), do: :allow

  # The plan is read first: most stops have nothing open, and those never
  # copy the transcript out of the session.
  def stop(%__MODULE__{} = config, :stop, %{session: session}) do
    with {:ok, %{value: plan}} <- Planning.read(session),
         [_ | _] = open <- open_tasks(plan),
         run = current_run(session),
         true <- planned?(run),
         used = count(run, @marker),
         true <- used < config.max_continuations,
         true <- worked_since?(run, @marker) do
      {:deny, plan_message(open, used + 1, config.max_continuations)}
    else
      _ordinary_stop -> :allow
    end
  end

  def stop(%__MODULE__{} = config, :length, %{session: session}) do
    run = current_run(session)
    used = count(run, @output_marker)

    if used < config.max_output_continuations and worked_since?(run, @output_marker),
      do: {:deny, output_message(used + 1, config.max_output_continuations)},
      else: :allow
  end

  def stop(_config, _reason, _context), do: :allow

  defp open_tasks(plan) do
    plan
    |> Planning.tasks()
    |> Enum.filter(&(&1["status"] in ["pending", "in_progress"]))
  end

  # Everything since the person last spoke. A stop hook's message — this
  # extension's, or Verify's — is the harness speaking, so the run goes on
  # through it.
  defp current_run(session) do
    %{entries: entries} = Session.snapshot(session, :timer.seconds(30))

    entries
    |> Enum.reverse()
    |> Enum.take_while(&(not prompt?(&1)))
    |> Enum.reverse()
  end

  defp prompt?(%Entry{type: :user} = entry), do: not Transcript.stop_hook?(entry)
  defp prompt?(_entry), do: false

  defp planned?(run) do
    namespace = Planning.namespace()

    Enum.any?(
      run,
      &match?(%Entry{type: :extension_state, payload: %{"namespace" => ^namespace}}, &1)
    )
  end

  defp count(run, marker), do: Enum.count(run, &ours?(&1, marker))

  defp ours?(%Entry{type: :user, payload: %{"text" => text}} = entry, marker)
       when is_binary(text),
       do: Transcript.stop_hook?(entry) and String.starts_with?(text, marker)

  defp ours?(_entry, _marker), do: false

  # True the first time; afterwards only if a tool ran after the last
  # message with this marker.
  defp worked_since?(run, marker) do
    run
    |> Enum.reverse()
    |> Enum.take_while(&(not ours?(&1, marker)))
    |> then(fn since ->
      length(since) == length(run) or Enum.any?(since, &match?(%Entry{type: :tool_result}, &1))
    end)
  end

  defp plan_message(open, attempt, allowance) do
    {listed, rest} = Enum.split(open, @listed_tasks)
    lines = Enum.map(listed, &"- #{&1["id"]} [#{&1["status"]}] #{&1["title"]}")
    lines = if rest == [], do: lines, else: lines ++ ["- and #{length(rest)} more"]

    """
    #{@marker} You ended your turn, but your plan still has open tasks:
    #{Enum.join(lines, "\n")}
    If the person asked you to stop at this point, say so in a sentence and end your turn \
    without calling a tool. Otherwise ending your turn hands control back to the person, so go \
    on with the next task now and keep the plan current as you work: mark a task completed when \
    it is done, and take off the plan anything no longer needed. If you are blocked, or need \
    something only the person can give, say so in a sentence or two and end your turn without \
    calling a tool. Either way you will not be sent back again. \
    (Continuation #{attempt} of #{allowance}.)\
    """
  end

  defp output_message(attempt, allowance) do
    "#{@output_marker} Your last response reached the output-token limit and was cut off: " <>
      "nothing after the cut arrived, and no tool call in it ran. Continue from where it " <>
      "stopped. If you were writing something long, such as a whole file, split it into " <>
      "smaller tool calls. (Continuation #{attempt} of #{allowance}.)"
  end
end
