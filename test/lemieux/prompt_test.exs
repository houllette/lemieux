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

  test "the default prompt stays short enough to pay for on every request" do
    assert byte_size(Prompt.default()) < 2_500
  end
end
