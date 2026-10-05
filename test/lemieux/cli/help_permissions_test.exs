defmodule Lemieux.CLI.HelpPermissionsTest do
  # `lmx help permissions` described `auto` as "everything runs unasked
  # inside a sandbox", as if the mode brought a sandbox with it. It does not:
  # without `--sandbox` it is `accept_edits`, and the tools that run beside a
  # sandbox ask either way (`Lemieux.Extensions.Permissions`).
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Help

  test "auto says what it does with and without --sandbox" do
    {:ok, text} = Help.topic("permissions")
    prose = String.replace(text, ~r/\s+/, " ")

    refute prose =~ "everything runs unasked inside a sandbox"
    assert prose =~ "auto with --sandbox (lmx help sandbox), edits and commands run unasked"
    assert prose =~ "without it, like accept_edits"
    assert prose =~ "MCP, web and eval tools ask either way"
  end
end
