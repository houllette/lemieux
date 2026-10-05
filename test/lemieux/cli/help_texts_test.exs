defmodule Lemieux.CLI.HelpTextsTest do
  # The help topics that describe a rule the code enforces — which variables
  # the credential scrub withholds, what the sandbox hides, how updates
  # install, what `--context-window` can and cannot change — checked against
  # that code where it can be read, so the two cannot drift apart again.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Help
  alias Lemieux.CLI.Options
  alias Lemieux.Environment.Credentials
  alias Lemieux.Environment.Sandbox

  defp topic(name) do
    assert {:ok, text} = Help.topic(name)
    text
  end

  # Joined across the help's own line breaks, so a phrase can be looked for
  # wherever the text wraps it.
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  @markers ~w(KEY TOKEN SECRET PASSWORD PASSWD)

  describe "the credential scrub" do
    test "config and mcp name every marker, and each one is a marker the scrub uses" do
      for name <- ~w(config mcp), marker <- @markers do
        assert flat(topic(name)) =~ "*#{marker}*", "lmx help #{name} does not name *#{marker}*"
        assert Credentials.sensitive?("DB_" <> marker, {:scrub, []})
      end
    end
  end

  describe "lmx help sandbox" do
    test "names every path the sandbox hides by default, as it is in the code" do
      sandbox = flat(topic("sandbox"))

      for path <- Sandbox.default_hidden("~"),
          do: assert(sandbox =~ path, "lmx help sandbox does not name #{path}")

      assert sandbox =~ "~/.lemieux"
      refute sandbox =~ "…"
    end

    test "names the places this run keeps its own state, and that file tools are covered" do
      sandbox = flat(topic("sandbox"))

      assert sandbox =~ "wherever this run keeps its config, state, sessions and MCP tokens"
      assert sandbox =~ "--config, LMX_HOME, --sessions-dir, --credentials"
      assert sandbox =~ "Hidden from commands and file tools alike, if they exist"
      assert sandbox =~ "The eval node, MCP servers, hooks and web tools run outside it"
    end

    # `Lemieux.CLI.Runtime.SecretPaths` keeps the working directory, home and
    # temporary directories in reach, and only for the run's own locations:
    # the default list and the config's "hidden" are hidden wherever they
    # are, the working directory included. Said of every path, the topic
    # promised a sandbox started in ~/.lmx/extensions/NAME would not hide
    # the directory it works in.
    test "keeps the working directory in reach only among this run's own locations" do
      sandbox = flat(topic("sandbox"))

      assert sandbox =~
               "--sessions-dir, --credentials); of those, nothing that is or holds the " <>
                 "working directory, home or a temporary directory"

      refute sandbox =~ "are hidden, and nothing that is or holds"
    end
  end

  describe "lmx help environment" do
    # The installed host installs on its own only on macOS and Linux and with
    # no extension selected (`Lmx.Update.host/1`); a source checkout never
    # does. The line used to say updates install on their own, full stop.
    test "names both update switches, that updates install only once verified, and where" do
      environment = topic("environment")

      assert environment =~ "LMX_CHECK_UPDATES     0 stops"
      assert environment =~ "LMX_AUTO_UPDATE       0 stops the installed lmx installing updates"

      assert flat(environment) =~
               "which it does only once their Ed25519 signature verifies, and not on " <>
                 "Windows or with extensions selected"
    end
  end

  describe "lmx help options" do
    test "--context-window says what it plans, and that Ollama's own window decides" do
      options = flat(topic("options"))

      assert options =~
               "How many tokens this model's window holds, for planning compaction; for " <>
                 "Ollama, the server's own window (OLLAMA_CONTEXT_LENGTH) decides what the " <>
                 "model sees"

      refute options =~ "anything served locally"
    end
  end

  describe "lmx help models" do
    test "says the model you last chose, a local model that can call tools, and its window" do
      models = flat(topic("models"))

      assert models =~ "the one you last chose"
      assert models =~ "can call tools"
      assert models =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"
      refute models =~ "the last session used"
    end
  end

  # All but the line naming where MCP tokens are kept by default: a path
  # under this machine's home (or $LMX_CREDENTIALS), as long as the machine
  # makes it — a 60-character temporary HOME failed this test — and no
  # line written here.
  test "the topics changed here fit 80 columns" do
    machine_path = Options.default_credentials()

    for name <- ~w(config models sandbox mcp environment),
        line <- String.split(topic(name), "\n"),
        not String.contains?(line, machine_path) do
      assert String.length(line) <= 80,
             "lmx help #{name}: longer than 80 columns: #{inspect(line)}"
    end
  end
end
