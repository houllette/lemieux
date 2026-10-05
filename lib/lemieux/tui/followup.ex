defmodule Lemieux.TUI.Followup do
  @moduledoc """
  Guesses what a person is likely to type next, from what the turn just did.

  The guess is local. A model call would read better — it has the transcript
  and this has four counters — but it would also bill somebody for a sentence
  they may never accept, put a request between the answer landing and the
  input becoming usable, and send the transcript somewhere on a keystroke
  nobody pressed. A hint is not worth any of those, so this reads the turn's
  own tool activity instead and stays a pure function over it. Being pure is
  also what lets it be tested without a provider, for the same reason
  `Lemieux.Conversation` is.

  The rules are deliberately few, and `nil` is the ordinary answer. A wrong
  hint is one more thing to read and dismiss on every turn, so anything this
  is not fairly confident about it declines to say, and the input keeps its
  usual placeholder.

  ## Replacing the guess

  This module is the behaviour and the shipped implementation at once, the
  way `Lemieux.TUI.Status` is: the contract is `c:suggest/1`, and the
  clauses below are what `lmx` ships, so the two cannot drift. A host passes
  `followups: MyApp.Followup` to `Lemieux.TUI.start_link/1` and gets the
  same `t:signals/0` this reads. What it may not change is how the signals
  are gathered — `called/2` and `returned/2` stay here — because that is the
  part that keeps paths and commands out of the input box, and a host that
  wanted them there would be asking for the leak this shape exists to
  prevent.
  """

  @doc """
  What to offer as the next prompt, or `nil` to offer nothing.

  Called between turns with the finished turn's signals, only when the input
  box is empty. The string is placed in the box when Tab is pressed, so it
  should read as something a person would type.
  """
  @callback suggest(signals :: signals()) :: String.t() | nil

  @behaviour __MODULE__

  @typedoc """
  What one turn did, accumulated as its tool calls and results arrive.

  Counters rather than the arguments themselves: the hint only needs to know
  *that* a file changed or a command failed, and keeping the text out means no
  path or command can leak into the input box by accident.

    * `:edits` — files written or edited.
    * `:commands` — shell commands run.
    * `:failures` — tool calls that came back as errors.
    * `:reads` — files read and searches made.
    * `:last` — the kind of the most recent call, which is the only ordering
      kept. Counts alone cannot tell a command that verified an edit from one
      that went looking for where to make it, and those want opposite hints.
  """
  @type signals :: %{
          edits: non_neg_integer(),
          commands: non_neg_integer(),
          failures: non_neg_integer(),
          reads: non_neg_integer(),
          last: :edit | :command | :read | nil
        }

  @empty %{edits: 0, commands: 0, failures: 0, reads: 0, last: nil}

  @doc "Signals for a turn that has done nothing yet."
  @spec empty() :: signals()
  def empty, do: @empty

  @doc """
  The module a sitting guesses with, given what the host asked for.

  `nil` is this module, so every caller can hold "whatever was configured"
  in one field without a second one saying whether anything was.
  """
  @spec module(configured :: module() | nil) :: module()
  def module(nil), do: __MODULE__
  def module(configured) when is_atom(configured), do: configured

  @doc """
  Folds one tool call into a turn's signals.

  Counted when the call is announced rather than when it returns, so a turn
  cancelled part-way still reflects what it had started.
  """
  @spec called(signals :: signals(), name :: String.t()) :: signals()
  def called(signals, name) when name in ["edit", "write"],
    do: %{signals | edits: signals.edits + 1, last: :edit}

  def called(signals, "bash"),
    do: %{signals | commands: signals.commands + 1, last: :command}

  def called(signals, name) when name in ["read", "web_search"],
    do: %{signals | reads: signals.reads + 1, last: :read}

  def called(signals, _name), do: signals

  @doc "Folds one tool result into a turn's signals."
  @spec returned(signals :: signals(), error? :: boolean()) :: signals()
  def returned(signals, true), do: %{signals | failures: signals.failures + 1}
  def returned(signals, _error?), do: signals

  @doc """
  What to offer as the next prompt, or `nil` to offer nothing.

  Ordered by how close the thing is to the person's hand: something that
  failed is already on screen, a change nothing has run yet is the check they
  were about to ask for, and a change that was checked is finished work.

  A turn that only read code offers nothing. It used to offer "make the
  change", and the README's own first prompt — "explain the main entry
  points. Do not change files." — was answered by reading files, so the
  input box suggested the one thing the person had just ruled out. Reading
  says what the model needed, not what the person wants next: a question, a
  plan and a change are all as likely, and the usual placeholder already
  invites any of them.
  """
  @impl __MODULE__
  @spec suggest(signals :: signals()) :: String.t() | nil
  def suggest(%{failures: failures}) when failures > 0, do: "fix what failed and try again"

  # Nothing has run since the file changed — whatever ran before it was
  # looking for where to change, not checking that the change holds.
  def suggest(%{edits: edits, last: :edit}) when edits > 0, do: "run the tests"

  def suggest(%{edits: edits, commands: 0}) when edits > 0, do: "run the tests"

  def suggest(%{edits: edits}) when edits > 0, do: "commit this"

  def suggest(_signals), do: nil
end
