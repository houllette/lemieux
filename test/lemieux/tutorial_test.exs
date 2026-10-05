defmodule Lemieux.TutorialTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "the published first-session script runs without a key or network" do
    assert capture_io(fn -> Code.eval_file("examples/first_session.exs") end) ==
             "Hello from Lemieux\n"
  end

  test "the copyable tutorial runs the same complete program" do
    source = File.read!("docs/first-embedded-agent.md")
    [_, code] = Regex.run(~r/<!-- executable-tutorial -->\n```elixir\n(.*?)```/s, source)
    assert capture_io(fn -> Code.eval_string(code) end) == "Hello from Lemieux\n"
  end
end
