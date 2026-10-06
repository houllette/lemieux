defmodule Lemieux.CLI.HelpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Help
  alias Lemieux.CLI.Models

  defp topic(name) do
    assert {:ok, text} = Help.topic(name)
    text
  end

  describe "lmx --help" do
    # It was 172 lines. About fifty now — not one screen of a 24-row
    # terminal, but nothing on it is there by accident (`Help.usage/0`) —
    # and a line added to it should have to move this number (`lmx update`
    # did, 2026-10).
    test "opens with the tagline, stays within 80 columns and about fifty lines" do
      usage = Help.usage()
      lines = String.split(usage, "\n")

      assert hd(lines) == "lmx — an open-source terminal coding agent, built on Lemieux"
      assert length(lines) <= 54

      for line <- lines,
          do: assert(String.length(line) <= 80, "longer than 80 columns: #{inspect(line)}")
    end

    test "lists the everyday commands before anything else, and no research commands" do
      usage = Help.usage()

      for command <- ~w(run log fork explain mcp plugin extension skills update help),
          do: assert(usage =~ "lmx #{command}")

      for research <- [
            "lmx feedback",
            "corpus promote",
            "harness verify",
            "--build-ext",
            "--quota"
          ],
          do: refute(usage =~ research)
    end

    # The owner's call: the Ixway route stays where it was, in the first
    # screen of options beside the gateway flag.
    test "keeps the routing flags in the short help" do
      usage = Help.usage()

      assert usage =~ "--router MODE"
      assert usage =~ "--ixway URL"
      assert usage =~ "LMX_IXWAY_URL and"
      assert usage =~ "--base-url URL"
    end

    test "says where the docs are, where to report a bug and where to ask" do
      usage = capture_io(fn -> CLI.run(["--help"]) end)

      assert usage =~ "Docs:      https://hexdocs.pm/lemieux"
      assert usage =~ "Issues:    https://github.com/houllette/lemieux/issues"
      assert usage =~ "Questions: https://github.com/houllette/lemieux/discussions"
    end

    test "says what Claude Code configuration lmx reads, and where the limits are" do
      usage = Help.usage()

      assert usage =~
               "lmx reads Claude Code skills, slash commands, plugins, MCP configuration and\n" <>
                 "hook settings"

      assert usage =~ "https://hexdocs.pm/lemieux/configuration.html"
    end

    test "names models the code would start on" do
      usage = Help.usage()

      for provider <- ~w(anthropic openai) do
        row = Enum.find(Models.recommended(), &(&1.provider == provider))
        assert usage =~ row.model
      end
    end
  end

  describe "topics" do
    test "every topic the footer names exists" do
      for name <- ~w(config models permissions sandbox mcp plugins skills extensions sessions
                     environment options learning) do
        assert name in Help.topics()
        assert topic(name) =~ "Usage:"
        assert Help.footer() =~ name
      end
    end

    test "options is the full flag list, research flags excepted" do
      options = topic("options")

      for flag <- ~w(--no-delegate --context-window --mcp-config --extension-dir --no-mouse
                     --sessions-dir --hooks --router --ixway --base-url --at-turn --bare) do
        assert options =~ flag
      end

      refute options =~ "--build-ext      Optional"
      assert options =~ "lmx help learning"
    end

    test "states the web tools' real defaults: on with a Brave key, fetch with search" do
      options = topic("options")

      assert options =~ "it is on whenever\n"
      assert options =~ "a Brave key is set"
      assert options =~ "On by default whenever web\n"
      assert options =~ "search is on, off otherwise"
      refute options =~ "Add an explicitly configured web-search backend"
      refute options =~ "Off by default; loopback"
    end

    test "--hooks says Claude Code settings work, and that not every field does" do
      options = topic("options")

      assert options =~ "a Claude Code settings file's \"hooks\""
      assert options =~ "not supported"
      assert options =~ "https://hexdocs.pm/lemieux/hooks.html"
    end

    test "learning holds the research commands and the builder's flags" do
      learning = topic("learning")

      for text <- [
            "lmx feedback --mine",
            "draft-case",
            "corpus promote",
            "harness export",
            "--build-ext",
            "--quota",
            "--extension-profile",
            "--standing-rule"
          ] do
        assert learning =~ text
      end

      assert learning =~ "Experimental"
    end

    test "mcp carries the OAuth flags" do
      mcp = topic("mcp")

      for flag <- ~w(--credentials --oauth-callback-port --oauth-client-id),
          do: assert(mcp =~ flag)
    end

    test "environment names the variables the code reads" do
      environment = topic("environment")

      for variable <- ~w(LMX_EXTENSIONS_DIR LMX_OAUTH_CALLBACK_PORT LMX_LOG_LEVEL LMX_HOME),
          do: assert(environment =~ variable)

      assert environment =~ "logs/lmx.log"
    end

    test "an unknown topic names the ones there are" do
      assert {:error, message} = Help.topic("nope")
      assert message =~ "options"
      assert message =~ "learning"
    end
  end

  describe "what moved out of the short help" do
    test "lmx request and the session names are in the sessions topic" do
      refute Help.usage() =~ "lmx request"

      sessions = topic("sessions")
      assert sessions =~ "lmx request SESSION ID"
      assert sessions =~ "wayne-gretzky"
    end

    test "the footer does not promise every flag in one topic" do
      refute Help.footer() =~ "every flag"
      assert Help.footer() =~ "options (more flags)"
    end
  end

  describe "COMMAND --help" do
    test "a command with a topic prints the topic" do
      assert capture_io(fn -> CLI.run(["feedback", "--help"]) end) =~ "harness learning"
      assert capture_io(fn -> CLI.run(["log", "-h"]) end) =~ "lmx log SESSION [--jsonl]"
      assert capture_io(fn -> CLI.run(["run", "--help"]) end) =~ "Common options:"
    end
  end
end
