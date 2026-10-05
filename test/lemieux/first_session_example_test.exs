defmodule Lemieux.FirstSessionExampleTest do
  # docs/first-embedded-agent.md calls `examples/first_session.exs` "the
  # checked-in version of this script". `Lemieux.TutorialTest` runs both, and
  # running is not being the same: the example kept a provider teardown the
  # tutorial had dropped — it took the scripted provider's tuple apart to stop
  # its Agent — while both still printed the same line, so nothing failed.
  # Someone who copies the tutorial and then reads the checked-in script should
  # be reading one program.
  use ExUnit.Case, async: true

  test "the checked-in first-session script is the tutorial's program, byte for byte" do
    source = File.read!("docs/first-embedded-agent.md")
    [_, code] = Regex.run(~r/<!-- executable-tutorial -->\n```elixir\n(.*?)```/s, source)

    assert File.read!("examples/first_session.exs") == code
  end
end
