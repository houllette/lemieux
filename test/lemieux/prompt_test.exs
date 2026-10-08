defmodule Lemieux.PromptTest do
  use ExUnit.Case, async: true

  alias Lemieux.Prompt

  test "the default prompt defers to the live catalog instead of promising named tools" do
    prompt = Prompt.default()

    assert prompt =~ "tool catalog on the current request is authoritative"
    refute prompt =~ "`bash`"
    refute prompt =~ "`read`"
  end

  # Line breaks are layout; the rules are the words.
  defp prose, do: Prompt.default() |> String.split() |> Enum.join(" ")

  test "the default prompt leaves version control to the person" do
    assert prose() =~ "Leave version control to the person"
    assert prose() =~ "Do not commit, push, reset, rebase, force-push or discard changes"
  end

  test "the default prompt asks for independent calls together and no unrequested files" do
    assert prose() =~ "make those calls together in one response"
    assert prose() =~ "Do not create files nobody asked for"
  end

  test "the default prompt says that ending a turn hands control back" do
    assert prose() =~ "Keep working until the task is done"
    assert prose() =~ "Ending your turn hands control back to the person"
  end

  # Four gaps the 0.9.1 benchmark failures showed (#37): an existing assertion
  # rewritten before any test ran, sessions that pip-installed beside the
  # project's prepared interpreter, a script whose packages the program that
  # ran it did not have, and fixes that added behaviour nobody asked for.
  test "the default prompt treats a failing existing test as evidence, by default" do
    assert prose() =~ "A test that already existed and now fails is evidence about your change"
    assert prose() =~ "unless the task changes what the test expects"
  end

  test "the default prompt keeps work in the project's own environment" do
    assert prose() =~ "Use the project's own environment"
    assert prose() =~ "What you deliver must work where it will run"
  end

  test "the default prompt asks for no behaviour the task did not ask for" do
    assert prose() =~
             "Change what the task needs and nothing more: no behaviour it did not ask for"
  end

  test "the default prompt stays short enough to pay for on every request" do
    assert byte_size(Prompt.default()) < 2_500
  end
end
