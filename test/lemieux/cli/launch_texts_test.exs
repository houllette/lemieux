defmodule Lemieux.CLI.LaunchTextsTest do
  # Sentences that told a person to do something that does not work, or
  # described a rule wider or narrower than the code's.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Errors
  alias Lemieux.CLI.Help
  alias Lemieux.CLI.TUI

  defp topic(name) do
    assert {:ok, text} = Help.topic(name)
    String.replace(text, ~r/\s+/, " ")
  end

  # `/provider` switches providers and saves no key; the provider panel,
  # which opens when the terminal UI starts on a model without one, does.
  test "a missing key's sentence offers no /provider that saves one" do
    sentence = Errors.describe({:missing_api_key, "xai", "XAI_API_KEY env var"})

    assert sentence =~ "no API key for xai: set XAI_API_KEY, or choose another model with --model"
    assert sentence =~ "the terminal UI asks for a key it cannot find when it starts"
    refute sentence =~ "/provider"
  end

  describe "lmx help mcp" do
    test "names a selected plugin's servers as the fourth place, by the name they get" do
      mcp = topic("mcp")

      assert mcp =~ "MCP servers come from four places"
      assert mcp =~ "plugins a selected plugin's, named plugin_PLUGIN_SERVER"
      refute mcp =~ "three places"
    end
  end

  describe "lmx help environment" do
    # Only the installed lmx checks on its own, and `/update` still checks
    # with LMX_CHECK_UPDATES=0 (`Lemieux.TUI.Updates`).
    test "LMX_CHECK_UPDATES stops the automatic checks, not /update" do
      assert topic("environment") =~
               "LMX_CHECK_UPDATES 0 stops the installed lmx checking for a new version on its " <>
                 "own (at start, after /new and /resume, and hourly); /update still checks"
    end
  end

  # While the screen is up, a standard error that is the terminal is the
  # screen (`Lemieux.CLI.TUI.quiet_stderr/2`). Windows has no /dev/stderr to
  # tell a redirection by, so it is muted there whatever it is.
  test "lmx help environment says where the terminal UI prints log lines" do
    assert topic("environment") =~
             "also prints them on standard error, at that level, which the terminal UI does " <>
               "only when standard error is not the terminal (2> FILE), and on Windows not at all"
  end

  describe "the remembered model" do
    # Only the terminal UI's start remembers a model, and only one somebody
    # named (`Lemieux.CLI.Models.remember/2`).
    test "lmx help models says which choices are remembered and which are not" do
      models = topic("models")

      assert models =~
               "the model the terminal UI last started on because you named it (--model, " <>
                 "LMX_MODEL, the config file or an Ixway route, or /model or /provider after " <>
                 "a start that failed)"

      assert models =~ "A model chosen in a running session, or for lmx run, is not remembered"
    end

    test "lmx help options says the same of --model" do
      assert topic("options") =~
               "without one, the model the terminal UI last started on because you named it"
    end
  end

  # The terminal UI's modules are compiled only where `ex_ratatui` is
  # loaded, so a path dependency compiled before it was added has none.
  test "without the terminal UI built in, says how to build it into a path dependency" do
    assert {:error, message} = TUI.available({:error, :bad_name})

    assert message =~ ~s({:ex_ratatui, "~> 0.16"})
    assert message =~ "mix deps.compile lemieux --force"
  end

  # A repository's overlay may not describe tools; an export there says so
  # (`Lemieux.CLI.Harness.descriptions_note/3`), and so does the help.
  test "lmx help learning says what an exported overlay applies from where" do
    assert topic("learning") =~
             "Write a confirmed discovery candidate to .lmx/harness.json (prompt text only; " <>
               "tool descriptions apply from ~/.lmx/harness.json)"
  end
end
