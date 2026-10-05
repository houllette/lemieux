defmodule CaptureExtension.SignalsTest do
  use ExUnit.Case, async: true

  alias CaptureExtension.Config
  alias CaptureExtension.Signals
  alias Lemieux.Entry

  setup do
    {:ok, config} = Config.new([])
    %{config: config}
  end

  describe "verification failures" do
    test "a matching command that exited non-zero and was never rerun is a signal", %{
      config: config
    } do
      [_user, assistant, result] =
        entries = [user("fix it"), bash_call("c1", "mix test"), bash_result("c1", 1)]

      assert [signal] = Signals.detect(entries, config)
      assert signal.kind == :verification_failure
      assert signal.command == "mix test"
      assert signal.exit_status == 1
      assert signal.call_id == "c1"
      assert signal.pattern == "mix test"
      assert signal.anchor_entry_id == result.id
      assert signal.entry_ids == [assistant.id, result.id]
    end

    test "a later matching command that exited zero suppresses the signal", %{config: config} do
      entries = [
        user("fix it"),
        bash_call("c1", "mix test"),
        bash_result("c1", 1),
        bash_call("c2", "mix test test/one_test.exs"),
        bash_result("c2", 0)
      ]

      assert Signals.detect(entries, config) == []
    end

    test "the last matching result decides, even after an earlier pass", %{config: config} do
      entries = [
        user("fix it"),
        bash_call("c1", "mix test"),
        bash_result("c1", 0),
        bash_call("c2", "cd sub && mix test"),
        bash_result("c2", 2)
      ]

      assert [%{command: "cd sub && mix test", exit_status: 2}] = Signals.detect(entries, config)
    end

    test "commands that do not match the patterns are not verifications", %{config: config} do
      entries = [user("go"), bash_call("c1", "mix tests"), bash_result("c1", 1)]
      assert Signals.detect(entries, config) == []

      entries = [user("go"), bash_call("c1", "ls -la"), bash_result("c1", 1)]
      assert Signals.detect(entries, config) == []
    end

    test "patterns match whole tokens anywhere in the command", %{config: config} do
      for command <- [
            "./tests/run.sh --fast",
            "python -m pytest tests/",
            "go test ./...",
            "npm test -- --watch=false",
            "make check && make test"
          ] do
        entries = [user("go"), bash_call("c1", command), bash_result("c1", 1)]
        assert [%{command: ^command}] = Signals.detect(entries, config), command
      end
    end

    test "only tool results that exited count; a timed-out or background run is ignored", %{
      config: config
    } do
      entries = [
        user("go"),
        bash_call("c1", "mix test"),
        Entry.new(:tool_result, %{
          "call_id" => "c1",
          "name" => "bash",
          "arguments" => %{"command" => "mix test"},
          "output" => "[timed out after 1000ms]",
          "error" => false,
          "structured_content" => %{"status" => "timed_out", "timeout_ms" => 1000}
        })
      ]

      assert Signals.detect(entries, config) == []
    end

    test "tools other than bash are not verifications, whatever their arguments", %{
      config: config
    } do
      call = %{"id" => "c1", "name" => "write", "arguments" => %{"command" => "mix test"}}

      entries = [
        user("go"),
        Entry.new(:assistant, %{"tool_calls" => [call]}),
        bash_result("c1", 1)
      ]

      assert Signals.detect(entries, config) == []
    end

    test "a configured pattern list replaces the defaults", %{config: _default} do
      {:ok, config} = Config.new(verification_patterns: ["just check"])

      entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 1)]
      assert Signals.detect(entries, config) == []

      entries = [user("go"), bash_call("c1", "just check"), bash_result("c1", 1)]
      assert [%{pattern: "just check"}] = Signals.detect(entries, config)
    end
  end

  describe "corrections" do
    test "a user message after an assistant turn that starts with a correction is a signal", %{
      config: config
    } do
      [_first, _assistant, correction] =
        entries = [user("add a flag"), assistant("done"), user("No, that's the wrong file")]

      assert [signal] = Signals.detect(entries, config)
      assert signal.kind == :correction
      assert signal.text == "No, that's the wrong file"
      assert signal.pattern == "no"
      assert signal.anchor_entry_id == correction.id
      assert signal.entry_ids == [correction.id]
    end

    test "the first prompt is never a correction, even when it starts like one", %{
      config: config
    } do
      assert Signals.detect([user("revert the last commit"), assistant("ok")], config) == []
    end

    test "a prefix inside a longer word is not a correction", %{config: config} do
      for text <- ["now add tests", "nothing else, thanks", "undoubtedly right", "wrongly"] do
        assert Signals.detect([user("go"), assistant("ok"), user(text)], config) == [], text
      end
    end

    test "matching ignores case and surrounding punctuation", %{config: config} do
      for text <- ["Undo.", "  WRONG!", "That's not what I meant", "you broke the build"] do
        assert [%{kind: :correction}] =
                 Signals.detect([user("go"), assistant("ok"), user(text)], config),
               text
      end
    end

    test "every correction in the session is reported, in order", %{config: config} do
      entries = [user("go"), assistant("a"), user("wrong"), assistant("b"), user("revert that")]

      assert [%{text: "wrong"}, %{text: "revert that"}] = Signals.detect(entries, config)
    end
  end

  test "a verification failure is listed before corrections", %{config: config} do
    entries = [
      user("go"),
      assistant("running"),
      user("no, use make"),
      bash_call("c1", "make test"),
      bash_result("c1", 1)
    ]

    assert [%{kind: :verification_failure}, %{kind: :correction}] =
             Signals.detect(entries, config)
  end

  test "a clean session has no signals", %{config: config} do
    entries = [user("go"), bash_call("c1", "mix test"), bash_result("c1", 0), assistant("done")]
    assert Signals.detect(entries, config) == []
    assert Signals.detect([], config) == []
  end

  defp user(text), do: Entry.new(:user, %{"text" => text})

  defp assistant(text),
    do: Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => text}]})

  defp bash_call(id, command) do
    Entry.new(:assistant, %{
      "content" => [],
      "tool_calls" => [%{"id" => id, "name" => "bash", "arguments" => %{"command" => command}}]
    })
  end

  defp bash_result(id, exit_status) do
    Entry.new(:tool_result, %{
      "call_id" => id,
      "name" => "bash",
      "arguments" => %{},
      "output" => "[exit status #{exit_status}]",
      "error" => false,
      "structured_content" => %{"status" => "exited", "exit_status" => exit_status}
    })
  end
end
