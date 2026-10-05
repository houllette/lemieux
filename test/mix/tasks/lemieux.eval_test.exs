defmodule Mix.Tasks.Lemieux.EvalTest do
  @moduledoc """
  What the evaluation task needs from Mix before it can run anything.

  There is one assertion here and it is about a module attribute, which is a
  strange thing to test until you know what its absence did: `req_llm` fills
  its provider registry — a `:persistent_term` — when the application starts,
  and a Mix task that does not ask for `app.start` runs against a compiled but
  unstarted application. Every live model then resolved to
  `Unknown provider: openai` before a single request was built, so `--model`
  had never once worked.

  Nothing caught it because the only thing anybody runs here is the recorded
  corpus, and a fixture replay makes no provider call. `--approve-live` was a
  gate in front of a path that could not run, and the nightly was green the
  whole time.
  """

  use ExUnit.Case, async: true

  test "the task starts the application, so provider registration has happened" do
    assert "app.start" in Mix.Task.requirements(Mix.Tasks.Lemieux.Eval)
  end
end
