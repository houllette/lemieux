defmodule Lemieux.CLI.TUIModelSpecTest do
  @moduledoc """
  A model specification nothing can resolve is refused before the terminal
  UI opens, as `lmx run` refuses it, and a session that meets one anyway is
  never told to `/retry`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.TUI
  alias Lemieux.Conversation

  describe "before the screen opens" do
    test "a bare model name is a usage error with lmx run's sentence" do
      stderr =
        capture_io(:stderr, fn ->
          assert TUI.main(["--config", "none", "--model", "gpt-4o"], program: "mix lmx") ==
                   {:error, 2}
        end)

      assert stderr =~ "gpt-4o is not a model specification: write PROVIDER:MODEL"
      assert stderr =~ "(mix lmx help models)"
    end

    test "a provider nobody knows is named" do
      stderr =
        capture_io(:stderr, fn ->
          assert TUI.main(["--config", "none", "--model", "nosuch:model"]) == {:error, 2}
        end)

      assert stderr =~ "names a provider lmx does not know (nosuch)"
    end
  end

  describe "the error line" do
    test "offers /model and /provider, not /retry, and names no shell command" do
      conversation = Conversation.new(model: "gpt-4o")

      for hint <- [:invalid_format, :unknown_provider] do
        line = Conversation.error_line(conversation, {:unknown_model, "gpt-4o", hint})

        assert line =~ "/model or /provider picks another"
        refute line =~ "/retry"
        refute line =~ "help models"
      end
    end
  end
end
