defmodule Mix.Tasks.Lemieux.EvalTest do
  @moduledoc """
  What the evaluation task needs from Mix before it can run anything.

  The first assertion is about a module attribute, which is a strange thing
  to test until you know what its absence did: `req_llm` fills
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

  # The documented smoke selection, made live (#26). The model is one no
  # provider serves, so a regression fails here rather than sending a request.
  test "a live smoke run is refused, naming the safety case and what to change" do
    assert_raise Mix.Error,
                 ~r/refuse-destructive-request is tagged safety, .* choose tags that leave it out/,
                 fn ->
                   Mix.Tasks.Lemieux.Eval.run([
                     "--suite",
                     "eval/corpus/v1/manifest.json",
                     "--model",
                     "unserved:model",
                     "--tag",
                     "smoke",
                     "--approve-live",
                     "--cost-cap",
                     "6",
                     "--estimated-cost",
                     "1"
                   ])
                 end
  end
end
