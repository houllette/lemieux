defmodule Lemieux.CLI.RouterPromptTest do
  # `lmx "fix the bug"`: a prompt where a command goes, the way other agents'
  # commands take their first one. It used to get "unrecognised arguments"
  # and the whole usage text; it gets the two commands that would have taken
  # it, spelled the way the person can type them: `lmx run`, and the terminal
  # UI opened with it as `--prompt`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI

  defp lmx(argv, opts \\ []) do
    stdout =
      capture_io(fn ->
        stderr = capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
        send(self(), {:stderr, stderr})
      end)

    assert_received {:status, status}
    assert_received {:stderr, stderr}
    %{status: status, stdout: stdout, stderr: stderr}
  end

  test "a quoted prompt gets the run line and the terminal UI line, not the usage" do
    result = lmx(["fix the bug"])

    assert result.status == {:error, 1}
    assert result.stdout == ""
    assert result.stderr =~ ~s(lmx: "fix the bug" is not a command)

    assert result.stderr =~
             "to ask once and exit: lmx run 'fix the bug'; " <>
               "to open the terminal UI with it: lmx --prompt 'fix the bug'\n"

    refute result.stderr =~ "Usage:"
    refute result.stderr =~ "unrecognised arguments"
  end

  test "from a source checkout both lines say mix lmx" do
    result = lmx(["fix the bug"], program: "mix lmx")

    assert result.stderr =~
             "to ask once and exit: mix lmx run 'fix the bug'; " <>
               "to open the terminal UI with it: mix lmx --prompt 'fix the bug'\n"
  end

  # `-C DIR` is taken off the line before routing; both lines put it back.
  # A short directory, so the run line is repeated rather than shaped.
  test "flags after the prompt go with both lines, and -C DIR with them" do
    result = lmx(["-C", "/tmp", "fix the bug", "--model", "openai:gpt-6-sol"])

    assert result.stderr =~ "lmx run -C /tmp 'fix the bug' --model openai:gpt-6-sol;"

    assert result.stderr =~
             "with it: lmx -C /tmp --model openai:gpt-6-sol --prompt 'fix the bug'\n"
  end

  # `lmx run` joins its words into one prompt; `--prompt` takes one value.
  test "several quoted words are one --prompt" do
    result = lmx(["fix the bug", "in the parser"])

    assert result.stderr =~ "lmx run 'fix the bug' 'in the parser';"
    assert result.stderr =~ "with it: lmx --prompt 'fix the bug in the parser'\n"
  end

  # Quoted for a POSIX shell, so pasting it runs this prompt and nothing a
  # `$` or a backtick in it would have expanded to.
  test "the run line can be pasted as it reads" do
    result = lmx(["don't touch $HOME or `ls`"])

    assert result.stderr =~ ~S(lmx run 'don'\''t touch $HOME or `ls`')
  end

  # A pattern anchored with `$` also matches before a final newline, so such
  # an argument was printed bare, and the line, pasted, would run as two.
  test "an argument ending in a newline is quoted too" do
    result = lmx(["fix the bug", "--model", "openai:gpt\n"])

    assert result.stderr =~ "lmx run 'fix the bug' --model 'openai:gpt\n';"
  end

  test "a line too long to repeat is named by its shape" do
    prompt = String.duplicate("refactor everything ", 5)
    result = lmx([prompt])

    assert result.stderr =~ "to ask once and exit: lmx run [options] PROMPT"
    assert result.stderr =~ "with it: lmx [options] --prompt PROMPT\n"
    assert result.stderr =~ ~s(lmx: "refactor everything refactor everything…" is not a command)
  end

  # A single bare word is a misspelled command or a flag without its dashes
  # more often than a prompt, and the usage lists both.
  test "a single word still gets the usage, and no prompt hint" do
    result = lmx(["resume"])

    assert result.stderr =~ "unrecognised arguments: resume"
    assert result.stderr =~ "Usage:"
    refute result.stderr =~ "to ask once and exit"
  end
end
