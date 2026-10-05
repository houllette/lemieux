defmodule Lemieux.Session.Guard do
  @moduledoc """
  Whether the loop goes on after a round of tool calls, and how a host decides
  that itself.

  This module is two things at once, deliberately. It declares the behaviour a
  host implements to stop a session by its own rule, and it *is* the rule
  `Lemieux.Session` ships — so the contract cannot drift from the thing it
  describes, and the shipped rule is a worked example of the behaviour rather
  than a paragraph about one. `Lemieux.Compaction` and `Lemieux.Messages` are
  built the same way.

  ## What the shipped rule is, and why it is not the turn budget

  `:max_turns` is a budget, not a guard: it catches a loop eventually, having
  paid for every round on the way, and the most expensive loops look
  productive — a denied command or an identically failing test, called again
  because nothing tells the model it has been here before. So the session
  fingerprints each round by what was asked *and* what came back, and this
  module reads two rules off that record:

    * **stuck** — the same round, answer and all, three times running. Two is
      a model retrying, which is often right; three is a model that has
      stopped reading.
    * **cycling** — half or more of the last eight calls repeated an earlier
      one with the same answer. That is the alternating loop (`a, b, a, b, …`)
      which is never the same round twice, so the first rule never fires on
      it, and it is the loop a weaker model actually falls into.
      `Lemieux.Progress.repeating?/1` is the rule, shared with the check a
      delegated child gets.

  Asking twice is not the problem — re-running the tests after an edit is
  exactly right — which is why the answer is half of each test, and why a
  detector keying on the call alone would kill good work. Only after both
  rules pass does the turn budget count.

  Neither rule sees a result that says what it reports on is still in
  progress: `structured_content` whose `"status"` is `running`, `pending`,
  `queued` or `in_progress` — what `bash` answers when a background command
  is polled — or `metadata` with `"in_progress" => true`. Waiting on a test
  suite asks the same thing and hears the same answer until it finishes, and
  counting that as no progress stopped sessions for waiting. The session
  leaves such results out of the record; the turn budget still bounds a
  model that polls forever.

  ## Why it is a seam

  A host that runs a session over a long, legitimately repetitive job — a
  poller, a retry loop somebody meant — wants the repeat rules off and the
  budget on; a host paying per request wants a stricter one; a host with its
  own notion of progress wants to consult it. The rule was three lines in the
  session with a constant above them, and the only way to change it was to
  change them.

  A host passes `guard: MyApp.Guard` or `guard: {MyApp.Guard, state}` to
  `Lemieux.start_session/1`. The option is host behaviour, like `:hooks`, and
  is neither recorded nor restored. What it cannot change is the record: the
  session still fingerprints every round and keeps the window, and the view
  is built from that. The budget checks elsewhere in the loop — a stop hook
  that keeps asking for more, a steer after the model stopped — are not this
  callback's; they are the budget doing what a budget does. The session also
  enforces `:max_turns` after this callback returns `:continue`. Replacing
  the repetition detector cannot disable the host's turn ceiling. A custom
  stop retains its reason, and the shipped guard retains its existing
  no-progress precedence when both conditions hold.

  ## What the view is

  A map of what the session knows after a round has settled: the last eight
  tool results (`recent_calls`, newest last, each with `name`, `arguments`,
  `output` and `error?`), how many times the round just finished has come
  back the same (`repeats`, one for a round seen once), that round's
  fingerprint (`last_wave`), how many requests the prompt has made
  (`turns_taken`) and how many it may (`max_turns`), and the session's
  `Lemieux.Messages` module, so a stop's text follows the host's wording
  without the guard having to know what it is.

  A stop's `reason` is the atom `{:finished, reason}` carries and the run
  evidence records; `message` is written to the `:error` entry that ends the
  prompt, which a person reads and a parent session sees as a child's
  uncertainty.
  """

  @behaviour __MODULE__

  alias Lemieux.Messages
  alias Lemieux.Progress

  # Two identical rounds are a model retrying, which is often right. Three is
  # a model that has stopped reading.
  @max_repeats 3

  @typedoc "How a session guards its loop: a module implementing this behaviour, or one paired with state."
  @type t :: module() | {module(), state :: term()}

  @typedoc "What the session knows when it asks; see the module documentation."
  @type view :: %{
          recent_calls: [map()],
          repeats: non_neg_integer(),
          last_wave: term(),
          turns_taken: non_neg_integer(),
          max_turns: pos_integer(),
          messages: module()
        }

  @typedoc "Go on, or stop with the reason `:finished` carries and the text the transcript gets."
  @type decision :: :continue | {:stop, reason :: atom(), message :: String.t()}

  @doc """
  Decides, once per settled round of tool calls, whether the loop goes on.

  Called after the round's results are written and before the next request
  is built, which is the one moment the loop can stop without leaving a call
  unanswered. Not called when the model answers without calling tools: that
  turn is over, and the budgets decide what a queued steer may buy.
  """
  @callback decide(state :: term(), view :: view()) :: decision()

  @impl true
  def decide(_state, view) do
    cond do
      view.repeats >= @max_repeats ->
        {:stop, :no_progress, Messages.render(view.messages, :stuck, [view.repeats])}

      Progress.repeating?(view.recent_calls) ->
        {:stop, :no_progress,
         Messages.render(view.messages, :cycling, [length(view.recent_calls)])}

      view.turns_taken >= view.max_turns ->
        {:stop, :max_turns, Messages.render(view.messages, :turn_budget_spent, [view.max_turns])}

      true ->
        :continue
    end
  end
end
