defmodule Lemieux.Prompt do
  @moduledoc """
  The system prompt a session gets when it is not given one.

  ## Why it is short

  A system prompt is paid for on every request of every turn, forever, and it
  competes with the conversation for the model's attention. The long ones tend
  to be long because they accumulated: a rule per incident, none ever removed,
  most of them restating something the model already does. What survives here
  is the small set of things a frontier model genuinely does differently when
  told — mostly about *this* harness's tools, which it has not seen before.

  Everything else belongs in the host's own prompt or in the repository's own
  instructions, both of which a caller supplies through `:system`.

  ## Why there is one at all

  A library that shipped no prompt would make every host write the paragraph
  about `edit` requiring a unique string, and get it subtly wrong. The tools
  are lemieux's, so their instructions are lemieux's too.

  ## The lines that earned a place

  Each rule below changes what a capable model actually does, and the
  newest ones each answer something that happened:

    * **Version control belongs to the person.** An evaluated session
      committed the working tree of the repository it ran in (2026-09-17)
      because nothing said not to: to a model, `git commit` is just the tidy
      way to finish. Pushing, resetting and discarding changes are the same
      class of act — each one outlives the session and none is the model's
      to decide.
    * **Only what was asked.** Models leave behind summaries, notes and
      scratch scripts nobody requested. The corrected discovery rerun's
      winning candidate added a rule like this one; its confirmation on a
      second model was inconclusive, so it
      is here because it costs one line, not because it was proven.
    * **Independent calls together.** A model that reads five files one per
      response pays five round trips of latency and re-sends the prefix
      five times. The session runs calls from one response concurrently when
      their tools allow it, but only if the model sends them together.
    * **Say what was checked.** The last paragraph was already there; it now
      asks for the check, not only for honesty about its absence.
    * **Finish before stopping.** A response that calls no tool ends the
      prompt, and nothing told the model so. A long task was reported
      (2026-10-07) to stop partway until somebody prompted it to go on.
      Codex's prompt carries the same instruction. It is not measured here,
      and it does not carry the fix alone — `Lemieux.Extensions.Continuation`
      is the part that does not depend on the model reading it.

  Four more came from the failures of one benchmark run of 0.9.1 on
  `openai_codex:gpt-6.1-sol` (Terminal-Bench 2.1 and a SWE-bench Verified
  sample, #37). None is a benchmark trick: each is what an engineer new to
  a repository is told on their first day. None is measured yet either;
  the issue's author offered the before-and-after run.

    * **An existing test that fails is evidence.** On
      `matplotlib__matplotlib-25479` the agent rewrote an existing
      assertion before running any test — the one assertion that would have
      shown its fix incomplete. It stays a default, with its exception
      named, because a task sometimes does change what a test should
      expect (`django__django-13933` was resolved by doing exactly that).
    * **The project's own environment.** 32 of 50 SWE-bench sessions never
      used the repository's prepared interpreter, and many installed
      packages beside it or built a fresh virtualenv: turns spent, and
      failures that only happen under the wrong Python.
    * **A deliverable works where it runs.** On Terminal-Bench
      `filter-js-from-html` the agent installed two packages for its script,
      and the program that later ran the script had neither, so every case
      failed on an import.
    * **No behaviour nobody asked for.** Three SymPy misses added
      restrictions beyond the issue, which asked, for one, to "return None
      if it cannot decide". The most speculative of the four, and folded
      into the line that was already about scope rather than given one of
      its own.
  """

  @default """
  You are a coding agent. You work in a real repository on a real machine,
  through the tools you have been given.

  Work like an engineer, not like a chat assistant:

  - Look before you change anything. Read the files you are about to edit, and
    the code around them, rather than guessing at what they contain.
  - Follow what the surrounding code already does — its naming, its structure,
    its idioms — over what you would write from scratch.
  - Prefer a small, verifiable change to a large speculative one. When there is
    a way to check your work on this machine (a test suite, a compiler, a
    linter), run it.
  - A test that already existed and now fails is evidence about your change:
    fix the code, unless the task changes what the test expects.
  - Use the project's own environment — its interpreter, virtualenv or
    toolchain — rather than a new one or the system's. What you deliver must
    work where it will run, without anything you installed only for yourself.
  - Change what the task needs and nothing more: no behaviour it did not ask
    for. Do not create files nobody asked for, such as notes, summaries or
    scratch scripts left behind.
  - When something fails, read the error. Do not retry the same call hoping for
    a different answer.
  - Leave version control to the person. Do not commit, push, reset, rebase,
    force-push or discard changes unless they ask you to.
  - Keep working until the task is done. Ending your turn hands control back
    to the person, so do not stop to report progress or to ask whether to go
    on; stop when the work is finished, or when you need something only the
    person can give, and say which.

  About the tools:

  - The tool catalog on the current request is authoritative. Use only tools
    listed there; a tool used earlier in the conversation may no longer be
    available.
  - Read each tool's description before using it. Its result may report a
    failed operation without meaning that the tool itself failed.
  - When several reads or searches do not depend on one another, make those
    calls together in one response instead of one at a time.

  Be direct. Say what you did and what you found, not what you are about to do.
  Say what you checked and how. If you could not do something, say so plainly
  and say why; do not describe work you did not perform, and do not claim a
  change is verified when nothing checked it.
  """

  @doc """
  The default system prompt.
  """
  @spec default() :: String.t()
  def default, do: @default
end
